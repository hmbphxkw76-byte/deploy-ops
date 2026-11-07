# Promptfoo 部署手册 — Windows（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Windows** 上自动完成 Promptfoo 的全局安装、验证与红队测试基础使用。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；安装与初始化幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像源（中国大陆建议） |
| `PROJECT_DIR` | 当前目录 | 执行 init / 红队测试的项目根目录 |

## 1. 前置检查（只读，不修改系统）

```powershell
node --version; if (-not $?) { echo "NODE_NOT_INSTALLED" }
npm --version; if (-not $?) { echo "NPM_NOT_INSTALLED" }
promptfoo --version; if (-not $?) { echo "PROMPTFOO_NOT_INSTALLED" }
Test-Path "$PROJECT_DIR/promptfoo.yaml" ? "CONFIG_EXISTS" : "NO_CONFIG"
```

判定逻辑：

- Node/npm 不可用 → 先按 [npm.md](./npm.md) 第 2 章安装 Node.js，再继续。
- `promptfoo --version` 正常输出 → 跳过第 2 章。
- 项目下已有 `promptfoo.yaml` → 跳过第 3 章初始化。

## 2. 全局安装

```powershell
# 走默认源
npm install -g promptfoo --allow-scripts

# 或指定国内镜像源（网络较慢时）
npm install -g promptfoo --registry=https://registry.npmmirror.com --allow-scripts
```

> `--allow-scripts` 允许执行包的安装脚本（Promptfoo 需要）；仅对可信包使用该参数。

## 3. 验证安装

```powershell
promptfoo --version
```

正常输出版本号 → 安装成功；命令不可用时检查 npm 全局路径是否在 PATH 中（`npm root -g`、`where.exe promptfoo`）。

## 4. 初始化项目

在 `PROJECT_DIR` 下执行，会生成配置示例文件并引导下一步：

```powershell
cd "$PROJECT_DIR"
promptfoo init

# 或使用 npx 保证初始化脚本为最新版本：
npx promptfoo@latest init
```

已存在 `promptfoo.yaml` 时跳过，避免覆盖现有配置。

## 5. 红队测试命令（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 初始化红队配置 | `promptfoo redteam init` |
| 从模板生成测试用例（生成 redteam.yaml） | `promptfoo redteam generate --config promptfoo-redteam-config.yaml` |
| 执行评估（读取 redteam.yaml） | `promptfoo redteam eval --config redteam.yaml` |
| 合并 generate + eval 两步 | `promptfoo redteam run --config promptfoo-redteam-config.yaml` |
| 查看结果报告 | `promptfoo redteam report` |

## 6. Agent 执行注意事项

- 全局安装失败时，先检查网络与镜像源（`npm ping`），不要盲目重试。
- `redteam run` / `redteam eval` 可能调用外部模型 API，执行前向用户确认目标系统与所用的 API Key 已配置。
- 红队测试属于对目标系统的主动测试，Agent 应仅在用户明确要求时执行第 5 章。
- 每完成一章，向用户汇报当前状态与下一步计划。
