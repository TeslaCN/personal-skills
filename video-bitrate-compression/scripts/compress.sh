#!/usr/bin/env bash
# 视频码率压缩：保持分辨率/兼容性，把体积压到目标以内
set -euo pipefail

usage() {
  cat <<'EOF'
用法: compress.sh -i <输入> -o <输出> [选项]

  -i, --in FILE        输入文件
  -o, --out FILE       输出文件（默认 <输入>_compressed.mp4）
      --target SIZE    目标体积，如 70MB（十进制）；给了就用两遍编码精确控制
      --crf N          质量优先模式（不给 --target 时默认 22）
      --codec C        h264 | hevc | auto（默认 auto：bpp>=0.035 用 h264，否则 hevc）
      --height H       缩放到指定高度（默认保持原分辨率）
      --preset P       编码预设（默认 medium）
      --audio A        auto | copy | aac | none（默认 auto）
      --audio-kbps N   音频码率（默认 128）
      --dry-run        只打印命令

示例:
  compress.sh -i in.mp4 -o out.mp4 --target 70MB
  compress.sh -i in.mp4 -o out.mp4 --crf 20 --codec hevc
EOF
  exit "${1:-0}"
}

IN=""; OUT=""; TARGET=""; CRF=""; CODEC=auto; HEIGHT=""; PRESET=medium
AUDIO=auto; ABPS=128; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--in) IN=${2:?}; shift 2;;
    -o|--out) OUT=${2:?}; shift 2;;
    --target) TARGET=${2:?}; shift 2;;
    --crf) CRF=${2:?}; shift 2;;
    --codec) CODEC=${2:?}; shift 2;;
    --height) HEIGHT=${2:?}; shift 2;;
    --preset) PRESET=${2:?}; shift 2;;
    --audio) AUDIO=${2:?}; shift 2;;
    --audio-kbps) ABPS=${2:?}; shift 2;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage 0;;
    *) echo "未知参数: $1" >&2; usage 1;;
  esac
done

[ -n "$IN" ] || usage 1
[ -f "$IN" ] || { echo "输入不存在: $IN" >&2; exit 1; }
[ -n "$OUT" ] || OUT="${IN%.*}_compressed.mp4"

probe() { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" -of csv=p=0 "$IN" | head -1; }
to_bytes() {
  local v=$1
  case "$v" in
    *MiB) echo $(( ${v%[Mm][Ii][Bb]} * 1024 * 1024 ));;
    *MB)  echo $(( ${v%[Mm][Bb]} * 1000000 ));;
    *GB)  echo $(( ${v%[Gg][Bb]} * 1000000000 ));;
    *)    echo "$v";;
  esac
}
even() { local v=$1; if [ $((v % 2)) -ne 0 ]; then v=$((v - 1)); fi; echo "$v"; }

W=$(probe v:0 width); H=$(probe v:0 height)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")
NB=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$IN")
ACODEC=$(probe a:0 codec_name || true)
FPS=$(awk -v n="$NB" -v d="$DUR" 'BEGIN{ if (d>0 && n>0) printf "%.4f", n/d; else print "30" }')

OUTW=$W; OUTH=$H
if [ -n "$HEIGHT" ] && [ "$HEIGHT" -lt "$H" ]; then
  OUTH=$(even "$HEIGHT")
  OUTW=$(even $(( W * OUTH / H )) )
fi

VBPS=""
if [ -n "$TARGET" ]; then
  BYTES=$(to_bytes "$TARGET")
  AV=$ABPS
  [ "$AUDIO" = "none" ] && AV=0
  [ -z "$ACODEC" ] && AV=0
  VBPS=$(awk -v b="$BYTES" -v d="$DUR" -v a="$AV" 'BEGIN{ v=b*8*0.92/d - a*1000; if (v<100000) v=100000; printf "%d", v }')
fi
if [ -z "$TARGET" ] && [ -z "$CRF" ]; then CRF=22; fi

BPP=$(awk -v v="${VBPS:-0}" -v w="$OUTW" -v h="$OUTH" -v f="$FPS" 'BEGIN{ if (v>0) printf "%.4f", v/(w*h*f); else print "-" }')

SRC_CODEC=$(probe v:0 codec_name || true)
if [ "$CODEC" = "auto" ]; then
  # 默认保持与源相同的编码家族：源能播的设备，输出也能播，兼容性不会更差
  case "$SRC_CODEC" in
    hevc) CODEC=hevc;;
    h264) CODEC=h264;;
    *)    CODEC=h264;;
  esac
fi

echo "输入  : $IN"
echo "源    : ${W}x${H}  ${FPS}fps  ${DUR}s  音频=${ACODEC:-无}"
echo "输出  : ${OUTW}x${OUTH}  $([ -n "$VBPS" ] && echo "${VBPS} bps ($(awk -v v="$VBPS" 'BEGIN{printf "%.2f", v/1000000}') Mbps)" || echo "CRF $CRF")  bpp=${BPP}"
echo "编码  : $CODEC / preset=$PRESET"
[ "$BPP" != "-" ] && awk -v b="$BPP" 'BEGIN{ if (b<0.012) print "⚠ bpp<0.012，细节会明显变软；考虑 HEVC / 降帧率 / 降噪 / 放宽体积"; else if (b<0.02) print "⚠ bpp 偏低，手机观看尚可，放大可见软化" }'

# ---- 音频参数 ----
AOUT=(-an)
if [ -n "$ACODEC" ] && [ "$AUDIO" != "none" ]; then
  case "$AUDIO" in
    copy) AOUT=(-map 0:a:0 -c:a copy);;
    aac)  AOUT=(-map 0:a:0 -c:a aac -b:a "${ABPS}k");;
    auto) if [ "$ACODEC" = "aac" ]; then AOUT=(-map 0:a:0 -c:a copy); else AOUT=(-map 0:a:0 -c:a aac -b:a "${ABPS}k"); fi;;
  esac
fi

# ---- 色彩标记：源有就照抄 ----
CS=$(probe v:0 color_space); CP=$(probe v:0 color_primaries); CT=$(probe v:0 color_transfer); CR=$(probe v:0 color_range)
COLOR=()
[ -n "$CS" ] && [ "$CS" != "unknown" ] && COLOR+=(-colorspace "$CS")
[ -n "$CP" ] && [ "$CP" != "unknown" ] && COLOR+=(-color_primaries "$CP")
[ -n "$CT" ] && [ "$CT" != "unknown" ] && COLOR+=(-color_trc "$CT")
[ -n "$CR" ] && [ "$CR" != "unknown" ] && COLOR+=(-color_range "$CR")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vbc.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

VIN=(-hide_banner -y -i "$IN" -map 0:v:0)
VOPT=(-pix_fmt yuv420p "${COLOR[@]}")

run() {
  if [ "$DRY" -eq 1 ]; then printf '%q ' "$@"; echo; else "$@"; fi
}

echo ">> 编码 ($CODEC, ${PRESET})"
if [ -n "$TARGET" ]; then
  if [ "$CODEC" = "h264" ]; then
    run ffmpeg "${VIN[@]}" "${VOPT[@]}" -an -c:v libx264 -preset "$PRESET" -b:v "$VBPS" \
        -pass 1 -passlogfile "$TMP/x" -x264-params "keyint=60:min-keyint=15" -f null -
    run ffmpeg "${VIN[@]}" "${AOUT[@]}" "${VOPT[@]}" -c:v libx264 -preset "$PRESET" -b:v "$VBPS" \
        -pass 2 -passlogfile "$TMP/x" -x264-params "keyint=60:min-keyint=15" \
        -profile:v high -movflags +faststart "$OUT"
  else
    run ffmpeg "${VIN[@]}" "${VOPT[@]}" -an -c:v libx265 -preset "$PRESET" -b:v "$VBPS" \
        -x265-params "pass=1:stats=$TMP/x.log:keyint=60:min-keyint=15:log-level=error" -f null -
    run ffmpeg "${VIN[@]}" "${AOUT[@]}" "${VOPT[@]}" -c:v libx265 -preset "$PRESET" -b:v "$VBPS" \
        -x265-params "pass=2:stats=$TMP/x.log:keyint=60:min-keyint=15:log-level=error" \
        -tag:v hvc1 -movflags +faststart "$OUT"
  fi
else
  if [ "$CODEC" = "h264" ]; then
    run ffmpeg "${VIN[@]}" "${AOUT[@]}" "${VOPT[@]}" -c:v libx264 -preset "$PRESET" -crf "$CRF" \
        -x264-params "keyint=60:min-keyint=15" -profile:v high -movflags +faststart "$OUT"
  else
    run ffmpeg "${VIN[@]}" "${AOUT[@]}" "${VOPT[@]}" -c:v libx265 -preset "$PRESET" -crf "$CRF" \
        -x265-params "keyint=60:min-keyint=15:log-level=error" -tag:v hvc1 \
        -movflags +faststart "$OUT"
  fi
fi
