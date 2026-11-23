#!/usr/bin/env bash
# 公共函数库：素材发现、探测、数值工具
# 被 probe.sh / stitch.sh 通过 source 引入，不单独执行。

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# 视频流字段
vfield() { ffprobe -v error -select_streams v:0 -show_entries "stream=$2" -of csv=p=0 "$1"; }
# 容器字段
fformat() { ffprobe -v error -show_entries "format=$2" -of csv=p=0 "$1"; }

# 向下取偶（编码器要求宽高为偶数）
even() {
  local v=$1
  if [ $((v % 2)) -ne 0 ]; then v=$((v - 1)); fi
  printf '%d' "$v"
}

# 解析 70MB / 70MiB / 70000000
to_bytes() {
  local v=$1
  case "$v" in
    *MiB|*Mib) printf '%d' "$(( ${v%[Mm][Ii][Bb]} * 1024 * 1024 ))";;
    *MB|*Mb)   printf '%d' "$(( ${v%[Mm][Bb]} * 1000 * 1000 ))";;
    *GB)       printf '%d' "$(( ${v%[Gg][Bb]} * 1000 * 1000 * 1000 ))";;
    *)         printf '%d' "$v";;
  esac
}

# 从文件名提取分组键：去掉视角标记后剩下的数字串
# <前缀>_<视角>_YYYY_MM_DD_HH_MM_SS_mmm.mp4  ->  20240101000000000
group_key() {
  local base view=$2
  base=$(basename "$1" .mp4)
  base=${base//$view/}
  printf '%s' "$base" | tr -cd '0-9'
}

# 在源目录中找齐 N 路同一组的文件，结果写入全局数组 FILES（顺序与 views 一致）
# 用法: resolve_inputs <源目录> <主视角token> <侧视角token...>
# 可用环境变量 KEY=<分组键> 强制指定
resolve_inputs() {
  local src=$1; shift
  local -a views=("$@")
  local n=${#views[@]}
  local v f b k tmp key
  tmp=$(mktemp) || die "无法创建临时文件"

  for v in "${views[@]}"; do
    for f in "$src"/*"$v"*.mp4; do
      [ -e "$f" ] || continue
      k=$(group_key "$f" "$v")
      printf '%s %s %s\n' "$k" "$v" "$f" >> "$tmp"
    done
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; die "在 $src 下找不到任何视频（视角关键词: ${views[*]}）"; }

  if [ -n "${KEY:-}" ]; then
    key=$KEY
  else
    # 取 N 路齐全的最新一组
    key=$(awk '{print $1}' "$tmp" | sort | uniq -c \
          | awk -v n="$n" '$1 == n {print $2}' | sort | tail -1)
  fi
  [ -n "$key" ] || { rm -f "$tmp"; die "没有找到 N=$n 路齐全的一组素材（可用 KEY=<分组键> 指定）"; }

  FILES=()
  for v in "${views[@]}"; do
    f=$(awk -v k="$key" -v v="$v" '$1 == k && $2 == v {print $3; exit}' "$tmp")
    [ -n "$f" ] || { rm -f "$tmp"; die "分组 $key 缺少视角 $v"; }
    FILES+=("$f")
  done
  rm -f "$tmp"
  GROUP_KEY=$key
}
