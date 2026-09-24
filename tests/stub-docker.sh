#!/usr/bin/env bash
# =============================================================================
#  stub-docker.sh —— 在没有 Docker 的环境下模拟 docker / docker compose，
#  用于自动化测试 atrust.sh 的完整交互流程。
#
#  通过 tests/run-tests.sh 生成的 `docker` 包装脚本以 `docker` 身份被调用。
#
#  环境变量：
#    STUB_LOG    命令调用日志（追加，用于断言命令顺序）
#    STUB_STATE  容器状态文件（每行 svc:running / svc:exited）
# =============================================================================
set -Eeuo pipefail

LOG="${STUB_LOG:?STUB_LOG 未设置}"
STATE="${STUB_STATE:?STUB_STATE 未设置}"

# 记录本次调用（原样参数）
printf '%s\n' "$*" >> "$LOG"

cmd="${1:-}"
rest=("${@:2}")

# 解析 docker compose 子命令：docker compose -f FILE <subcommand> [args...]
compose_cmd=""
compose_file=""
if [[ "$cmd" == "compose" ]]; then
  prev=""
  for a in "${rest[@]:-}"; do
    if [[ "$prev" == "-f" ]]; then
      compose_file="$a"
    elif [[ "$a" != -* && -z "$compose_cmd" ]]; then
      compose_cmd="$a"
    fi
    prev="$a"
  done
else
  compose_cmd="${1:-}"
fi

svc_running() {
  grep -qxF "${1}:running" "$STATE" 2>/dev/null
}

svc_state_set() {
  local svc=$1 st=$2
  grep -vF "${svc}:" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  printf '%s:%s\n' "$svc" "$st" >> "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
}

svc_state_remove() {
  local svc=$1
  grep -vF "${svc}:" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  mv -f "$STATE.tmp" "$STATE"
}

# 从参数中挑出 atrust-N 形式的显式服务名（无则为空）
explicit_svcs() {
  local a
  for a in "${@:-}"; do
    if [[ "$a" == atrust-* ]]; then
      printf '%s\n' "$a"
    fi
  done
}

# 从 compose 文件提取 atrust-N 服务名
compose_services() {
  [[ -f "$compose_file" ]] || return 0
  grep -E '^  atrust-[0-9]+:$' "$compose_file" | sed -E 's/^  ([a-z0-9-]+):.*/\1/'
}

state_services() {
  sed -n 's/^\(atrust-[0-9]*\):.*/\1/p' "$STATE" 2>/dev/null | sort -u
}

case "$cmd" in
  info)
    exit 0
    ;;
  version)
    echo "Docker version 29.7.2, build deadbeef"
    exit 0
    ;;
  compose)
    case "$compose_cmd" in
      version)
        echo "Docker Compose version v5.5.0"
        exit 0
        ;;
      config)
        if [[ -n "$compose_file" && -f "$compose_file" ]]; then
          printf 'name: atrust\nservices:\n  [stub: validated]\n'
          exit 0
        fi
        echo "stub: compose config 找不到文件: ${compose_file:-?}" >&2
        exit 1
        ;;
      ps)
        svcs=()
        mapfile -t svcs < <(compose_services)
        for s in "${svcs[@]}"; do
          [[ -n "$s" ]] || continue
          if svc_running "$s"; then st="running"; else st="exited"; fi
          printf '%s|%s\n' "$s" "$st"
        done
        exit 0
        ;;
      up)
        svcs=()
        mapfile -t svcs < <(compose_services)
        for s in "${svcs[@]}"; do
          [[ -n "$s" ]] || continue
          svc_state_set "$s" running
        done
        exit 0
        ;;
      stop)
        targets=()
        mapfile -t targets < <(explicit_svcs "${rest[@]:-}")
        if (( ${#targets[@]} == 0 )); then
          mapfile -t targets < <(state_services)
        fi
        for s in "${targets[@]}"; do
          [[ -n "$s" ]] || continue
          svc_state_set "$s" exited
        done
        exit 0
        ;;
      start)
        targets=()
        mapfile -t targets < <(explicit_svcs "${rest[@]:-}")
        if (( ${#targets[@]} == 0 )); then
          mapfile -t targets < <(state_services)
        fi
        for s in "${targets[@]}"; do
          [[ -n "$s" ]] || continue
          svc_state_set "$s" running
        done
        exit 0
        ;;
      restart)
        exit 0
        ;;
      rm)
        targets=()
        mapfile -t targets < <(explicit_svcs "${rest[@]:-}")
        for s in "${targets[@]}"; do
          [[ -n "$s" ]] || continue
          svc_state_remove "$s"
        done
        exit 0
        ;;
      down)
        : > "$STATE"
        exit 0
        ;;
      pull)
        exit 0
        ;;
      logs)
        echo "[stub] 模拟日志 $(date '+%H:%M:%S')"
        echo "[stub] 正在跟踪日志（2 秒后自动结束）"
        sleep 2
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  ps)
    # 模拟 docker ps --filter name=^atrust- → 输出运行中的服务名（充当容器 ID）
    sed -n 's/^\(atrust-[0-9]*\):running$/\1/p' "$STATE" 2>/dev/null
    exit 0
    ;;
  inspect)
    # 模拟 docker inspect --format ... <svc> → 输出该实例声明的 4 个宿主端口
    id="${*: -1}"
    n="${id#atrust-}"
    if [[ "$id" == atrust-* && "$n" =~ ^[0-9]+$ ]]; then
      printf '%d\n' "$((SOCKS5_BASE + n - 1))"
      printf '%d\n' "$((HTTP_BASE + n - 1))"
      printf '%d\n' "$((VNC_BASE + n - 1))"
      printf '%d\n' "$((TUNNEL_BASE + n - 1))"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
