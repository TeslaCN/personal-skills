#!/usr/bin/env bash
# 交付前校验：时长/帧数/体积/解码/关键帧抽取/接缝亮度
# 用法:
#   verify.sh <文件> [--expect-duration 105] [--max-bytes 70MB]
#                    [--frames 90,104] [--seam 90]
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$DIR/lib.sh"

F=${1:?用法: verify.sh <文件> [--expect-duration 105] [--max-bytes 70MB] [--frames 90,104] [--seam 90]}
shift || true
[ -f "$F" ] || die "文件不存在: $F"

EXPECT_DUR=""; MAX_BYTES=""; FRAMES=""; SEAM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-duration) EXPECT_DUR=${2:?}; shift 2;;
    --max-bytes)       MAX_BYTES=${2:?}; shift 2;;
    --frames)          FRAMES=${2:?}; shift 2;;
    --seam)            SEAM=${2:?}; shift 2;;
    *) die "未知参数: $1";;
  esac
done

rc=0
SZ=$(stat -c %s "$F" 2>/dev/null || stat -f %z "$F")
DUR=$(fformat "$F" duration)
W=$(vfield "$F" width); H=$(vfield "$F" height)
CODEC=$(vfield "$F" codec_name); LEVEL=$(vfield "$F" level)
PIX=$(vfield "$F" pix_fmt); TAG=$(vfield "$F" codec_tag_string)
NB=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$F")

printf '文件      : %s\n' "$(basename "$F")"
printf '体积      : %s 字节 (%.1f MB)\n' "$SZ" "$(awk -v v="$SZ" 'BEGIN{print v/1000000}')"
printf '时长      : %ss   视频包数: %s\n' "$DUR" "$NB"
printf '画面      : %sx%s (%s 像素)  编码: %s level=%s pix=%s tag=%s\n' \
  "$W" "$H" "$((W * H))" "$CODEC" "${LEVEL:-?}" "$PIX" "$TAG"
printf '码率      : %d kbps\n' "$(( SZ * 8 / 1000 / ${DUR%.*} ))"

echo "---"
# 体积
if [ -n "$MAX_BYTES" ]; then
  MB=$(to_bytes "$MAX_BYTES")
  if [ "$SZ" -gt "$MB" ]; then echo "✗ 体积超限: $SZ > $MB"; rc=1; else echo "✓ 体积在 $MAX_BYTES 内"; fi
fi
# 时长
if [ -n "$EXPECT_DUR" ]; then
  ok=$(awk -v a="$DUR" -v b="$EXPECT_DUR" 'BEGIN{ d=a-b; if (d<0) d=-d; print (d<=0.2)?1:0 }')
  if [ "$ok" = "1" ]; then echo "✓ 时长符合预期 ($DUR ≈ $EXPECT_DUR)"; else echo "✗ 时长不符: $DUR != $EXPECT_DUR"; rc=1; fi
fi
# 编码器兼容
if [ "$TAG" != "hvc1" ] && [ "$CODEC" = "hevc" ]; then
  echo "⚠ HEVC 的 tag 是 $TAG，Apple/QuickTime 可能打不开（建议 -tag:v hvc1）"
fi
if [ "$PIX" != "yuv420p" ]; then echo "⚠ 像素格式 $PIX，部分硬解会退回软解"; fi
if [ "$((W * H))" -gt 8912896 ]; then
  echo "⚠ 画布 $((W * H)) 像素 > level 5.1 上限，需 level 6.0；部分手机硬解不支持"
fi
if [ "$H" -gt 2304 ]; then
  echo "⚠ 高度 $H > 2304，移动端播放有风险，建议另出兼容版"
fi

# 全片解码
if err=$(ffmpeg -v error -xerror -i "$F" -f null - 2>&1); then
  echo "✓ 全片解码无错误"
else
  echo "✗ 解码报错:"; printf '%s\n' "$err" | head -10; rc=1
fi

# 关键帧抽取（1:1，便于放大看车牌）
if [ -n "$FRAMES" ]; then
  base=${F%.*}
  IFS=',' read -ra TS <<< "$FRAMES"
  for t in "${TS[@]}"; do
    out="${base}_t${t}.jpg"
    ffmpeg -v error -y -ss "$t" -i "$F" -frames:v 1 -q:v 2 "$out"
    echo "已抽取 ${t}s -> $out（建议用图片查看器放大到 100% 看细节）"
  done
fi

# 接缝亮度连续性
if [ -n "$SEAM" ]; then
  tmp=$(mktemp)
  st=$(( SEAM > 1 ? SEAM - 1 : 0 ))
  ffmpeg -v error -ss "$st" -t 2 -i "$F" \
    -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$tmp" -f null - 2>/dev/null || true
  awk -v seam="$SEAM" -F= '/YAVG/ {v=$2+0; if (n) {d=v-p; if (d<0) d=-d; if (d>m) m=d} p=v; n++; s+=v}
    END { if (!n) {print "⚠ 未取到亮度数据"; exit}
          printf "接缝 %ss 附近 %d 帧，平均 Y=%.1f，单帧最大跳变 %.1f\n", seam, n, s/n, m;
          if (m > 6) print "⚠ 跳变偏大，检查两段 CRF 差是否过大";
          else print "✓ 亮度过渡平滑" }' "$tmp"
  rm -f "$tmp"
fi

exit "$rc"
