# Node.js / npm 部署手册 — Windows（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Windows** 上自动完成 Node.js 安装、npm/pnpm 镜像配置、缓存维护与常见问题排查。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；配置类步骤幂等，已完成的会自动跳过。涉及删除文件的操作必须先经用户确认。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NODE_VERSION` | `stable` | 要安装的 Node 版本（nvm-windows） |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm/pnpm 镜像源（中国大陆建议） |
| `PNPM_VERSION` | `latest` | 要安装的 pnpm 版本 |

## 1. 前置检查（只读，不修改系统）

```powershell
# Node / npm 是否已安装
node --version 2>$null; if (-not $?) { echo "NODE_NOT_INSTALLED" }
npm --version 2>$null; if (-not $?) { echo "NPM_NOT_INSTALLED" }

# 当前镜像源
npm config get registry

# nvm-windows 是否已安装
nvm version

# pnpm 是否已安装
pnpm --version
```

判定逻辑：

- Node 与 npm 均可用 → 跳过第 2 章，仅按需执行第 3、4、5 章。
- Node 未安装 → 继续第 2 章。
- registry 已是 `NPM_REGISTRY` → 跳过 3.1。
- pnpm 未安装 → 执行第 4 章；已安装 → 仅按需执行 4.2 验证镜像源。

## 2. 安装 Node.js

### 2.1 安装方式（GUI 安装需用户手动完成）

- Windows 使用 [nvm-windows](https://github.com/coreybutler/nvm-windows) 或官方安装器，Agent 不代替执行 GUI 安装，仅提示下载地址并等待用户完成后继续验证。
- 已装 nvm-windows 时可由 Agent 执行：

```powershell
nvm install $NODE_VERSION
nvm use $NODE_VERSION   # 需管理员权限
```

### 2.2 验证

```powershell
node --version; npm --version
```

两者均正常输出版本号 → 安装成功；否则按第 6 章排查。

## 3. npm 配置（检查 → 执行 → 验证）

### 3.1 配置镜像源

```powershell
# 已在 NPM_REGISTRY 时跳过
npm config set registry https://registry.npmmirror.com
npm config get registry   # 验证输出为目标地址
```

### 3.2 缓存维护（按需）

```powershell
npm config get cache     # 查看缓存路径
npm cache clean --force  # 清理缓存（安装失败时使用）
```

## 4. pnpm 安装与配置（检查 → 执行 → 验证）

### 4.1 安装（三种方式任选其一）

**方式一：npm 全局安装（国内镜像加速，推荐）**

```powershell
npm install -g pnpm@$PNPM_VERSION
```

**方式二：独立脚本（不依赖 Node.js，系统全新时可用）**

```powershell
iwr https://get.pnpm.io/install.ps1 -useb | iex
```

**方式三：corepack（Node.js >= 16.13 自带）**

```powershell
corepack enable pnpm
corepack prepare pnpm@$PNPM_VERSION --activate
```

### 4.2 配置国内源

pnpm 与 npm 共用 `.npmrc` 配置体系：若 3.1 已将 npm 源设为 `NPM_REGISTRY`，pnpm 默认继承，仅需验证：

```powershell
pnpm config get registry   # 输出应为 NPM_REGISTRY；不是则执行下行
pnpm config set registry https://registry.npmmirror.com
```

也可写入项目根目录 `.npmrc`（仅对当前项目生效，建议随仓库提交）：

```ini
registry=https://registry.npmmirror.com
```

### 4.3 验证

```powershell
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
| `npm`/`node` 命令不可用 | `node --version`、`npm --version`；`where.exe npm` 检查 PATH |
| `pnpm` 命令不可用 | `pnpm --version`；独立脚本安装后需新开终端使 `PNPM_HOME` 生效；`where.exe pnpm` 检查 PATH |
| `nvm use` 报权限错误 | 需以管理员身份运行终端后重试 |
| 网络拉取超时 | `npm config get registry` / `pnpm config get registry` 确认镜像源；`npm ping` 测连通性；必要时切回 `NPM_REGISTRY` |
| 依赖安装失败 | 先 `npm cache clean --force` 后重试；仍失败时删除 `node_modules` 与 `package-lock.json` 重装（**删除前必须经用户确认**） |

```powershell
npm cache clean --force
Remove-Item -Recurse -Force node_modules, package-lock.json   # 破坏性操作，需用户确认
npm install
```

## 7. CI 集成参考

CI 运行环境通常为 Linux（`runs-on: ubuntu-latest`），配置与 Linux 手册一致：

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

- GUI 安装（nvm-windows / 官方安装器）由用户手动完成，Agent 仅提示下载地址并在完成后验证。
- `nvm use` 需管理员权限，失败时提示用户以管理员身份重开终端。
- pnpm 独立脚本安装只修改当前用户的环境变量，需新开终端（或重载 PATH）后 `pnpm` 命令才生效。
- 修改 registry 前先读取当前值（npm 与 pnpm 各读一次），避免覆盖用户自定义源。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 参考链接

- nvm-windows: https://github.com/coreybutler/nvm-windows
- npm 镜像（国内）: https://registry.npmmirror.com
- npm 官方文档: https://docs.npmjs.com/
- pnpm 官方文档: https://pnpm.io/zh/
