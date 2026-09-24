# aTrust Manager

一个面向 **WSL / Linux** 的交互式 aTrust（[`hagb/docker-atrust`](https://github.com/hagb/docker-atrust)）多实例管理工具。

纯 **Bash + Docker Compose** 实现，无需 Node.js / Python / Go / Docker Desktop。

## 特性

- 创建 / 更新多个 aTrust 实例（默认上限 20 个）
- **添加 / 删除 / 重建单个实例**：删除后保留编号空位，可补齐空缺；可视化展示现有与空缺编号
- 每个实例拥有独立数据目录（`./atrust-data-N:/root`），登录状态互相隔离
- 宿主端口自动递增，默认只绑定 `127.0.0.1`，不暴露给局域网
- 交互式输入实例数量；VNC 密码不回显、两次校验
- 自动生成 `compose.yaml`，并先通过 `docker compose config` 校验再启动
- 启动 / 停止 / 重启 / 状态 / 日志 / 删除容器（可含数据）/ 更新镜像
- **Mihomo JS 覆写配置输出**：生成可点击的 Windows 路径文件，直接复制填入 Mihomo / Clash Verge
- `restart: unless-stopped`，Docker Engine 重启后自动恢复实例
- 自动适配 `docker` 或 `sudo docker` 权限
- 端口冲突检测；删除类操作需输入 `DELETE` 二次确认

## 快速开始

在 WSL / Linux 中（一键运行）：

```bash
curl -fsSL https://am.voemp.top/atrust.sh | bash
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
| 2 | 添加单个实例 | 默认追加到最大编号 + 1；也可输入空缺编号填空位；可视化展示现有/空缺编号 |
| 3 | 删除单个实例 | 输入编号 → 删除容器，可选是否删除数据目录；**需输入 `DELETE` 确认**；剩余编号/端口保留（留空位） |
| 4 | 重建单个实例 | `docker compose up -d --force-recreate atrust-N`，保留数据 |
| 5 | 查看实例状态 | 展示每个实例的服务/状态/四个端口 + 运行汇总（无边框；不含 Mihomo 配置） |
| 6 | 启动所有实例 | `docker compose up -d` |
| 7 | 停止所有实例 | `docker compose stop`（保留容器与数据） |
| 8 | 重启所有实例 | `docker compose restart` |
| 9 | 查看日志 | 输入编号查看单个实例，直接回车查看全部；Ctrl-C 退出回到菜单 |
| 10 | 删除全部实例 | 删除所有容器，可选是否同时删除数据；**需输入 `DELETE` 确认**（原「删除容器」「完全删除」两项合并） |
| 11 | 更新 Docker 镜像 | `docker compose pull` + `up -d`，不删除数据 |
| 12 | Mihomo 配置输出 | 生成 Mihomo **JS 覆写文件**，输出可点击的 Windows 路径（`\\wsl.localhost\...`）方便复制 |
| 0 | 退出 | |

> 每个操作执行完成后，会提示「按任意键返回主菜单」，方便看完输出后再回到菜单。
>
> 删除类操作（3 / 10）都需要输入完整的 `DELETE` 才能执行，防止误删。

## 安全说明

- **VNC 密码**保存在 `~/atrust/.env`（`chmod 600`），`compose.yaml` 中只引用 `${ATRUST_PASSWORD}`，不写死密码。
- `.env` 包含 VNC 密码，**不要提交到 Git 仓库**（项目内 `.gitignore` 已忽略 `.env`）。
- 密码要求：非空、最长 128 字符、不含换行、**不含单引号**（避免破坏 `.env` 格式）。
- 默认端口只绑定 `127.0.0.1`，避免 VNC / 代理端口暴露到局域网。
- 脚本**不保存 aTrust 企业账号密码**；每个实例通过独立 `/root` 数据目录隔离登录状态。
- 删除类操作不可恢复，且需输入完整 `DELETE` 后才执行；删除实例时若同时删除数据目录，其中的 root 属主文件可能导致删除失败，脚本会（且仅会在此时）尝试 `sudo rm -rf`。

## Mihomo 配置输出

选择「12. Mihomo 配置输出」会生成 **JS 覆写配置文件**：

- 文件位置：`${ATRUST_HOME}/mihomo-override.js`
- 输出**可点击路径**（`\\wsl.localhost\Ubuntu\...`）以及 `file:///` 链接，在 Windows 中打开 → 全选复制 → 粘贴到 Mihomo / Clash Verge 的覆写配置即可
- 覆写脚本已用脚本配置的**真实 SOCKS5 起始端口**生成 aTrust 节点，`main()` 结构保持不变
- `RULES` / `HOSTS` / `FAKE_IP_FILTER` 留空并带一行注释示例，按内网需求填写（可留空）

示例文件开头：

```js
// RULES[0] → aTrust-1 → 127.0.0.1:1080
// RULES[1] → aTrust-2 → 127.0.0.1:1081
const RULES = [
  // 示例：['192.168.5.0/24', '172.25.0.0/24', '10.11.2.0/24']
]
```

「5. 查看实例状态」仅展示实例状态，不再输出 Mihomo 相关内容。

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

v0.2 不修改系统配置；实例通过 `restart: unless-stopped` 由 Docker 自动恢复。WSL 自启动配置计划在后续版本作为独立功能提供。

## 开发与测试

```bash
bash -n atrust.sh              # 语法检查
shellcheck atrust.sh           # 静态检查
bash tests/run-tests.sh        # 自动化交互测试（需在 Linux / WSL 中运行）
```

## License

[MIT](LICENSE)
