# Docker 部署手册（Kali / Debian）（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 Kali Linux（及 Debian 系发行版）上自动安装配置 Docker CE 与 Compose 插件。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；各步骤幂等，已完成的内容会自动跳过。镜像加速配置可参考 [../docker.md](../docker.md) 第 2.2 章。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `DEBIAN_SUITE` | `trixie` | Docker 官方 Debian 仓库套件名。按 `/etc/debian_version` 选择：13.x → `trixie`（Kali 2025+），12.x → `bookworm`（Kali 2023.3~2024）；`bullseye`(11) 已停止支持，不建议 |
| `ADD_USER_TO_DOCKER` | `true` | 是否将当前用户加入 docker 组（免 sudo） |

## 1. 前置检查（只读，不修改系统）

```bash
# 系统与架构
cat /etc/os-release | head -n 2
cat /etc/debian_version            # 决定 DEBIAN_SUITE：13.x→trixie，12.x→bookworm
dpkg --print-architecture

# Docker 是否已安装
docker --version 2>/dev/null || echo "DOCKER_NOT_INSTALLED"
docker compose version 2>/dev/null || echo "COMPOSE_NOT_INSTALLED"

# 服务状态（已安装时）
systemctl is-active docker 2>/dev/null || true
```

判定逻辑：

- Docker 与 Compose 均可用 → 跳过第 2 章，仅按需执行第 3 章用户组与第 4 章验证。
- Docker 已装但缺 Compose 插件 → 仅补装 `docker-compose-plugin`。
- Docker 未安装 → 继续第 2 章。

## 2. 安装 Docker CE 与 Compose 插件

### 2.1 更新系统并安装依赖

```bash
sudo apt update && sudo apt -y full-upgrade
sudo apt install -y curl gnupg2 apt-transport-https software-properties-common ca-certificates
```

### 2.2 添加 GPG Key 与仓库（已存在时跳过）

```bash
# GPG key（keyring 文件已存在则跳过）
sudo install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.asc
  sudo install -m 0644 /tmp/docker.asc /etc/apt/keyrings/docker.asc
fi

# apt 源（文件已存在则跳过；DEBIAN_SUITE 必须与 /etc/debian_version 对应）
[ -f /etc/apt/sources.list.d/docker.list ] || \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_SUITE:-trixie} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
```

### 2.3 安装

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## 3. 启用服务与用户组

```bash
sudo systemctl enable --now docker
```

将当前用户加入 docker 组（幂等；需重新登录或 `newgrp docker` 生效）：

```bash
if [ "${ADD_USER_TO_DOCKER:-true}" = "true" ] && ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo "已加入 docker 组，请重新登录后生效"
fi
```

## 4. 验证部署

```bash
docker version
docker compose version
docker run --rm hello-world
```

判定：

- 三条命令均正常输出 → 部署成功。
- `hello-world` 拉取慢或失败 → 参考 [../docker.md](../docker.md) 第 2.2 章配置镜像加速后重试。
- 服务启动失败 → `journalctl -u docker --no-pager -n 50` 查看日志。

## 5. Agent 执行注意事项

- Kali 为滚动更新发行版，`full-upgrade` 可能耗时较长，执行前告知用户；不希望升级系统时可将 2.1 拆开，仅安装依赖包。
- `DEBIAN_SUITE` 必须与 Kali 的 Debian 基底一致（`cat /etc/debian_version`：13.x 用 `trixie`，12.x 用 `bookworm`）。选错会导致依赖不满足或仓库 404；`bullseye` 已停止支持，仅老版本 Kali 需要。
- 加入 docker 组等同授予 root 级权限，执行前向用户说明风险。
- 每完成一章，向用户汇报当前状态与下一步计划。
