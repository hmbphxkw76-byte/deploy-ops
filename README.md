# deploy-ops — Agent 部署手册集

本仓库收录面向 AI IDE / Agent（Trae、Qoder、WorkBuddy 等）的环境部署手册。每本手册统一格式：**参数区 → 前置检查 → 幂等执行步骤 → 验证部署 → Agent 注意事项**，Agent 按手册执行即可，重复运行安全。

## 目录结构

- 根目录 — 部署手册与脚本，统一按「主题-环境」命名：
  - `*-linux.md` — Linux / Unix 环境（默认 Ubuntu）
  - `*-kubernetes.md` — Kubernetes 环境
  - `*-kali.md` — Kali / Debian 环境
- `.tmp-*` — 含密钥/临时值的文件，不提交仓库。

## 手册目录

| 手册 | 系统 | 用途 |
| --- | --- | --- |
| [docker-linux.md](docker-linux.md) | Linux（Ubuntu）/ Windows | 安装 Docker、镜像加速、空间清理（含验证脚本） |
| [docker-kali.md](docker-kali.md) | Linux（Kali） | Kali / Debian 安装 Docker CE 与 Compose 插件 |
| [cisco-ai-defense-kali.md](cisco-ai-defense-kali.md) | Linux（Kali） | Cisco AI Defense 扫描工具集（mcp/skill/a2a-scanner、aibom） |
| [ollama-linux.md](ollama-linux.md) | Linux（Ubuntu） | 部署 Ollama 离线包与 systemd 服务 |
| [npm-linux.md](npm-linux.md) | Linux（Ubuntu） | Node.js（nvm）安装、npm 镜像配置与排障 |
| [promptfoo-linux.md](promptfoo-linux.md) | Linux（Ubuntu） | Promptfoo 安装与红队测试 |
| [kubernetes-linux.md](kubernetes-linux.md) | Linux（Ubuntu） | 单节点 Kubernetes（kubeadm + containerd + flannel）部署、验证与排障 |
| [harbor-kubernetes.md](harbor-kubernetes.md) | Kubernetes（Ubuntu） | 在 K8s 上用 Helm 部署 Harbor 私有镜像仓库（NodePort / 自签 HTTPS / 国内镜像源） |
| [harbor-install-kubernetes.sh](harbor-install-kubernetes.sh) | Kubernetes（Ubuntu） | Harbor 一键安装脚本（前置检查 → 渲染校验 → 安装/升级 → 导出 CA → 验证，幂等） |
| [gitlab-linux.md](gitlab-linux.md) | Linux（Ubuntu） | 独立 Docker 部署 GitLab CE（不接入 K8s，国内镜像源） |

## 选型与决策记录

| 文档 | 说明 |
| --- | --- |
| [docs/osai-ai300-skill-coverage-decision.md](docs/osai-ai300-skill-coverage-decision.md) | OSAI（AI-300）考前靶机与工具精选、场景覆盖矩阵 |
| [docs/OSAI-Exam-Report.pdf](docs/OSAI-Exam-Report.pdf) | OSAI 考试报告 |

> 注：`docs/` 目录当前不在本仓库工作区，上表链接待文件就位后生效。

## 通用提问模板

按目的选择一种问法，Agent 会自动读取手册并执行：

```text
【完整部署】按 docker-linux.md 手册在本机部署 Docker，执行前向我确认参数区的参数。

【仅执行某一章】按 docker-linux.md 第 2.2 章为 Ubuntu 配置镜像加速。

【仅验证】按 docker-linux.md 第 4.1 章的快速验证脚本验证 Docker 部署，汇报结果与日志路径。

【带参数覆盖】按 ollama-linux.md 部署 Ollama，安装包在 D:\downloads\ollama-linux-amd64.tar.zst，
OLLAMA_ORIGINS 收紧为 https://myapp.example.com。

【排障】docker 服务启动失败，按 docker-linux.md 第 6 章排查并给出原因。
```

## 各手册使用示例

### Docker（docker-linux.md）

```text
1. Ubuntu 安装：
   按 docker-linux.md 在 Ubuntu 24.04 上安装 Docker 并配置镜像加速。

2. 运行验证脚本：
   按 docker-linux.md 第 4.1 章验证 Docker 部署，传入参数区的镜像地址比对加速是否生效。

3. 空间清理：
   按 docker-linux.md 第 5 章清理 Docker，但跳过卷清理（我还有要保留的数据）。
```

预期行为：安装走逐步执行、失败即停；daemon.json 合并而非覆盖；卷清理与 `system prune -a` 必须逐项确认。

### Kali Docker（docker-kali.md）

```text
在 Kali 上按 docker-kali.md 安装 Docker，我不想升级整个系统（跳过 full-upgrade，只装依赖包）。
```

### Cisco AI Defense（cisco-ai-defense-kali.md）

```text
按 cisco-ai-defense-kali.md 在 Kali 上安装 mcp-scanner、skill-scanner、a2a-scanner、aibom，
装完后对各工具做冒烟验证并汇报。
```

### Node.js / npm（npm-linux.md）

```text
1. 安装：按 npm-linux.md 用 nvm 安装 Node、把 registry 切到 npmmirror，并全局安装 pnpm。
2. 排障：npm install 反复失败，按手册排查章节处理，删除 node_modules 前先征求我同意。
```

### Promptfoo（promptfoo-linux.md）

```text
1. 安装：按 promptfoo-linux.md 安装 Promptfoo 并在当前项目初始化。
2. 红队测试：按该手册第 5 章对 promptfoo-redteam-config.yaml 生成用例并执行评估，
   目标系统的 API Key 我已配置在环境变量中。
```

预期行为：红队测试属于主动测试，Agent 会先与你确认目标再执行。

### Kubernetes（kubernetes-linux.md）

```text
1. 部署：按 kubernetes-linux.md 在 Ubuntu 上部署单节点 Kubernetes（kubeadm + containerd + flannel），执行前向我确认参数区参数。
2. 验证：按 kubernetes-linux.md 第 7.1 章运行验证脚本，汇报结果与日志路径。
3. 排障：节点 NotReady / 镜像拉取失败（ImagePullBackOff），按 kubernetes-linux.md 第 8 章定位。
```

预期行为：已 init 的集群跳过初始化；重启 containerd 等影响 Docker 的操作先告知影响面；`kubeadm reset` 等破坏性操作必须确认。

### GitLab（gitlab-linux.md）

```text
1. 部署：按 gitlab-linux.md 在 192.168.40.189 用独立 Docker Compose 部署 GitLab CE（不接入 K8s），执行前向我确认参数区参数。
2. 验证：按 gitlab-linux.md「验证部署」运行检查（Web / Registry / SSH / API），汇报结果。
3. 排障：登录不上或仓库不可用，按 gitlab-linux.md「验证失败恢复」重置密码或查日志。
```

预期行为：镜像走国内源（docker.m.daocloud.io），不得直连 Docker Hub；端口避开 80/22 与 K8s 端口；不创建任何 K8s 资源；默认关闭公开注册；升级 `:latest` 前备份 `/opt/gitlab`。

### Harbor（harbor-kubernetes.md）

```text
1. 部署：按 harbor-kubernetes.md 第 0 章用 harbor-install-kubernetes.sh 一键安装（NodePort + 自签 HTTPS，镜像走国内源），执行前向我确认参数区参数。
2. 验证：脚本已自动导出 CA；再按 harbor-kubernetes.md 第 6.4 章运行 harbor_verify.sh 并汇报结果。
3. 使用：建项目后 docker login/push/pull；让集群从 Harbor 拉镜像按第 6.5 章配置。
4. 排障：Pod 起不来 / ImagePullBackOff / 证书报错，按 harbor-kubernetes.md 第 8 章定位。
```

预期行为：一键脚本幂等（已安装走 `helm upgrade`）；镜像保持 `docker.io` 由 containerd 镜像源加速；密码/密钥随机生成写入 values 文件（不提交仓库）；重启 containerd、卸载等破坏性操作必须先确认。

### Ollama（ollama-linux.md）

```text
1. 部署：按 ollama-linux.md 部署 Ollama，安装包在 /opt/ollama-linux-amd64.tar.zst，监听 0.0.0.0。
2. 收紧配置：把 OLLAMA_ORIGINS 从 * 改为 https://myapp.example.com 并重启服务。
3. 排障：ollama 服务起不来，按 ollama-linux.md 第 5 章查日志定位（先确认 ollama 用户是否存在）。
```

## 组合工作流示例

### 新 Ubuntu 服务器初始化

```text
按顺序执行并逐步汇报：
1. docker-linux.md 第 2~3 章 — 安装 Docker、配置加速、加入 docker 组
2. npm-linux.md 第 2~4 章 — nvm 安装 Node、切换 npmmirror 并安装 pnpm
```

## Agent 行为约定（所有手册通用）

- **先检查再执行**：每章先做只读检查，已完成的内容自动跳过。
- **参数先确认**：执行变更前向用户确认参数区的参数。
- **危险操作必须确认**：重启系统、删除文件/卷、`system prune -a`、对外监听地址收紧等，逐项征求同意。
- **失败即停**：命令失败时查日志定位原因（各手册注意事项节指定了对应日志命令），不盲目重试。
- **逐步汇报**：每完成一章汇报当前状态与下一步计划。
