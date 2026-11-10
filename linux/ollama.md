# Ollama 服务部署手册（Ubuntu）（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 Ubuntu 上自动完成 Ollama 离线包安装与 systemd 服务配置。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；各步骤幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `OLLAMA_TAR_PATH` | `./ollama-linux-amd64.tar.zst` | 离线安装包路径（.tar.zst） |
| `INSTALL_PREFIX` | `/usr` | 解压目标目录（二进制将位于 `<PREFIX>/bin/ollama`） |
| `OLLAMA_HOST` | `0.0.0.0` | 服务监听地址 |
| `OLLAMA_ORIGINS` | `*` | 允许的跨域来源（生产环境应收紧） |

## 1. 前置检查（只读，不修改系统）

```bash
# 系统环境
cat /etc/os-release | head -n 2

# 是否已安装二进制
ollama --version 2>/dev/null || echo "OLLAMA_NOT_INSTALLED"

# 运行用户与服务是否已配置
id ollama 2>/dev/null || echo "NO_USER"
ls /etc/systemd/system/ollama.service 2>/dev/null || echo "NO_SERVICE"

# 解压工具 zstd 是否可用
command -v zstd >/dev/null 2>&1 && echo "ZSTD_OK" || echo "NO_ZSTD"

# 安装包是否存在（未设置参数时按默认路径检查）
ls -lh "${OLLAMA_TAR_PATH:-./ollama-linux-amd64.tar.zst}" 2>/dev/null || echo "TAR_MISSING"
```

判定逻辑：

- 安装包不存在 → 向用户索取 tar.zst 文件路径，不要继续。
- 二进制已存在 → 跳过第 2 章，仅检查/修复第 3、4 章。
- 服务已存在且 `systemctl is-active ollama` 为 active → 跳过第 3、4 章，仅执行第 5 章验证。

## 2. 安装 Ollama 二进制

### 2.1 安装解压工具（缺失时）

```bash
sudo apt update && sudo apt install -y zstd
```

### 2.2 解压安装

```bash
sudo tar -I zstd -xvf "${OLLAMA_TAR_PATH:-./ollama-linux-amd64.tar.zst}" -C "${INSTALL_PREFIX:-/usr}"
```

验证：

```bash
ollama --version
```

> 离线包含 `bin/ollama`、`lib/ollama` 等目录，解压到 `INSTALL_PREFIX`（默认 `/usr`）后二进制位于 `<PREFIX>/bin/ollama`。

## 3. 创建运行用户（缺失时）

```bash
id ollama >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin -m -d /home/ollama ollama
sudo mkdir -p /home/ollama/.ollama
sudo chown -R ollama:ollama /home/ollama
```

> 服务文件以 `User=ollama` 运行，用户不存在会导致服务启动失败，故此步为必检项。
> **注意：不要使用 `-M`（不建主目录）。** Ollama 启动时需要在 `/home/ollama/.ollama` 下生成密钥与配置，若目录不存在且 `/home` 对 ollama 用户不可写，服务会报
> `Error: could not create directory mkdir /home/ollama: permission denied` 并反复重启。

## 4. 配置 systemd 服务

### 4.1 写入服务文件

若 `/etc/systemd/system/ollama.service` 已存在，先读取内容向用户展示差异，确认后再覆盖：

```bash
sudo tee /etc/systemd/system/ollama.service > /dev/null <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${INSTALL_PREFIX:-/usr}/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=${OLLAMA_HOST:-0.0.0.0}"
Environment="OLLAMA_ORIGINS=${OLLAMA_ORIGINS:-*}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF
```

> 服务文件在写入时由 shell 展开参数区变量；`PATH` 固定为标准系统路径（与官方安装脚本一致），不依赖当前会话。修改参数后需重新写文件并 `daemon-reload` + restart。

### 4.2 启用并启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl restart ollama
```

## 5. 验证部署

```bash
sudo systemctl is-active ollama
curl -s http://127.0.0.1:11434/api/version
```

判定：

- 服务 active 且 `/api/version` 返回 JSON 版本信息 → 部署成功。
- 服务启动失败 → `journalctl -u ollama --no-pager -n 50` 查看日志，常见原因：
  - `could not create directory mkdir /home/ollama: permission denied` → 第 3 章主目录未创建（勿用 `useradd -M`），执行 `mkdir -p /home/ollama/.ollama && chown -R ollama:ollama /home/ollama` 后重启服务。
  - `ollama` 用户不存在 → 补做第 3 章。
  - 二进制路径不符 → 检查第 2 章解压目录，确认 `<INSTALL_PREFIX>/bin/ollama`（默认 `/usr/bin/ollama`）存在。

## 6. 日常管理（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 查看服务状态 | `sudo systemctl status ollama` |
| 重启服务 | `sudo systemctl restart ollama` |
| 拉取模型 | `ollama pull <model>` |
| 运行模型对话 | `ollama run <model>` |
| 查看已装模型 | `ollama list` |

## 7. Agent 执行注意事项

- 服务操作失败时用 `journalctl -u ollama --no-pager -n 50` 定位原因，不要盲目重试。
- `OLLAMA_HOST=0.0.0.0` 会将服务暴露给局域网，生产环境建议收紧 `OLLAMA_ORIGINS` 并配合防火墙规则，修改前向用户确认。
- 修改服务文件后必须 `daemon-reload` 再重启，否则配置不生效。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 8. 部署执行记录

| 项目 | 值 |
| --- | --- |
| 执行日期 | 2026-11-08 |
| 目标主机 | 192.168.40.189（Ubuntu 24.04.2 LTS，hostname: ubuntu） |
| 登录账号 | 实际可用账号为 `root`（已配置免密公钥，密码不在文档中记录）；`roo` 账号认证失败 |
| 安装包 | `/root/ollama-linux-amd64.tar.zst`（1.5G） |
| 安装版本 | Ollama 0.40.15 |
| 运行用户 | ollama（uid=999），已创建主目录 `/home/ollama` |
| 服务状态 | active，开机自启（multi-user.target.wants） |
| 验证结果 | 本机 `127.0.0.1:11434/api/version` 与局域网 `192.168.40.189:11434/api/version` 均返回 `{"version":"0.40.15"}`，监听 `*:11434` |
| 运行模式 | CPU 推理（无 GPU），内存 62.9 GiB |
| 遇到的问题 | 首次启动失败：`useradd -M` 未创建主目录，服务无法写 `/home/ollama/.ollama`。已通过创建目录并 chown 修复，流程已同步更新至第 3 章 |
| 安全决策（2026-11-08） | 经与用户确认：`OLLAMA_ORIGINS` 保持 `*`，不启用 UFW 防火墙，11434/SSH 允许任意来源网段访问（该服务器有跨网段访问需求，客户端来自 192.168.11.x 与 192.168.40.x 等多个网段，且主机上运行有 Docker 服务占用 80 端口）。此为用户知悉并接受的风险，后续如需收紧按第 5/7 章处理 |
