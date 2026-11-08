# Cisco AI Defense 安全扫描工具集部署手册（Kali）（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder 等），用于在 Kali Linux 上自动安装 [Cisco AI Defense](https://github.com/cisco-ai-defense) 开源安全扫描工具集：`mcp-scanner`、`skill-scanner`、`a2a-scanner`、`aibom`。
工具使用 `uv tool` 安装，**每个工具一个独立隔离的虚拟环境**，同时对外暴露清晰统一的命令名。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；各步骤幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `TARGET_HOST` | `192.168.40.188` | 目标主机（Kali，hostname: chengdu-linux） |
| `ACCOUNT` | `root` | 登录账号（已配置免密公钥） |
| `PYTHON_VER` | `3.13` | uv 托管的 Python 版本（工具要求 3.11+，官方示例用 3.13） |

工具与 PyPI 包名对照（名称已与命令名统一，清晰易辨认）：

| 工具命令 | PyPI 包名 | 用途 |
| --- | --- | --- |
| `mcp-scanner` / `mcp-scanner-api` | `cisco-ai-mcp-scanner` | 扫描 MCP 服务器/工具/提示词/资源的安全威胁 |
| `skill-scanner` / `skill-scanner-api` | `cisco-ai-skill-scanner` | 扫描 Agent Skill 包的恶意行为 |
| `a2a-scanner` / `a2a-scanner-api` | `cisco-ai-a2a-scanner` | 扫描 A2A（Agent-to-Agent）协议实现 |
| `cisco-aibom` | `cisco-aibom` | 生成 AI BOM（模型/智能体/MCP/数据集等资产清单） |

## 1. 前置检查（只读，不修改系统）

```bash
# 系统环境
head -n 2 /etc/os-release

# Python 版本（需 3.11+）
python3 --version

# uv 是否已安装
command -v uv >/dev/null 2>&1 && uv --version || echo "NO_UV"

# ~/.local/bin 是否在 PATH（uv tool 的命令安装位置）
echo "$PATH" | grep -c ".local/bin"

# 磁盘与内存
df -h / | tail -n 1
free -h | head -n 2
```

判定逻辑：

- uv 未安装 → 执行第 2 章。
- `~/.local/bin` 不在 PATH → 将 `export PATH="$HOME/.local/bin:$PATH"` 写入 `~/.zshrc`（Kali 默认 shell 为 zsh）。
- Python < 3.11 → 无需升级系统 Python，`uv tool install --python 3.13` 会自动下载 uv 托管的 3.13 解释器。

## 2. 安装 uv（缺失时）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"
uv --version
```

## 3. 安装工具集（每工具一个独立环境）

```bash
export PATH="$HOME/.local/bin:$PATH"

# MCP 扫描器（CLI + REST API）
uv tool install --python 3.13 cisco-ai-mcp-scanner

# Skill 扫描器（CLI + REST API + pre-commit 钩子）
uv tool install cisco-ai-skill-scanner

# A2A 协议扫描器（CLI + REST API + 代理）
uv tool install --python 3.13 cisco-ai-a2a-scanner

# AI BOM（核心版；analyze 全功能见下方注意事项）
uv tool install --python 3.13 cisco-aibom
```

> **zsh 注意：** zsh 会把 `[all]` 当作通配符并报 `no matches found`。如需安装 aibom 全功能版（含 agentic/LLM 分析），必须转义：`uv tool install --python 3.13 cisco-aibom\[all\]`。全功能版依赖 onnxruntime，旧 CPU 见第 5 章注意事项。

## 4. 验证安装

```bash
export PATH="$HOME/.local/bin:$PATH"

# 查看独立环境与命令映射（应列出 4 个工具环境）
uv tool list

# 各工具冒烟测试
mcp-scanner --help | head -n 3
skill-scanner --help | head -n 3
a2a-scanner list-analyzers | head -n 5
cisco-aibom --help | head -n 5
```

判定：

- `uv tool list` 列出 `cisco-ai-mcp-scanner`、`cisco-ai-skill-scanner`、`cisco-ai-a2a-scanner`、`cisco-aibom` 四个环境 → 安装成功。
- `cisco-aibom` 无输出且退出码 132（SIGILL）→ 见第 7 章执行记录中的 duckdb 修复方案。

## 5. 日常管理（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 列出工具环境 | `uv tool list` |
| 升级单个工具 | `uv tool upgrade cisco-ai-mcp-scanner` |
| 重装（恢复默认依赖） | `uv tool install --reinstall cisco-aibom` |
| 卸载 | `uv tool uninstall <包名>` |
| MCP 扫描 | `mcp-scanner --server-url https://host/mcp --analyzers yara --format summary` |
| 扫描本机已知 MCP 配置 | `mcp-scanner --scan-known-configs --analyzers yara` |
| Skill 扫描 | `skill-scanner scan <目录或URL>` |
| A2A 扫描 | `a2a-scanner scan --url https://host/a2a`（或 `a2a-scanner --help` 查看用法） |
| 生成 AI BOM | `cisco-aibom scan <代码目录>` |

### DVAA 靶场扫描配置（192.168.40.183:9000）

DVAA（Damn Vulnerable AI Agent，OpenA2A 出品）是 AI Agent 攻击训练靶场：主服务 9000 端口为 SPA 控制台，另有 21 个 agent 分别监听 7001+ 端口（自定义 api 协议，无标准 A2A Agent Card）。

已部署一键扫描脚本 `/usr/local/bin/dvaa-scan`（已写入服务器，可直接使用）：

```bash
# 批量扫描全部 agent（端点安全头/HTTPS/健康检查），结果存 /root/dvaa-scan-results/
dvaa-scan
# 指定其他 DVAA 地址
dvaa-scan http://192.168.40.183:9000
```

脚本行为：
1. 从 `<DVAA>/agents` 拉取 agent 清单（id/port/securityLevel）；
2. 按 agent 元数据自动生成 A2A agent card（存 `cards/<id>.json`，可用 `a2a-scanner scan-card cards/<id>.json --analyzers yara` 做 card 级分析）；
3. 逐 agent 执行 `a2a-scanner scan-endpoint http://<host>:<port>`，JSON 结果存 `<id>.json`；
4. 汇总各 agent 的 `Total Findings` 到 `summary.txt`。

**使用前提**：第 6 章的 a2a-scanner 私网放行补丁必须已应用（否则所有 agent 端口都报 `Private IP addresses not allowed`）。

### DVAA 红队对抗脚本（Prompt Injection 自动化）

仓库脚本 `tools/dvaa-redteam.py`，已部署到 `/usr/local/bin/dvaa-redteam.py`。对 DVAA 的 agent 批量执行多类 prompt injection，采集 `attacks.detected` 检测结果并按「精确 secret 模式」量化数据外泄（不做关键词启发式，避免误报）。

```bash
# 枚举 agent 清单（端口动态下发，无需手工维护）
python3 /usr/local/bin/dvaa-redteam.py --list

# 攻击 legacybot（critical），每载荷 5 轮（应对非确定性后端）
python3 /usr/local/bin/dvaa-redteam.py --target legacybot --rounds 5

# 攻击全部 21 个 agent，每载荷 3 轮
python3 /usr/local/bin/dvaa-redteam.py --target all --rounds 3

# 只跑某几类载荷 + 输出完整证据
python3 /usr/local/bin/dvaa-redteam.py --target legacybot --cats obfuscation,roleplay -o /tmp/rt.json
```

载荷类别（`--cats` 参数）：`direct`（直接注入）/ `jailbreak`（越狱）/ `exfiltration`（数据外泄）/ `obfuscation`（模板占位符、debug 措辞混淆）/ `roleplay`（角色扮演游戏化）。

实测结论（legacybot，15 次）：漏报率约 53%，其中 **`obfuscation` 与 `roleplay` 两类 100% 绕过检测**（`detected=false`），`direct`/`jailbreak`/`exfiltration` 大部分被检出；模型层零数据外泄（安全对齐 LLM 兜底）。详见 `reports/red-team-dvaa-20261108.md`。

### 可选环境变量（按需配置，不配也能用离线分析器）

```bash
# Cisco AI Defense API 分析器
export MCP_SCANNER_API_KEY="your_cisco_api_key"

# LLM 分析器（支持任意 LiteLLM 模型，也支持本地 Ollama）
export MCP_SCANNER_LLM_API_KEY="any-value"          # 本地模型时可为任意值
export MCP_SCANNER_LLM_ENDPOINT="http://192.168.40.189:11434"  # 指向已有 Ollama
```

### 在 AI IDE（Trae/Qoder）中调用

1. **CLI 方式**：IDE Agent 通过 SSH 到本机直接执行上述命令（需 `~/.local/bin` 在 PATH 中）。
2. **REST API 方式**：`mcp-scanner-api --host 0.0.0.0 --port 8080` 起服务，远端 Agent 用 curl 调用。
3. **MCP 封装**：可用 FastMCP 把上述 CLI 封装成 MCP Server 注册进 IDE，实现 Agent 原生调用。

## 6. Agent 执行注意事项

- Kali 默认 shell 是 **zsh**：`[all]` 等 `[...]` 模式必须转义（`\[all\]`），`===` 开头的 echo 标记会触发 `=cmd` 展开，标记避免用等号开头。
- **从 Windows 通过 ssh 执行远程命令时，双引号会被 Windows OpenSSH 剥掉**，复杂脚本建议先 `scp` 脚本文件再执行，避免内联引号。
- a2a-scanner 首次运行会尝试联网拉取 LiteLLM 模型价格表（raw.githubusercontent.com），失败时自动回退本地备份并打印 WARNING，属正常现象，不影响 YARA/静态分析。
- 本机网络对部分境外源较慢/超时，LLM 分析器建议指向内网 Ollama（见第 5 章环境变量）。
- 验证无输出的命令时用 `echo EXIT=$?` 拿退出码：132 = SIGILL（指令集不兼容），0 = 正常。
- **a2a-scanner 私网限制补丁**：官方为防 SSRF 硬编码禁止扫描私网/localhost 地址（CLI 无开关）。内网扫描需打补丁：将 `site-packages/a2ascanner/utils/validators.py`、`utils/http_client.py` 中所有 `allow_private_ips=False`（含默认值与显式传参）改为 `True`。注意 `uv tool upgrade` 后补丁会被覆盖，需重新执行。

## 7. 部署执行记录

| 项目 | 值 |
| --- | --- |
| 执行日期 | 2026-11-08 |
| 目标主机 | 192.168.40.188（Kali GNU/Linux Rolling，hostname: chengdu-linux），root 免密登录 |
| 基础环境 | Python 3.14.8（系统）/ uv 0.13.7（`~/.local/bin`，PATH 已含） |
| 安装结果 | mcp-scanner v4.8.7、skill-scanner v2.3.2、a2a-scanner v1.0.1、cisco-aibom v1.10.1，全部 `uv tool` 独立环境，命令冒烟测试通过 |
| 遇到的问题 | `cisco-aibom` 启动即 SIGILL（退出码 132）：CPU 为 Intel Xeon X5660（Westmere，2010，无 AVX/AVX2），duckdb 2.0.0 官方 wheel 使用了不支持的指令集，import 即崩溃（numpy/pandas 正常，二分定位到 duckdb） |
| 修复方案 | `uv pip install --python /root/.local/share/uv/tools/cisco-aibom/bin/python duckdb==1.1.3`（满足 aibom 的 `duckdb>=1.0.0` 约束），修复后全部模块导入正常、CLI 可用 |
| 遗留说明 | aibom 未装 `[all]` extras（agentic/LLM 依赖 onnxruntime，同样要求 AVX，此 CPU 无法运行）；核心扫描功能不受影响，`analyze` 子命令需在支持 AVX2 的机器上使用 |
| 后续使用（2026-11-08） | 首次实际扫描 `http://192.168.40.183:9000`：a2a-scanner 官方硬编码禁止私网地址（防 SSRF，CLI 无开关），已按第 6 章补丁方案放行；扫描返回 2 个发现（HTTP 明文协议、缺少安全响应头）。经探测确认该端点是 **DVAA（Damn Vulnerable AI Agent，OpenA2A 出品的 AI Agent 攻击训练靶场）**，SPA 对未知路径一律回退 index.html，故无 A2A Agent Card、也非 MCP server（mcp-scanner 扫 `/` 与 `/mcp` 均 404）。2 个发现属靶场预期形态，可将其作为 AI Defense 工具集的检测演练目标 |
| DVAA 批量扫描（2026-11-08） | 部署 `/usr/local/bin/dvaa-scan` 并完成首轮全量扫描：21 个 agent（7001-7023 端口，securebot/legacybot/memorybot 等）全部 3 个发现（HTTP 明文、缺安全头、无标准 card，属靶场预期）。已按 agent 元数据生成 21 个 A2A card（`/root/dvaa-scan-results/cards/`），`scan-card --analyzers yara` 验证通过——card 中的 vulnerabilities 描述（如 legacybot 的 promptInjection）可触发 YARA 的 PROMPT INJECTION 检测规则，可用于蓝队规则演练 |
