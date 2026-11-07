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

# 安装包是否存在
ls -lh "$OLLAMA_TAR_PATH" 2>/dev/null || echo "TAR_MISSING"
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
sudo tar -I zstd -xvf "$OLLAMA_TAR_PATH" -C /usr
```

验证：

```bash
ollama --version
```

> 离线包含 `bin/ollama`、`lib/ollama` 等目录，直接解压到 `/usr` 后二进制位于 `/usr/bin/ollama`。

## 3. 创建运行用户（缺失时）

```bash
id ollama >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin -M ollama
```

> 服务文件以 `User=ollama` 运行，用户不存在会导致服务启动失败，故此步为必检项。

## 4. 配置 systemd 服务

### 4.1 写入服务文件

若 `/etc/systemd/system/ollama.service` 已存在，先读取内容向用户展示差异，确认后再覆盖：

```bash
sudo tee /etc/systemd/system/ollama.service > /dev/null <<-'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_ORIGINS=*"
Environment="PATH=$PATH"

[Install]
WantedBy=multi-user.target
EOF
```

> `OLLAMA_HOST` / `OLLAMA_ORIGINS` 的值应与参数区一致，Agent 按参数替换后再写入。

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
- 服务启动失败 → `journalctl -u ollama --no-pager -n 50` 查看日志，常见原因：ollama 用户不存在（第 3 章）、二进制路径不符（第 2 章）。

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
