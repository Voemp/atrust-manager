# aTrust Manager

一个面向 **WSL / Linux** 的交互式 aTrust（[`hagb/docker-atrust`](https://github.com/hagb/docker-atrust)）多实例管理工具。

纯 **Bash + Docker Compose** 实现，无需 Node.js / Python / Go / Docker Desktop。

## 特性

- 创建 / 更新多个 aTrust 实例（默认上限 20 个）
- 每个实例拥有独立数据目录（`./atrust-data-N:/root`），登录状态互相隔离
- 宿主端口自动递增，默认只绑定 `127.0.0.1`，不暴露给局域网
- 交互式输入实例数量；VNC 密码不回显、两次校验
- 自动生成 `compose.yaml`，并先通过 `docker compose config` 校验再启动
- 启动 / 停止 / 重启 / 状态 / 日志 / 删除容器 / 完全删除 / 更新镜像
- `restart: unless-stopped`，Docker Engine 重启后自动恢复实例
- 自动适配 `docker` 或 `sudo docker` 权限
- 端口冲突检测；完全删除需输入 `DELETE` 二次确认

## 快速开始

在 WSL / Linux 中：

```bash
curl -fsSL https://<HOST>/atrust.sh | bash
```

或本地运行：

```bash
bash atrust.sh
```

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Linux（含 WSL2） |
| Shell | Bash ≥ 4 |
| Docker | Docker Engine（正在运行） |
| Compose | Docker Compose V2（`docker compose`） |

运行前建议确认：

```bash
docker info
docker compose version
```

若当前用户不在 `docker` 组，脚本会自动尝试 `sudo docker`（需要 sudo 权限）。

## 数据目录

默认数据目录为 `~/atrust`，可用环境变量覆盖：

```bash
ATRUST_HOME=/some/path bash atrust.sh
```

同样可用环境变量调整起始端口（默认与下表一致）与实例上限：

```bash
SOCKS5_BASE=1080   # SOCKS5 起始端口
HTTP_BASE=8888     # HTTP 代理起始端口
VNC_BASE=5901      # VNC 起始端口
TUNNEL_BASE=54631  # Tunnel 起始端口
MAX_INSTANCES=20   # 实例数量上限
```

目录结构：

```
~/atrust/
├── compose.yaml
├── .env                # VNC 密码（权限 600）
├── atrust-data-1/      # 实例 1 的 /root 挂载数据
├── atrust-data-2/
└── ...
```

## 端口分配

实例编号从 1 开始，宿主端口按基数递增：

| 实例 | SOCKS5 | HTTP | VNC | Tunnel |
| --- | ---: | ---: | ---: | ---: |
| atrust-1 | 1080 | 8888 | 5901 | 54631 |
| atrust-2 | 1081 | 8889 | 5902 | 54632 |
| atrust-3 | 1082 | 8890 | 5903 | 54633 |

容器内部端口固定为 `1080 / 8888 / 5901 / 54631`，仅宿主端口递增，且全部绑定 `127.0.0.1`。

## 菜单说明

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 创建 / 更新实例 | 询问数量 → 端口冲突检查 → VNC 密码 → 生成 compose → 校验 → 拉取镜像 → 启动 |
| 2 | 查看实例状态 | `docker compose ps` + 端口汇总 + Mihomo SOCKS5 示例 |
| 3 | 启动所有实例 | `docker compose up -d` |
| 4 | 停止所有实例 | `docker compose stop`（保留容器与数据） |
| 5 | 重启所有实例 | `docker compose restart` |
| 6 | 查看日志 | 输入编号查看单个实例，直接回车查看全部；Ctrl-C 退出回到菜单 |
| 7 | 删除所有容器（保留数据） | `docker compose down`，不删除数据目录 |
| 8 | 完全删除（容器 + 数据） | 删除容器、`compose.yaml`、`.env`、`atrust-data-*`，需输入 `DELETE` 确认 |
| 9 | 更新 Docker 镜像 | `docker compose pull` + `up -d`，不删除数据 |
| 0 | 退出 | |

## 安全说明

- **VNC 密码**保存在 `~/atrust/.env`（`chmod 600`），`compose.yaml` 中只引用 `${ATRUST_PASSWORD}`，不写死密码。
- `.env` 包含 VNC 密码，**不要提交到 Git 仓库**（项目内 `.gitignore` 已忽略 `.env`）。
- 密码要求：非空、最长 128 字符、不含换行、**不含单引号**（避免破坏 `.env` 格式）。
- 默认端口只绑定 `127.0.0.1`，避免 VNC / 代理端口暴露到局域网。
- 脚本**不保存 aTrust 企业账号密码**；每个实例通过独立 `/root` 数据目录隔离登录状态。
- 完全删除不可恢复。数据目录中若存在 root 属主文件导致删除失败，脚本会（且仅会在此时）尝试 `sudo rm -rf`。

## Mihomo 配置示例

选择「2. 查看实例状态」会自动输出 SOCKS5 节点示例：

```yaml
proxies:
  - name: aTrust-1
    type: socks5
    server: 127.0.0.1
    port: 1080

  - name: aTrust-2
    type: socks5
    server: 127.0.0.1
    port: 1081
```

第一阶段只做展示，不会自动修改 Mihomo 配置。

## 常见问题

**`[✗] 未检测到可用的 Docker。`**

```bash
sudo systemctl start docker    # 启动
sudo systemctl enable docker   # 设置开机自启
```

**WSL 中容器启动失败（tun 设备 / NET_ADMIN）**

确认内核与 Docker 支持 TUN：

```bash
ls -l /dev/net/tun
```

**端口冲突**

创建之前脚本会检查宿主端口；若 1080 / 8888 / 5901 / 54631 等端口被其他程序占用，会明确提示并停止创建。

**有关 WSL 开机自启动**

v0.1 不修改系统配置；实例通过 `restart: unless-stopped` 由 Docker 自动恢复。WSL 自启动配置计划在后续版本作为独立功能提供。

## 开发与测试

```bash
bash -n atrust.sh              # 语法检查
shellcheck atrust.sh           # 静态检查
bash tests/run-tests.sh        # 自动化交互测试（需在 Linux / WSL 中运行）
```

## License

[MIT](LICENSE)
