# VSCode + Claude Code 接入硅基流动（DeepSeek V4.1-Flash）安装与配置文档

> 适用日期：2026-11-15　｜　目标：在 **Windows / Kali** 的 VSCode 中，用 Claude Code 直连硅基流动（SiliconFlow），模型为 DeepSeek 最新 Flash（**V4.1-Flash**）。
>
> **安全提示（请先读）**
> 1. 本文**不写入真实 API Key**，一律用占位符 `sk-你的硅基流动密钥`。密钥只应放在用户级配置里，**不要**放进项目目录的 `.claude/settings.json`（会随 git 提交泄露）。
> 2. 若 Key 曾在聊天/截图中明文出现，建议到硅基流动控制台**吊销并重建**。
> 3. 模型 ID 已通过硅基流动 `/v1/models` 接口**实测核实**为 `deepseek-ai/DeepSeek-V4.1-Flash`（见第 3 节）。

---

## 0. 快速安装 Runbook（按顺序执行）

### 0.1 Windows（PowerShell）

```powershell
# ① 确认 Node ≥ 18
node --version

# ② 安装 Claude Code 到「用户级 npm 前缀」（关键：该目录才在持久 PATH 上）
npm install -g @anthropic-ai/claude-code --prefix "$env:APPDATA\npm"

# ③ 刷新 PATH 并确认 claude 可解析
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
where.exe claude
claude --version

# ④ 写入配置（内容见第 4 节）
notepad "$env:USERPROFILE\.claude\settings.json"

# ⑤ 安装 VS Code 扩展
& "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" --install-extension anthropic.claude-code

# ⑥ 端到端验证（见第 6 节）
claude -p "请只回复两个字：正常"
```

> **为什么用 `--prefix "$env:APPDATA\npm"`**：本机 Node 由妙手托管，其目录（`C:\Users\liude\.meituan-catpaw\runtimes\node\versions\24.18.0`）**只在妙手进程内注入 PATH**，普通终端和 VS Code 看不到。而 `%APPDATA%\npm` 本就在用户 PATH 上，装这里才能被 VS Code 直接调用。详见第 7 节。

### 0.2 Kali / Linux（bash）

```bash
# ① 确认 Node ≥ 18（必须是 Linux 原生 Node）
node --version

# ② 安装 Claude Code（推荐官方脚本，无需 sudo）
curl -fsSL https://claude.ai/install.sh | bash

#   或：npm 装到用户前缀（避免 sudo）
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
export PATH=~/.npm-global/bin:$PATH
npm install -g @anthropic-ai/claude-code

# ③ 确认可解析
which claude
claude --version

# ④ 写入配置（内容见第 4 节），并收紧权限
chmod 600 ~/.claude/settings.json

# ⑤ 安装 VS Code 扩展
code --install-extension anthropic.claude-code

# ⑥ 端到端验证（见第 6 节）
claude -p "请只回复两个字：正常"
```

> **不要**用 `sudo` **运行** `claude`（安装可以用 sudo，但运行时会去读 `/root/.claude`，读不到你用户的配置）。

---

## 1. 原理与链路

Claude Code 本质是一个跑在终端里的 CLI（Node.js），VSCode 的「Claude Code」扩展只是给它套了一层图形壳。真正发请求、读文件、执行命令的是 `claude` 进程。

Claude Code 只说 **Anthropic Messages 协议**（`POST /v1/messages`）。硅基流动提供了 **Anthropic 兼容端点**，所以可以直接把 Claude Code 的 Base URL 指过去，底层模型换成 DeepSeek。

```
你在 VSCode 侧边栏输入
        │
        ▼
Claude Code CLI  ──(Anthropic Messages /v1/messages)──►  硅基流动 https://api.siliconflow.cn
        │                                                        │
        │                                                        ▼
        │                                              DeepSeek V4.1-Flash
        ▼
   流式响应渲染回 VSCode 面板
```

**关键规则（最容易踩的坑）**：`ANTHROPIC_BASE_URL` **只填到域名，不要带 `/v1`**。Claude Code 内部会自动拼 `/v1/messages`；写成 `.../v1` 会变成 `/v1/v1/messages` → **404**。这与 OpenAI 系工具（Cline 等通常要带 `/v1`）正好相反。

两种接法：

| 方案 | 说明 | 适用 |
|---|---|---|
| **直连（推荐）** | Claude Code 直接指向硅基流动兼容端点 | 只固定用 DeepSeek，最简单、少一层进程 |
| 网关（ccr / ccSwitch） | 本地起一个转换/路由层（如 `127.0.0.1:3456`），Claude Code 指向它 | 需要多模型切换、失败回退、请求日志、多 Key 池（见第 9 节） |

---

## 2. 前置准备

### 2.1 Node.js
- Claude Code 要求 **Node.js ≥ 18**；若打算用 claude-code-router（ccr），要求 **Node.js ≥ 22**。
- 本机实测：`node v24.18.0` / `npm 11.16.0`，两者都满足。
- Kali 上务必装 **Linux 原生 Node**（见第 7 节 WSL 坑）。

### 2.2 硅基流动侧
1. 登录硅基流动控制台，完成**实名认证**（未实名无法调用 API）。
2. 「API 密钥」→ 新建 → 复制 `sk-...`（只显示一次）。
3. 「模型广场」确认 DeepSeek V4.1-Flash 的**完整模型 ID**（见第 3 节）。

---

## 3. 模型选择：DeepSeek 最新 Flash

- DeepSeek 最新 Flash 为 **V4.1-Flash**，官方接口名 **`deepseek-flash`**；当前主力快照 V4.1-Flash-1017（2026-10-17 上线，1M 上下文，编程/Agent 任务强化）。2026-11-13 起该模型还承载了联网搜索、文件输入、读链接等「全家桶」能力。
- 硅基流动模型广场已上架该版本，API 调用方式与价格不变。

**硅基流动 model ID（已实测核实）**：
```
deepseek-ai/DeepSeek-V4.1-Flash
```
> **核实方式**（推荐，最可靠）：
> ```bash
> curl https://api.siliconflow.cn/v1/models -H "Authorization: Bearer <你的Key>"
> ```
> 在返回的 `data[].id` 列表中确认。
>
> ⚠️ 注意**没有** `-1017` 后缀：写成 `deepseek-ai/DeepSeek-V4.1-Flash-1017` 会返回 `400 Model does not exist`。

---

## 4. 配置文件（Windows / Kali 通用）

### 4.1 用户级 `~/.claude/settings.json`（推荐，持久、全项目生效）

- Windows 路径：`C:\Users\liude\.claude\settings.json`（即 `%USERPROFILE%\.claude\settings.json`）
- Kali 路径：`/home/你的用户名/.claude/settings.json`

内容（严格 JSON，不能有注释、末尾不能多逗号）：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.siliconflow.cn",
    "ANTHROPIC_AUTH_TOKEN": "sk-你的硅基流动密钥",
    "ANTHROPIC_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash"
  },
  "hasCompletedOnboarding": true
}
```

字段说明：

| 字段 | 作用 |
|---|---|
| `ANTHROPIC_BASE_URL` | 兼容端点域名，**不带 `/v1`** |
| `ANTHROPIC_AUTH_TOKEN` | 第三方端点的 bearer 凭证（也可用 `ANTHROPIC_API_KEY`，**二选一，不要同时设**） |
| `ANTHROPIC_MODEL` | 默认模型 |
| `ANTHROPIC_DEFAULT_HAIKU/SONNET/OPUS_MODEL` | Claude Code 内部各档位任务用的模型名。第三方端点没有 Claude 的 haiku/sonnet/opus，全部指向 DeepSeek，避免后台任务报「模型不存在」 |
| `hasCompletedOnboarding` | 跳过首次登录引导。若你的版本不识别该字段（报错/无效），删掉它即可，不影响主流程 |

Kali 上建议收紧权限：
```bash
chmod 600 ~/.claude/settings.json
```

> 若之前用 OAuth 登录过，可能存在旧凭证导致冲突：先执行 `claude /logout`，或删除 `~/.claude/.credentials.json` 后重试。

### 4.2 临时验证（当前终端会话，可选）

PowerShell：
```powershell
$env:ANTHROPIC_BASE_URL = "https://api.siliconflow.cn"
$env:ANTHROPIC_AUTH_TOKEN = "sk-你的硅基流动密钥"
$env:ANTHROPIC_MODEL = "deepseek-ai/DeepSeek-V4.1-Flash"
claude
```

Git Bash / Kali：
```bash
export ANTHROPIC_BASE_URL="https://api.siliconflow.cn"
export ANTHROPIC_AUTH_TOKEN="sk-你的硅基流动密钥"
export ANTHROPIC_MODEL="deepseek-ai/DeepSeek-V4.1-Flash"
claude
```

> `~/.claude/settings.json` 与 shell `export` **二选一即可**，前者更省事（VS Code 扩展也会读到）。

---

## 5. VS Code 侧

### 5.1 安装扩展
- 图形方式：扩展市场搜 **`Claude Code`**（发布方 Anthropic，ID `anthropic.claude-code`）。
- 命令行方式（Windows / Kali 都可用）：
  ```bash
  code --install-extension anthropic.claude-code
  ```
  Windows 若 `code` 不在 PATH，用全路径：
  ```powershell
  & "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd" --install-extension anthropic.claude-code
  ```

### 5.2 环境变量继承
- 一般情况下**无需**改 VS Code 的 `settings.json`：扩展会启动 Claude Code CLI，CLI 读取 `~/.claude/settings.json` 的 `env`。
- 若扩展面板连不上、但终端 `claude` 正常，说明是 VS Code 进程环境变量没继承。可在 VS Code 用户 `settings.json` 注入：
  - Windows：`%APPDATA%\Code\User\settings.json`
    ```json
    {
      "terminal.integrated.env.windows": {
        "ANTHROPIC_BASE_URL": "https://api.siliconflow.cn",
        "ANTHROPIC_AUTH_TOKEN": "sk-你的硅基流动密钥",
        "ANTHROPIC_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash"
      }
    }
    ```
  - Kali：`~/.config/Code/User/settings.json`
    ```json
    {
      "terminal.integrated.env.linux": {
        "ANTHROPIC_BASE_URL": "https://api.siliconflow.cn",
        "ANTHROPIC_AUTH_TOKEN": "sk-你的硅基流动密钥",
        "ANTHROPIC_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash"
      }
    }
    ```
- 改完**完全重启 VS Code**（不是 reload window）。

---

## 6. 验证（分层）

1. **CLI 可用**：`claude --version`
2. **PATH 可解析**（Windows 重要）：
   ```powershell
   $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
   where.exe claude
   ```
3. **接口连通（绕过 Claude Code 直接测）**
   ```bash
   curl https://api.siliconflow.cn/v1/messages \
     -H "x-api-key: sk-你的硅基流动密钥" \
     -H "anthropic-version: 2023-06-01" \
     -H "content-type: application/json" \
     -d '{"model":"deepseek-ai/DeepSeek-V4.1-Flash","max_tokens":64,"messages":[{"role":"user","content":"你好"}]}'
   ```
   Windows PowerShell 里 `curl` 是别名，请用 `curl.exe` 或 Git Bash。能返回正常文本 → 端点/Key/模型 ID 都对。
4. **Claude Code 冒烟**：
   ```bash
   claude -p "请只回复两个字：正常"
   ```
   预期返回 `正常`。
5. **VS Code 内**：**完全重启 VS Code** 后打开 Claude 图标面板，发一句并观察是否读取/修改当前工作区文件。

> **已知无害提示**：首次运行会打印
> `Claude Code doesn't recognize the model "deepseek-ai/DeepSeek-V4.1-Flash", so it assumes a context window of 1m tokens.`
> 这是因为 Claude Code 内置的模型表里没有第三方模型名，它按 1M 上下文处理。**不影响使用，可忽略**（V4.1-Flash 本身就是 1M 上下文）。

---

## 7. Windows VSCode vs Kali VSCode：差异与注意点

**结论：协议、环境变量名、模型 ID、密钥完全一致；差异只在「安装方式、配置文件路径、Shell 语法、Node/npm 来源、VSCode 设置键」这几处。**

| 维度 | Windows | Kali / Linux |
|---|---|---|
| Claude Code 安装 | `npm i -g ... --prefix "$env:APPDATA\npm"`（或官方 `irm https://claude.ai/install.ps1 \| iex`） | `curl -fsSL https://claude.ai/install.sh \| bash`（推荐）或 npm 用户前缀 |
| 全局包落点 | `%APPDATA%\npm`（已在用户 PATH） | `~/.npm-global/bin` 或官方脚本目录（需自行加 PATH） |
| Shell | PowerShell / cmd / Git Bash | bash / zsh |
| 环境变量语法 | `$env:NAME="value"`（仅当前会话） | `export NAME="value"` |
| 持久化配置 | `%USERPROFILE%\.claude\settings.json` | `~/.claude/settings.json` |
| VSCode 用户设置 | `%APPDATA%\Code\User\settings.json` | `~/.config/Code/User/settings.json` |
| 注入终端 env 的设置键 | `terminal.integrated.env.windows` | `terminal.integrated.env.linux` |
| Node 来源 | 本机 Node `v24.18.0`（满足）；**注意妙手托管目录不在持久 PATH** | **必须 Linux 原生 Node**；WSL 里不要用 Windows 侧继承的 node/npm |
| 凭据权限 | 一般无需额外处理 | 建议 `chmod 600 ~/.claude/settings.json` |
| `curl` 注意 | `curl` 是 `Invoke-WebRequest` 别名，测 API 用 `curl.exe`/Git Bash | 原生 `curl` |
| 路径 | 反斜杠、盘符；含中文路径个别工具可能异常 | 正斜杠；大小写敏感 |

**共同注意点**
1. `ANTHROPIC_BASE_URL` 不要带 `/v1`。
2. `ANTHROPIC_AUTH_TOKEN` 与 `ANTHROPIC_API_KEY` 二选一，同设可能报 auth conflict。
3. 改完配置要**新开终端 / 完全重启 VSCode** 才生效。
4. 模型 ID 用**带斜杠的全名** `deepseek-ai/DeepSeek-V4.1-Flash`，不能只写 `DeepSeek-V4.1-Flash`，也不能加 `-1017`。

**Windows 专属坑**
- **PATH 陷阱（本机实测）**：妙手托管的 Node 运行时（`C:\Users\liude\.meituan-catpaw\runtimes\node\versions\24.18.0`）只在妙手进程内注入 PATH，普通终端 / VS Code 看不到。若把 `claude` 装到这里，会出现「妙手里能用、VS Code 里报 command not found」。务必装到 `%APPDATA%\npm`（已在用户 PATH）。
- npm 安装时可能提示 `npm warn allow-scripts ... postinstall: node install.cjs`——**可忽略**，原生二进制已随包发布，不跑 postinstall 也能用。如确需执行：`npm approve-scripts <pkg>`。
- 中文工作区路径（如 `D:\文档\GitHub\deploy-ops`）：多数工具没问题，个别 CLI/脚本对非 ASCII 路径敏感；若出现诡异报错，先复制到纯英文路径试一次以排除。
- 企业杀软/代理可能拦截对 `api.siliconflow.cn` 的请求；必要时配置系统代理或加白名单。
- 若同时装了 WSL，注意 `claude` 到底跑在 Windows 侧还是 WSL 侧——**两侧配置不通用**，别改错文件。

**Kali 专属坑**
- **WSL 场景**：必须装 WSL 原生 Node（`apt install nodejs npm` 或 NodeSource），否则会出现 `node: not found` 或调用到 Windows 侧 npm 的怪问题；同时确认 `PATH` 里 `/usr/bin` 优先。
- Kali 是 Debian 系，软件用 `sudo apt`；**安装**可以用 sudo，但**运行** `claude` 不要加 sudo，否则读 `/root/.claude`。
- 若 npm 全局安装提示权限不足，优先用第 0.2 节的 `~/.npm-global` 用户前缀方案，或直接用官方 `install.sh`。
- 若 Kali 在 VM/远程机上，确保能直连 `api.siliconflow.cn`，必要时设 `HTTP_PROXY`/`HTTPS_PROXY`。

---

## 8. 排错速查

| 现象 | 大概率原因 | 处理 |
|---|---|---|
| `401` / `403` | Base URL 没改，请求打到 Anthropic 官方；或 Key 错/未实名 | 确认 `ANTHROPIC_BASE_URL` 生效、Key 正确、已实名 |
| `404` | Base URL 带了 `/v1`，拼成 `/v1/v1/messages` | 去掉 `/v1` |
| `400 Model does not exist` | 模型 ID 拼错（如多写了 `-1017`）或缺组织前缀 | 用第 3 节 `/v1/models` 核实，改为 `deepseek-ai/DeepSeek-V4.1-Flash` |
| `claude: command not found`（仅 VS Code/新终端） | 装到了不在持久 PATH 的目录（如妙手托管 Node 目录） | 改用 `--prefix "$env:APPDATA\npm"` 重装（Windows）/ 用户前缀（Kali），见第 7 节 |
| `Not logged in` / 引导去官方登录 | 凭证没被识别 | 确认 `AUTH_TOKEN` 非空；`/logout` 后重试 |
| `Auth conflict`（同时有 token 和 key） | `ANTHROPIC_AUTH_TOKEN` 与 `ANTHROPIC_API_KEY` 同设 | 只留一个 |
| 后台小任务报模型不存在 | Claude Code 用了 haiku/opus 等默认名 | 设置 `ANTHROPIC_DEFAULT_*_MODEL` 指向 DeepSeek |
| `unrecognized_model` 提示 | Claude Code 内置模型表无此第三方模型名 | **无害**，按 1M 上下文处理，可忽略 |
| VSCode 面板转圈，终端正常 | VSCode 进程没继承环境变量 | 用 `terminal.integrated.env.*` 注入并**完全重启** VSCode |
| Windows 上 `curl` 报错 | `curl` 是别名 | 用 `curl.exe` 或 Git Bash |
| WSL/Kali `node: not found` | 用了 Windows 侧 node | 装 WSL 原生 Node |

---

## 9. 可选：网关方案（ccr / ccSwitch）

仅在需要**多模型切换、失败回退、请求日志、多 Key 池**时才引入，否则直连更稳。

- **claude-code-router（ccr）**：本地网关，默认 `http://127.0.0.1:3456`，管理界面 `http://127.0.0.1:3458`。
  ```bash
  npm install -g @musistudio/claude-code-router   # 需 Node ≥ 22
  ccr ui                                        # 浏览器配置 Provider
  ccr start                                     # 启动网关（注意是 start，不是 serve）
  ccr code                                      # 自动注入环境变量并启动 Claude Code
  ```
  选 DeepSeek/SiliconFlow 预设 → 填 Key → 勾模型 → Agent 配置选默认模型。Claude Code 侧只需：
  ```
  ANTHROPIC_BASE_URL=http://127.0.0.1:3456
  ANTHROPIC_AUTH_TOKEN=任意非空字符串
  ```
- **ccSwitch**：跨平台桌面应用，图形化管理 Claude Code / Codex 等的多 Provider，自带本地代理与故障转移。
- 取舍：网关多一跳、多一个常驻进程，但换来可观测性与灵活性；**单一 DeepSeek 固定使用的场景，直连足够。**

---

## 10. 安全须知

- Key 只放用户级配置（`~/.claude/settings.json` 或系统环境变量），**不要**提交进 git。
- Kali 上 `chmod 600 ~/.claude/settings.json`。
- 若对话/截图可能外发，**吊销并重建**已暴露的 Key。
- 直连时 Key 会明文经过 Claude Code 发往硅基流动；仅在可信网络使用，公共网络建议加代理并注意防窃听。
- 定期在硅基流动控制台核对用量与余额。

---

## 11. 本机实测记录（Windows，2026-11-15）

已在本机按本文档完成安装与配置，端到端实测通过：

| 项 | 结果 |
|---|---|
| Claude Code CLI | `2.1.325`，安装于 `C:\Users\liude\AppData\Roaming\npm`（用户 PATH 上，VS Code 可直接调用） |
| VS Code 扩展 | `anthropic.claude-code` v2.1.325 已安装 |
| 配置文件 | `C:\Users\liude\.claude\settings.json`（已写入） |
| 模型 ID | `deepseek-ai/DeepSeek-V4.1-Flash`（经 `/v1/models` 核实） |
| 端到端验证 | `claude -p "请只回复两个字：正常"` → 返回 `正常` |
| PATH 核实 | `where.exe claude` → `C:\Users\liude\AppData\Roaming\npm\claude.cmd` |

**实测过的弯路与结论**：
1. 最初用 `deepseek-ai/DeepSeek-V4.1-Flash-1017` → `400 Model does not exist`；查 `/v1/models` 后更正为无后缀版本。
2. 第一次 `npm install -g` 装进了妙手托管 Node 目录，结果 `where.exe claude` 找不到（该目录不在持久 PATH）；改用 `--prefix "$env:APPDATA\npm"` 后正常。
3. `code` 命令在本机优先解析到 Qoder CN IDE（VS Code 分支），安装 VS Code 扩展时需用 VS Code 的 `code.cmd` 全路径。

---

## 附：最小可用配置（复制即用）

`~/.claude/settings.json`：
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.siliconflow.cn",
    "ANTHROPIC_AUTH_TOKEN": "sk-你的硅基流动密钥",
    "ANTHROPIC_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-ai/DeepSeek-V4.1-Flash"
  },
  "hasCompletedOnboarding": true
}
```

---

## 变更记录

- **2026-11-15（实测修订）**：模型 ID 由候选 `...-Flash-1017` 更正为实测的 `deepseek-ai/DeepSeek-V4.1-Flash`；新增第 0 节快速安装 Runbook；补充 Windows 用户级 npm 前缀 `--prefix` 与 PATH 陷阱、VS Code 扩展 CLI 安装、npm `allow-scripts` 提示说明、`unrecognized_model` 无害提示、`400 Model does not exist` 排错项；Kali 侧补充用户前缀安装与 sudo 注意事项。
