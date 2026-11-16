# deploy-ops — Agent 部署手册集

本仓库收录面向 AI IDE / Agent（Trae、Qoder、WorkBuddy 等）的环境部署手册。每本手册统一格式：**参数区 → 前置检查 → 幂等执行步骤 → 验证部署 → Agent 注意事项**，Agent 按手册执行即可，重复运行安全。

## 目录结构

- 根目录 — 部署手册与脚本，统一按「环境-主题」命名：
  - `linux-*.md` — Linux / Unix 环境（默认 Ubuntu）
  - `kali-*.md` — Kali / Debian 环境
  - `kubernetes-*.md` — Kubernetes 环境
  - `windows-*.md` — Windows 环境（PowerShell / git bash）
  - `others-*.md` — 跨平台 / 未归类（如 IDE 接入配置）
- `.tmp-*` — 含密钥/临时值的文件，不提交仓库。

## 手册目录

| 手册 | 系统 | 用途 |
| --- | --- | --- |
| [linux-docker.md](linux-docker.md) | Linux（Ubuntu）/ Windows | 安装 Docker、镜像加速、空间清理（含验证脚本） |
| [kali-docker.md](kali-docker.md) | Linux（Kali） | Kali / Debian 安装 Docker CE 与 Compose 插件 |
| [kali-gitlab-runner.md](kali-gitlab-runner.md) | Linux（Kali） | 安装 GitLab Runner、注册到自建 GitLab 与流水线冒烟 |
| [kali-cisco-ai-defense.md](kali-cisco-ai-defense.md) | Linux（Kali） | Cisco AI Defense 扫描工具集（mcp/skill/a2a-scanner、aibom） |
| [linux-ollama.md](linux-ollama.md) | Linux（Ubuntu） | 部署 Ollama 离线包与 systemd 服务 |
| [linux-npm.md](linux-npm.md) | Linux（Ubuntu） | Node.js（nvm）安装、npm 镜像配置与排障 |
| [linux-promptfoo.md](linux-promptfoo.md) | Linux（Ubuntu） | Promptfoo 安装与红队测试 |
| [linux-kubernetes.md](linux-kubernetes.md) | Linux（Ubuntu） | 单节点 Kubernetes（kubeadm + containerd + flannel）部署、验证与排障 |
| [linux-provisioning-playbook.md](linux-provisioning-playbook.md) | Linux（Ubuntu） | 跨组件实操要点、镜像源实测数据与共性踩坑速查（被各手册引用） |
| [kubernetes-harbor.md](kubernetes-harbor.md) | Kubernetes（Ubuntu） | 在 K8s 上用 Helm 部署 Harbor 私有镜像仓库（NodePort / 自签 HTTPS / 国内镜像源） |
| [kubernetes-harbor-install.sh](kubernetes-harbor-install.sh) | Kubernetes（Ubuntu） | Harbor 一键安装脚本（前置检查 → 渲染校验 → 安装/升级 → 导出 CA → 验证，幂等） |
| [kubernetes-gitlab.md](kubernetes-gitlab.md) | Kubernetes（Ubuntu） | 在 K8s 上用 Helm 部署极狐 GitLab（外置 PostgreSQL / Redis / MinIO，国内镜像源） |
| [kubernetes-gitlab-runner.md](kubernetes-gitlab-runner.md) | Kubernetes（Ubuntu） | 在 K8s 上用 Helm 部署 GitLab Runner（kubernetes 执行器，3 副本，标签路由，国内镜像源） |
| [linux-gitlab.md](linux-gitlab.md) | Linux（Ubuntu） | 独立 Docker 部署 GitLab CE（不接入 K8s，国内镜像源） |
| [kubernetes-argocd.md](kubernetes-argocd.md) | Kubernetes（Ubuntu） | 在 K8s 上用 Helm 部署 Argo CD（GitOps 持续交付，NodePort + 国内镜像源） |
| [kubernetes-argocd-install.sh](kubernetes-argocd-install.sh) | Kubernetes（Ubuntu） | Argo CD 一键安装脚本（镜像源 → 渲染校验 → 安装/升级 → TLS → 验证，幂等） |
| [kubernetes-ingress-cert-manager.md](kubernetes-ingress-cert-manager.md) | Kubernetes（Ubuntu） | 部署 ingress-nginx + cert-manager，用自建 CA 签证书（域名入口 + 自动签发） |
| [kubernetes-cluster-health.md](kubernetes-cluster-health.md) | Kubernetes（Ubuntu） | 集群健康排查与自愈（凭据漂移 401 / 节点重启残留 / 组件 NotReady 的判别与修复） |
| [kubernetes-cluster-audit.sh](kubernetes-cluster-audit.sh) | Kubernetes（Ubuntu） | 集群健康与凭据一致性只读审计（节点 / Pod / DaemonSet / Argo CD / 凭据同步） |
| [windows-kubectl.md](windows-kubectl.md) | Windows | 安装 kubectl、取回并配置 kubeconfig 直连集群（含 PowerShell 踩坑与安全） |
| [ingress/](ingress/) | Kubernetes（Ubuntu） | 上述部署的 values 与清单（ingress-nginx / cert-manager / ClusterIssuer / Argo CD Ingress / 验证脚本） |
| [others-vscode-claude.md](others-vscode-claude.md) | Windows / Kali | VSCode + Claude Code 接入硅基流动（DeepSeek）的安装与配置 |

## 仓库维护与 CI 清理

仓库配套两个幂等维护脚本与一条 GitHub Actions 清理流水线，保证流水线运行期与运行结束后工作区、缓存、临时资源无残留。

| 脚本 / 流水线 | 作用 |
| --- | --- |
| [`scripts/cleanup.sh`](scripts/cleanup.sh) | 标准化清理：临时文件 / 构建产物 / 依赖缓存 / 全局工具缓存；已跟踪文件一律跳过 |
| [`scripts/validate.sh`](scripts/validate.sh) | 仓库健康校验：Shell 语法、内嵌脚本一致性、死链、孤儿文件、敏感信息、残留扫描 |
| [`.github/workflows/cleanup.yml`](.github/workflows/cleanup.yml) | 清理流水线，三阶段串行 |

`cleanup.sh` 模式：`--check`（只读门禁）、`--pre`（前置清理）、`--post`（收尾清理 + 全局缓存 + 校验）、`--all`、`--cache`。

| 阶段 | 内容 | 触发时机 |
| --- | --- | --- |
| 1/3 前置清理 | `cleanup.sh --pre`：清临时 / 构建 / 缓存 | 每次运行开始 |
| 2/3 仓库校验 | `validate.sh`（含残留扫描） | 前置清理通过后 |
| 3/3 收尾清理 | `cleanup.sh --post` + `git status --porcelain` 必须为空 | 校验通过后 |

自动触发规则：`push` 到 `main`、`pull_request`、手动 `workflow_dispatch`、每周日 02:17 UTC 定时。

## 通用提问模板

按目的选择一种问法，Agent 会自动读取手册并执行：

```text
【完整部署】按 linux-docker.md 手册在本机部署 Docker，执行前向我确认参数区的参数。

【仅执行某一章】按 linux-docker.md 第 2.2 章为 Ubuntu 配置镜像加速。

【仅验证】按 linux-docker.md 第 4.1 章的快速验证脚本验证 Docker 部署，汇报结果与日志路径。

【带参数覆盖】按 linux-ollama.md 部署 Ollama，安装包在 D:\downloads\ollama-linux-amd64.tar.zst，
OLLAMA_ORIGINS 收紧为 https://myapp.example.com。

【排障】docker 服务启动失败，按 linux-docker.md 第 6 章排查并给出原因。
```

## 各手册使用示例

### Docker（linux-docker.md）

```text
1. Ubuntu 安装：
   按 linux-docker.md 在 Ubuntu 24.04 上安装 Docker 并配置镜像加速。

2. 运行验证脚本：
   按 linux-docker.md 第 4.1 章验证 Docker 部署，传入参数区的镜像地址比对加速是否生效。

3. 空间清理：
   按 linux-docker.md 第 5 章清理 Docker，但跳过卷清理（我还有要保留的数据）。
```

预期行为：安装走逐步执行、失败即停；daemon.json 合并而非覆盖；卷清理与 `system prune -a` 必须逐项确认。

### Kali Docker（kali-docker.md）

```text
在 Kali 上按 kali-docker.md 安装 Docker，我不想升级整个系统（跳过 full-upgrade，只装依赖包）。
```

### Cisco AI Defense（kali-cisco-ai-defense.md）

```text
按 kali-cisco-ai-defense.md 在 Kali 上安装 mcp-scanner、skill-scanner、a2a-scanner、aibom，
装完后对各工具做冒烟验证并汇报。
```

### Node.js / npm（linux-npm.md）

```text
1. 安装：按 linux-npm.md 用 nvm 安装 Node、把 registry 切到 npmmirror，并全局安装 pnpm。
2. 排障：npm install 反复失败，按手册排查章节处理，删除 node_modules 前先征求我同意。
```

### Promptfoo（linux-promptfoo.md）

```text
1. 安装：按 linux-promptfoo.md 安装 Promptfoo 并在当前项目初始化。
2. 红队测试：按该手册第 5 章对 promptfoo-redteam-config.yaml 生成用例并执行评估，
   目标系统的 API Key 我已配置在环境变量中。
```

预期行为：红队测试属于主动测试，Agent 会先与你确认目标再执行。

### Kubernetes（linux-kubernetes.md）

```text
1. 部署：按 linux-kubernetes.md 在 Ubuntu 上部署单节点 Kubernetes（kubeadm + containerd + flannel），执行前向我确认参数区参数。
2. 验证：按 linux-kubernetes.md 第 7.1 章运行验证脚本，汇报结果与日志路径。
3. 排障：节点 NotReady / 镜像拉取失败（ImagePullBackOff），按 linux-kubernetes.md 第 8 章定位。
```

预期行为：已 init 的集群跳过初始化；重启 containerd 等影响 Docker 的操作先告知影响面；`kubeadm reset` 等破坏性操作必须确认。

### GitLab（linux-gitlab.md）

```text
1. 部署：按 linux-gitlab.md 在 192.168.40.189 用独立 Docker Compose 部署 GitLab CE（不接入 K8s），执行前向我确认参数区参数。
2. 验证：按 linux-gitlab.md「验证部署」运行检查（Web / Registry / SSH / API），汇报结果。
3. 排障：登录不上或仓库不可用，按 linux-gitlab.md「验证失败恢复」重置密码或查日志。
```

预期行为：镜像走国内源（docker.m.daocloud.io），不得直连 Docker Hub；端口避开 80/22 与 K8s 端口；不创建任何 K8s 资源；默认关闭公开注册；升级 `:latest` 前备份 `/opt/gitlab`。

### GitLab Runner on K8s（kubernetes-gitlab-runner.md）

```text
1. 部署：按 kubernetes-gitlab-runner.md 在 K8s 上部署 GitLab Runner（3 副本，标签 k8s），执行前向我确认参数区参数。
2. 验证：按第 4 章核对 3/3 Pod、GitLab 侧 online + 3 managers，并跑通带 k8s 标签的冒烟作业。
3. 排障：job 一直 Pending / 镜像拉取超时，按第 5 章定位（helper 镜像、镜像源顺序、节点 kubelet）。
```

预期行为：只接带 `k8s` 标签的作业（`run_untagged=false`），不抢既有 runner 的无标签作业；镜像与 helper 走国内源；重启 containerd、强制删 Pod、重跑他人流水线前先确认。

### Harbor（kubernetes-harbor.md）

```text
1. 部署：按 kubernetes-harbor.md 第 0 章用 kubernetes-harbor-install.sh 一键安装（NodePort + 自签 HTTPS，镜像走国内源），执行前向我确认参数区参数。
2. 验证：脚本已自动导出 CA；再按 kubernetes-harbor.md 第 6.4 章运行 harbor_verify.sh 并汇报结果。
3. 使用：建项目后 docker login/push/pull；让集群从 Harbor 拉镜像按第 6.5 章配置。
4. 排障：Pod 起不来 / ImagePullBackOff / 证书报错，按 kubernetes-harbor.md 第 8 章定位。
```

预期行为：一键脚本幂等（已安装走 `helm upgrade`）；镜像保持 `docker.io` 由 containerd 镜像源加速；密码/密钥随机生成写入 values 文件（不提交仓库）；重启 containerd、卸载等破坏性操作必须先确认。

### Argo CD（kubernetes-argocd.md）

```text
1. 部署：按 kubernetes-argocd.md 第 0 章用 kubernetes-argocd-install.sh 一键安装（NodePort + TLS，默认 TLS_MODE=ca），执行前向我确认参数区参数。
2. 接入：按第 6.3 节登记 Git 仓库凭据（configs.repositories），按第 6.4 节创建 root Application / ApplicationSet。
3. 域名入口：按 kubernetes-ingress-cert-manager.md 部署 ingress-nginx + cert-manager，UI 走 https://argocd.lan。
4. 排障：应用一直 OutOfSync / SyncFailed，按第 8.3 节定位（repo server 日志 + configs.repositories）。
```

预期行为：quay.io / registry.k8s.io 镜像走 containerd 镜像源；只用稳定版（拒装 rc/beta）；CI 只改 manifests、由 Argo CD 负责 sync；凭据只进 Secret / 本地 values，不写仓库。

### Windows kubectl 直连集群（windows-kubectl.md）

```text
1. 安装：按 windows-kubectl.md 第 2 章用 winget 安装 kubectl 1.37.2（与服务端对齐）。
2. 配置：按第 3 章从 192.168.40.189 取回 admin.conf 到 .kube/config，并设 KUBECONFIG 环境变量。
3. 验证：按第 4 章跑一键验证脚本，确认三节点 Ready、auth can-i 返回 yes。
4. 排障：连不上 / 证书报错 / PowerShell 传参不生效，按第 8 章与第 6 章定位。
```

预期行为：客户端与服务端 minor 版本对齐；`--kubeconfig` 变量加引号；凭据不入库、不外泄；危险操作先确认。

### 集群健康排查与自愈（kubernetes-cluster-health.md）

```text
1. 体检：按 kubernetes-cluster-health.md 第 0 章跑 kubernetes-cluster-audit.sh（只读），再带 --secrets 查凭据一致性。
2. 排障：Pod ImagePullBackOff / Argo CD Degraded，按第 3 章区分 401 与 404，定位凭据漂移并同步三份 harbor-creds。
3. 排障：CreateContainerError / 系统 Pod NotReady，按第 4 章查 containerd 残留容器与 CNI 探针，删 Pod 由 DaemonSet 重建。
```

预期行为：先只读定位再动资源；凭据先溯源（core 日志 + admin update_time）后同步；不直接改 `harbor_user.password`；删 Pod / 重启 containerd 前先评估影响面；密码不写进仓库。

### Ollama（linux-ollama.md）

```text
1. 部署：按 linux-ollama.md 部署 Ollama，安装包在 /opt/ollama-linux-amd64.tar.zst，监听 0.0.0.0。
2. 收紧配置：把 OLLAMA_ORIGINS 从 * 改为 https://myapp.example.com 并重启服务。
3. 排障：ollama 服务起不来，按 linux-ollama.md 第 5 章查日志定位（先确认 ollama 用户是否存在）。
```

## 组合工作流示例

### GitLab CI + Argo CD 交付闭环（~10 个应用）

```text
按顺序执行并逐步汇报：
1. GitLab Runner：注册 Runner 并跑通一条最小流水线（构建 → push Harbor）
2. kubernetes-argocd.md 第 0 章：安装 Argo CD（NodePort + TLS），验证 /healthz
3. kubernetes-argocd.md 第 6.3/6.4 节：登记 GitLab 仓库凭据 + 创建 root Application / ApplicationSet
4. kubernetes-ingress-cert-manager.md：部署 ingress-nginx + cert-manager，UI 走 https://argocd.lan
5. 选一个应用试点：GitLab CI 更新 manifests 仓库的 image tag → Argo CD 自动 sync
```

预期行为：同一批 K8s 资源只由 Argo CD 管理（不再用 CI 里的 helm upgrade 并管）；root Application 加 finalizer；CI 侧不直接操作集群；客户端信任一次自建 CA 后域名访问无告警。

### 平台入口与自动证书（域名 + 443）

```text
按 kubernetes-ingress-cert-manager.md 执行：
1. 确认宿主机 443 空闲（ss -ltnp），选定固定节点
2. 部署 ingress-nginx（hostPort 443）与 cert-manager
3. 用自建 CA 建 ClusterIssuer lab-ca，为 Argo CD 建 Ingress（https://argocd.lan）
4. 跑 ingress/ingress_verify.sh（7 项全 PASS）
```

预期行为：80 被占用时不强行抢占（HTTP 走 30081 自动 308 跳转）；CA 私钥不入库；客户端未导入 CA 时明确提示告警而非静默。

### 新 Ubuntu 服务器初始化

```text
按顺序执行并逐步汇报：
1. linux-docker.md 第 2~3 章 — 安装 Docker、配置加速、加入 docker 组
2. linux-npm.md 第 2~4 章 — nvm 安装 Node、切换 npmmirror 并安装 pnpm
```

## Agent 行为约定（所有手册通用）

- **先检查再执行**：每章先做只读检查，已完成的内容自动跳过。
- **参数先确认**：执行变更前向用户确认参数区的参数。
- **危险操作必须确认**：重启系统、删除文件/卷、`system prune -a`、对外监听地址收紧等，逐项征求同意。
- **失败即停**：命令失败时查日志定位原因（各手册注意事项节指定了对应日志命令），不盲目重试。
- **逐步汇报**：每完成一章汇报当前状态与下一步计划。
