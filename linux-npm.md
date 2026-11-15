# Node.js / npm 部署手册 — Linux（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Linux / Unix（默认 Ubuntu）** 上自动完成 Node.js（nvm）安装、npm/pnpm 镜像配置、缓存维护与常见问题排查，适用于本地开发和 CI 环境。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；配置类步骤幂等，已完成的会自动跳过。涉及删除文件的操作必须先经用户确认。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NVM_VERSION` | `v0.40.3` | nvm 安装版本 |
| `NODE_VERSION` | `24` | 要安装的 Node 主版本（默认当前 LTS）。**注意**：填 `stable` 时，npmmirror 等国内镜像的版本索引含预发布版，按 semver 取最高可能解析到 alpha 版，建议始终显式指定 LTS 主版本（如 `24`、`22`） |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm/pnpm 镜像源（中国大陆建议） |
| `PNPM_VERSION` | `latest` | 要安装的 pnpm 版本 |

## 1. 前置检查（只读，不修改系统）

```bash
# Node / npm 是否已安装
node --version 2>/dev/null || echo "NODE_NOT_INSTALLED"
npm --version 2>/dev/null || echo "NPM_NOT_INSTALLED"

# 当前镜像源
npm config get registry 2>/dev/null || true

# nvm 是否已安装
[ -s "$HOME/.nvm/nvm.sh" ] && echo "NVM_INSTALLED" || echo "NVM_NOT_INSTALLED"

# pnpm 是否已安装
pnpm --version 2>/dev/null || echo "PNPM_NOT_INSTALLED"
```

判定逻辑：

- Node 与 npm 均可用 → 跳过第 2 章，仅按需执行第 3、4、5 章。
- Node 未安装 → 继续第 2 章。
- registry 已是 `NPM_REGISTRY` → 跳过 3.1。
- pnpm 未安装 → 执行第 4 章；已安装 → 仅按需执行 4.2 验证镜像源。

## 2. 安装 Node.js 与 nvm

### 2.1 安装 nvm

```bash
# 安装 nvm（若前置检查已显示 NVM_INSTALLED 则跳过；raw.githubusercontent.com 不可达时可在地址前加代理前缀，如 https://ghfast.top/）
curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION:-v0.40.3}/install.sh" | bash

# 加载 nvm（当前会话）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# 安装并启用 Node（默认取参数区 NODE_VERSION；国内镜像建议显式 LTS 主版本）
export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node/
nvm install "${NODE_VERSION:-24}"
nvm use "${NODE_VERSION:-24}"
nvm alias default "${NODE_VERSION:-24}"
```

> **非交互会话注意**：Ubuntu 默认 `~/.bashrc` 对非交互 shell 提前 `return`，nvm 初始化块不执行，导致 `ssh host 'node --version'` 或 `bash -lc` 找不到 node。需将 nvm 初始化追加到 `~/.profile`：
>
> ```bash
> export NVM_DIR="$HOME/.nvm"
> [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
> export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node/
> ```
>
> 追加后用 `bash -lc 'node --version'` 验证。

### 2.2 验证

```bash
node --version && npm --version
```

两者均正常输出版本号 → 安装成功；否则按第 6 章排查。

## 3. npm 配置（检查 → 执行 → 验证）

### 3.1 配置镜像源

```bash
# 已在 NPM_REGISTRY 时跳过
npm config set registry "${NPM_REGISTRY:-https://registry.npmmirror.com}"
npm config get registry   # 验证输出为目标地址
```

### 3.2 缓存维护（按需）

```bash
npm config get cache     # 查看缓存路径
npm cache clean --force  # 清理缓存（安装失败时使用）
```

## 4. pnpm 安装与配置（检查 → 执行 → 验证）

### 4.1 安装（两种方式任选其一）

**方式一：npm 全局安装（国内镜像加速，推荐）**

```bash
npm install -g "pnpm@${PNPM_VERSION:-latest}"
```

**方式二：独立脚本（不依赖 Node.js，系统全新时可用）**

```bash
curl -fsSL https://get.pnpm.io/install.sh | sh -
```

**方式三：corepack（Node.js >= 16.13 自带）**

```bash
corepack enable pnpm
corepack prepare "pnpm@${PNPM_VERSION:-latest}" --activate
```

### 4.2 配置国内源

pnpm 与 npm 共用 `.npmrc` 配置体系：若 3.1 已将 npm 源设为 `NPM_REGISTRY`，pnpm 默认继承，仅需验证：

```bash
pnpm config get registry   # 输出应为 NPM_REGISTRY；不是则执行下行
pnpm config set registry "${NPM_REGISTRY:-https://registry.npmmirror.com}"
```

也可写入项目根目录 `.npmrc`（仅对当前项目生效，建议随仓库提交）：

```ini
registry=https://registry.npmmirror.com
```

> 该地址应与参数区 `NPM_REGISTRY` 一致（上面为默认值）。

### 4.3 验证

```bash
pnpm --version
```

正常输出版本号 → 安装成功；否则按第 6 章排查。

## 5. 日常命令（Agent 按需调用）

| 操作 | npm | pnpm |
| --- | --- | --- |
| 安装全部依赖 | `npm install` | `pnpm install` |
| 仅安装生产依赖 | `npm install --omit=dev` | `pnpm install --prod` |
| 查看全局安装路径 | `npm root -g` | `pnpm root -g` |
| 查看缓存/存储路径 | `npm config get cache` | `pnpm store path` |
| 检查镜像连通性 | `npm ping` | `pnpm config get registry` |

## 6. 常见问题排查（Agent 排障手册，按现象定位）

| 现象 | 排查步骤 |
| --- | --- |
| `npm`/`node` 命令不可用 | `node --version`、`npm --version`；`which npm` 检查 PATH |
| `pnpm` 命令不可用 | `pnpm --version`；独立脚本安装后需新开终端使 `PNPM_HOME` 生效 |
| 网络拉取超时 | `npm config get registry` / `pnpm config get registry` 确认镜像源；`npm ping` 测连通性；必要时切回 `NPM_REGISTRY` |
| 全局安装权限报错 | 禁止 `sudo npm install -g`；应使用 nvm 管理版本，或修复全局目录权限 |
| `nvm install stable` 装出预发布版 | npmmirror 的 node 版本索引含预发布版（如 `v27.0.0-alpha.0.0.0`），nvm 按 semver 取最高会选中 alpha。改用显式版本 `nvm install 24`（或 `nvm install --lts`），并 `nvm uninstall` 误装版本 |
| SSH 非交互会话 `node`/`nvm` 不可用 | Ubuntu 默认 `~/.bashrc` 对非交互 shell 提前 `return`，nvm 初始化块不执行。将 nvm 初始化（含 `NVM_NODEJS_ORG_MIRROR`）追加到 `~/.profile`，`bash -lc 'node --version'` 验证 |
| 依赖安装失败 | 先 `npm cache clean --force` 后重试；仍失败时删除 `node_modules` 与 lock 文件重装（npm 为 `package-lock.json`，pnpm 为 `pnpm-lock.yaml`；**删除前必须经用户确认**） |

```bash
npm cache clean --force
rm -rf node_modules package-lock.json pnpm-lock.yaml   # 破坏性操作，需用户确认
npm install
```

## 7. CI 集成参考

```yaml
name: Node.js CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 'lts/*'
          cache: 'npm'
      - name: Install dependencies
        run: npm ci
```

> CI 中固定使用 `npm ci`（严格按 lock 文件安装），不使用 `npm install`。

pnpm 项目改用：

```yaml
      - uses: pnpm/action-setup@v4
        with:
          version: 10
      - name: Install dependencies
        run: pnpm install --frozen-lockfile
```

## 8. Agent 执行注意事项

- nvm 安装脚本只修改当前用户的 shell 配置，Agent 执行后需 `source ~/.nvm/nvm.sh` 或新开 shell 才能使用 `nvm`；如需在 SSH 非交互会话可用，将 nvm 初始化追加到 `~/.profile`（见第 2.1 章）。
- pnpm 独立脚本安装只修改当前用户的环境变量，需新开终端（或重载 PATH）后 `pnpm` 命令才生效。
- 修改 registry 前先读取当前值（npm 与 pnpm 各读一次），避免覆盖用户自定义源。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 参考链接

- nvm: https://github.com/nvm-sh/nvm
- npm 镜像（国内）: https://registry.npmmirror.com
- npm 官方文档: https://docs.npmjs.com/
- pnpm 官方文档: https://pnpm.io/zh/
