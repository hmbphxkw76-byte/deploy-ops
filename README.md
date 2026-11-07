# deploy-ops — Agent 部署手册集

本仓库收录面向 AI IDE / Agent（Trae、Qoder、WorkBuddy 等）的环境部署手册。每本手册统一格式：**参数区 → 前置检查 → 幂等执行步骤 → 验证部署 → Agent 注意事项**，Agent 按手册执行即可，重复运行安全。

## 目录结构

- `linux/` — Linux / Unix 手册，默认 Ubuntu 系统；`docker_kali.md` 为 Kali 专用
- `tools/` — 选型与决策记录（非部署手册）

## 手册目录

| 手册 | 系统 | 用途 |
| --- | --- | --- |
| [linux/docker.md](linux/docker.md) | Linux（Ubuntu） | 安装 Docker、镜像加速、空间清理（含验证脚本） |
| [linux/docker_kali.md](linux/docker_kali.md) | Linux（Kali） | Kali / Debian 安装 Docker CE 与 Compose 插件 |
| [linux/ollama.md](linux/ollama.md) | Linux（Ubuntu） | 部署 Ollama 离线包与 systemd 服务 |
| [linux/npm.md](linux/npm.md) | Linux（Ubuntu） | Node.js（nvm）安装、npm 镜像配置与排障 |
| [linux/promptfoo.md](linux/promptfoo.md) | Linux（Ubuntu） | Promptfoo 安装与红队测试 |
| [linux/aivp-promptfoo.md](linux/aivp-promptfoo.md) | Linux（Ubuntu） | AIVP 平台（HTTP SSE Provider）对接实战记录 |

## 通用提问模板

按目的选择一种问法，Agent 会自动读取手册并执行：

```text
【完整部署】按 linux/docker.md 手册在本机部署 Docker，执行前向我确认参数区的参数。

【仅执行某一章】按 linux/docker.md 第 2.2 章为 Ubuntu 配置镜像加速。

【仅验证】按 linux/docker.md 第 4.1 章的快速验证脚本验证 Docker 部署，汇报结果与日志路径。

【带参数覆盖】按 linux/ollama.md 部署 Ollama，安装包在 D:\downloads\ollama-linux-amd64.tar.zst，
OLLAMA_ORIGINS 收紧为 https://myapp.example.com。

【排障】docker 服务启动失败，按 linux/docker.md 第 6 章排查并给出原因。
```

## 各手册使用示例

### Docker（linux/docker.md）

```text
1. Ubuntu 安装：
   按 linux/docker.md 在 Ubuntu 24.04 上安装 Docker 并配置镜像加速。

2. 运行验证脚本：
   按 linux/docker.md 第 4.1 章验证 Docker 部署，传入参数区的镜像地址比对加速是否生效。

3. 空间清理：
   按 linux/docker.md 第 5 章清理 Docker，但跳过卷清理（我还有要保留的数据）。
```

预期行为：安装走逐步执行、失败即停；daemon.json 合并而非覆盖；卷清理与 `system prune -a` 必须逐项确认。

### Kali Docker（linux/docker_kali.md）

```text
在 Kali 上按 linux/docker_kali.md 安装 Docker，我不想升级整个系统（跳过 full-upgrade，只装依赖包）。
```

### Node.js / npm（linux/npm.md）

```text
1. 安装：按 linux/npm.md 用 nvm 安装 Node、把 registry 切到 npmmirror，并全局安装 pnpm。
2. 排障：npm install 反复失败，按手册排查章节处理，删除 node_modules 前先征求我同意。
```

### Promptfoo（linux/promptfoo.md）

```text
1. 安装：按 linux/promptfoo.md 安装 Promptfoo 并在当前项目初始化。
2. 红队测试：按该手册第 5 章对 promptfoo-redteam-config.yaml 生成用例并执行评估，
   目标系统的 API Key 我已配置在环境变量中。
```

预期行为：红队测试属于主动测试，Agent 会先与你确认目标再执行。

### AIVP 对接（linux/aivp-promptfoo.md）

```text
按 linux/aivp-promptfoo.md 的实战记录，把 AIVP 平台配置为 promptfoo 的 HTTP SSE Provider 并跑通评估。
```

### Ollama（linux/ollama.md）

```text
1. 部署：按 linux/ollama.md 部署 Ollama，安装包在 /opt/ollama-linux-amd64.tar.zst，监听 0.0.0.0。
2. 收紧配置：把 OLLAMA_ORIGINS 从 * 改为 https://myapp.example.com 并重启服务。
3. 排障：ollama 服务起不来，按 linux/ollama.md 第 5 章查日志定位（先确认 ollama 用户是否存在）。
```

## 组合工作流示例

### 新 Ubuntu 服务器初始化

```text
按顺序执行并逐步汇报：
1. linux/docker.md 第 2~3 章 — 安装 Docker、配置加速、加入 docker 组
2. linux/npm.md 第 2~4 章 — nvm 安装 Node、切换 npmmirror 并安装 pnpm
```

## Agent 行为约定（所有手册通用）

- **先检查再执行**：每章先做只读检查，已完成的内容自动跳过。
- **参数先确认**：执行变更前向用户确认参数区的参数。
- **危险操作必须确认**：重启系统、删除文件/卷、`system prune -a`、对外监听地址收紧等，逐项征求同意。
- **失败即停**：命令失败时查日志定位原因（各手册注意事项节指定了对应日志命令），不盲目重试。
- **逐步汇报**：每完成一章汇报当前状态与下一步计划。
