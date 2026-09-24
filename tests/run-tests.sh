#!/usr/bin/env bash
# =============================================================================
#  run-tests.sh —— atrust.sh 自动化交互测试
#
#  在 Linux / WSL 中运行（需要 bash + script + python3 + ss）。
#  使用 tests/stub-docker.sh 模拟 docker，不触碰真实 Docker 守护进程。
#
#  用法： bash tests/run-tests.sh
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANAGER="${ROOT}/atrust.sh"
STUB_DIR="${SCRIPT_DIR}"

WORK="$(mktemp -d /tmp/atrust-tests.XXXXXX)"
HOMEDIR="${WORK}/atrust-home"
BINDIR="${WORK}/bin"
mkdir -p "${BINDIR}"
# 把 stub 以 `docker` 身份挂到 PATH 最前面，避免误用真实 Docker
cat > "${BINDIR}/docker" <<EOF
#!/usr/bin/env bash
exec "${STUB_DIR}/stub-docker.sh" "\$@"
EOF
chmod +x "${BINDIR}/docker"

export ATRUST_HOME="${HOMEDIR}"
export STUB_LOG="${WORK}/docker.log"
export STUB_STATE="${WORK}/state.txt"
export PATH="${BINDIR}:${PATH}"
trap 'rm -rf "${WORK}"' EXIT

# 使用空闲的起始端口（本机 1080+ 可能已被真实的 aTrust 实例占用）
export SOCKS5_BASE=14080
export HTTP_BASE=14088
export VNC_BASE=15901
export TUNNEL_BASE=25463
S0=$SOCKS5_BASE
S1=$((S0 + 1))
H1=$((HTTP_BASE + 1))
V1=$((VNC_BASE + 1))
T1=$((TUNNEL_BASE + 1))

pass=0
fail=0

reset_state() {
  : > "$STUB_STATE"
  : > "$STUB_LOG"
}

reset_home() {
  rm -rf "${HOMEDIR}"
  reset_state
}

# 通过 PTY 运行一次管理器会话；$1 = 输入的字节序列，输出写入 CAP
# （timeout 兜底：script 在输入 EOF 时不会把 EOF 送给子进程，防止挂起）
capture() {
  local input=$1
  set +e
  CAP="$(printf '%b' "$input" | timeout 40 script -qec "bash '${MANAGER}'" /dev/null 2>&1)"
  RC=$?
  set -e
}

check() { # $1 断言结果(1/0)  $2 说明  $3 失败详情
  if [[ "$1" == "1" ]]; then
    pass=$((pass + 1))
    printf 'PASS | %s\n' "$2"
  else
    fail=$((fail + 1))
    printf 'FAIL | %s\n' "$2"
    printf '       期望：%s\n' "$3"
  fi
}

contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo 1
  else
    echo 0
  fi
}

count_of() { printf '%s' "$1" | grep -oF -- "$2" | wc -l; }
file_mode() { stat -c %a "$1" 2>/dev/null || echo "missing"; }

line_of() { # $1 = 日志中要定位的字符串（返回行号，找不到返回 100000）
  local l
  l="$(grep -nF -m1 -- "$1" "$STUB_LOG" 2>/dev/null | cut -d: -f1 || true)"
  if [[ -z "$l" ]]; then
    echo 100000
  else
    echo "$l"
  fi
}

echo
echo "================ atrust.sh 自动化测试 ================"
echo "工作目录: ${WORK}"
echo

# ---------------------------------------------------------------
echo "--- 0. 命令行选项 ---"

out="$(bash "${MANAGER}" --version 2>&1 || true)"
check "$(contains "$out" "atrust-manager 0.2.0")" "0.1 --version 输出版本号" "atrust-manager 0.2.0"

out="$(bash "${MANAGER}" --help 2>&1 || true)"
check "$(contains "$out" "用法")" "0.2 --help 显示用法" "用法"

# ---------------------------------------------------------------
echo "--- 1. Docker 不可用时的错误处理 ---"

SHADOW="${WORK}/shadow"
mkdir -p "${SHADOW}"
cat > "${SHADOW}/docker" <<'SH'
#!/usr/bin/env bash
echo "docker: Cannot connect to the Docker daemon" >&2
exit 1
SH
cat > "${SHADOW}/sudo" <<'SH'
#!/usr/bin/env bash
echo "sudo: permission denied (stub)" >&2
exit 1
SH
chmod +x "${SHADOW}/docker" "${SHADOW}/sudo"

set +e
CAP="$(printf '' | timeout 40 script -qec "env PATH=\"${SHADOW}:${PATH}\" bash '${MANAGER}'" /dev/null 2>&1)"
RC=$?
set -e
out="$CAP"
check "$(contains "$out" "未检测到可用的 Docker")" "1.1 Docker 不可用时给出明确错误" "未检测到可用的 Docker"
check "$(contains "$out" "尝试使用 sudo")" "1.2 提示尝试 sudo" "尝试使用 sudo"
check "$([ "$RC" != "0" ] && echo 1 || echo 0)" "1.3 Docker 不可用时脚本非 0 退出（rc=${RC}）" "退出码非 0"

# ---------------------------------------------------------------
echo "--- 2. 非法数量输入不会退出 ---"

reset_home
capture '1\n0\n5\npassw0rd\npassw0rd\nk0\n'
out="$CAP"
check "$(contains "$out" "输入无效")" "2.1 数量=0 时提示输入无效并重新询问" "输入无效"
check "$(contains "$out" "创建完成")" "2.2 数量=5 后正常创建" "创建完成"

# ---------------------------------------------------------------
echo "--- 3. Test 1：创建 1 个实例 ---"

reset_home
capture '1\n1\npwtest\npwtest\nk0\n'
out="$CAP"
check "$(contains "$out" "已生成")" "3.1 生成 compose" "已生成"
check "$(contains "$out" "创建完成")" "3.2 创建完成提示" "创建完成"

ENVF="${HOMEDIR}/.env"
COMPOSE="${HOMEDIR}/compose.yaml"
check "$(contains "$(cat "${ENVF}" 2>/dev/null || true)" "ATRUST_PASSWORD='pwtest'")" "3.3 .env 含密码" "ATRUST_PASSWORD='pwtest'"
check "$([ "$(file_mode "${ENVF}")" = "600" ] && echo 1 || echo 0)" "3.4 .env 权限 600" "600 (actual: $(file_mode "${ENVF}"))"

C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$(contains "$C" "container_name: atrust-1")" "3.5 compose 含 atrust-1" "container_name: atrust-1"
# 断言的是 compose 文件中的字面文本 ${ATRUST_PASSWORD}（SC2016 属误报）
# shellcheck disable=SC2016
check "$(contains "$C" 'PASSWORD: "${ATRUST_PASSWORD}"')" "3.6 compose 不写死密码（引用环境变量）" 'PASSWORD: "${ATRUST_PASSWORD}"'
check "$([ "$(printf '%s' "$C" | grep -cF "pwtest" || true)" = "0" ] && echo 1 || echo 0)" "3.7 compose 不含明文密码" "compose 不含 pwtest"
check "$(contains "$C" "127.0.0.1:${S0}:1080")" "3.8 SOCKS5 端口 ${S0}" "127.0.0.1:${S0}:1080"
check "$(contains "$C" "127.0.0.1:${HTTP_BASE}:8888")" "3.9 HTTP 端口 ${HTTP_BASE}" "127.0.0.1:${HTTP_BASE}:8888"
check "$(contains "$C" "127.0.0.1:${VNC_BASE}:5901")" "3.10 VNC 端口 ${VNC_BASE}" "127.0.0.1:${VNC_BASE}:5901"
check "$(contains "$C" "127.0.0.1:${TUNNEL_BASE}:54631")" "3.11 Tunnel 端口 ${TUNNEL_BASE}" "127.0.0.1:${TUNNEL_BASE}:54631"
check "$(contains "$C" "./atrust-data-1:/root")" "3.12 数据目录挂载" "./atrust-data-1:/root"
check "$(contains "$C" "restart: unless-stopped")" "3.13 restart 策略" "restart: unless-stopped"
check "$([ -d "${HOMEDIR}/atrust-data-1" ] && echo 1 || echo 0)" "3.14 数据目录已创建" "存在 atrust-data-1"
check "$([ "$(line_of ' config')" -lt "$(line_of ' pull')" ] && [ "$(line_of ' pull')" -lt "$(line_of ' up -d')" ] && echo 1 || echo 0)" "3.15 命令顺序 config→pull→up -d" "config < pull < up -d"
check "$(contains "$out" "aTrust 实例")" "3.16 状态展示" "aTrust 实例"
check "$([ "$(printf '%s' "$out" | grep -cF '覆写文件' || true)" = "0" ] && [ "$(printf '%s' "$out" | grep -cF 'SOCKS5 节点示例' || true)" = "0" ] && echo 1 || echo 0)" "3.17 状态输出不含 Mihomo（由菜单 12 单独输出）" "状态不含 Mihomo 覆写/示例"

# ---------------------------------------------------------------
echo "--- 4. Test 2：创建 2 个实例，端口递增 ---"

reset_home
capture '1\n2\npw\npw\nk0\n'
out="$CAP"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$([ "$(printf '%s' "$C" | grep -cF 'container_name: atrust-' || true)" = "2" ] && echo 1 || echo 0)" "4.1 两个 service" "container_name 数量 = 2"
check "$(contains "$C" "127.0.0.1:${S1}:1080")" "4.2 实例2 SOCKS5=${S1}" "127.0.0.1:${S1}:1080"
check "$(contains "$C" "127.0.0.1:${H1}:8888")" "4.3 实例2 HTTP=${H1}" "127.0.0.1:${H1}:8888"
check "$(contains "$C" "127.0.0.1:${V1}:5901")" "4.4 实例2 VNC=${V1}" "127.0.0.1:${V1}:5901"
check "$(contains "$C" "127.0.0.1:${T1}:54631")" "4.5 实例2 Tunnel=${T1}" "127.0.0.1:${T1}:54631"
check "$([ -d "${HOMEDIR}/atrust-data-2" ] && echo 1 || echo 0)" "4.6 第二个数据目录" "存在 atrust-data-2"

# ---------------------------------------------------------------
echo "--- 5. Test 3：停止所有实例 ---"

capture '7\nk0\n' # 复用上一场景的状态（2 个实例 running）
out="$CAP"
check "$(contains "$out" "已停止")" "5.1 停止提示" "已停止"
check "$([ "$(grep -c ':running$' "$STUB_STATE" 2>/dev/null || true)" = "0" ] && \
         [ "$(grep -c ':exited$' "$STUB_STATE" 2>/dev/null || true)" = "2" ] && echo 1 || echo 0)" "5.2 两个实例进入 exited" "exited=2 running=0"

# ---------------------------------------------------------------
echo "--- 6. Test 4：启动所有实例 ---"

capture '6\nk0\n'
out="$CAP"
check "$(contains "$out" "已启动")" "6.1 启动提示" "已启动"
check "$([ "$(grep -c ':running$' "$STUB_STATE" 2>/dev/null || true)" = "2" ] && echo 1 || echo 0)" "6.2 两个实例恢复 running" "running=2"

# ---------------------------------------------------------------
echo "--- 7. 删除全部实例（菜单 10：删除容器，保留数据） ---"

# 菜单 10 → 数据? n → DELETE 确认 → 只删容器保留数据
capture '10\nn\nDELETE\nk0\n'
out="$CAP"
check "$(contains "$out" "已删除所有 aTrust 容器")" "7.1 删除提示" "已删除所有 aTrust 容器"
check "$([ "$(wc -l < "$STUB_STATE" 2>/dev/null || echo 0)" = "0" ] && echo 1 || echo 0)" "7.2 状态已清空（容器删除）" "state 空"
check "$([ -d "${HOMEDIR}/atrust-data-1" ] && [ -d "${HOMEDIR}/atrust-data-2" ] && echo 1 || echo 0)" "7.3 数据目录仍存在" "atrust-data-1/2 存在"
check "$([ -f "${COMPOSE}" ] && [ -f "${ENVF}" ] && echo 1 || echo 0)" "7.4 compose 与 .env 保留" "compose.yaml / .env 存在"

# 删除全部实例时取消（DELETE 文本不匹配）
capture '10\nn\nwrongtext\nk0\n'
out="$CAP"
check "$(contains "$out" "已取消")" "7.5 确认文本不匹配则取消" "已取消"
check "$([ -e "${HOMEDIR}" ] && echo 1 || echo 0)" "7.6 未删除任何内容" "目录仍存在"

# ---------------------------------------------------------------
echo "--- 8. 删除全部实例（菜单 10：容器 + 数据，不可逆） ---"

capture '10\ny\nDELETE\nk0\n'
out="$CAP"
check "$(contains "$out" "已完全删除")" "8.1 DELETE 后完全删除" "已完全删除"
check "$([ ! -e "${HOMEDIR}" ] && echo 1 || echo 0)" "8.2 目录被删除" "目录不存在"

# ---------------------------------------------------------------
echo "--- 9. Test 7：密码不一致要求重新输入 ---"

reset_home
capture '1\n1\npwA\npwB\nrealmatch\nrealmatch\nk0\n'
out="$CAP"
check "$(contains "$out" "两次输入不一致")" "9.1 提示密码不一致" "两次输入不一致"
check "$(contains "$(cat "${HOMEDIR}/.env" 2>/dev/null || true)" "ATRUST_PASSWORD='realmatch'")" "9.2 最终保存正确密码" "ATRUST_PASSWORD='realmatch'"

# ---------------------------------------------------------------
echo "--- 10. Test 8：端口冲突检测 ---"

reset_home
# 尝试占用 SOCKS5 基线端口（若已存在其他进程占用，则直接利用该占用；两者都会被检测到）
python3 - "$S0" >/dev/null 2>&1 <<'PY' &
import socket, time, sys
try:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.listen(1)
    time.sleep(60)
except OSError:
    pass
PY
LISTENER_PID=$!
sleep 0.5
capture "1\n1\nk0\n"
out="$CAP"
check "$(contains "$out" "端口 ${S0} 已被占用")" "10.1 提示端口冲突" "端口 ${S0} 已被占用"
check "$(contains "$out" "检测到端口冲突")" "10.2 提示停止创建" "检测到端口冲突"
check "$([ "$(line_of ' up -d')" = "100000" ] && echo 1 || echo 0)" "10.3 未执行 up（创建被中止）" "日志不含 up -d"
kill "${LISTENER_PID}" 2>/dev/null || true
wait "${LISTENER_PID}" 2>/dev/null || true

# ---------------------------------------------------------------
echo "--- 11. 已有配置重新生成（数量变化） ---"

reset_home
capture '1\n1\npw\npw\nk0\n' # 先创建 1 个
capture '1\n3\ny\nnewpw\nnewpw\nk0\n'
out="$CAP"
check "$(contains "$out" "检测到已有 aTrust 配置")" "11.1 提示已有配置" "检测到已有 aTrust 配置"
check "$(contains "$out" "重新生成配置为 3 个实例")" "11.2 提示新数量" "重新生成配置为 3 个实例"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$([ "$(printf '%s' "$C" | grep -cF 'container_name: atrust-' || true)" = "3" ] && echo 1 || echo 0)" "11.3 compose 更新为 3 个 service" "container_name 数量 = 3"
check "$([ -d "${HOMEDIR}/atrust-data-1" ] && echo 1 || echo 0)" "11.4 旧数据目录保留" "atrust-data-1 存在"
check "$([ -d "${HOMEDIR}/atrust-data-3" ] && echo 1 || echo 0)" "11.5 新建数据目录" "atrust-data-3 存在"

# ---------------------------------------------------------------
echo "--- 12. 无效菜单选项 ---"

capture 'x\nk0\n'
out="$CAP"
check "$(contains "$out" "无效选项")" "12.1 无效选项提示" "无效选项"

# ---------------------------------------------------------------
echo "--- 13. 日志查看（结束后回到菜单） ---"

# 输入菜单 9 → 实例 2 → stub 跟踪 2 秒 → 回到菜单；3 秒后再发 0 退出
set +e
CAP="$( { printf '9\n2\n'; sleep 3; printf 'k0\n'; } | timeout 40 script -qec "bash '${MANAGER}'" /dev/null 2>&1 )"
RC=$?
set -e
out="$CAP"
check "$(contains "$out" "[stub] 模拟日志")" "13.1 显示日志" "[stub] 模拟日志"
check "$([ "$(count_of "$out" "请选择 [0-")" -ge 2 ] && echo 1 || echo 0)" "13.2 日志结束后回到主菜单" "请选择出现 ≥2 次"

# ---------------------------------------------------------------
echo "--- 14. curl | bash 一键运行（管道模式） ---"

# 回归测试：通过管道把脚本喂给 bash（等价 curl -fsSL ... | bash），
# 必须能看到数量提示且创建成功（之前 ensure_tty 的 2>/dev/null 会吞掉数量提示）
reset_home
set +e
CAP="$( printf '1\n2\npw\npw\nk0\n' | timeout 40 script -qec "cat '${MANAGER}' | bash" /dev/null 2>&1 )"
RC=$?
set -e
out="$CAP"
check "$(contains "$out" "请输入要创建的 aTrust 实例数量")" "14.1 管道模式下数量提示可见" "请输入要创建的 aTrust 实例数量"
check "$(contains "$out" "创建完成")" "14.2 管道模式下创建成功" "创建完成"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$([ "$(printf '%s' "$C" | grep -cF 'container_name: atrust-' || true)" = "2" ] && echo 1 || echo 0)" "14.3 管道模式生成 2 个实例" "container_name 数量 = 2"

# ---------------------------------------------------------------
echo "--- 15. 添加单个实例（默认最大编号+1） ---"

reset_home
capture '1\n2\npw\npw\nk0\n'   # 先创建 2 个实例
capture '2\n\nk0\n'            # 菜单 2：直接回车 → max+1 = 3
out="$CAP"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$(contains "$out" "已添加实例")" "15.1 添加提示" "已添加实例"
check "$([ "$(printf '%s' "$C" | grep -cF 'container_name: atrust-' || true)" = "3" ] && echo 1 || echo 0)" "15.2 共 3 个实例" "container_name 数量 = 3"
SS=$((S0 + 2))
check "$(contains "$C" "127.0.0.1:${SS}:1080")" "15.3 新实例 SOCKS5=${SS}" "127.0.0.1:${SS}:1080"
check "$([ -d "${HOMEDIR}/atrust-data-3" ] && echo 1 || echo 0)" "15.4 数据目录 atrust-data-3" "存在 atrust-data-3"
check "$(contains "$out" "空缺")" "15.5 展示空缺可视化" "空缺"

# ---------------------------------------------------------------
echo "--- 16. 删除单个实例（保留数据，留空位） ---"

# 上节场景：1,2,3；删除编号 2，数据保留
capture '3\n2\nn\nDELETE\nk0\n'
out="$CAP"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$(contains "$out" "已删除实例")" "16.1 删除提示" "已删除实例"
check "$([ -d "${HOMEDIR}/atrust-data-2" ] && echo 1 || echo 0)" "16.2 数据目录保留" "atrust-data-2 存在"
check "$([ "$(printf '%s' "$C" | grep -cF 'container_name: atrust-' || true)" = "2" ] && echo 1 || echo 0)" "16.3 剩 2 个实例" "container_name 数量 = 2"
check "$(contains "$C" "container_name: atrust-3")" "16.4 atrust-3 保留（编号不动）" "atrust-3"
check "$(contains "$C" "container_name: atrust-1")" "16.5 atrust-1 保留" "atrust-1"

# 删除单个实例：DELETE 文本不匹配则取消
capture '3\n3\nn\nwrongtext\nk0\n'
out="$CAP"
check "$(contains "$out" "已取消")" "16.6 确认文本不匹配则取消" "已取消"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$(contains "$C" "container_name: atrust-3")" "16.7 取消后 atrust-3 仍在" "atrust-3"

# ---------------------------------------------------------------
echo "--- 17. 删除单个实例（同时删除数据） ---"

capture '3\n3\ny\nDELETE\nk0\n'
out="$CAP"
check "$(contains "$out" "已删除实例")" "17.1 删除提示" "已删除实例"
check "$([ ! -e "${HOMEDIR}/atrust-data-3" ] && echo 1 || echo 0)" "17.2 数据目录已删除" "atrust-data-3 不存在"
check "$([ -d "${HOMEDIR}/atrust-data-1" ] && echo 1 || echo 0)" "17.3 其他数据目录保留" "atrust-data-1 存在"

# ---------------------------------------------------------------
echo "--- 18. 添加单个实例（指定空缺编号） ---"

# 当前编号：1（空缺 2,3）
capture '2\n2\nk0\n'
out="$CAP"
C="$(cat "${COMPOSE}" 2>/dev/null || true)"
check "$(contains "$out" "空缺")" "18.1 展示空缺可视化" "空缺"
check "$(contains "$C" "container_name: atrust-2")" "18.2 补齐空缺 atrust-2" "atrust-2"
SS=$((S0 + 1))
check "$(contains "$C" "127.0.0.1:${SS}:1080")" "18.3 空缺端口 SOCKS5=${SS}" "127.0.0.1:${SS}:1080"
check "$(contains "$C" "container_name: atrust-1")" "18.4 atrust-1 不受影响" "atrust-1"

# ---------------------------------------------------------------
echo "--- 19. 重建单个实例 ---"

capture '4\n1\nk0\n'
out="$CAP"
check "$(contains "$out" "已重建")" "19.1 重建提示" "已重建"
check "$([ "$(line_of '--force-recreate atrust-1')" != "100000" ] && echo 1 || echo 0)" "19.2 调用 force-recreate atrust-1" "日志含 --force-recreate atrust-1"

# ---------------------------------------------------------------
echo "--- 20. Mihomo 配置输出 ---"

reset_home
capture '1\n2\npw\npw\nk0\n'
capture '12\nk0\n'
out="$CAP"
MJ="${HOMEDIR}/mihomo-override.js"
check "$([ -f "${MJ}" ] && echo 1 || echo 0)" "20.1 生成 mihomo-override.js" "文件存在"
MJ_C="$(cat "${MJ}" 2>/dev/null || true)"
check "$(contains "$MJ_C" "const port = ${SOCKS5_BASE} + i")" "20.2 端口使用真实 SOCKS5_BASE=${SOCKS5_BASE}" "const port = ${SOCKS5_BASE} + i"
check "$(contains "$MJ_C" "function main(config)")" "20.3 main() 原样保留" "function main(config)"
check "$(contains "$MJ_C" "const RULES = [")" "20.4 RULES 段保留" "const RULES = ["
check "$(contains "$MJ_C" "const HOSTS = [")" "20.5 HOSTS 段保留" "const HOSTS = ["
check "$(contains "$MJ_C" "const FAKE_IP_FILTER = [")" "20.6 FAKE_IP_FILTER 段保留" "const FAKE_IP_FILTER = ["
check "$(contains "$MJ_C" "// 示例")" "20.7 用户配置留注释示例" "// 示例"
check "$(contains "$out" "mihomo-override.js")" "20.8 输出文件路径" "mihomo-override.js"

# ---------------------------------------------------------------
echo "--- 21. 查看实例状态（无边框、无 Mihomo） ---"

capture '5\nk0\n'
out="$CAP"
check "$([ "$(printf '%s' "$out" | grep -cF '┌' || true)" = "0" ] && echo 1 || echo 0)" "21.1 状态无表格边框" "状态不含 ┌"
check "$(contains "$out" "atrust-1")" "21.2 显示实例 atrust-1" "atrust-1"
check "$(contains "$out" "atrust-2")" "21.3 显示实例 atrust-2" "atrust-2"
check "$(contains "$out" "${S0}")" "21.4 显示 SOCKS5 端口 ${S0}" "${S0}"
check "$(contains "$out" "运行")" "21.5 运行汇总" "运行"
check "$([ "$(printf '%s' "$out" | grep -cF '覆写文件' || true)" = "0" ] && echo 1 || echo 0)" "21.6 状态输出不含 Mihomo 覆写文件" "状态不含 Mihomo 覆写文件"

# ---------------------------------------------------------------
echo
echo "================ 结果汇总 ================"
echo "通过: ${pass}"
echo "失败: ${fail}"
echo "==========================================="

if (( fail > 0 )); then
  exit 1
fi
exit 0
