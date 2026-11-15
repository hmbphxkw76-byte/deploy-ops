# Promptfoo 部署手册 — Linux（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Linux / Unix（默认 Ubuntu）** 上自动完成 Promptfoo 的全局安装、验证与红队测试基础使用。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；安装与初始化幂等，已完成的内容会自动跳过。

> **实测基线（2026-11-15）**：Ubuntu 24.04.2 LTS / x86_64 / root，Node v24.22.3 + npm 11.19.1。全局安装耗时约 1 分钟（603 个包），装得 **promptfoo 0.125.1**；`promptfoo init --no-interactive` 实测可在非交互 SSH 会话中完成，生成 `promptfooconfig.yaml` + `README.md`。
>
> 跨组件的实操要点与镜像源实测数据见 [linux-provisioning-playbook.md](linux-provisioning-playbook.md)。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像源（中国大陆建议） |
| `PROJECT_DIR` | 当前目录 | 执行 init / 红队测试的项目根目录 |

## 1. 前置检查（只读，不修改系统）

```bash
node --version 2>/dev/null || echo "NODE_NOT_INSTALLED"
npm --version 2>/dev/null || echo "NPM_NOT_INSTALLED"
promptfoo --version 2>/dev/null || echo "PROMPTFOO_NOT_INSTALLED"
# 配置可能是 promptfooconfig.yaml（新版默认）或 promptfoo.yaml（旧版/兼容名），两者都要看
ls "${PROJECT_DIR:-.}/promptfooconfig.yaml" "${PROJECT_DIR:-.}/promptfoo.yaml" 2>/dev/null || echo "NO_CONFIG"
```

判定逻辑：

- Node/npm 不可用 → 先按 [linux-npm.md](./linux-npm.md) 第 2 章安装 Node.js，再继续。
- `promptfoo --version` 正常输出 → 跳过第 2 章。
- 项目下已有 `promptfooconfig.yaml` 或 `promptfoo.yaml` → 跳过第 4 章初始化。
- Node 版本：实测 Node 24 LTS（v24.22.3）可正常安装与运行；建议使用 LTS 主版本而非 `stable`（避免镜像索引解析到预发布版）。

## 2. 全局安装

```bash
# 使用参数区镜像源安装
npm install -g promptfoo --registry="${NPM_REGISTRY:-https://registry.npmmirror.com}" --allow-scripts
```

> `--allow-scripts` 允许执行包的安装脚本（Promptfoo 需要）；仅对可信包使用该参数。实测 npm 11.19.1 下该参数有效且为推荐写法；若 npm 版本较旧、报 `Unknown cli config`，去掉该参数直接安装即可。
>
> npm ≥ 11 即使不加该参数也通常能装上（只是打印 `npm warn install-scripts` 警告），但部分包会因安装脚本未执行而行为异常，建议始终显式加上。

## 3. 验证安装

```bash
promptfoo --version
```

正常输出版本号 → 安装成功；命令不可用时检查 npm 全局路径是否在 PATH 中（`npm root -g`、`which promptfoo`）。

## 4. 初始化项目

在 `PROJECT_DIR` 下执行，会生成配置示例文件并引导下一步：

**Agent / SSH 非交互会话**：必须加 `--no-interactive`，否则命令会等待键盘输入而挂起：

```bash
cd "${PROJECT_DIR:-.}"
promptfoo init --no-interactive

# 或使用 npx 保证初始化脚本为最新版本：
npx promptfoo@latest init --no-interactive
```

> 实测（promptfoo 0.125.1）`init` 生成的是 **`promptfooconfig.yaml`**（新版默认名）与 `README.md`，而不是旧文档常写的 `promptfoo.yaml`；promptfoo 两者都识别。写文档或做存在性检查时不要只找 `promptfoo.yaml`。

已存在 `promptfooconfig.yaml` / `promptfoo.yaml` 时跳过，避免覆盖现有配置。

## 5. 红队测试命令（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 初始化红队配置 | `promptfoo redteam init` |
| 从模板生成测试用例（生成 redteam.yaml） | `promptfoo redteam generate --config promptfoo-redteam-config.yaml` |
| 执行评估（读取 redteam.yaml） | `promptfoo redteam eval --config redteam.yaml` |
| 合并 generate + eval 两步 | `promptfoo redteam run --config promptfoo-redteam-config.yaml` |
| 查看结果报告 | `promptfoo redteam report` |

## 6. Web 结果查看（promptfoo view）

### 6.1 本机直接查看（SSH 隧道，推荐）

`promptfoo view` 默认只监听远程主机的 localhost，需通过 SSH 隧道映射到本机：

```bash
# 1) 服务器上启动查看服务（-n 不自动开浏览器；默认端口 15500；nohup 使其断开 SSH 后仍存活）
ssh root@<server> "nohup bash -lc 'promptfoo view -n' >/tmp/pf-view.log 2>&1 &"

# 2) 验证服务已启动（应输出 HTTP:200）
ssh root@<server> "curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://localhost:15500"

# 3) 本机建立 SSH 隧道（Windows PowerShell 下保持窗口开启即可；-N 不执行远程命令）
ssh -N -L 15500:localhost:15500 root@<server>

# 4) 本机浏览器访问
#    http://localhost:15500
# 本机连通性验证：curl.exe -s -o NUL -w "HTTP:%{http_code}" http://localhost:15500
```

注意：
- PowerShell 中 `curl` 是 `Invoke-WebRequest` 别名，验证隧道需用 `curl.exe`。
- 隧道依赖本机 SSH 进程，断开后重跑第 3 步即可。
- 服务器重启后需重新执行第 1 步。

### 6.2 局域网直接访问（可选）

如希望 `http://<server>:15501` 直接访问（不走隧道），在服务器上用 socat 把 localhost:15500 转发到 0.0.0.0:15501（15500 已被 promptfoo 自身占用，故对外用 15501）：

```bash
# 安装 socat 并常驻转发
apt install -y socat
nohup socat TCP-LISTEN:15501,fork,reuseaddr TCP:127.0.0.1:15500 >/tmp/socat-pf.log 2>&1 &
```

> 直接暴露会将红队评估结果开放给整个局域网，执行前向用户确认风险。

### 6.3 新结果刷新

每次 `promptfoo eval` 跑完后，浏览器刷新页面即可看到新评估；`--filter-description <regex>` 可按描述过滤评估。

## 7. Agent 执行注意事项

- 全局安装失败时，先检查网络与镜像源（`npm ping`），不要盲目重试。
- **`init` 在非交互会话必须加 `--no-interactive`**；无该参数时命令卡在交互向导上，Agent 易误判为“安装失败”。
- `promptfoo init` 结束后可能打印 `telemetry.shutdown() timed out during shutdown`，属正常退出噪声，不影响生成的配置。
- 全新环境建议先按第 1 章检查 Node 版本，再安装；promptfoo 依赖较新 Node，避免在 Node 16 等旧版本上直接装最新版。
- `redteam run` / `redteam eval` 可能调用外部模型 API，执行前向用户确认目标系统与所用的 API Key 已配置。
- 红队测试属于对目标系统的主动测试，Agent 应仅在用户明确要求时执行第 5 章。
- 每完成一章，向用户汇报当前状态与下一步计划。
