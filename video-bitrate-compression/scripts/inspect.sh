#!/usr/bin/env bash
# 量素材：分辨率/帧率/时长/码率/bpp/元数据 flag，并给出压缩建议
set -euo pipefail

IN=${1:?用法: inspect.sh <文件> [目标体积MB ...]}
shift || true
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(50 70 100)

[ -f "$IN" ] || { echo "文件不存在: $IN" >&2; exit 1; }
P() { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" -of csv=p=0 "$IN" | head -1; }

W=$(P v:0 width); H=$(P v:0 height)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")
NB=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$IN")
FPS=$(awk -v n="$NB" -v d="$DUR" 'BEGIN{ if (d>0&&n>0) printf "%.3f", n/d; else print "?" }')
SZ=$(stat -c %s "$IN" 2>/dev/null || stat -f %z "$IN")
CODEC=$(P v:0 codec_name); PROF=$(P v:0 profile); LEV=$(P v:0 level)
TAG=$(P v:0 codec_tag_string); PIX=$(P v:0 pix_fmt)
CS=$(P v:0 color_space); CP=$(P v:0 color_primaries); CT=$(P v:0 color_transfer); CR=$(P v:0 color_range)
SAR=$(P v:0 sample_aspect_ratio)
ACODEC=$(P a:0 codec_name || true)

SRC_BPS=$(awk -v s="$SZ" -v d="$DUR" 'BEGIN{ if (d>0) printf "%d", s*8/d; else print 0 }')
SRC_BPP=$(awk -v b="$SRC_BPS" -v w="$W" -v h="$H" -v f="$FPS" 'BEGIN{ if (f>0) printf "%.4f", b/(w*h*f); else print "-" }')

echo "文件      : $IN"
echo "体积      : $((SZ/1000000)) MB  (${SZ} 字节)"
echo "画面      : ${W}x${H}  ${FPS} fps  ${DUR}s  ${NB} 帧"
echo "编码      : $CODEC $PROF level=$LEV tag=$TAG  $PIX"
echo "色彩      : range=$CR space=$CS trc=$CT prim=$CP"
echo "SAR       : ${SAR:-N/A}"
echo "音频      : ${ACODEC:-无}"
echo "源码率    : $(awk -v v="$SRC_BPS" 'BEGIN{printf "%.2f", v/1000000}') Mbps   bpp=$SRC_BPP"
echo
echo "=== 目标体积对应的码率/bpp ==="
printf "%-10s %-12s %-9s %s\n" 目标 视频码率 bpp 观感
for MB in "${TARGETS[@]}"; do
  awk -v mb="$MB" -v d="$DUR" -v w="$W" -v h="$H" -v f="$FPS" 'BEGIN{
    v = mb*1000000*8*0.92/d - 128000;
    if (v < 50000) { printf "%-10s %-12s %-9s %s\n", mb"MB", "过低", "-", "不可行"; exit }
    bpp = v/(w*h*f);
    obs = (bpp>=0.10?"透明":(bpp>=0.05?"高质量":(bpp>=0.02?"日常OK":(bpp>=0.012?"偏软":"明显糊"))));
    printf "%-10s %-12.2f %-9.4f %s\n", mb"MB", v/1000000, bpp, obs;
  }'
done
echo
echo "建议: 默认保持源编码（$CODEC）兼容性最稳；只在需要老旧设备播放时才换 H.264"
echo "命令: scripts/compress.sh -i \"$IN\" -o out.mp4 --target ${TARGETS[0]}MB"
