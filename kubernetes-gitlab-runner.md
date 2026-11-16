# GitLab Runner on Kubernetes 部署文档

> 目标：在现有 Kubernetes 集群上用官方 Helm Chart 部署 GitLab Runner（Kubernetes 执行器），3 副本，接入自建极狐 GitLab（`http://192.168.40.189:30080`），镜像走国内源，并提供可复用的安装、验证、排障与卸载流程。
>
> 本文基于 2026-11-16 的实际部署记录整理。集群 Kubernetes v1.37.2（control-plane `ubuntu` 192.168.40.189 + worker `ubunt-dev` 192.168.40.183），GitLab v19.5.5-jh，Runner Chart `gitlab-cn/gitlab-runner` 0.94.3（appVersion 19.5.3）。

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在已就绪的 Kubernetes 集群上部署 GitLab Runner，并注册到自建 GitLab（K8s 部署，见 [kubernetes-gitlab.md](kubernetes-gitlab.md)），打通「代码 → 构建 → 镜像 → 部署」的 CI 闭环。

Agent 应按「前置检查 → 执行 → 验证」的模式逐步操作；各步骤幂等，已完成的内容会自动跳过。

**本次实测基线（2026-11-16）**：Kubernetes v1.37.2 · GitLab v19.5.5-jh（`http://192.168.40.189:30080`）· Runner Chart 0.94.3 / Runner 19.5.3 · 执行器 `kubernetes` · 副本 3（1 个 runner 实体 + 3 个 runner manager）· 并发 4/副本 · 标签 `k8s`。

---

## 0. 复用指南（先读这里）

本节面向后续重复安装、迁移与升级。只改参数区，然后按第 3 章顺序执行即可。

### 0.1 参数区

```bash
# ---- 目标集群与 GitLab ----
GITLAB_URL="http://192.168.40.189:30080"   # GitLab 根地址（内网 HTTP，必须含端口）
CLUSTER_HOST="192.168.40.189"              # 集群对外 IP

# ---- Runner ----
RUNNER_NS="gitlab-runner"                  # Runner 与 job pod 所在命名空间
RUNNER_NAME="k8s-gitlab-runner"            # Runner 显示名
RUNNER_TAGS="k8s"                          # 标签（逗号分隔）；标签路由见 1.3
RUNNER_REPLICAS="3"                        # 副本数（runner manager 数量）
RUNNER_CONCURRENT="4"                      # 单副本并发 job 数
CHART_VERSION="0.94.3"                     # gitlab-cn/gitlab-runner Chart 版本
RUNNER_IMAGE_TAG="alpine-v19.5.3"          # 与 Chart appVersion 对齐

# ---- 镜像源（国内优先）----
IMAGE_REGISTRY="docker.m.daocloud.io"
HELPER_IMAGE="${IMAGE_REGISTRY}/gitlab/gitlab-runner-helper:x86_64-<runner_revision>"

# ---- 令牌（必填，不入库）----
GLRT_TOKEN=""                              # glrt- 开头的 Runner 认证令牌，见 3.1
ADMIN_PAT=""                               # GitLab 管理员 PAT（仅用于取令牌/改属性）

# ---- 工作目录 ----
WORK_DIR="/root/gitlab-runner-deploy"
```

> 复用原则：标准配置进入 Helm values；令牌只放本地文件（`$WORK_DIR/values.yaml`），**不写进仓库**。升级后必须重放第 3.4 节的属性调整。

### 0.2 前置检查（只读）

```bash
set -euo pipefail

# 1) 集群与节点（NotReady 节点上的 job pod 会调度失败，先确认）
kubectl get nodes -o wide
kubectl get sc

# 2) Helm 版本（建议 3.18+）
helm version --short

# 3) GitLab 可达性（应返回 200）
curl -sS -o /dev/null -w 'gitlab_health=%{http_code}\n' --max-time 10 "${GITLAB_URL}/-/health"

# 4) 已有 Runner / 命名空间
kubectl -n "$RUNNER_NS" get deploy,pods 2>/dev/null || echo "runner_ns_not_exist"
helm -n "$RUNNER_NS" list 2>/dev/null || true

# 5) 镜像源连通性（逐个实测，成功者才写进 values）
for u in https://docker.m.daocloud.io/v2/ https://docker.imgdb.de/v2/ https://hub.rat.dev/v2/; do
  printf '%s -> ' "$u"
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --connect-timeout 8 --max-time 15 "$u" || echo FAIL
done

# 6) 确认参数
echo "GITLAB_URL=$GITLAB_URL RUNNER_NS=$RUNNER_NS REPLICAS=$RUNNER_REPLICAS"
read -r -p "参数确认无误？[y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || exit 1
```

判定逻辑：

- Runner 已部署（`helm -n $RUNNER_NS list` 有 `gitlab-runner`）→ 跳到第 3.3 节做升级，或直接第 4 章验证。
- GitLab 不可达（非 200）→ 先恢复 GitLab，不要继续。
- 存在 NotReady 节点 → 记录，必要时在 values 里用 `nodeSelector`/`affinity` 避开（见 5.3）。

### 0.3 复用步骤（按顺序执行）

1. **取令牌**：第 3.1 节（`glrt-`，UI 或 API）。
2. **准备 values**：第 3.2 节，写入 `$WORK_DIR/values.yaml`。
3. **安装 / 升级**：第 3.3 节（`helm upgrade --install`，幂等）。
4. **安装后调整**：第 3.4 节（标签、`run_untagged`、`request_concurrency`）——升级后必须重放。
5. **验收**：第 4 章（集群侧 + GitLab 侧 + 端到端冒烟）。

### 0.4 最佳实践清单

- **1 个 runner 实体 + N 个 manager**：GitLab 17+ 的 `glrt-` 认证令牌支持复用，多副本注册后 UI 只显示一个 runner，附带 N 个 system ID（见 1.1）。这是官方推荐的多副本形态，不要为每副本单独建 runner。
- **标签路由，不抢无标签作业**：多 runner 共存时（本机已有 `kali-192.168.40.188`），新 runner 设 `tags` 且 `run_untagged=false`，只接带标签的作业，避免与既有 runner 抢活（事故复盘见 5.4）。
- **镜像国内源优先**：Runner 与 helper 镜像用 `docker.m.daocloud.io`；`docker.io` 作业镜像由 containerd 的 `/etc/containerd/certs.d/docker.io/hosts.toml` 镜像源加速。**写死前逐个实测**（见 5.2）。
- **helper 镜像显式指定**：不指定时 Runner 默认去 `registry.gitlab.com` 拉 helper，内网不可达会直接卡死作业；用 `helper_image` 指向国内源、且 tag 与 Runner 版本对齐。
- **RBAC 最小权限**：`rbac.create=true` + 显式 `rules`，不要用 Chart 默认的 `*`。
- **副本分散**：`topologySpreadConstraints` 按 `kubernetes.io/hostname` 软打散；生产可改 `podAntiAffinity` 硬约束。
- **`request_concurrency` ≥ 2**：GitLab 19.5 会对 `request_concurrency=1` 打印长轮询告警并可能拖慢领作业，建议 2–4。
- **资源限制**：给 manager 设 `requests/limits`，避免与 GitLab 主组件抢资源。
- **令牌安全**：`glrt-` 与 PAT 等同密码，只进本地 values / Secret，不写文档、日志、仓库。

### 0.5 验收标准

- `kubectl -n gitlab-runner get deploy gitlab-runner` 显示 `3/3` 可用，Pod 全部 `Running` 且 `RESTARTS=0`。
- GitLab 侧 `GET /api/v4/runners/:id` 返回 `online=true`、`status=online`。
- `GET /api/v4/runners/:id/managers` 返回 3 条记录（对应 3 副本）。
- 端到端冒烟：带 `k8s` 标签的作业 `success`，日志含预期输出（见 4.3）。

### 0.5.1 已知陷阱速查

| 陷阱 | 现象 | 正确做法 |
|---|---|---|
| 未指定 `helper_image` | job 一直 `Pending`，事件停在 `Pulling image "registry.gitlab.com/gitlab-org/gitlab-runner-helper..."` | values 里显式写国内源 helper 镜像（3.2） |
| `glrt-` 令牌注册多副本失败 | 报 `410 Gone` / 认证失败 | 用 `glrt-` 认证令牌（非旧 registration token），见 3.1 |
| 用 `gitlab-gitlab-runner-secret` 里的 token | 注册报 `410 Gone` | 该值是旧机制遗留，GitLab 16+ 不可用；改用 API/UI 创建的 `glrt-` 令牌（3.1） |
| 以为 GitLab Chart 会自带 Runner | 集群里找不到 runner 资源 | GitLab values 中 `gitlab-runner.install: false`，Runner 由独立 Chart 部署（3.3） |
| `rbac.rules` 留空 | 生成 `*` 权限 Role，权限过大 | 显式写最小权限规则（3.2） |
| 副本数改了但 Job 不均衡 | 所有 job 落同一副本 | 设 `request_concurrency`、`topologySpreadConstraints` |
| `docker.1ms.run` 等慢源 | job 因拉镜像超时而 `failed`（system failure） | 实测并调整 containerd 镜像源顺序（5.2） |
| 节点 kubelet 卡死 | 该节点所有镜像拉取停滞、Pod 长期 `ContainerCreating` | 重启 kubelet（5.3） |
| 抢走既有 runner 的无标签作业 | 其他项目流水线被新 runner 领走并失败 | `run_untagged=false` + 标签路由（1.3、5.4） |

### 0.6 复用安装脚本

前提：`$WORK_DIR/values.yaml` 已生成（首次部署按 3.2 生成；含真实令牌）。之后重装、修复、升级直接运行：

```bash
set -euo pipefail
GITLAB_NS="gitlab-runner"
WORK_DIR="/root/gitlab-runner-deploy"

kubectl create namespace "$GITLAB_NS" --dry-run=client -o yaml | kubectl apply -f -
helm repo add gitlab-cn https://charts.gitlab.cn/ >/dev/null 2>&1 || true
helm repo update gitlab-cn >/dev/null 2>&1 || true
helm upgrade --install gitlab-runner gitlab-cn/gitlab-runner \
  --version "0.94.3" \
  -n "$GITLAB_NS" \
  -f "$WORK_DIR/values.yaml" \
  --timeout 300s
kubectl -n "$GITLAB_NS" rollout status deploy/gitlab-runner --timeout=240s
```

---

## 1. 架构与关键决策

### 1.1 副本模型：1 个 runner 实体 + N 个 runner manager

GitLab 17.0 起用 **Runner 认证令牌**（`glrt-`）取代旧 registration token。官方文档明确：**同一认证令牌可复用注册多个 runner**，多副本在 GitLab UI 中显示为同一个 runner，通过唯一的 system ID 区分（[迁移说明](https://docs.gitlab.com/ci/runners/new_creation_workflow/)）。

因此「3 副本」的正确落地方式是：

```
GitLab:  Ci::Runner (id=2, description=k8s-gitlab-runner)
             ├── runner manager  system_id=r_xxx  ← gitlab-runner-xxx-aaaa  (node ubunt-dev)
             ├── runner manager  system_id=r_yyy  ← gitlab-runner-xxx-bbbb  (node ubuntu)
             └── runner manager  system_id=r_zzz  ← gitlab-runner-xxx-cccc  (node ubunt-dev)
```

Chart 的 `replicas: 3` 起 3 个 Pod，每个 Pod 启动时用同一个 `glrt-` 令牌注册（各自生成唯一 system ID），作业由 GitLab 在该 runner 的多个 manager 间分发。**不要**为每个副本单独创建 runner（会产生 3 个独立 runner 实体，UI 与配额都变复杂）。

### 1.2 命名空间与执行器

- 独立命名空间 `gitlab-runner`：manager Pod 与 job Pod 同命名空间（Chart 默认 `runners.jobNamespace` = Release 命名空间），RBAC 用 Role/RoleBinding 即可，无需 ClusterRole。
- 执行器 `kubernetes`：每个 job 一个独立 Pod（`runner-<token>-project-<id>-concurrent-<n>-<rand>`），隔离性好，是 K8s 上的默认推荐。

### 1.3 标签路由（多 runner 共存）

本机 GitLab 上已有 `kali-192.168.40.188`（docker 执行器，接无标签作业）。新 runner 若开 `run_untagged=true` 会与它抢活，可能把不适合 K8s 执行器的作业（如依赖宿主机 Docker daemon 的 `docker build`）抢过来跑失败（事故见 5.4）。

决策：**新 runner 只接带 `k8s` 标签的作业**，即 `run_untagged=false` + `tag_list=k8s`。作业侧用 `tags: [k8s]` 显式路由。

> 若确认要让 K8s runner 接管全部作业，可在 GitLab 侧把它设为 `run_untagged=true` 并停掉旧 runner——但必须先确认作业镜像与执行器匹配。

### 1.4 镜像源

| 用途 | 镜像 | 说明 |
|---|---|---|
| Runner manager | `docker.m.daocloud.io/gitlab/gitlab-runner:alpine-v19.5.3` | 与 Chart appVersion 对齐 |
| helper（git/artifacts） | `docker.m.daocloud.io/gitlab/gitlab-runner-helper:x86_64-33227fd4` | tag 取 Runner 二进制 `revision`（见 3.2 注释） |
| 作业默认镜像 | `docker.m.daocloud.io/library/alpine:3.20` | job 未写 `image:` 时使用 |
| 作业 `docker.io/*` | 走 containerd `certs.d` 镜像源 | 见 5.2，源顺序需实测 |

---

## 2. 前置条件

- Kubernetes 集群就绪，`kubectl` 可用，`local-path` 为默认 StorageClass（job 需要 PVC 时）。
- GitLab 健康（`/-/health` 返回 200），且有一个**管理员账号**可用于取 `glrt-` 令牌。
- Helm 3.18+，且已添加 `gitlab-cn` 仓库（`helm repo add gitlab-cn https://charts.gitlab.cn/`）。
- 准备存放 values 与令牌的工作目录（默认 `/root/gitlab-runner-deploy`），**该目录不入库**。

---

## 3. 部署步骤（幂等）

### 3.1 获取 `glrt-` 认证令牌

GitLab 16 起旧的 registration token 已不可用，必须用 `glrt-` 开头的 Runner 认证令牌。

**方式 A：Web UI（推荐，人工）**

管理员登录 → Admin Area → CI/CD → Runners → New instance runner → 填描述/标签 → Create runner → 复制 `glrt-` 令牌（只显示一次）。

> ⚠️ **不要用 `gitlab-gitlab-runner-secret` 里的 token。** GitLab Chart 会在 `gitlab` 命名空间创建 `gitlab-gitlab-runner-secret`，其中 `runner-registration-token` 是旧注册机制的遗留值（`runner-token` 通常为空）。GitLab 16+ 已禁用该机制，拿它注册会报 `410 Gone - runner registration disallowed`。请按下面方式 A/B 取 `glrt-` 令牌。

**方式 B：API（需管理员 PAT）**

```bash
# 1) 创建实例级 runner，返回 glrt- 令牌
curl -sS -X POST -H "PRIVATE-TOKEN: ${ADMIN_PAT}" \
  "${GITLAB_URL}/api/v4/user/runners" \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=${RUNNER_NAME}" \
  --data-urlencode "run_untagged=false" \
  --data-urlencode "tag_list=${RUNNER_TAGS}"
# 返回 {"id":2,"token":"glrt-...","token_expires_at":null}

# 2) 保存令牌（本地文件，权限 600）
printf '%s' '<glrt-...>' > "$WORK_DIR/.glrt-token"; chmod 600 "$WORK_DIR/.glrt-token"
```

> 没有 PAT 时，可用 toolbox Pod 的 rails console 现场生成（root 密码在 `/root/gitlab-deploy/.secrets` 的 `ROOT_PASS`）：
>
> ```bash
> kubectl -n gitlab exec deploy/gitlab-toolbox -c toolbox -- gitlab-rails runner \
>   "u=User.find_by_username!('root'); t=PersonalAccessToken.new(user:u,name:'agent',scopes:['api'],expires_at:7.days.from_now); raw='glpat-'+SecureRandom.hex(20); t.set_token(raw); t.save!; puts raw"
> ```

### 3.2 准备 values

写入 `$WORK_DIR/values.yaml`（**令牌为占位符，实际部署时替换为真实值，且不入库**）：

```yaml
# GitLab Runner on Kubernetes - values
image:
  registry: docker.m.daocloud.io
  repository: gitlab/gitlab-runner
  tag: alpine-v19.5.3
  imagePullPolicy: IfNotPresent

gitlabUrl: "http://192.168.40.189:30080/"

# glrt- 认证令牌（本地文件，不入库）
runnerToken: "<GLRT_TOKEN>"

replicas: 3

concurrent: 4
checkInterval: 3
logLevel: info
logFormat: json

rbac:
  create: true
  clusterWideAccess: false
  rules:
    - apiGroups: [""]
      resources: ["pods", "pods/exec", "pods/attach", "pods/log"]
      verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]
    - apiGroups: [""]
      resources: ["secrets", "configmaps", "services", "events", "persistentvolumeclaims"]
      verbs: ["get", "list", "watch", "create", "patch", "update", "delete"]

serviceAccount:
  create: true

runners:
  name: "k8s-gitlab-runner"
  executor: kubernetes
  config: |
    [[runners]]
      request_concurrency = 4
      [runners.kubernetes]
        namespace = "gitlab-runner"
        image = "docker.m.daocloud.io/library/alpine:3.20"
        pull_policy = "if-not-present"
        # tag 与 Runner 二进制 revision 对齐：docker run --rm --entrypoint gitlab-runner <runner镜像> --version
        helper_image = "docker.m.daocloud.io/gitlab/gitlab-runner-helper:x86_64-33227fd4"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: "1"
    memory: 512Mi

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: gitlab-runner
```

要点：

- `runnerToken` 用 `glrt-` 令牌；Chart 会把它写进 Secret `gitlab-runner`，Pod 启动时注册。
- `helper_image` 的 tag `x86_64-33227fd4` 来自 Runner 二进制 revision（`gitlab-runner --version` 输出的 `revision=`）。换 Runner 版本时同步换 helper tag。
- `runners.config` 里的 `namespace` 必须与 Release 命名空间一致（`jobNamespace` 留空时），否则 RoleBinding 主体命名空间与 Role 所在命名空间不匹配导致 RBAC 失效。
- `podSecurityContext.runAsUser` 默认 100（alpine 镜像 `gitlab-runner` 用户 UID=100），不要随意改。

### 3.3 安装 / 升级

```bash
kubectl create namespace gitlab-runner --dry-run=client -o yaml | kubectl apply -f
helm upgrade --install gitlab-runner gitlab-cn/gitlab-runner \
  --version 0.94.3 -n gitlab-runner \
  -f "$WORK_DIR/values.yaml" --timeout 300s
kubectl -n gitlab-runner rollout status deploy/gitlab-runner --timeout=240s
kubectl -n gitlab-runner get pods -o wide
```

预期：3 个 Pod `Running` 后转 `1/1 Ready`（readiness 默认 `initialDelaySeconds=60`，稍等即可）。

### 3.4 安装后调整（升级后必须重放）

Chart 的 `runners.tags` / `runUntagged` 在 `glrt-` 令牌下**不生效**（entrypoint 会 unset `RUNNER_TAG_LIST`），标签与 `run_untagged` 必须在 GitLab 侧设置：

```bash
RUNNER_ID=$(curl -sS -H "PRIVATE-TOKEN: ${ADMIN_PAT}" \
  "${GITLAB_URL}/api/v4/runners/all?per_page=100" \
  | python3 -c "import sys,json;[print(r['id']) for r in json.load(sys.stdin) if r['description']=='${RUNNER_NAME}"]")

curl -sS -X PUT -H "PRIVATE-TOKEN: ${ADMIN_PAT}" "${GITLAB_URL}/api/v4/runners/${RUNNER_ID}" \
  --data-urlencode "run_untagged=false" \
  --data-urlencode "tag_list=${RUNNER_TAGS}" \
  --data-urlencode "description=${RUNNER_NAME}"
```

`request_concurrency` 是 Runner 配置项，写在 values 的 `runners.config` 里即可，`helm upgrade` 后生效（用于消除 19.5 的长轮询告警）。

---

## 4. 验证

### 4.1 集群侧

```bash
kubectl -n gitlab-runner get deploy,pods -o wide
# deploy 3/3，Pod 全 Running、RESTARTS=0

# 注册日志：应看到 3 个不同 system_id，且 runner= 相同
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=2000 \
  | grep -o '"system_id=r_[A-Za-z0-9]*"' | sort -u

# 不应再出现长轮询告警
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=2000 | grep -c "Long polling"
```

### 4.2 GitLab 侧

```bash
curl -sS -H "PRIVATE-TOKEN: ${ADMIN_PAT}" "${GITLAB_URL}/api/v4/runners/${RUNNER_ID}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["id"],d["description"],d["online"],d["status"],d["tag_list"],d["run_untagged"])'
# 期望：online=True status=online tag_list=['k8s'] run_untagged=False

curl -sS -H "PRIVATE-TOKEN: ${ADMIN_PAT}" "${GITLAB_URL}/api/v4/runners/${RUNNER_ID}/managers" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("managers=",len(d));[print(m["system_id"],m["version"]) for m in d]'
# 期望：managers= 3
```

### 4.3 端到端冒烟（必做）

用一个带 `k8s` 标签的最小作业验证「领作业 → 起 Pod → 拉镜像 → 执行 → 回收」全链路：

```yaml
# .gitlab-ci.yml
stages: [smoke]
smoke-k8s:
  stage: smoke
  image: docker.m.daocloud.io/library/alpine:3.20
  tags: [k8s]
  script:
    - echo SMOKE_OK_FROM_K8S_RUNNER
    - uname -a
```

触发并轮询：

```bash
PID=$(curl -sS -X POST -H "PRIVATE-TOKEN: ${ADMIN_PAT}" \
  "${GITLAB_URL}/api/v4/projects/<project_id>/pipeline" --data-urlencode ref=main \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

for i in $(seq 1 30); do
  S=$(curl -sS -H "PRIVATE-TOKEN: ${ADMIN_PAT}" "${GITLAB_URL}/api/v4/projects/<project_id>/pipelines/${PID}" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')
  echo "status=$S"; [ "$S" = success ] && break; [ "$S" = failed ] && break; sleep 5
done

# 作业日志应含 SMOKE_OK_FROM_K8S_RUNNER 与 Job succeeded
curl -sS -H "PRIVATE-TOKEN: ${ADMIN_PAT}" "${GITLAB_URL}/api/v4/projects/<project_id>/jobs/<job_id>/trace" | tail -20
```

**实测结果（2026-11-16）**：pipeline 8 秒内 `success`，job trace 含 `SMOKE_OK_FROM_K8S_RUNNER` 与 `Job succeeded`。

---

## 5. 排障

| 现象 | 可能原因 | 处理 |
|---|---|---|
| job 一直 `Pending`，事件停在 `Pulling image "registry.gitlab.com/.../gitlab-runner-helper..."` | 未指定 `helper_image`，默认源内网不可达 | values 写国内源 helper 镜像（3.2） |
| job `Pending`，`docker.m.daocloud.io/...` 也拉不动 | 节点 kubelet 卡死 / 镜像源慢 | 见 5.2、5.3 |
| job 失败：`prepare environment: waiting for pod running: timed out waiting for pod to start` | Pod 未在超时内起来，多为镜像拉取超时 | 先看 `kubectl -n gitlab-runner describe pod <job-pod>` 的 Events；再查节点拉取（5.2/5.3） |
| 注册失败 `410 Gone - runner registration disallowed` | 用了旧 registration token | 改用 `glrt-` 认证令牌（3.1） |
| Runner 不上线 / `Checking for jobs... failed` | GitLab 不可达或 URL 写错 | 确认 `${GITLAB_URL}/-/health` 为 200；Pod 内 `curl` 该地址 |
| 副本起来但 GitLab 只看到 1 个 manager | 只注册了 1 个副本 / 令牌复用未生效 | 查 `kubectl get pods` 是否 3 个；`/runners/:id/managers` 数量 |
| 长轮询告警 `request_concurrency=1` | 默认并发为 1 | `runners.config` 加 `request_concurrency = 4` 后 `helm upgrade`（3.4） |
| 作业不被领取 | `run_untagged=false` 且作业无匹配标签 | 作业加 `tags: [k8s]`，或按需在 GitLab 侧开 `run_untagged` |
| RBAC 报错 `forbidden` | `jobNamespace` 与 Release 命名空间不一致 | 保持 `namespace = "<Release 命名空间>"`（3.2） |

### 5.1 排查顺序（job 卡 Pending 时）

```bash
# 1) Pod 事件（最先看）
kubectl -n gitlab-runner describe pod <job-pod> | sed -n '/Events:/,$p'

# 2) 卡在 Pulling：确认是哪个镜像、哪个节点
# 3) 该节点直连测试（用节点上已有镜像起 Pod）
kubectl run net-test --image=<节点已有镜像> -n default --restart=Never \
  --overrides='{"spec":{"nodeName":"<node>"}}' --command -- \
  sh -c 'curl -sS -m 10 -o /dev/null -w "%{http_code} %{time_total}\n" https://docker.m.daocloud.io/v2/'

# 4) runner manager 日志
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=200
```

### 5.2 镜像源慢 / 拉取超时（实测）

**现象**：`docker.io/library/docker:27-cli` 拉取极慢，containerd 日志出现
`cancel pulling image ... because of no progress in 5m0s`，job 因等 Pod 超时 `failed`。

**实测（2026-11-16，控制节点 `docker pull` 计时）**：

| 镜像源 | 拉取 `docker:27-cli` |
|---|---|
| `docker.1ms.run` | >90s 未完成（超时） |
| `docker.m.daocloud.io` | 12s |
| `hub.rat.dev` | 1.1s |

**根因**：containerd `/etc/containerd/certs.d/docker.io/hosts.toml` 的镜像源按顺序尝试，排在前面的慢源会拖垮整条链路。

**处理**：

```bash
# 1) 逐源实测（写进配置前必须实测）
for m in docker.1ms.run docker.m.daocloud.io hub.rat.dev docker.1panel.live docker.xuanyuan.me; do
  printf '%s: ' "$m"
  curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 15 "https://$m/v2/" || echo TIMEOUT
done

# 2) 调整顺序：把实测最快的源放前面（两个节点都要改）
#    编辑 /etc/containerd/certs.d/docker.io/hosts.toml，重排 [host."..."] 块
# 3) 重启 containerd（会短暂影响该节点上正在运行的容器，先确认影响面）
systemctl restart containerd
```

> ⚠️ 重启 containerd 会中断该节点上所有容器（含 GitLab 依赖组件）。生产环境应先在低峰期并确认 Pod 可重建。**本仓库建议在排查阶段优先用 5.3 的节点隔离，确认后再统一调源。**

### 5.3 节点 kubelet 卡死（实测）

**现象**：某节点上**所有**镜像拉取停滞，新 Pod 长期 `ContainerCreating`，事件只有 `Pulling image ...`；`ctr` 直连拉取正常、宿主机 `curl` 正常。

**定位**（无需 SSH，用 `kubectl debug node`）：

```bash
kubectl debug node/<node> --image=<节点已有镜像> -- cat /host/etc/containerd/config.toml
kubectl debug node/<node> --image=<节点已有镜像> -- \
  sh -c 'journalctl -u kubelet --since "30 min ago" --no-pager | grep -iE "pull|error" | tail -20'
```

**实测（2026-11-16，`ubunt-dev`）**：kubelet 进程卡住，不再发起 `PullImage`；`systemctl restart kubelet` 后 1.3s 拉起镜像、Pod 正常。常见诱因是强制删除（`--force --grace-period=0`）卡住的 Pod 后 kubelet 状态混乱。

**处理**：

```bash
# 优先：重启 kubelet（不杀容器，影响小）
kubectl debug node/<node> --image=<节点已有镜像> -- chroot /host systemctl restart kubelet

# 仍不行再考虑重启 containerd（会中断该节点容器，影响面大，需先确认）
```

**临时隔离**：若该节点短期不可用，给 values 加 `nodeSelector`/`affinity` 把 manager 与 job 都调度到健康节点：

```yaml
# values：manager 调度约束
nodeSelector:
  kubernetes.io/hostname: ubuntu
# values：job pod 调度约束（写在 runners.config 里）
# [runners.kubernetes.node_selector]
#   kubernetes.io/hostname = "ubuntu"
```

### 5.4 抢走既有 runner 的无标签作业（实测事故）

**现象**：新 runner 上线后，`news/ai` 项目（作业无标签、`image: docker:27-cli`）的流水线被新 runner 领走并 `failed`（3 个 job）。

**根因**：新 runner 设了 `run_untagged=true`，与既有 `kali-192.168.40.188` 抢无标签作业；而该类作业依赖宿主机 Docker daemon（docker 执行器），在 kubernetes 执行器下本就不适配，加上镜像拉取慢，直接失败。

**处理**：

1. GitLab 侧把新 runner 设为 `run_untagged=false`（3.4 的 API）。
2. 后续作业用 `tags: [k8s]` 显式路由。
3. 若已产生失败 job，可由人工确认后重跑（`POST /projects/:id/jobs/:job_id/retry`）——重跑会重新构建并推送镜像，**务必先确认影响面**。
4. 被新 runner 抢过且卡住的旧 job Pod 需清理：`kubectl -n gitlab-runner delete pod <job-pod> --force --grace-period=0`（会触发 5.3 的 kubelet 状态问题，清理后按需重启 kubelet）。

**预防**：多 runner 环境默认 `run_untagged=false` + 标签路由；上线前用 `GET /api/v4/runners/all` 盘点既有 runner 及其 `run_untagged`。

---

## 6. 卸载

```bash
# 1) 先注销（Chart 默认 unregisterRunners=true，卸载时会自动注销 runner manager）
helm -n gitlab-runner uninstall gitlab-runner
# 若需保留 GitLab 侧 runner 记录，仅删 manager 不影响；如需彻底删除在 UI/API 删 runner

# 2) 清理命名空间（确认无其他资源后）
kubectl -n gitlab-runner delete sa,role,rolebinding gitlab-runner --ignore-not-found
kubectl delete namespace gitlab-runner --ignore-not-found

# 3) 删除本地 values 与令牌
rm -f "$WORK_DIR/values.yaml" "$WORK_DIR/.glrt-token"
```

> 删除命名空间前确认其中没有别的负载；`kubectl delete namespace` 会级联删除其中所有资源。

---

## 7. Agent 执行注意事项

- **令牌安全**：`glrt-` 令牌与 PAT 等同密码，只进本地 values / Secret，不写文档、日志、仓库；用完按需吊销（`DELETE /api/v4/runners/:id`）。
- **幂等**：`helm upgrade --install`、命名空间创建、RBAC 均先判断再写，重复执行无副作用。
- **危险操作必须确认**：重启 containerd、`kubectl delete namespace`、`--force --grace-period=0` 删 Pod、重跑他人流水线，逐项征求同意。
- **镜像源必须实测**：不同网络环境可达性差异很大，写进配置前逐个计时验证（5.2）。
- **GitLab 17+ 令牌机制**：旧 `--registration-token` 已不可用（410 Gone），脚本不要沿用旧参数。
- **先验证再交付**：集群侧 3/3、GitLab 侧 online + 3 managers、端到端冒烟 `success` 三项全过才算完成。
- **多 runner 共存先盘点**：`GET /api/v4/runners/all` 看清既有 runner 的 `run_untagged` 与标签，再决定新 runner 的路由策略。

## 关联文档

- [kubernetes-gitlab.md](kubernetes-gitlab.md)：GitLab 本体的 K8s 部署与对象存储配置
- [kali-gitlab-runner.md](kali-gitlab-runner.md)：docker 执行器 Runner（systemd）部署与流水线冒烟
- [linux-kubernetes.md](linux-kubernetes.md)：K8s 集群与节点规划
- [kubernetes-harbor.md](kubernetes-harbor.md)：Harbor 私有镜像仓库（CI 推送目标）
- [kubernetes-argocd.md](kubernetes-argocd.md)：Argo CD（CI 交付闭环）
