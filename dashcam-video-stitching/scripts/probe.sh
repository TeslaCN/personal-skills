#!/usr/bin/env bash
# 侦察多视角素材：分辨率/帧率/时长/音轨电平，并给出推荐画布
# 用法: probe.sh <源目录>
# 环境变量: VIEWS="MAIN LEFT BACK RIGHT"  （第一个视为主视角）
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$DIR/lib.sh"

SRC=${1:?用法: probe.sh <源目录>}
[ -d "$SRC" ] || die "目录不存在: $SRC"
read -ra VIEWS <<< "${VIEWS:-MAIN LEFT BACK RIGHT}"

resolve_inputs "$SRC" "${VIEWS[@]}"
info "分组键: $GROUP_KEY"
info ""

printf '%-8s %-40s %-12s %-10s %-10s %s\n' VIEW FILE RES FPS DUR CODEC
for i in "${!FILES[@]}"; do
  f=${FILES[$i]}
  w=$(vfield "$f" width); h=$(vfield "$f" height)
  rfr=$(vfield "$f" avg_frame_rate)
  if [ "$rfr" = "0/0" ]; then rfr=$(vfield "$f" r_frame_rate); fi
  dur=$(fformat "$f" duration)
  codec=$(vfield "$f" codec_name)
  printf '%-8s %-40s %-12s %-10s %-10.3f %s\n' "${VIEWS[$i]}" "$(basename "$f")" "${w}x${h}" "$rfr" "${dur:-0}" "$codec"
done

info ""
MW=$(vfield "${FILES[0]}" width);  MH=$(vfield "${FILES[0]}" height)
SW=$(vfield "${FILES[1]}" width);  SH=$(vfield "${FILES[1]}" height)
D0=$(fformat "${FILES[0]}" duration)
D1=$(fformat "${FILES[1]}" duration)
awk -v a="$D0" -v b="$D1" 'BEGIN{ d=a-b; if (d<0) d=-d; if (d>0.2) printf "⚠ 时长不一致（差 %.3f 秒），检查是否为同一次录制\n", d; else printf "✓ 时长一致\n" }'

rf=$(vfield "${FILES[0]}" r_frame_rate); af=$(vfield "${FILES[0]}" avg_frame_rate)
if [ "$rf" != "$af" ]; then
  info "提示: 主视角疑似 VFR (r=$rf / avg=$af)，分段编码时会统一为 CFR"
fi
info "像素格式: $(vfield "${FILES[0]}" pix_fmt)"

al=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "${FILES[0]}" || true)
if [ -n "$al" ]; then
  vol=$(ffmpeg -hide_banner -nostats -ss 5 -t 5 -i "${FILES[0]}" -map 0:a:0 -af volumedetect -f null - 2>&1 \
        | awk -F: '/mean_volume/{gsub(/ /,"",$2); print $2}') || true
  info "音轨: $al  平均电平: ${vol:-未知}"
else
  info "音轨: 无（封装时可留一条静音 AAC 提高兼容性）"
fi

# ---- 推荐画布 ----
n=$(( ${#FILES[@]} - 1 ))
TILE_W=$(even $((MW / n)))
TILE_H=$(even $((TILE_W * SH / SW)))
CANVAS_H=$((MH + TILE_H))
LUMA=$((MW * CANVAS_H))

info ""
info "推荐模板 A（主视角在上，$n 路侧视角在下）："
info "  下排单块 ${TILE_W}x${TILE_H}   画布 ${MW}x${CANVAS_H}（${LUMA} 像素）"
if [ $((TILE_W * n)) -ne "$MW" ]; then
  info "  注意: 下排总宽 $((TILE_W * n)) 不等于 $MW，右侧会留窄黑边"
fi
if [ "$LUMA" -gt 8912896 ]; then
  info "  注意: 超过 HEVC level 5.1 上限(8912896)，需 level 6.0，部分手机硬解不支持"
  info "        建议另出一个高度 <=2304 的兼容版（stitch.sh 加 --scale 1348）"
fi
if [ "$CANVAS_H" -gt 2304 ]; then
  info "  注意: 画布高度 $CANVAS_H > 2304，移动端播放兼容性有风险"
fi
