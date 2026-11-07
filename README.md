# deploy-ops — Agent 部署手册集

本仓库收录面向 AI IDE / Agent（Trae、Qoder、WorkBuddy 等）的环境部署手册。每本手册统一格式：**参数区 → 前置检查 → 幂等执行步骤 → 验证部署 → Agent 注意事项**，Agent 按手册执行即可，重复运行安全。

## 手册目录

| 手册 | 用途 |
| --- | --- |
| [wsl/wsl.md](wsl/wsl.md) | Windows 上安装配置 WSL、发行版管理、备份迁移 |
| [docker/docker.md](docker/docker.md) | Ubuntu 安装 Docker、镜像加速、空间清理（含验证脚本） |
| [kali/docker.md](kali/docker.md) | Kali / Debian 安装 Docker CE 与 Compose 插件 |
| [npm/npm.md](npm/npm.md) | Node.js（nvm）安装、npm 镜像配置与排障 |
| [npm/promptfoo.md](npm/promptfoo.md) | Promptfoo 安装与红队测试 |
| [python/python.md](python/python.md) | uv 初始化 Python 项目、国内镜像、安全工具包 |
| [ubuntu/ollama.md](ubuntu/ollama.md) | Ubuntu 部署 Ollama 离线包与 systemd 服务 |

## 通用提问模板

按目的选择一种问法，Agent 会自动读取手册并执行：

```text
【完整部署】按 wsl/wsl.md 手册在本机部署 WSL，执行前向我确认参数区的参数。

【仅执行某一章】按 docker/docker.md 第 2.2 章为 Ubuntu 配置镜像加速。

【仅验证】按 docker/docker.md 第 4.1 章的快速验证脚本验证 Docker 部署，汇报结果与日志路径。

【带参数覆盖】按 ubuntu/ollama.md 部署 Ollama，安装包在 D:\downloads\ollama-linux-amd64.tar.zst，
OLLAMA_ORIGINS 收紧为 https://myapp.example.com。

【排障】docker 服务启动失败，按 docker/docker.md 第 6 章排查并给出原因。
```

## 各手册使用示例

### WSL（wsl/wsl.md）

```text
1. 全新安装：
   按 wsl/wsl.md 部署 WSL，使用离线镜像 D:\iso\ubuntu-24.04.wsl，发行版命名为 Ubuntu24。

2. 备份迁移：
   按 wsl/wsl.md 第 5 章把 Ubuntu-22.04 导出到 D:\backup\ubuntu2204.tar，
   再导入为新发行版 Ubuntu24，安装目录 D:\WSL\Ubuntu24，导入后修复默认用户。

3. 日常管理：
   停止 Ubuntu-22.04 并查看当前所有发行版状态。
```

预期行为：Agent 先做前置检查（WSL 状态、管理员权限），需重启或交互输入（设置 UNIX 用户名密码）时暂停交还给用户。

### Docker（docker/docker.md）

```text
1. Ubuntu 安装：
   按 docker/docker.md 在 Ubuntu 24.04 上安装 Docker 并配置镜像加速。

2. 运行验证脚本：
   按 docker/docker.md 第 4.1 章验证 Docker 部署，传入参数区的镜像地址比对加速是否生效。

3. 空间清理：
   按 docker/docker.md 第 5 章清理 Docker，但跳过卷清理（我还有要保留的数据）。
```

预期行为：安装走逐步执行、失败即停；daemon.json 合并而非覆盖；卷清理与 `system prune -a` 必须逐项确认。

### Kali Docker（kali/docker.md）

```text
在 Kali 上按 kali/docker.md 安装 Docker，我不想升级整个系统（跳过 full-upgrade，只装依赖包）。
```

### Node.js / npm（npm/npm.md）

```text
1. 安装：按 npm/npm.md 用 nvm 安装 Node 并把 registry 切到 npmmirror。
2. 排障：npm install 反复失败，按 npm/npm.md 第 5 章排查，删除 node_modules 前先征求我同意。
```

### Promptfoo（npm/promptfoo.md）

```text
1. 安装：按 npm/promptfoo.md 安装 Promptfoo 并在当前项目初始化。
2. 红队测试：按 npm/promptfoo.md 第 5 章对 promptfoo-redteam-config.yaml 生成用例并执行评估，
   目标系统的 API Key 我已配置在环境变量中。
```

预期行为：红队测试属于主动测试，Agent 会先与你确认目标再执行。

### Python / uv（python/python.md）

```text
1. 新项目：在 D:\projects\sec-lab 按 python/python.md 初始化 uv 项目（Python 3.13）并配置清华源。
2. 装工具包：按 python/python.md 第 6 章安装全部安全评估工具包，装完汇报验证结果。
```

### Ollama（ubuntu/ollama.md）

```text
1. 部署：按 ubuntu/ollama.md 部署 Ollama，安装包在 /opt/ollama-linux-amd64.tar.zst，监听 0.0.0.0。
2. 收紧配置：把 OLLAMA_ORIGINS 从 * 改为 https://myapp.example.com 并重启服务。
3. 排障：ollama 服务起不来，按 ubuntu/ollama.md 第 5 章查日志定位（先确认 ollama 用户是否存在）。
```

## 组合工作流示例

### 全新 Windows 开发机一键链式部署

```text
按以下顺序链式执行，每完成一步停下向我汇报再继续：
1. wsl/wsl.md — 部署 WSL 与 Ubuntu 24.04（离线镜像 D:\iso\ubuntu-24.04.wsl）
2. docker/docker.md — 在该 Ubuntu 内安装 Docker 并配置镜像加速
3. ubuntu/ollama.md — 在该 Ubuntu 内部署 Ollama 服务
4. 每一步完成后用对应手册的"验证部署"章节确认，全部通过后输出总结
```

### 新 Ubuntu 服务器初始化

```text
按顺序执行并逐步汇报：
1. docker/docker.md 第 2~3 章 — 安装 Docker、配置加速、加入 docker 组
2. python/python.md 第 2.1、3、4 章 — 安装 uv 并初始化项目
3. npm/npm.md 第 2~3 章 — nvm 安装 Node 并切换 npmmirror
```

## Agent 行为约定（所有手册通用）

- **先检查再执行**：每章先做只读检查，已完成的内容自动跳过。
- **参数先确认**：执行变更前向用户确认参数区的参数。
- **危险操作必须确认**：重启系统、删除文件/卷、`system prune -a`、对外监听地址收紧等，逐项征求同意。
- **失败即停**：命令失败时查日志定位原因（各手册注意事项节指定了对应日志命令），不盲目重试。
- **逐步汇报**：每完成一章汇报当前状态与下一步计划。
