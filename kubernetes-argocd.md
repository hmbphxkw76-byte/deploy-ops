# Argo CD on Kubernetes 部署手册（GitOps CD · 可直接安装）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在 **Kubernetes 集群** 上以 **Helm Chart** 部署 **Argo CD**（声明式 GitOps 持续交付平台），并优先使用**国内镜像源**。文档与 [kubernetes-harbor.md](kubernetes-harbor.md) / [kubernetes-gitlab.md](kubernetes-gitlab.md) 同格式：**参数区 → 前置检查 → 幂等执行 → 验证 → 排障 → Agent 注意事项**。

**为什么选 Argo CD（本仓库的决策）**：应用规模约 10 个，需要**漂移检测/自愈、版本树回滚、部署审计与可视化**，且 GitLab CI 已承担构建（CI）——按职责拆分，构建归 GitLab CI，部署归 Argo CD。若只有 1–3 个应用，直接用 GitLab CI `helm upgrade` 更省事（见 [README.md](README.md) 的组合工作流示例）。

**部署形态**：Helm（官方 chart `argo/argo-cd`），命名空间 `argocd`，release 名 `argocd`；暴露方式 **NodePort**（集群当前无 ingress-nginx，与 Harbor/GitLab 的"节点 IP + 端口"形态一致）；**server 以 HTTP 明文提供服务**（`server.insecure=true`，lab 环境；上生产前应换 Ingress + cert-manager + HTTPS）；Dex/Notifications 默认关闭以减少组件与镜像依赖。

**版本状态（截至 2026-11-15 核对）**：Argo CD 稳定线为 **v3.5.x**；`v3.6.0` 目前仅到 `rc4`（预发布），**不建议生产使用**。安装前必须按第 3.2 节交叉核对 chart 与 app 版本。

> 前置依赖：集群已按 [linux-kubernetes.md](linux-kubernetes.md) 部署（含 containerd 镜像源、local-path）；镜像仓库为 [kubernetes-harbor.md](kubernetes-harbor.md)；代码仓库为 [kubernetes-gitlab.md](kubernetes-gitlab.md)。

---

## 0. 快速安装（一键脚本）

### 0.1 用法

```bash
# 把 kubernetes-argocd-install.sh 放到集群可执行节点（如 control-plane），然后：
NODE_IP=192.168.40.189 bash kubernetes-argocd-install.sh
```

常用覆盖项：

```bash
CHART_VERSION=8.6.0 ARGOCD_VERSION=v3.5.2 \
NODEPORT_HTTP=30700 NODEPORT_HTTPS=30701 \
bash kubernetes-argocd-install.sh
```

- `NODE_IP` 必填（无默认值）；其余均有默认值，见第 1 章参数区。
- `CHART_VERSION` / `ARGOCD_VERSION` 留空时**自动解析**（取仓库最新稳定 chart 及其 appVersion），脚本会打印解析结果供确认。
- **幂等**：已安装则自动走 `helm upgrade`，可重复执行。

### 0.2 脚本（kubernetes-argocd-install.sh）

```bash
#!/bin/bash
# Argo CD on Kubernetes 一键安装（NodePort + HTTP + 国内镜像源）
# 用法:
#   NODE_IP=192.168.40.189 bash kubernetes-argocd-install.sh
#   CHART_VERSION=8.6.0 ARGOCD_VERSION=v3.5.2 bash kubernetes-argocd-install.sh
#   NODEPORT_HTTP=30700 NODEPORT_HTTPS=30701 bash kubernetes-argocd-install.sh
# 说明: 幂等。已安装则走 helm upgrade；脚本末尾打印访问地址 / 账号 / 初始密码。
# 退出码: 0=成功, 1=失败
set -euo pipefail

# ---------------- 参数（环境变量覆盖）----------------
NAMESPACE="${NAMESPACE:-argocd}"
RELEASE="${RELEASE:-argocd}"
CHART_VERSION="${CHART_VERSION:-}"          # 留空 = 取仓库最新稳定 chart
ARGOCD_VERSION="${ARGOCD_VERSION:-}"        # 留空 = 取 chart 的 appVersion
NODE_IP="${NODE_IP:?need NODE_IP, e.g. 192.168.40.189}"
NODEPORT_HTTP="${NODEPORT_HTTP:-30700}"
NODEPORT_HTTPS="${NODEPORT_HTTPS:-30701}"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
VALUES_FILE="${VALUES_FILE:-/tmp/argocd-values.yaml}"
export KUBECONFIG

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------- 1. 前置检查（只读）----------------
log "前置检查"
command -v kubectl >/dev/null 2>&1 || die "kubectl 未安装"
command -v helm    >/dev/null 2>&1 || die "helm 未安装"
kubectl get --raw='/readyz' >/dev/null 2>&1 || die "apiserver 不可达（检查 KUBECONFIG）"

# NodePort 占用检查（排除自身命名空间）
CONFLICT=""
while read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  for np in $(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}'); do
    if { [ "$np" = "$NODEPORT_HTTP" ] || [ "$np" = "$NODEPORT_HTTPS" ]; } && [ "$ns" != "$NAMESPACE" ]; then
      CONFLICT="${CONFLICT} ${ns}:${np}"
    fi
  done
done < <(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {range .spec.ports[*]}{.nodePort} {end}{"\n"}{end}' 2>/dev/null)
[ -z "$CONFLICT" ] || die "NodePort 已被占用:${CONFLICT}"

# ---------------- 2. 镜像源：quay.io 走 containerd 透明映射 ----------------
# Argo CD 镜像在 quay.io/argoproj/*，保持镜像地址不变，由 certs.d 映射到国内源
MIRROR_FILE=/etc/containerd/certs.d/quay.io/hosts.toml
if [ ! -f "$MIRROR_FILE" ] || ! grep -q 'daocloud\|nju\|1ms' "$MIRROR_FILE"; then
  log "未检测到 quay.io 镜像映射，准备写入 $MIRROR_FILE"
  cat <<'EOF'

# 需要执行的配置（脚本不会擅自修改 containerd）：
sudo mkdir -p /etc/containerd/certs.d/quay.io
sudo tee /etc/containerd/certs.d/quay.io/hosts.toml <<'CONF'
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://quay.nju.edu.cn"]
  capabilities = ["pull", "resolve"]
CONF
# 若拉取失败再重启 containerd（会影响共用 containerd 的 Docker 容器）：
# sudo systemctl restart containerd

EOF
  read -r -p "是否现在自动写入该配置？[y/N] " ok
  if [[ "$ok" =~ ^[Yy]$ ]]; then
    sudo mkdir -p /etc/containerd/certs.d/quay.io
    sudo tee /etc/containerd/certs.d/quay.io/hosts.toml >/dev/null <<'CONF'
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://quay.nju.edu.cn"]
  capabilities = ["pull", "resolve"]
CONF
    log "已写入；如镜像拉取失败再执行 sudo systemctl restart containerd"
  else
    die "未配置 quay.io 镜像源，Argo CD 镜像可能拉取超时（可手动配置后重跑）"
  fi
fi

# ---------------- 3. 版本解析（交叉核对）----------------
log "添加 helm 仓库"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1 || die "helm repo update argo 失败（argoproj.github.io 可能不可达，见第 3.2 节备选方案）"

if [ -z "$CHART_VERSION" ]; then
  CHART_VERSION=$(helm search repo argo/argo-cd --versions | awk 'NR>1 && $2 !~ /-/ {print $2; exit}')
  [ -n "$CHART_VERSION" ] || die "无法解析 chart 版本"
  log "自动选择最新稳定 chart: $CHART_VERSION"
fi

if [ -z "$ARGOCD_VERSION" ]; then
  ARGOCD_VERSION=$(helm show chart argo/argo-cd --version "$CHART_VERSION" | sed -n 's/^appVersion:[[:space:]]*//p' | tr -d '"')
  [ -n "$ARGOCD_VERSION" ] || die "无法解析 appVersion"
  log "chart 自带 appVersion: $ARGOCD_VERSION"
fi

echo "将安装: chart ${CHART_VERSION} / app ${ARGOCD_VERSION}"
case "$ARGOCD_VERSION" in
  *-rc*|*-beta*) die "ARGOCD_VERSION 是预发布版本（$ARGOCD_VERSION），生产环境请用稳定版" ;;
esac

# ---------------- 4. 生成 values ----------------
log "生成 values: $VALUES_FILE"
cat > "$VALUES_FILE" <<EOF
# 由 kubernetes-argocd-install.sh 生成（含访问配置，勿提交仓库）
global:
  image:
    imagePullPolicy: IfNotPresent

server:
  replicas: 1
  insecure: true                 # NodePort + HTTP（lab）；上生产改 false 并接 Ingress+TLS
  service:
    type: NodePort
    nodePortHttp: ${NODEPORT_HTTP}
    nodePortHttps: ${NODEPORT_HTTPS}

controller:
  replicas: 1
repo:
  replicas: 1

dex:
  enabled: false                 # 暂不接 SSO（省一个 ghcr 镜像）
notifications:
  enabled: false
applicationSet:
  enabled: true

redis:
  enabled: true
  persistence:
    enabled: false               # 缓存无需持久化；若渲染出 redis PVC，见第 5.2 节说明
EOF

# ---------------- 5. 渲染校验（先校验再安装）----------------
log "渲染校验（helm template）"
helm template "$RELEASE" argo/argo-cd --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE" > /tmp/argocd-rendered.yaml \
  || die "helm template 渲染失败"
grep -q "image: quay.io/argoproj/argocd:${ARGOCD_VERSION}" /tmp/argocd-rendered.yaml \
  || die "渲染出的 argocd 镜像 tag 不是 ${ARGOCD_VERSION}（chart 与 app 版本不匹配，见第 3.2 节）"
grep -q 'kind: StatefulSet' /tmp/argocd-rendered.yaml \
  || die "渲染结果缺少 StatefulSet（application-controller）"
if grep -q 'dexidp/dex' /tmp/argocd-rendered.yaml; then
  die "dex 未成功禁用（渲染结果仍含 dexidp/dex 镜像）"
fi
log "渲染校验通过：argocd:${ARGOCD_VERSION}"

# ---------------- 6. 安装 / 升级（幂等）----------------
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if helm -n "$NAMESPACE" list 2>/dev/null | grep -q "^${RELEASE}"; then
  log "已安装 → helm upgrade"
  helm upgrade "$RELEASE" argo/argo-cd --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 600s
else
  log "helm install"
  helm install "$RELEASE" argo/argo-cd --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 600s
fi

# ---------------- 7. 等待就绪 ----------------
log "等待组件就绪（最长 300s）"
for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
  kubectl -n "$NAMESPACE" rollout status "deploy/${d}" --timeout=300s >/dev/null 2>&1 || log "警告: deploy/${d} 未在超时内就绪"
done
for s in argocd-application-controller argocd-redis; do
  kubectl -n "$NAMESPACE" rollout status "statefulset/${s}" --timeout=300s >/dev/null 2>&1 || log "警告: statefulset/${s} 未在超时内就绪"
done
kubectl -n "$NAMESPACE" get pods -o wide

# ---------------- 8. 验证 ----------------
log "验证服务"
sleep 5
HEALTH=$(curl -s -o /dev/null -w '%{http_code}' "http://${NODE_IP}:${NODEPORT_HTTP}/api/health" || echo 000)
[ "$HEALTH" = "200" ] || log "警告: /api/health 返回 ${HEALTH}（可能仍在启动）"
BODY=$(curl -s "http://${NODE_IP}:${NODEPORT_HTTP}/api/health" || true)
echo "$BODY" | grep -q '"status":"healthy"' || log "警告: health 未返回 healthy"

# ---------------- 9. 结果 ----------------
ADMIN_PASS=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<未生成>")
cat <<EOF

================ Argo CD 安装完成 ================
地址:   http://${NODE_IP}:${NODEPORT_HTTP}
账号:   admin
密码:   ${ADMIN_PASS}
版本:   ${ARGOCD_VERSION}（chart ${CHART_VERSION}）
values: ${VALUES_FILE}
CLI:    argocd login ${NODE_IP}:${NODEPORT_HTTP} --plaintext --username admin --password '${ADMIN_PASS}'
下一步: 按本文第 6 章接入 GitLab 仓库并创建 root Application
==================================================
EOF
```

### 0.3 脚本做了什么（步骤对应）

| 步骤 | 章节 | 说明 |
| --- | --- | --- |
| 1. 前置检查 | 第 2 章 | 工具/可达性/NodePort 占用（排除自身命名空间） |
| 2. 镜像源 | 第 4 章 | 检测并（经确认后）配置 `certs.d/quay.io` → `quay.m.daocloud.io` |
| 3. 版本解析 | 第 3.2 章 | 自动取最新稳定 chart 与 appVersion，拒绝 rc/beta |
| 4. 生成 values | 第 5.2 章 | NodePort + insecure + 关闭 dex/notifications |
| 5. 渲染校验 | 第 5.3 章 | 核对镜像 tag、StatefulSet、dex 已禁用，**先校验再安装** |
| 6. 安装/升级 | 第 5.3 章 | 幂等：已装走 `upgrade`，否则 `install` |
| 7. 等待就绪 | 第 5.4 章 | 5 个组件逐个 rollout |
| 8. 验证 | 第 6.6 节 | `/api/health` = healthy |
| 9. 结果 | 第 6.1 章 | 打印地址/账号/初始密码/CLI 登录命令 |

---

## 1. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `argocd` | 命名空间 |
| `RELEASE` | `argocd` | Helm release 名 |
| `CHART_VERSION` | 自动（仓库最新稳定） | Helm Chart 版本；建议显式固定 |
| `ARGOCD_VERSION` | 自动（chart 的 appVersion） | Argo CD 应用版本；**必须为稳定版**（非 rc/beta） |
| `NODE_IP` | 必填 | 集群节点 IP（NodePort 对外地址） |
| `NODEPORT_HTTP` | `30700` | server HTTP NodePort（`server.insecure=true` 时用这个访问 UI） |
| `NODEPORT_HTTPS` | `30701` | server HTTPS NodePort（当前留作后续上 TLS） |
| `KUBECONFIG` | `/root/.kube/config` | kubeconfig 路径 |
| `VALUES_FILE` | `/tmp/argocd-values.yaml` | 生成的 values 文件路径（勿提交仓库） |
| `MIRROR_QUAY` | `quay.m.daocloud.io` | `quay.io` 主镜像源（containerd `certs.d`） |
| `MIRROR_QUAY_BACKUP` | `quay.nju.edu.cn` | `quay.io` 备用镜像源 |
| `STORAGE_CLASS` | 不需要 | Argo CD 各组件无状态（redis 缓存不持久化），不依赖 PVC |

> **端口占用现状**：`30002/30003`（Harbor）、`30080`（GitLab）。`30700/30701` 为新增，执行前确认未被占用。

## 2. 前置检查（只读，不修改系统）

```bash
export KUBECONFIG=/root/.kube/config

# 1) 客户端工具
kubectl version --client --short 2>/dev/null || kubectl version --client
helm version --short

# 2) 集群可达
kubectl get nodes -o wide
kubectl get --raw='/readyz' | tail -1

# 3) 是否已安装 Argo CD（存在则走 5.3 的 upgrade 分支）
helm -n argocd list
kubectl -n argocd get pods

# 4) NodePort 占用（排除 argocd 自身）
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {range .spec.ports[*]}{.nodePort} {end}{"\n"}{end}' \
  | grep -E ' (30700|30701)$' | grep -v '^argocd ' || echo "30700/30701 空闲"

# 5) 镜像源连通性
curl -s -o /dev/null -w 'quay.m.daocloud.io: %{http_code}\n' --max-time 15 \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  https://quay.m.daocloud.io/v2/argoproj/argocd/manifests/v3.5.2
curl -s -o /dev/null -w 'argoproj.github.io: %{http_code}\n' --max-time 15 https://argoproj.github.io/argo-helm/index.yaml

# 6) 实际拉一个 Argo CD 镜像验证（走 containerd 镜像源；耗时约 20-60s）
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d quay.io/argoproj/argocd:v3.5.2
```

判定逻辑：

- `helm -n argocd list` 有记录 → 已安装，跳到 5.3 用 `helm upgrade` 更新，不要重复 `install`。
- `quay.io` 镜像拉取失败 → 按第 4 章配置/换源后重试；`argoproj.github.io` 不可达 → 按第 3.2 节用 `helm pull` 本地安装。
- 端口被占用 → 换 `NODEPORT_HTTP` / `NODEPORT_HTTPS`。

## 3. 架构与版本选型

### 3.1 组件构成（本部署形态，dex/notifications 关闭）

| 组件 | 作用 | 类型 | 镜像 |
| --- | --- | --- | --- |
| `argocd-server` | API + Web UI | Deployment | `quay.io/argoproj/argocd` |
| `argocd-repo-server` | Git/Helm/Kustomize 渲染 | Deployment | `quay.io/argoproj/argocd` |
| `argocd-application-controller` | 协调循环（比较期望/实际状态） | StatefulSet | `quay.io/argoproj/argocd` |
| `argocd-applicationset-controller` | ApplicationSet 控制器 | Deployment | `quay.io/argoproj/argocd` |
| `argocd-redis` | 缓存/状态（无持久化） | StatefulSet | `docker.io/library/redis` |
| `argocd-dex-server` | SSO（**默认关闭**） | Deployment | `ghcr.io/dexidp/dex` |
| `argocd-notifications-controller` | 通知（**默认关闭**） | Deployment | `quay.io/argoproj/argocd` |

> **与 GitLab CI 的职责边界**：GitLab CI 负责 build + push Harbor；Argo CD 只负责把 manifests 仓库的状态同步到集群。**同一批 K8s 资源不要同时用 `helm upgrade` 和 Argo CD 管理**（会互相覆盖），二选一。

### 3.2 版本选型（chart 与 app 版本不同步）

Helm 仓库 `https://argoproj.github.io/argo-helm` 的 chart 与 Argo CD app 版本**并非一一对应**。截至 2026-11-15 的核对结果：

| 想要的版本 | 做法 | 风险 |
| --- | --- | --- |
| **v3.5.x 最新补丁**（推荐） | 取仓库最新稳定 chart（`CHART_VERSION` 自动解析），`ARGOCD_VERSION` 取 chart 的 `appVersion` | 低 |
| 指定旧版本（如 v3.4.x） | 显式 `ARGOCD_VERSION` + 对应 chart，或渲染后覆盖镜像 tag | 中：需确认 chart 模板兼容 |
| v3.6.0（最新 GA 候选） | 当前仅 `rc4`，**不建议** | 高 |

> 交叉核对命令：
> ```bash
> helm search repo argo/argo-cd --versions | head -5
> curl -s https://api.github.com/repos/argoproj/argo-cd/releases?per_page=5
> ```
> **备选方案（helm 仓库不可达）**：浏览器/其它可达机器下载 chart tgz，`helm install argocd ./argo-cd-<ver>.tgz -n argocd -f argocd-values.yaml`。

### 3.3 为什么用 NodePort + HTTP（而不是 Ingress）

集群当前无 ingress-nginx、无 cert-manager，80/8080 已被占用（见 [kubernetes-gitlab.md](kubernetes-gitlab.md) 1.2）。Argo CD 的 UI/API 需要被人和 CLI 访问，**NodePort 是零新增依赖的暴露方式**，与 Harbor/GitLab 一致。安全边界：`server.insecure=true` 只应在内网 lab 使用；上生产前按第 7 章第 6 条接入 Ingress + TLS。

## 4. 镜像源最佳实践（containerd `certs.d`）

Argo CD 全部控制器镜像都在 `quay.io/argoproj/*`（dex 关闭后**不依赖 ghcr**）。**不要**改 chart 的镜像仓库地址，保持 `quay.io/...`，由 containerd 的 `certs.d` 做透明映射——与 Harbor 的 `docker.io` 方案一致，保留主/备回退且 chart 升级不受影响。

```bash
# 已配置则跳过（主备顺序按本机实测调整）
sudo mkdir -p /etc/containerd/certs.d/quay.io
cat <<'EOF' | sudo tee /etc/containerd/certs.d/quay.io/hosts.toml
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://quay.nju.edu.cn"]
  capabilities = ["pull", "resolve"]
EOF

# 新增/修改 certs.d 下的配置一般无需重启；若拉取仍失败再重启（会影响共用 containerd 的 Docker 容器）
sudo systemctl restart containerd
```

**选源方法（部署前必做）**：

```bash
for m in quay.m.daocloud.io quay.nju.edu.cn; do
  printf '%s: ' "$m"
  timeout 120 ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d \
    "$m/argoproj/argocd:v3.5.2" >/dev/null 2>&1 && echo OK || echo FAIL
done
```

> 详见 [linux-kubernetes.md](linux-kubernetes.md) 4.2。**坑**：`ctr -n k8s.io images pull` 默认**不读** CRI 的 `config_path`，验证时必须加 `--hosts-dir /etc/containerd/certs.d`。

## 5. 安装步骤（手动，备查）

### 5.1 添加 Helm 仓库

```bash
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || echo "repo exists"
helm repo update argo
helm search repo argo/argo-cd --versions | head -3
```

### 5.2 values 模板

保存为 `/root/argocd-deploy/argocd-values.yaml`（**勿提交仓库**；本仓库约定用 `.tmp-` 前缀）。参数含义见第 1 章。

```yaml
# Argo CD values —— 参数区见第 1 章
global:
  image:
    imagePullPolicy: IfNotPresent

server:
  replicas: 1
  insecure: true                    # NodePort + HTTP（lab）
  service:
    type: NodePort
    nodePortHttp: 30700
    nodePortHttps: 30701

controller:
  replicas: 1
repo:
  replicas: 1

dex:
  enabled: false                    # 暂不接 SSO（省 ghcr 镜像）
notifications:
  enabled: false
applicationSet:
  enabled: true

redis:
  enabled: true
  persistence:
    enabled: false
```

> **key 名以实际 chart 为准**：用 `helm show values argo/argo-cd --version <CHART_VERSION> | grep -n 'replicas\|nodePort' | head` 核对；不同 chart 版本可能用 `replicaCount`。若渲染出 redis PVC，改为 `redis.master.persistence.enabled: false`（bitnami 命名）。
> **不需要 nodeSelector**：Argo CD 无本地卷（redis 不持久化），Pod 漂移无副作用，这是它比 Harbor/GitLab 省心之处。

### 5.3 渲染校验并安装（幂等）

**先渲染校验，再安装**——提前发现镜像 tag 不匹配、dex 未禁用等问题：

```bash
helm template argocd argo/argo-cd --version "$CHART_VERSION" -n argocd -f argocd-values.yaml > /tmp/argocd-rendered.yaml
grep -oE 'image: [^ ]+' /tmp/argocd-rendered.yaml | sort -u      # 应含 argoproj/argocd:${ARGOCD_VERSION}
grep -c 'kind: StatefulSet' /tmp/argocd-rendered.yaml            # 应为 2（application-controller / redis）
grep -n 'dexidp/dex' /tmp/argocd-rendered.yaml                   # 应无输出

# 安装（或升级）
if helm -n argocd list | grep -q '^argocd'; then
  helm upgrade argocd argo/argo-cd --version "$CHART_VERSION" -n argocd -f argocd-values.yaml --timeout 600s
else
  helm install argocd argo/argo-cd --version "$CHART_VERSION" -n argocd --create-namespace -f argocd-values.yaml --timeout 600s
fi
```

### 5.4 等待就绪

```bash
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd get pods -o wide
```

## 6. 客户端配置与使用

### 6.1 访问 UI 与初始密码

```bash
NODE_IP=192.168.40.189; PORT=30700
# 初始管理员密码（首次登录后请立即修改）
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# 浏览器打开
echo "http://${NODE_IP}:${PORT}"
```

### 6.2 安装 argocd CLI 并登录

```bash
# Linux amd64（版本与 app 版本一致）
ARGOCD_VERSION=v3.5.2
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
chmod +x /tmp/argocd && sudo mv /tmp/argocd /usr/local/bin/argocd
argocd version --client

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login 192.168.40.189:30700 --plaintext --username admin --password "$PASS"
argocd cluster list          # 应看到 https://kubernetes.default.svc
argocd app list              # 应为空（尚未创建应用）
```

> `--plaintext` 对应 `server.insecure=true`。CLI 二进制也可在容器内执行：`kubectl -n argocd exec -it deploy/argocd-server -- argocd version`。

### 6.3 接入 GitLab 仓库（私有库凭据）

Argo CD 需要读取 GitLab 上的 manifests 仓库。**推荐声明式 Secret**（不把凭据写进 values）：

```bash
# 在 GitLab 建一个 Personal Access Token（scope: read_repository），或用项目机器人账号
GITLAB_TOKEN='<PAT>'
kubectl -n argocd create secret generic argocd-repo-creds \
  --from-literal=type=repository \
  --from-literal=url=http://192.168.40.189:30080 \
  --from-literal=username=argocd-bot \
  --from-literal=password="$GITLAB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret argocd-repo-creds argocd.argoproj.io/secret-type=repository --overwrite
```

> 该 Secret 的 label `argocd.argoproj.io/secret-type: repository` 会被 Argo CD 自动识别为**仓库凭据模板**，所有 `url` 前缀匹配的仓库共用。**凭据只存 Secret，不入 Git、不入 values**。

### 6.4 创建 root Application（app-of-apps）

10 个应用推荐 **app-of-apps** 结构：一个 root Application 指向 manifests 仓库的 `apps/` 目录，目录内每个应用一个子目录（内含该应用的 Kustomize/Helm 清单）。Argo CD 会为每个子目录自动生成一个 Application。

GitLab 仓库目录结构（示例仓库 `ops/k8s-apps`）：

```text
k8s-apps/
├── root.yaml                  # root Application（app-of-apps）
└── apps/
    ├── 01-redteam-ai/
    │   ├── kustomization.yaml  # 或 Chart.yaml + values
    │   └── *.yaml
    ├── 02-promptfoo/
    ├── 03-ollama/
    └── ...（共 10 个）
```

`root.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://192.168.40.189:30080/ops/k8s-apps.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

创建并同步：

```bash
kubectl -n argocd apply -f root.yaml     # root.yaml 先本地执行一次（bootstrap）
argocd app list                          # 应出现 root 及其子应用
argocd app sync root
argocd app list
```

> **bootstrap 说明**：root Application 本身不在 Git 里，需要手动 `kubectl apply` 一次；之后的一切变更都走 Git。也可以把 `root.yaml` 也放进 Git 仓库的 `bootstrap/` 目录，用 `argocd app create --upsert` 管理，但**不要**让 root 管理自己所在的目录（避免循环）。

### 6.5 与 GitLab CI 衔接（构建 → Harbor → Argo CD）

```text
开发者 push → GitLab CI: build → docker push Harbor → 更新 k8s-apps 中该应用的 image tag（git commit/push）
                                                        ↓
                              Argo CD 轮询 Git（默认 3 分钟）→ 检测到 OutOfSync → 自动 sync 到集群
```

CI 侧 `.gitlab-ci.yml` 片段（仅更新 manifest，不直接操作集群）：

```yaml
deploy:
  stage: deploy
  image: alpine/git
  script:
    - git clone http://argocd-bot:${GITLAB_TOKEN}@192.168.40.189:30080/ops/k8s-apps.git
    - cd k8s-apps
    - |
      if [ -f "apps/01-redteam-ai/kustomization.yaml" ]; then
        sed -i "s#image: 192.168.40.189:30003/redteam/ai:.*#image: 192.168.40.189:30003/redteam/ai:${CI_COMMIT_SHORT_SHA}#" \
          apps/01-redteam-ai/kustomization.yaml   # 或用 kustomize edit set image
      fi
    - git commit -am "chore(redteam-ai): bump image to ${CI_COMMIT_SHORT_SHA}"
    - git push origin main
  only: [main]
```

> **避免循环**：CI 只改 manifests，由 Argo CD 负责 sync；**不要**在 CI 里同时调 `argocd app sync` 又改 manifest（除非明确要"立即同步"）。若确需 CI 触发立即同步，可给 Argo CD 配 webhook（`argocd.notifications`/CI webhook token），并确保幂等。
> **镜像拉取凭据**：应用 Pod 从 Harbor 拉镜像需要 `imagePullSecrets`，建议在目标命名空间把凭据设为 ServiceAccount 默认（见 [kubernetes-harbor.md](kubernetes-harbor.md) 6.5）。

### 6.6 快速验证脚本（一键检查）

保存为 `argocd_verify.sh`，只读检查。退出码 `0` = 通过。

```bash
#!/bin/bash
# Argo CD 快速验证：Pod / API 健康 / 初始密码 / CLI 登录
# 用法: bash argocd_verify.sh
set -u
NODE_IP="${NODE_IP:-192.168.40.189}"
PORT="${PORT:-30700}"
NS="${NS:-argocd}"
PASS=0; FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

chk "全部 Pod Running/Completed" "test \$(kubectl -n $NS get pods --no-headers | grep -cE 'Running|Completed') -eq \$(kubectl -n $NS get pods --no-headers | wc -l)"
chk "API health healthy"       "curl -s http://${NODE_IP}:${PORT}/api/health | grep -q '\"status\":\"healthy\"'"
chk "初始密码 Secret 存在"     "test -n \"\$(kubectl -n $NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null)\""
chk "server Service 为 NodePort" "kubectl -n $NS get svc argocd-server -o jsonpath='{.spec.type}' | grep -q NodePort"
chk "root Application 存在"    "kubectl -n $NS get application root --no-headers | grep -q ."

echo "=== 结果: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

> 首次安装后 `root Application 存在` 一条预期为 FAIL（尚未创建），创建后应为 5/5 PASS。

## 7. 最佳实践与踩坑总结

> 换环境复用时**先通读本章**。

| # | 实践 | 原因 / 做法 |
| --- | --- | --- |
| 1 | **chart 与 app 版本交叉核对** | chart 与 app 不同步；用 `helm search repo` + GitHub Releases API 核对，只用稳定版（非 rc/beta） |
| 2 | **先渲染再安装** | `helm template` 后核对镜像 tag、StatefulSet 数量（2）、dex 已禁用 |
| 3 | **幂等安装** | `helm -n argocd list` 判断 install / upgrade |
| 4 | **镜像源用 containerd `certs.d` 透明映射** | 不改 chart 仓库地址，保留主/备回退；`quay.io` → `quay.m.daocloud.io` 为主、`quay.nju.edu.cn` 为备 |
| 5 | **`ctr` 验证镜像源要加 `--hosts-dir`** | 不加会直连上游误判 |
| 6 | **上生产前换 HTTPS** | `server.insecure=true` 仅 lab；生产用 Ingress + cert-manager（见 8.2） |
| 7 | **职责单一** | 同一批资源只由 Argo CD 或 `helm upgrade` 之一管理，不要并用 |
| 8 | **CI 改 manifest、Argo CD 做 sync** | 避免循环；CI 不直接 `kubectl`/`helm` 操作集群 |
| 9 | **root Application 加 finalizer** | `resources-finalizer.argocd.argoproj.io` 保证删除级联正确 |
| 10 | **`prune: true` 谨慎启用** | 首次建议先手动 sync 观察，确认无"误删手工资源"后再开自动 prune |
| 11 | **凭据只进 Secret** | 仓库 PAT、Harbor 拉取凭据都放 K8s Secret / GitLab CI Variables，不入 Git、不入 values |
| 12 | **Redis 不持久化** | 缓存丢了可重建；避免无谓的 PVC 与 local-path 节点绑定 |
| 13 | **dex/notifications 按需开启** | 默认关闭可省 2 个组件；上 SSO 时再开 dex（需 ghcr 镜像与 OIDC 配置） |
| 14 | **升级前备份 Application 定义** | `kubectl -n argocd get applications -o yaml > backup.yaml`；manifests 仓库本身即事实来源 |

## 8. 排障

### 8.1 Pod 一直 Pending / ImagePullBackOff

```bash
kubectl -n argocd describe pod <pod>        # 看 Events 真实拉取地址与错误
```

- `quay.io` 超时 → 检查 `/etc/containerd/certs.d/quay.io/hosts.toml` 主备顺序，按第 4 章选源方法重测；必要时 `sudo systemctl restart containerd`（影响 Docker 业务容器，先确认）。
- `manifest unknown / not found` → 确认 `${ARGOCD_VERSION}` 镜像真实存在（第 2 章第 6 步）。

### 8.2 UI 打不开 / 登录页异常

- `server.insecure=true` 时**必须用 `http://` 访问**（用 https 会握手失败）；访问地址为 `http://<NODE_IP>:30700`。
- CLI 报 TLS 错误 → 加 `--plaintext`。
- 端口不通 → 确认 NodePort 未被占用、防火墙放行（`ss -ltnp | grep 30700`）。

### 8.3 应用一直 OutOfSync / SyncFailed

```bash
argocd app get <app>
argocd app events <app>
kubectl -n argocd logs deploy/argocd-repo-server --tail=50
```

- `repo server` 报认证失败 → 检查 6.3 的 Secret 与 label（`argocd.argoproj.io/secret-type: repository`）。
- GitLab 私有仓库 → 确认 PAT scope 含 `read_repository`，`url` 前缀与 `repoURL` 完全一致（含 `http://` 与端口）。
- Helm chart 拉取失败 → chart 仓库（如 Harbor）需单独配凭据。

### 8.4  drift / 自愈不生效

确认 Application 的 `syncPolicy.automated.selfHeal: true`；手工 `kubectl edit` 改过的资源若不在 Git 声明中，`selfHeal` 会把它改回 Git 状态——**这是特性不是故障**，但开启前确认 Git 里的声明是完整的。

### 8.5 升级 Argo CD 版本

```bash
# 1) 备份 Application 定义
kubectl -n argocd get applications -o yaml > /root/argocd-deploy/applications-backup.yaml
# 2) 交叉核对目标 chart/app 版本（第 3.2 节）
# 3) helm upgrade（脚本可直接重跑：CHART_VERSION=... ARGOCD_VERSION=... bash kubernetes-argocd-install.sh）
# 4) 重跑第 6.6 节验证脚本
```

> 跨小版本升级前阅读官方 upgrading 文档（2→3 有破坏性变更的先例，如弃用参数、CRD 版本）。

## 9. Agent 执行注意事项

- **先检查再执行**：第 2 章全只读；`helm -n argocd list` 有记录就走 `upgrade`，不要重复 `install`。
- **参数先确认**：执行前向用户确认第 1 章参数（尤其 `NODE_IP`、`CHART_VERSION`、`ARGOCD_VERSION`、端口）。
- **优先用一键脚本**：`kubernetes-argocd-install.sh` 已封装检查/镜像源/校验/安装/验证全流程；手动分步用于排障。
- **危险操作必须确认**：`systemctl restart containerd`（影响 Docker 业务容器）、`helm uninstall`、删除 namespace，逐项征求同意。
- **版本红线**：拒绝安装 `rc`/`beta` 版本（脚本已内置拦截）；升级前先备份 Application 定义。
- **凭据管理**：初始 admin 密码、GitLab PAT、Harbor 凭据只存 Secret / CI Variables，**不写入仓库、values、Issue、日志**。
- **失败即停**：拉取失败先看 Events 真实地址，不盲目重试。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 10. 卸载（可选，破坏性，需用户确认）

```bash
# 1) 先导出所有 Application 定义（备份）
kubectl -n argocd get applications -o yaml > /root/argocd-deploy/applications-backup.yaml

# 2) 卸载 release（Argo CD 管理的业务应用不会被自动删除——它们不在本 release 内）
helm -n argocd uninstall argocd

# 3) 删除残留资源与命名空间
kubectl -n argocd delete pvc --all --ignore-not-found
kubectl -n argocd delete secret argocd-repo-creds --ignore-not-found
kubectl delete ns argocd
```

> Argo CD 卸载**不会**删除它部署的业务应用（Application 的 `destination` 资源独立存在）；如需一并清理，先 `kubectl -n argocd get applications -o jsonpath=...` 逐个 `kubectl delete`，谨慎操作。

## 11. 复用 checklist 与已知遗留

**换环境复用清单（逐项确认）**

- [ ] 集群已就绪（kubectl/helm 可用、节点 Ready）。
- [ ] `NODE_IP` = 对外可访问的节点 IP；`NODEPORT_HTTP/HTTPS` 未被占用。
- [ ] containerd `certs.d/quay.io` 已配并**按本机实测**定主备顺序。
- [ ] 版本：`CHART_VERSION` 与 `ARGOCD_VERSION` 已交叉核对，且为稳定版。
- [ ] `helm repo add argo` 可达（或已下载 chart tgz）。
- [ ] 渲染校验通过（镜像 tag / StatefulSet 数量 / dex 禁用）。
- [ ] 安装后跑 `argocd_verify.sh`。
- [ ] GitLab 仓库凭据 Secret 已建并打 label；root Application 已 bootstrap。
- [ ] CI 侧只更新 manifests（第 6.5 节），未与 Argo CD 并管同一批资源。

**已知遗留**

- 本部署为 **HTTP 明文**（`server.insecure=true`），仅适用内网 lab；上生产前必须换 Ingress + TLS（第 7 章第 6 条）。
- **未接 SSO**：仅 admin 本地账号；多人使用需开 dex + GitLab OAuth（第 7 章第 13 条）。
- **未配监控/告警**：Argo CD 暴露 `:8082`/`:8083` 指标，需要时接 Prometheus。
- **Redis 无持久化**：重启后缓存重建，属预期。
- **首次执行结果待补**：第 6.6 节脚本首次运行应为 4/5 PASS（`root Application` 未创建），创建 root 后 5/5。

---

## 附录 A：当前部署的目录与文件

目标节点：`192.168.40.189`

```text
/root/argocd-deploy/
├── argocd-values.yaml            # Helm values（勿提交）
└── applications-backup.yaml      # 升级前备份（按需生成）
```

> 敏感信息仅用于本次部署与后续维护，不应放入 Git 仓库。

## 附录 B：root Application 与子应用示例

子应用（`apps/01-redteam-ai/kustomization.yaml` 示例，纯静态清单时可直接放 Deployment YAML）：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redteam-ai
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://192.168.40.189:30080/<group>/<app-source>.git   # 或指向 k8s-apps 内的子目录
    targetRevision: main
    path: deploy/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: redteam-ai
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

> 若 10 个应用放在同一个 `k8s-apps` 仓库的 `apps/<name>/` 目录，则**不需要**逐个写 Application——root 的 `path: apps` 会自动发现（app-of-apps）。附录 B 的写法适用于"每个应用独立仓库"的场景。
