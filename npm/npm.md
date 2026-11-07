# Node.js / npm 部署手册（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于自动完成 Node.js（nvm）安装、npm 镜像配置、缓存维护与常见问题排查，适用于本地开发和 CI 环境。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；配置类步骤幂等，已完成的会自动跳过。涉及删除文件的操作必须先经用户确认。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `TARGET_OS` | 自动检测 | `windows` 或 `unix`，决定使用的命令集 |
| `NVM_VERSION` | `v0.40.3` | nvm 安装版本（仅 Unix） |
| `NODE_VERSION` | `stable` | 要安装的 Node 版本 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像源（中国大陆建议） |

## 1. 前置检查（只读，不修改系统）

```bash
# Node / npm 是否已安装
node --version 2>/dev/null || echo "NODE_NOT_INSTALLED"
npm --version 2>/dev/null || echo "NPM_NOT_INSTALLED"

# 当前镜像源
npm config get registry 2>/dev/null || true

# nvm 是否已安装（Unix）
[ -s "$HOME/.nvm/nvm.sh" ] && echo "NVM_INSTALLED" || echo "NVM_NOT_INSTALLED"
```

判定逻辑：

- Node 与 npm 均可用 → 跳过第 2 章，仅按需执行第 3、4 章。
- Node 未安装 → 继续第 2 章。
- registry 已是 `NPM_REGISTRY` → 跳过 3.1。

## 2. 安装 Node.js 与 nvm

### 2.1 Unix（Linux / macOS / WSL）

```bash
# 安装 nvm（若前置检查已显示 NVM_INSTALLED 则跳过）
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

# 加载 nvm（当前会话）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# 安装并启用 Node
nvm install stable
nvm use stable
nvm alias default stable
```

### 2.2 Windows

- Windows 使用 [nvm-windows](https://github.com/coreybutler/nvm-windows) 或官方安装器（GUI 安装需用户手动完成），Agent 不代替执行，仅提示下载地址并等待用户完成后继续验证。
- 已装 nvm-windows 时可执行：`nvm install <NODE_VERSION>` 与 `nvm use <NODE_VERSION>`（use 需管理员权限）。

### 2.3 验证

```bash
node --version && npm --version
```

两者均正常输出版本号 → 安装成功；否则按第 5 章排查。

## 3. npm 配置（检查 → 执行 → 验证）

### 3.1 配置镜像源

```bash
# 已在 NPM_REGISTRY 时跳过
npm config set registry https://registry.npmmirror.com
npm config get registry   # 验证输出为目标地址
```

### 3.2 缓存维护（按需）

```bash
npm config get cache     # 查看缓存路径
npm cache clean --force  # 清理缓存（安装失败时使用）
```

## 4. 日常命令（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 安装全部依赖 | `npm install` |
| 仅安装生产依赖 | `npm install --omit=dev` |
| 查看全局安装路径 | `npm root -g` |
| 检查镜像连通性 | `npm ping` |

## 5. 常见问题排查（Agent 排障手册，按现象定位）

| 现象 | 排查步骤 |
| --- | --- |
| `npm`/`node` 命令不可用 | `node --version`、`npm --version`；Windows 下 `where.exe npm` 检查 PATH |
| 网络拉取超时 | `npm config get registry` 确认镜像源；`npm ping` 测连通性；必要时切回 `NPM_REGISTRY` |
| 全局安装权限报错（Unix） | 禁止 `sudo npm install -g`；应使用 nvm 管理版本，或修复全局目录权限 |
| 依赖安装失败 | 先 `npm cache clean --force` 后重试；仍失败时删除 `node_modules` 与 `package-lock.json` 重装（**删除前必须经用户确认**） |

```bash
npm cache clean --force
rm -rf node_modules package-lock.json   # 破坏性操作，需用户确认
npm install
```

## 6. CI 集成参考

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

## 7. Agent 执行注意事项

- nvm 安装脚本只修改当前用户的 shell 配置，Agent 执行后需 `source ~/.nvm/nvm.sh` 或新开 shell 才能使用 `nvm`。
- 修改 registry 前先读取当前值，避免覆盖用户自定义源。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 参考链接

- nvm: https://github.com/nvm-sh/nvm
- npm 镜像（国内）: https://registry.npmmirror.com
- npm 官方文档: https://docs.npmjs.com/
