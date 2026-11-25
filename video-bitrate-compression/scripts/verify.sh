#!/usr/bin/env bash
# 压缩结果校验：体积/时长/分辨率/解码/兼容性 flag，可选抽帧裁切
set -euo pipefail

F=${1:?用法: verify.sh <文件> [--max-bytes 70MB] [--expect-duration 61.6] [--crop x:y:w:h:t] [--against 源文件]}
shift || true

MAX=""; EXPD=""; CROP=""; REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max-bytes) MAX=${2:?}; shift 2;;
    --expect-duration) EXPD=${2:?}; shift 2;;
    --crop) CROP=${2:?}; shift 2;;
    --against) REF=${2:?}; shift 2;;
    *) echo "未知参数: $1" >&2; exit 1;;
  esac
done
[ -f "$F" ] || { echo "文件不存在: $F" >&2; exit 1; }

P() { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" -of csv=p=0 "$F" | head -1; }
to_bytes() {
  case "$1" in
    *MiB) echo $(( ${1%[Mm][Ii][Bb]} * 1024 * 1024 ));;
    *MB)  echo $(( ${1%[Mm][Bb]} * 1000000 ));;
    *)    echo "$1";;
  esac
}

SZ=$(stat -c %s "$F" 2>/dev/null || stat -f %z "$F")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F")
W=$(P v:0 width); H=$(P v:0 height)
CODEC=$(P v:0 codec_name); PIX=$(P v:0 pix_fmt); TAG=$(P v:0 codec_tag_string)
NB=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$F")
ACODEC=$(P a:0 codec_name || true)

rc=0
printf '文件    : %s\n' "$(basename "$F")"
printf '体积    : %d MB (%d 字节)\n' $((SZ/1000000)) "$SZ"
printf '时长    : %s s   帧数: %s\n' "$DUR" "$NB"
printf '画面    : %sx%s  %s  %s\n' "$W" "$H" "$CODEC" "$PIX"
printf '音频    : %s\n' "${ACODEC:-无}"
echo "---"

if [ -n "$MAX" ]; then
  MB=$(to_bytes "$MAX")
  if [ "$SZ" -gt "$MB" ]; then echo "✗ 体积超限: $SZ > $MB"; rc=1; else echo "✓ 体积在 $MAX 内"; fi
fi
if [ -n "$EXPD" ]; then
  ok=$(awk -v a="$DUR" -v b="$EXPD" 'BEGIN{ d=a-b; if (d<0) d=-d; print (d<=0.2)?1:0 }')
  if [ "$ok" = "1" ]; then echo "✓ 时长符合 ($DUR ≈ $EXPD)"; else echo "✗ 时长偏差: $DUR vs $EXPD"; rc=1; fi
fi
[ "$PIX" != "yuv420p" ] && echo "⚠ 像素格式 $PIX，部分设备不支持，建议 -pix_fmt yuv420p"
if [ "$CODEC" = "hevc" ] && [ "$TAG" != "hvc1" ]; then echo "⚠ HEVC tag=$TAG，Apple 设备可能打不开（应 -tag:v hvc1）"; fi
awk -v w="$W" -v h="$H" 'BEGIN{ if ((w%2)||(h%2)) print "⚠ 宽高不是偶数" }'

if err=$(ffmpeg -v error -xerror -i "$F" -f null - 2>&1); then
  echo "✓ 全片解码无错误"
else
  echo "✗ 解码报错:"; printf '%s\n' "$err" | head -5; rc=1
fi

# 与源对比关键 flag，检查是否"不比源差"
if [ -n "$REF" ] && [ -f "$REF" ]; then
  echo "--- 与源对比 ---"
  for k in codec_name pix_fmt color_space color_transfer color_primaries color_range; do
    a=$(ffprobe -v error -select_streams v:0 -show_entries "stream=$k" -of csv=p=0 "$REF" | head -1)
    b=$(ffprobe -v error -select_streams v:0 -show_entries "stream=$k" -of csv=p=0 "$F" | head -1)
    [ "$a" != "$b" ] && echo "⚠ $k: 源=$a 输出=$b"
  done
  echo "(仅提示差异，色彩标记丢失会导致偏色；tag 差异见上)"
fi

if [ -n "$CROP" ]; then
  IFS=':' read -r cx cy cw ch ct <<< "$CROP"
  base=${F%.*}
  out="${base}_crop_t${ct:-5}.png"
  ffmpeg -v error -y -ss "${ct:-5}" -i "$F" -frames:v 1 \
    -vf "crop=${cw}:${ch}:${cx}:${cy},scale=$((cw*2)):-2:flags=neighbor" "$out"
  echo "已裁切: $out（最近邻放大 2 倍，用图片查看器看细节）"
fi

exit "$rc"
