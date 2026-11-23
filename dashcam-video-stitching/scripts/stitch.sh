#!/usr/bin/env bash
# 多视角拼接：模板 A（主视角在上，侧视角在下）
# 在体积上限内按重要程度分配码率；支持关键时段单独提质量。
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$DIR/lib.sh"

usage() {
  cat <<'EOF'
用法: stitch.sh -s <源目录> -o <输出文件> [选项]

  -s, --src DIR         素材目录（按 <前缀>_<视角>_<时间戳>.mp4 命名）
  -o, --out FILE        输出文件
  -d, --duration N      输出时长（秒，默认取主视角完整时长）
  -c, --crf N           基础 CRF（默认 30）
  -b, --boost A:D:CRF   关键段提质量：A=起始秒, D=持续秒，可重复
                        例: -b 90:15:27  表示 90s 起 15s 用 CRF 27
  -e, --encoder C       编码器（默认 libx265）
  -p, --preset P        编码预设（默认 medium）
      --scale H         画布等比缩放到高度 H（兼容版，如 1348）
      --no-audio        不封装音轨
      --budget 70MB     只做体积预算估算，不编码
      --max-bytes 70MB  结束后校验体积，超出告警并非零退出
      --keep-parts      保留分段中间文件
      --dry-run         只打印命令

环境变量:
  VIEWS="MAIN LEFT BACK RIGHT"   视角关键词，第一个是主视角
  KEY=<分组键>                    多组素材中强制指定一组
EOF
  exit "${1:-0}"
}

SRC=""; OUT=""; DUR=""; BASE_CRF=30; PRESET=medium; ENCODER=libx265
SCALE_H=""; AUDIO=1; BUDGET=""; MAX_BYTES=""; KEEP_PARTS=0; DRY_RUN=0
BOOSTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--src)       SRC=${2:?}; shift 2;;
    -o|--out)       OUT=${2:?}; shift 2;;
    -d|--duration)  DUR=${2:?}; shift 2;;
    -c|--crf)       BASE_CRF=${2:?}; shift 2;;
    -b|--boost)     BOOSTS+=("${2:?}"); shift 2;;
    -e|--encoder)   ENCODER=${2:?}; shift 2;;
    -p|--preset)    PRESET=${2:?}; shift 2;;
    --scale)        SCALE_H=${2:?}; shift 2;;
    --no-audio)     AUDIO=0; shift;;
    --budget)       BUDGET=${2:?}; shift 2;;
    --max-bytes)    MAX_BYTES=${2:?}; shift 2;;
    --keep-parts)   KEEP_PARTS=1; shift;;
    --dry-run)      DRY_RUN=1; shift;;
    -h|--help)      usage 0;;
    *) die "未知参数: $1（-h 查看帮助）";;
  esac
done

[ -n "$SRC" ] || usage 1
[ -d "$SRC" ] || die "目录不存在: $SRC"
read -ra VIEWS <<< "${VIEWS:-MAIN LEFT BACK RIGHT}"
resolve_inputs "$SRC" "${VIEWS[@]}"

n=$(( ${#FILES[@]} - 1 ))
[ "$n" -ge 1 ] || die "至少需要主视角 + 1 路侧视角"

MW=$(vfield "${FILES[0]}" width);  MH=$(vfield "${FILES[0]}" height)
SW=$(vfield "${FILES[1]}" width);  SH=$(vfield "${FILES[1]}" height)
TILE_W=$(even $((MW / n)))
TILE_H=$(even $((TILE_W * SH / SW)))
CANVAS_H=$((MH + TILE_H))

if [ -z "$DUR" ]; then
  DUR=$(fformat "${FILES[0]}" duration)
  DUR=${DUR%.*}          # 取整，避免末帧时间戳溢出
fi

# ---- 体积预算模式 ----
if [ -n "$BUDGET" ]; then
  BB=$(to_bytes "$BUDGET")
  BPS=$(( BB * 8 / DUR ))
  printf '目标体积   : %s (%d 字节)\n' "$BUDGET" "$BB"
  printf '时长       : %ss\n' "$DUR"
  printf '总码率上限 : %d kbps\n' $(( BPS / 1000 ))
  printf '音频预留   : 约 50 kbps\n'
  printf '视频可用   : 约 %d kbps\n' $(( (BPS / 1000) - 50 ))
  printf '\n对比参考（夜间 4K 场景，需按实际内容标定，见 references/encoding-budget.md）:\n'
  printf '  1080p 画布 CRF 24 ≈ 2.5 Mbps   CRF 22 ≈ 4 Mbps\n'
  printf '  4K    画布 CRF 32 ≈ 4 Mbps     CRF 30 ≈ 5.5 Mbps   CRF 27 ≈ 11 Mbps\n'
  printf '\n建议：先用 -d 15 编一小段实测，再外推。\n'
  exit 0
fi

[ -n "$OUT" ] || die "缺少 -o <输出文件>"

info "输入组 : ${GROUP_KEY}"
for i in "${!FILES[@]}"; do info "         ${VIEWS[$i]} -> $(basename "${FILES[$i]}")"; done
info "画布   : ${MW}x${CANVAS_H}（下排 ${n} 块 ${TILE_W}x${TILE_H}）"
if [ -n "$SCALE_H" ]; then info "缩放   : 高度 ${SCALE_H}（兼容版）"; fi
info "时长   : ${DUR}s   基础 CRF: ${BASE_CRF}   编码器: ${ENCODER}/${PRESET}"
if [ "${#BOOSTS[@]}" -gt 0 ]; then info "关键段 : ${BOOSTS[*]}"; fi

# ---- 构建滤镜图 ----
FILTER="[0:v]setpts=PTS-STARTPTS,format=yuv420p[m]"
for ((i=1; i<=n; i++)); do
  FILTER+=";[${i}:v]setpts=PTS-STARTPTS,scale=${TILE_W}:${TILE_H}:flags=lanczos,format=yuv420p[s${i}]"
done
LAYOUT="0_0"
for ((i=1; i<=n; i++)); do LAYOUT+="|$(( (i-1) * TILE_W ))_${MH}"; done
FILTER+=";[m]"
for ((i=1; i<=n; i++)); do FILTER+="[s${i}]"; done
FILTER+="xstack=inputs=$((n+1)):layout=${LAYOUT}:fill=black"
if [ -n "$SCALE_H" ]; then
  FILTER+=",scale=-2:${SCALE_H}:flags=lanczos,setsar=1"
fi
FILTER+="[o]"

# ---- 切段 ----
bounds=(0 "$DUR")
for b in "${BOOSTS[@]}"; do
  IFS=: read -r b_s b_d b_c <<<"$b"
  bounds+=("$b_s" "$((b_s + b_d))")
done
mapfile -t B < <(printf '%s\n' "${bounds[@]}" | sort -n | uniq)

PARTS=$(mktemp -d "${TMPDIR:-/tmp}/stitch.XXXXXX")
cleanup() {
  if [ "$KEEP_PARTS" -eq 1 ]; then
    info "分段保留在: $PARTS"
  else
    rm -rf "$PARTS"
  fi
}
trap cleanup EXIT

parts_list=()
p=0
for ((i=0; i<${#B[@]}-1; i++)); do
  s=${B[$i]}; e=${B[$((i+1))]}
  if [ "$e" -le "$s" ]; then continue; fi
  crf=$BASE_CRF
  for b in "${BOOSTS[@]}"; do
    IFS=: read -r b_s b_d b_c <<<"$b"
    if [ "$s" -ge "$b_s" ] && [ "$e" -le $((b_s + b_d)) ]; then crf=$b_c; fi
  done
  out=$(printf '%s/part_%03d.mp4' "$PARTS" "$p")
  info ""
  info ">> 段 $((p+1)): ${s}s ~ ${e}s (${e}-${s}s)  CRF=${crf}"
  args=()
  for i2 in "${!FILES[@]}"; do args+=(-ss "$s" -t "$((e-s))" -i "${FILES[$i2]}"); done
  args+=(-filter_complex "$FILTER" -map "[o]" -an
         -c:v "$ENCODER" -preset "$PRESET" -crf "$crf" -pix_fmt yuv420p -tag:v hvc1)
  case "$ENCODER" in
    libx265) args+=(-x265-params "keyint=60:min-keyint=15:log-level=error");;
    libx264) args+=(-x264-params "keyint=60:min-keyint=15");;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'ffmpeg'; printf ' %q' "${args[@]}"; printf ' %q\n' "$out"
  else
    ffmpeg -hide_banner -nostdin -y "${args[@]}" "$out"
  fi
  parts_list+=("$out")
  p=$((p+1))
done

# ---- 拼接 ----
LIST="$PARTS/list.txt"
: > "$LIST"
for f in "${parts_list[@]}"; do printf "file '%s'\n" "$f" >> "$LIST"; done

info ""
info ">> 拼接 ${#parts_list[@]} 段并封装"
if [ "$AUDIO" -eq 1 ]; then
  amap=(-map 0:v:0 -map 1:a:0? -c:a aac -b:a 48k)
else
  amap=(-map 0:v:0 -an)
fi
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'ffmpeg -f concat -safe 0 -i %q -ss 0 -t %q -i %q -c:v copy ' "$LIST" "$DUR" "${FILES[0]}"
  printf ' %q' "${amap[@]}"; printf ' -movflags +faststart -tag:v hvc1 %q\n' "$OUT"
else
  ffmpeg -hide_banner -nostdin -y \
    -f concat -safe 0 -i "$LIST" \
    -ss 0 -t "$DUR" -i "${FILES[0]}" \
    -c:v copy "${amap[@]}" \
    -movflags +faststart -tag:v hvc1 "$OUT"
fi

if [ "$DRY_RUN" -eq 1 ]; then exit 0; fi

# ---- 结果 ----
if [ -f "$OUT" ]; then
  SZ=$(stat -c %s "$OUT" 2>/dev/null || stat -f %z "$OUT")
  OUT_DUR=$(fformat "$OUT" duration)
  info ""
  info "输出: $OUT"
  info "体积: $(( SZ / 1000000 )) MB (${SZ} 字节)   时长: ${OUT_DUR}s   码率: $(( SZ * 8 / DUR / 1000 )) kbps"
  if [ -n "$MAX_BYTES" ]; then
    MB=$(to_bytes "$MAX_BYTES")
    if [ "$SZ" -gt "$MB" ]; then
      die "超出体积上限（${SZ} > ${MB} 字节）"
    fi
    info "体积校验通过（上限 $MAX_BYTES）"
  fi
fi
