#!/usr/bin/env bash
#
# =============================================================================
#  aTrust Manager v0.2.0
#
#  交互式 aTrust（hagb/docker-atrust）多实例管理工具。
#  纯 Bash + Docker Compose 实现，无需 Node.js / Python / Go。
#
#  运行环境：Linux / WSL2（需要 Docker Engine + Docker Compose V2）
#  数据目录：${ATRUST_HOME:-$HOME/atrust}
#
#  一键运行：
#     curl -fsSL https://am.voemp.top/atrust.sh | bash
#
#  命令行选项：
#     -h, --help     显示帮助
#     -v, --version  显示版本
#
#  License: MIT
# =============================================================================

set -Eeuo pipefail

VERSION="0.2.0"

# ----------------------------- 基本配置 -----------------------------
ATRUST_HOME="${ATRUST_HOME:-${HOME}/atrust}"
COMPOSE_FILE="${ATRUST_HOME}/compose.yaml"
ENV_FILE="${ATRUST_HOME}/.env"
IMAGE="hagb/docker-atrust:latest"
MAX_INSTANCES="${MAX_INSTANCES:-20}"

SOCKS5_BASE="${SOCKS5_BASE:-1080}"   # 宿主 SOCKS5 起始端口
HTTP_BASE="${HTTP_BASE:-8888}"       # 宿主 HTTP 代理起始端口
VNC_BASE="${VNC_BASE:-5901}"         # 宿主 VNC 起始端口
TUNNEL_BASE="${TUNNEL_BASE:-54631}"  # 宿主 aTrust Tunnel 起始端口

# ----------------------------- 颜色 -----------------------------
C_GREEN=''
C_YELLOW=''
C_RED=''
C_CYAN=''
C_NC=''
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[0;31m'
  C_CYAN=$'\033[0;36m'
  C_NC=$'\033[0m'
fi

# ----------------------------- 输出工具 -----------------------------
say() { printf '%b%s%b %s\n' "$1" "$2" "$C_NC" "$3"; }
info() { say "$C_CYAN" "[*]" "$*"; }
ok()   { say "$C_GREEN" "[✓]" "$*"; }
warn() { say "$C_YELLOW" "[!]" "$*" >&2; }
err()  { say "$C_RED" "[✗]" "$*" >&2; }
hint() { printf '    %s\n' "$*"; }

pause() { sleep 1; }

# 未预期错误兜底：打印位置与建议后返回主菜单，不退出整个脚本。
# 菜单动作在子 shell 中执行，trap 触发时错误只终止该动作。
on_error() {
  local rc=$?
  local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
  local ln=${BASH_LINENO[0]}
  err "脚本内部错误（退出码 ${rc}）：${src}:${ln}"
  err "该操作未完成。其余实例不受影响，请返回主菜单重试。"
}
trap 'on_error' ERR

# ----------------------------- 环境检查 -----------------------------
# 支持 curl -fsSL ... | bash 的一键运行：把 stdin 重新指向终端
ensure_tty() {
  if [[ -t 0 ]]; then
    return 0
  fi
  # 注意：exec 带重定向会把重定向永久应用到当前 shell。
  # 这里不能写 `exec < /dev/tty 2>/dev/null` —— 2>/dev/null 会永久保留，
  # 导致 curl | bash 模式下所有 stderr（数量提示、警告、错误）被静默丢弃。
  if [[ -r /dev/tty ]] && exec < /dev/tty; then
    return 0
  fi
  err "需要交互式终端（TTY）才能运行本管理器。"
  hint "请在本机终端中运行： bash atrust.sh"
  return 1
}

check_env() {
  if (( BASH_VERSINFO[0] < 4 )); then
    err "需要 Bash 4.0 或更高版本（当前 ${BASH_VERSION:-未知}）。"
    return 1
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "本工具面向 Linux / WSL 环境运行（当前系统: $(uname -s)）。"
    hint "请使用 WSL 或 Linux 主机执行。"
    return 1
  fi
  if [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
    info "检测到 WSL 环境。"
  fi
  return 0
}

# Docker 命令统一存放，检测到 sudo 时就整体切换，避免混用
DOCKER=(docker)

detect_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi
  warn "「docker info」失败，尝试使用 sudo ..."
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
    return 0
  fi
  err "未检测到可用的 Docker。"
  hint "请先启动 Docker Engine："
  hint "  sudo systemctl start docker    # 启动"
  hint "  sudo systemctl enable docker   # 设置开机自启"
  return 1
}

check_compose() {
  if ! "${DOCKER[@]}" compose version >/dev/null 2>&1; then
    err "未检测到 Docker Compose V2（docker compose）。"
    hint "安装 Docker Engine 时通常会自动附带 compose 插件。"
    return 1
  fi
  local ver
  ver="$("${DOCKER[@]}" compose version 2>/dev/null | head -n1 || true)"
  info "Docker Compose: ${ver:-未知}"
  return 0
}

# ----------------------------- 输入工具 -----------------------------
ask_yn() {
  local ans
  printf '%s [y/N] ' "$1"
  IFS= read -r ans || return 1
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# 统一询问实例编号：非法输入循环重询，EOF/取消返回非 0
ask_number() {
  local num
  while :; do
    # 提示走 stderr：本函数通过命令替换返回编号，提示若走 stdout 会被一并捕获
    printf '请输入实例编号: ' >&2
    IFS= read -r num || return 1
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$num"
      return 0
    fi
    warn "输入无效「${num}」，请输入数字编号。"
  done
}

ask_instance_count() {
  local count
  while :; do
    # 提示输出到 stderr：本函数通过命令替换返回实例数，
    # 提示信息若输出到 stdout 会被一并捕获，污染返回值。
    printf '请输入要创建的 aTrust 实例数量 [1-%d]: ' "$MAX_INSTANCES" >&2
    IFS= read -r count || return 1
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= 1 )) && (( count <= MAX_INSTANCES )); then
      printf '%s\n' "$count"
      return 0
    fi
    warn "输入无效，请输入 1-${MAX_INSTANCES} 之间的数字。"
  done
}

# VNC 密码：不回显、两次一致、非空、≤128、不含换行、不含单引号
prompt_vnc_password() {
  local pw1 pw2
  while :; do
    printf '请输入 VNC 密码（用于 VNC / noVNC 访问登录界面）: '
    IFS= read -r -s pw1 || { printf '\n'; return 1; }
    printf '\n'
    printf '请再次输入 VNC 密码: '
    IFS= read -r -s pw2 || { printf '\n'; return 1; }
    printf '\n'
    if [[ "$pw1" != "$pw2" ]]; then
      warn "两次输入不一致，请重新输入。"
      continue
    fi
    if [[ -z "$pw1" ]]; then
      warn "密码不能为空。"
      continue
    fi
    if (( ${#pw1} > 128 )); then
      warn "密码过长（最多 128 个字符）。"
      continue
    fi
    if [[ "$pw1" == *"'"* ]]; then
      warn "密码不能包含单引号（'），否则会破坏 .env 文件格式。"
      continue
    fi
    PASSWORD="$pw1"
    return 0
  done
}

# ----------------------------- Compose 相关 -----------------------------
require_config() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    err "尚未创建任何实例（缺少 ${COMPOSE_FILE}）。"
    hint "请先选择「1. 创建 / 更新 aTrust 实例」。"
    return 1
  fi
  return 0
}

# 当前 compose 文件中的实例数量（含编号空缺的计数）
existing_count() {
  local n
  n="$(grep -Ec '^  atrust-[0-9]+:' "${COMPOSE_FILE}" 2>/dev/null || true)"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    n=0
  fi
  printf '%s\n' "$n"
}

# 已配置实例的编号列表（升序、空格分隔）；无配置时为空字符串
instance_numbers() {
  local nums
  nums="$(grep -E '^  atrust-[0-9]+:$' "${COMPOSE_FILE}" 2>/dev/null \
          | sed -E 's/^  atrust-([0-9]+):.*/\1/' | sort -n | tr '\n' ' ')"
  printf '%s\n' "${nums% }"
}

# 最大编号（无实例为 0）
max_number() {
  local nums
  nums="$(instance_numbers)"
  if [[ -z "$nums" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "${nums##* }"
}

# 1..最大编号 之间的空缺编号（空格分隔）；无空缺输出空
gap_numbers() {
  local max i nums
  max="$(max_number)"
  if ! [[ "$max" =~ ^[0-9]+$ ]] || (( max < 1 )); then
    printf '\n'
    return
  fi
  nums=" $(instance_numbers) "
  for ((i = 1; i <= max; i++)); do
    [[ " $nums " == *" $i "* ]] || printf '%s ' "$i"
  done
  printf '\n'
}

instance_exists() {
  [[ " $(instance_numbers) " == *" $1 "* ]]
}

# 可视化展示现有 / 空缺 / 最大编号
show_layout() {
  local nums gaps max
  nums="$(instance_numbers)"
  gaps="$(gap_numbers)"
  max="$(max_number)"
  printf '现有编号：%s\n' "${nums:-（无）}"
  if [[ -n "${gaps// /}" ]]; then
    printf '空缺编号：%s\n' "${gaps% }"
  else
    printf '空缺编号：无\n'
  fi
  printf '最大编号：%s\n' "$max"
}

docker_compose_cmd() {
  "${DOCKER[@]}" compose -f "${COMPOSE_FILE}" "$@"
}

compose_validate() {
  local out
  out="$("${DOCKER[@]}" compose -f "${COMPOSE_FILE}" config 2>&1)" || {
    err "Compose 配置生成失败（docker compose config）。"
    err "输出："
    printf '%s\n' "$out" | sed 's/^/    /'
    hint "请重新选择「1. 创建 / 更新 aTrust 实例」重新生成配置。"
    return 1
  }
  return 0
}

# 收集当前运行中的 atrust-* 容器已占用的宿主端口（用于冲突检查排除自身）
OUR_PORTS=""
collect_our_ports() {
  OUR_PORTS=""
  local ids id p
  # 模板传给 docker 解析，其中的 $ 不能被 shell 展开（SC2016 属误报）
  # shellcheck disable=SC2016
  local fmt='{{range $port, $binds := .NetworkSettings.Ports}}{{range $bind := $binds}}{{if $bind}}{{printf "%s\n" $bind.HostPort}}{{end}}{{end}}{{end}}'
  ids="$("${DOCKER[@]}" ps --filter 'name=^atrust-' --format '{{.ID}}' 2>/dev/null || true)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    p="$("${DOCKER[@]}" inspect --format "$fmt" "$id" 2>/dev/null || true)"
    if [[ -n "$p" ]]; then
      OUR_PORTS+="$p"$'\n'
    fi
  done <<< "$ids"
}

is_our_port() {
  [[ "$OUR_PORTS" == *$'\n'"$1"$'\n'* ]]
}

# 返回 0 表示端口已被占用
port_in_use() {
  local port=$1
  if is_our_port "$port"; then
    return 1 # 属于已存在的 aTrust 实例，不视为冲突
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
      return 0
    fi
    return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  warn "系统缺少 ss / nc，无法检测端口占用，已跳过检查。"
  return 1
}

# 检查 $1（空格分隔的编号列表）对应的宿主端口是否冲突
check_ports() {
  local nums=$1 n port conflict=0
  collect_our_ports
  for n in $nums; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    for port in "$((SOCKS5_BASE + n - 1))" "$((HTTP_BASE + n - 1))" "$((VNC_BASE + n - 1))" "$((TUNNEL_BASE + n - 1))"; do
      if port_in_use "$port"; then
        err "端口 ${port} 已被占用，无法创建 atrust-${n}。"
        conflict=1
      fi
    done
  done
  if (( conflict )); then
    err "检测到端口冲突，已停止创建。"
    hint "请释放对应端口，或减少实例数量后重试。"
    return 1
  fi
  return 0
}

write_env() {
  printf 'ATRUST_PASSWORD=%s\n' "'${PASSWORD}'" > "${ENV_FILE}.tmp"
  chmod 600 "${ENV_FILE}.tmp"
  mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
}

# 生成 compose：$1 = 空格分隔的编号列表，如 "1 3"
generate_compose() {
  local i
  cat > "${COMPOSE_FILE}" <<EOF
services:
EOF
  for i in $1; do
    [[ "$i" =~ ^[0-9]+$ ]] || continue
    cat >> "${COMPOSE_FILE}" <<EOF

  atrust-${i}:
    image: ${IMAGE}
    container_name: atrust-${i}
    restart: unless-stopped

    devices:
      - /dev/net/tun

    cap_add:
      - NET_ADMIN

    environment:
      PASSWORD: "\${ATRUST_PASSWORD}"
      URLWIN: "1"

    volumes:
      - ./atrust-data-${i}:/root

    ports:
      - "127.0.0.1:$((SOCKS5_BASE + i - 1)):1080"
      - "127.0.0.1:$((HTTP_BASE + i - 1)):8888"
      - "127.0.0.1:$((VNC_BASE + i - 1)):5901"
      - "127.0.0.1:$((TUNNEL_BASE + i - 1)):54631"

    sysctls:
      net.ipv4.conf.default.route_localnet: "1"
EOF
  done
}

# compose 备份 / 恢复（用于单实例操作的原子性）
COMPOSE_BACKUP=""
backup_compose() {
  COMPOSE_BACKUP="${COMPOSE_FILE}.bak.$$"
  cp -f "${COMPOSE_FILE}" "${COMPOSE_BACKUP}" 2>/dev/null || true
}
restore_compose() {
  if [[ -n "$COMPOSE_BACKUP" && -f "$COMPOSE_BACKUP" ]]; then
    mv -f "$COMPOSE_BACKUP" "$COMPOSE_FILE"
  fi
  COMPOSE_BACKUP=""
}
cleanup_compose() {
  if [[ -n "$COMPOSE_BACKUP" ]]; then
    rm -f "$COMPOSE_BACKUP" 2>/dev/null || true
    COMPOSE_BACKUP=""
  fi
}

docker_alive() {
  "${DOCKER[@]}" info >/dev/null 2>&1
}

# ----------------------------- 菜单功能 -----------------------------
create_instances() {
  local count cur i

  count="$(ask_instance_count)" || return 0
  if [[ -z "$count" ]]; then
    return 0
  fi

  if [[ -f "${COMPOSE_FILE}" ]]; then
    cur="$(existing_count)"
    printf '\n检测到已有 aTrust 配置。\n当前实例数量：%s\n重新生成配置为 %s 个实例？\n这不会自动删除现有数据。\n' \
      "$cur" "$count"
    if ! ask_yn "确认？"; then
      echo "已取消。"
      return 0
    fi
    echo
  fi

  if ! check_ports "$(seq -s ' ' 1 "$count")"; then
    return 0
  fi

  if ! prompt_vnc_password; then
    echo "已取消。"
    return 0
  fi

  mkdir -p "${ATRUST_HOME}"
  for ((i = 1; i <= count; i++)); do
    mkdir -p "${ATRUST_HOME}/atrust-data-${i}"
  done

  write_env
  generate_compose "$(seq -s ' ' 1 "$count")"
  ok "已生成 ${COMPOSE_FILE}（共 ${count} 个实例）"

  if ! compose_validate; then
    return 0
  fi

  echo
  info "正在拉取镜像（${IMAGE}），首次可能需要数分钟 ..."
  if ! docker_compose_cmd pull; then
    err "docker compose pull 失败。"
    hint "请检查网络与 Docker Hub 连通性后重试。"
    return 0
  fi

  info "正在启动实例 ..."
  if ! docker_compose_cmd up -d; then
    err "docker compose up -d 失败。"
    hint "建议检查 /dev/net/tun 与 NET_ADMIN 是否可用。"
    return 0
  fi

  ok "实例创建完成并已启动。"
  show_status
}

# 添加单个实例：默认最大编号+1，也可指定空缺编号
add_instance() {
  require_config || return 0
  local nums max newn ans

  nums="$(instance_numbers)"
  max="$(max_number)"

  echo
  echo "当前实例布局："
  show_layout
  echo
  printf '请输入要添加的实例编号（直接回车 = 最大编号+1 = %d）: ' "$((max + 1))"
  IFS= read -r ans || return 0

  if [[ -z "$ans" ]]; then
    newn="$((max + 1))"
  elif [[ "$ans" =~ ^[0-9]+$ ]]; then
    newn="$ans"
  else
    warn "输入无效「${ans}」，操作已取消。"
    return 0
  fi

  if (( newn < 1 || newn > MAX_INSTANCES )); then
    warn "编号必须在 1-${MAX_INSTANCES} 之间，操作已取消。"
    return 0
  fi
  if instance_exists "$newn"; then
    err "编号 atrust-${newn} 已存在，操作已取消。"
    return 0
  fi

  if ! check_ports "$newn"; then
    return 0
  fi

  backup_compose
  mkdir -p "${ATRUST_HOME}/atrust-data-${newn}"
  generate_compose "${nums} ${newn}"
  if ! compose_validate; then
    restore_compose
    return 0
  fi
  cleanup_compose

  echo
  info "正在启动 atrust-${newn} ..."
  if ! "${DOCKER[@]}" compose -f "${COMPOSE_FILE}" up -d "atrust-${newn}"; then
    err "启动 atrust-${newn} 失败。"
    hint "建议检查 /dev/net/tun 与 NET_ADMIN 是否可用。"
    return 0
  fi

  ok "已添加实例 atrust-${newn}（SOCKS5: 127.0.0.1:$((SOCKS5_BASE + newn - 1))）。"
}

# 删除单个实例：留空位，可选择是否删除数据，需输入 DELETE 确认
delete_instance() {
  require_config || return 0
  local num nums newlist i dirdel ans

  nums="$(instance_numbers)"
  if [[ -z "${nums// /}" ]]; then
    warn "没有可删除的实例。"
    return 0
  fi

  echo
  echo "当前实例布局："
  show_layout
  echo
  num="$(ask_number)" || return 0
  if ! instance_exists "$num"; then
    err "编号 atrust-${num} 不存在，操作已取消。"
    return 0
  fi

  echo
  warn "将删除实例 atrust-${num} 的容器。"
  dirdel=""
  if ask_yn "是否同时删除数据目录 atrust-data-${num}？"; then
    dirdel="y"
  fi

  printf '\n请完整输入 DELETE 以确认: '
  IFS= read -r ans || return 0
  echo
  if [[ "$ans" != "DELETE" ]]; then
    warn "确认文本不匹配（需要输入 DELETE），已取消。"
    return 0
  fi

  info "正在停止并移除 atrust-${num} ..."
  "${DOCKER[@]}" compose -f "${COMPOSE_FILE}" stop "atrust-${num}" >/dev/null 2>&1 || true
  "${DOCKER[@]}" compose -f "${COMPOSE_FILE}" rm -sf "atrust-${num}" >/dev/null 2>&1 || true

  if [[ -n "$dirdel" ]]; then
    info "正在删除数据目录 atrust-data-${num} ..."
    if ! rm -rf "${ATRUST_HOME}/atrust-data-${num}" 2>/dev/null; then
      warn "普通删除失败（可能存在 root 属主文件），尝试 sudo ..."
      if command -v sudo >/dev/null 2>&1 && sudo rm -rf "${ATRUST_HOME}/atrust-data-${num}" 2>/dev/null; then
        ok "已删除数据目录 atrust-data-${num}。"
      else
        warn "数据目录删除失败，请手动执行： sudo rm -rf \"${ATRUST_HOME}/atrust-data-${num}\""
      fi
    fi
  fi

  # 重写 compose（去掉该编号，其余编号/端口保持不变 → 留空位）
  newlist=""
  for i in $nums; do
    [[ "$i" != "$num" ]] && newlist+=" $i"
  done
  backup_compose
  if [[ -z "${newlist// /}" ]]; then
    rm -f "${COMPOSE_FILE}" "${ENV_FILE}" 2>/dev/null || true
    echo
    ok "已删除唯一的实例 atrust-${num}（配置与密码已一并清除）。"
    return 0
  fi
  generate_compose "${newlist# }"
  if ! compose_validate; then
    restore_compose
    return 0
  fi
  cleanup_compose
  ok "已删除实例 atrust-${num}（编号空缺保留）。"
}

# 重建单个实例：仅重建指定容器，保留数据目录
rebuild_instance() {
  require_config || return 0
  local num

  echo
  echo "当前实例布局："
  show_layout
  echo
  num="$(ask_number)" || return 0
  if ! instance_exists "$num"; then
    err "编号 atrust-${num} 不存在，操作已取消。"
    return 0
  fi

  echo
  info "正在重建 atrust-${num}（保留数据）..."
  if ! docker_compose_cmd up -d --force-recreate "atrust-${num}"; then
    err "重建 atrust-${num} 失败。"
    hint "建议检查 /dev/net/tun 与 NET_ADMIN 是否可用。"
    return 0
  fi
  ok "已重建 atrust-${num}（数据保留）。"
}

show_status() {
  require_config || return 0
  if ! docker_alive; then
    err "Docker Engine 当前没有运行，无法查看状态。"
    hint "请执行： sudo systemctl start docker"
    return 0
  fi

  local count
  count="$(existing_count)"
  if (( count <= 0 )); then
    warn "配置中没有实例。"
    return 0
  fi

  echo
  echo "aTrust 实例"
  echo

  local -a lines=()
  mapfile -t lines <<< "$(docker_compose_cmd ps --format '{{.Service}}|{{.State}}' 2>/dev/null || true)"

  local line svc state n running=0
  local -a names=()
  # instance_numbers 返回空格分隔的编号列表，逐个处理
  mapfile -t names < <(printf '%s' "$(instance_numbers)" | tr ' ' '\n')
  for n in "${names[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    svc="atrust-${n}"
    state="exited"
    for line in "${lines[@]}"; do
      if [[ "${line%%|*}" == "$svc" ]]; then
        state="${line#*|}"
        break
      fi
    done
    local pts
    pts="S:$((SOCKS5_BASE + n - 1))  H:$((HTTP_BASE + n - 1))  V:$((VNC_BASE + n - 1))  T:$((TUNNEL_BASE + n - 1))"
    if [[ "$state" == "running" ]]; then
      printf '  %b%-10s%b %-9s %s\n' "$C_GREEN" "$svc" "$C_NC" "$state" "$pts"
      running=$((running + 1))
    else
      printf '  %-10s %-9s %s\n' "$svc" "$state" "$pts"
    fi
  done

  printf '\n正在运行：%d / %s 个实例\n' "$running" "$count"
  echo
}

# Mihomo JS 覆写配置：模板 main() 原样保留，端口按真实 SOCKS5_BASE，
# 用户配置段留空并带一行注释示例。
write_mihomo_override() {
  local MJ="${ATRUST_HOME}/mihomo-override.js"
  local ss=$1
  cat > "${MJ}" <<EOF
// =========================
// 用户配置
// =========================

// 每个数组对应一个 aTrust 出口
//
// RULES[0] → aTrust-1 → 127.0.0.1:${ss}
// RULES[1] → aTrust-2 → 127.0.0.1:$((ss + 1))
// RULES[2] → aTrust-3 → 127.0.0.1:$((ss + 2))
const RULES = [
  // 示例：['192.168.5.0/24', '172.25.0.0/24', '10.11.2.0/24']
]

// hosts 配置：左边支持通配符，右边是实际解析到的 IP
const HOSTS = [
  // 示例：['*.10.11.2.10.nip.io', '10.11.2.10']
]

// 不经过 fake-ip 的域名
const FAKE_IP_FILTER = [
  // 示例：'+.tianhe-tech.com', '+.nip.io', '+.nscc-tj.cn'
]

// =========================
// 以下内容无需修改
// =========================

function main(config) {
  // =========================
  // aTrust 节点
  // =========================

  config.proxies = config.proxies || []

  for (let i = 0; i < RULES.length; i++) {
    const name = \`aTrust-\${i + 1}\`
    const port = ${ss} + i

    if (!config.proxies.some((p) => p.name === name)) {
      config.proxies.push({
        name,
        type: 'socks5',
        server: '127.0.0.1',
        port,
      })
    }
  }

  // =========================
  // IP 分流规则
  // =========================

  config.rules = config.rules || []

  const rules = []

  for (let i = 0; i < RULES.length; i++) {
    const proxy = \`aTrust-\${i + 1}\`

    for (const cidr of RULES[i]) {
      rules.push(\`IP-CIDR,\${cidr},\${proxy},no-resolve\`)
    }
  }

  config.rules.unshift(...rules)

  // =========================
  // DNS
  // =========================

  config.dns = config.dns || {}

  // fake-ip-filter
  config.dns['fake-ip-filter'] = config.dns['fake-ip-filter'] || []

  for (const domain of FAKE_IP_FILTER) {
    if (!config.dns['fake-ip-filter'].includes(domain)) {
      config.dns['fake-ip-filter'].push(domain)
    }
  }

  // hosts
  config.dns.hosts = config.dns.hosts || {}

  for (const [domain, ip] of HOSTS) {
    config.dns.hosts[domain] = ip
  }

  return config
}
EOF
  printf '已生成 %s\n' "${MJ}"
}

mihomo_config() {
  require_config || return 0
  local ss="${SOCKS5_BASE}"
  local MJ win

  MJ="${ATRUST_HOME}/mihomo-override.js"
  backup_compose

  write_mihomo_override "${ss}"
  ok "Mihomo 覆写文件已生成：${MJ}"

  # Windows 可点击路径（WSL 下可转成 \\wsl.localhost\... ）
  win=""
  if command -v wslpath >/dev/null 2>&1; then
    win="$(wslpath -w "${MJ}" 2>/dev/null || true)"
  fi

  echo
  echo "在 Windows 中打开并复制（可点击）："
  if [[ -n "$win" ]]; then
    printf '  UNC 路径：  %s\n' "$win"
    printf '  file 链接： file:///%s\n' "$(printf '%s' "$win" | sed 's#\\#/#g; s#^/##')"
  fi
  printf '  WSL 路径：  %s\n' "${MJ}"
  echo
  hint "打开文件 → 全选复制 → 粘贴到 Mihomo / Clash Verge 的「覆写配置」。"
  hint "RULES / HOSTS / FAKE_IP_FILTER 按需填写即可（已留注释示例，可留空）。"
  cleanup_compose
}

start_all() {
  require_config || return 0
  compose_validate || return 0
  if ! docker_compose_cmd up -d; then
    err "启动失败（docker compose up -d）。"
    hint "请检查 /dev/net/tun 与 NET_ADMIN 是否可用。"
    return 0
  fi
  ok "所有实例已启动。"
}

stop_all() {
  require_config || return 0
  if ! docker_compose_cmd stop; then
    err "停止失败（docker compose stop）。"
    return 0
  fi
  ok "所有实例已停止（容器保留，数据保留）。"
}

restart_all() {
  require_config || return 0
  if ! docker_compose_cmd restart; then
    err "重启失败（docker compose restart）。"
    return 0
  fi
  ok "所有实例已重启。"
}

view_logs() {
  require_config || return 0
  local count i num
  count="$(existing_count)"
  if (( count <= 0 )); then
    warn "配置中没有实例。"
    return 0
  fi
  echo
  echo "输入实例编号，例如 1。直接回车查看全部实例。"
  echo
  echo "实例:"
  for i in $(instance_numbers); do
    printf '  atrust-%s\n' "$i"
  done
  printf '\n请输入实例编号（回车查看全部）: '
  IFS= read -r num || return 0

  local -a target=()
  if [[ -n "$num" ]]; then
    if [[ "$num" =~ ^[0-9]+$ ]] && instance_exists "$num"; then
      target=("atrust-${num}")
    else
      warn "无效编号「${num}」，改为查看全部实例。"
    fi
  fi

  echo
  info "按 Ctrl-C 停止日志跟踪。"
  docker_compose_cmd logs -f "${target[@]+"${target[@]}"}" || true
}

# 删除全部实例：可选择是否删除数据，需输入 DELETE 确认（原 7/8 两项合并）
delete_all() {
  require_config || return 0

  echo
  warn "将删除所有 aTrust 容器。"
  local dirdel=""
  if ask_yn "是否同时删除数据目录（atrust-data-*）？"; then
    dirdel="y"
  fi

  printf '\n请完整输入 DELETE 以确认: '
  local ans
  IFS= read -r ans || return 0
  echo
  if [[ "$ans" != "DELETE" ]]; then
    warn "确认文本不匹配（需要输入 DELETE），已取消。"
    return 0
  fi

  info "正在移除所有容器 ..."
  if ! docker_compose_cmd down --remove-orphans; then
    err "docker compose down 失败。"
    return 0
  fi

  if [[ -n "$dirdel" ]]; then
    info "正在删除数据目录 ..."
    if rm -rf "${ATRUST_HOME}" 2>/dev/null; then
      ok "已完全删除（容器 + 数据）。"
      return 0
    fi
    warn "普通删除失败（可能存在 root 属主文件），尝试 sudo ..."
    if command -v sudo >/dev/null 2>&1 && sudo rm -rf "${ATRUST_HOME}" 2>/dev/null; then
      ok "已通过 sudo 完全删除（容器 + 数据）。"
      return 0
    fi
    err "数据目录删除失败。"
    hint "请手动执行： sudo rm -rf \"${ATRUST_HOME}\""
    return 0
  fi

  ok "已删除所有 aTrust 容器（数据已保留）。"
}

update_image() {
  require_config || return 0
  echo
  info "正在拉取最新镜像 ${IMAGE} ..."
  if ! docker_compose_cmd pull; then
    err "docker compose pull 失败。"
    hint "请检查网络后重试。"
    return 0
  fi
  info "正在基于新镜像重建实例（数据保留）..."
  if ! docker_compose_cmd up -d; then
    err "docker compose up -d 失败。"
    return 0
  fi
  ok "镜像已更新，实例已重建。"
}

# ----------------------------- 菜单 -----------------------------
show_menu() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
  cat <<'MENU'

╔══════════════════════════════════════════╗
║          aTrust Manager v0.2.0           ║
╠══════════════════════════════════════════╣
║                                          ║
║  1. 创建 / 更新 aTrust 实例              ║
║  2. 添加单个实例                         ║
║  3. 删除单个实例                         ║
║  4. 重建单个实例                         ║
║  5. 查看实例状态                         ║
║  6. 启动所有实例                         ║
║  7. 停止所有实例                         ║
║  8. 重启所有实例                         ║
║  9. 查看日志                             ║
║ 10. 删除全部实例                         ║
║ 11. 更新 Docker 镜像                     ║
║ 12. Mihomo 配置输出                      ║
║  0. 退出                                 ║
║                                          ║
╚══════════════════════════════════════════╝

MENU
  printf '请选择 [0-12]: '
}

usage() {
  cat <<'EOF'
用法：
  bash atrust.sh [选项]

选项：
  -h, --help     显示帮助
  -v, --version  显示版本

不带参数直接运行将进入交互式菜单。

一键运行：
  curl -fsSL https://am.voemp.top/atrust.sh | bash
EOF
}

# 操作完成后按任意键返回主菜单，方便用户看完整输出；
# 无输入（例如管道/EOF）时自动跳过，不影响运行
wait_return() {
  printf '\n按任意键返回主菜单 ... '
  read -rsn1 || true
  printf '\n'
}

main() {
  ensure_tty || exit 1
  check_env || exit 1
  if ! detect_docker; then
    exit 1
  fi
  if ! check_compose; then
    exit 1
  fi

  mkdir -p "${ATRUST_HOME}"

  info "aTrust Manager v${VERSION} — 数据目录：${ATRUST_HOME}"
  info "Docker 可用（${DOCKER[*]}）"
  pause

  local choice
  while :; do
    show_menu
    IFS= read -r choice || break
    case "$choice" in
      1) ( create_instances ) ;;
      2) ( add_instance ) ;;
      3) ( delete_instance ) ;;
      4) ( rebuild_instance ) ;;
      5) ( show_status ) ;;
      6) ( start_all ) ;;
      7) ( stop_all ) ;;
      8) ( restart_all ) ;;
      9) ( view_logs ) ;;
      10) ( delete_all ) ;;
      11) ( update_image ) ;;
      12) ( mihomo_config ) ;;
      0) echo; ok "再见。"; exit 0 ;;
      *) warn "无效选项「${choice}」，请输入 0-12。" ;;
    esac
    wait_return
  done
}

case "${1:-unset}" in
  -h|--help)
    usage
    exit 0
    ;;
  -v|--version)
    echo "atrust-manager ${VERSION}"
    exit 0
    ;;
esac

main
