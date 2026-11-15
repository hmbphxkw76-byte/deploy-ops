# Argo CD on Kubernetes 部署手册（GitOps CD · 已实测）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在 **Kubernetes 集群** 上以 **Helm Chart** 部署 **Argo CD**（声明式 GitOps 持续交付平台），并优先使用**国内镜像源**。文档与 [kubernetes-harbor.md](kubernetes-harbor.md) / [kubernetes-gitlab.md](kubernetes-gitlab.md) 同格式：**参数区 → 前置检查 → 幂等执行 → 验证 → 排障 → Agent 注意事项**。

**为什么选 Argo CD（本仓库的决策）**：应用规模约 10 个，需要**漂移检测/自愈、版本树回滚、部署审计与可视化**，且 GitLab CI 已承担构建（CI）——按职责拆分，构建归 GitLab CI，部署归 Argo CD。若只有 1–3 个应用，直接用 GitLab CI `helm upgrade` 更省事（见 [README.md](README.md) 的组合工作流示例）。

**部署形态**：Helm（官方 chart `argo/argo-cd`），命名空间 `argocd`，release 名 `argocd`；暴露方式 **NodePort**（集群当前无 ingress-nginx，与 Harbor/GitLab 的"节点 IP + 端口"形态一致）；**server 以 HTTP 明文提供服务**（`configs.params.server.insecure=true`，lab 环境；上生产前应换 Ingress + cert-manager + HTTPS）；Dex/Notifications 默认关闭以减少组件与镜像依赖；Redis 用 chart 内置单节点（`redis-ha` 子 chart 关闭）。

**实测基线（2026-11-15，于 `192.168.40.189`）**：

| 项 | 值 |
| --- | --- |
| chart | `argo-cd-10.18.0`（GitHub Releases tgz） |
| app | **v3.6.1**（BuildDate 2026-11-04） |
| 集群 | v1.37.2，控制面 `ubuntu` 192.168.40.189 + 工作节点 `ubunt-dev` 192.168.40.183 |
| 访问 | `http://192.168.40.189:30700`（NodePort 30700 / HTTPS 30701） |
| 组件 | 5 个 Pod 全 Running（server / repo-server / application-controller / applicationset-controller / redis） |
| 仓库接入 | GitLab `ops/k8s-apps`（bot `argocd-bot` + PAT，`configs.repositories` 声明式登记） |
| GitOps 闭环 | ApplicationSet 生成子应用 → 自动 sync（实测 ≤120s）→ 漂移自愈（ replicas 3→1、被删 ConfigMap 重建） |

> 前置依赖：集群已按 [linux-kubernetes.md](linux-kubernetes.md) 部署（含 containerd 镜像源、local-path）；镜像仓库为 [kubernetes-harbor.md](kubernetes-harbor.md)；代码仓库为 [kubernetes-gitlab.md](kubernetes-gitlab.md)。

---

## 0. 快速安装（一键脚本）

### 0.1 用法

```bash
# 把 kubernetes-argocd-install.sh 放到集群可执行节点（如 control-plane），然后：
NODE_IP=192.168.40.189 bash kubernetes-argocd-install.sh
```

`argoproj.github.io` 在本环境**不稳定**（时通时断），脚本内置自动降级：`helm repo update` 失败会自动切到 `CHART_SOURCE=release`（GitHub Releases 下载 chart tgz）。也可显式指定：

```bash
CHART_SOURCE=release CHART_VERSION=10.18.0 ARGOCD_VERSION=v3.6.1 \
GITLAB_REPO_URL=http://192.168.40.189:30080/ops/k8s-apps.git \
GITLAB_REPO_USER=argocd-bot GITLAB_REPO_PASS='<PAT>' \
bash kubernetes-argocd-install.sh
```

- `NODE_IP` 必填（无默认值）；其余均有默认值，见第 1 章参数区。
- `CHART_SOURCE=release` 时 `CHART_VERSION` 必填；`repo` 模式下 `CHART_VERSION` / `ARGOCD_VERSION` 留空则自动解析（取最新稳定 chart 及其 appVersion）。
- 设置了 `GITLAB_REPO_URL/USER/PASS` 会把仓库凭据**声明式**写进 `configs.repositories`（推荐，见 6.3）。
- **幂等**：已安装则自动走 `helm upgrade`，可重复执行。

### 0.2 脚本（kubernetes-argocd-install.sh）

```bash
#!/bin/bash
# Argo CD on Kubernetes 一键安装（NodePort + HTTP + 国内镜像源）
#
# 用法:
#   NODE_IP=192.168.40.189 bash kubernetes-argocd-install.sh
#   CHART_SOURCE=release CHART_VERSION=10.18.0 ARGOCD_VERSION=v3.6.1 bash kubernetes-argocd-install.sh
#
# 两种取 chart 方式:
#   CHART_SOURCE=repo     helm 仓库（默认；argoproj.github.io 若不达会自动切 release）
#   CHART_SOURCE=release  GitHub Releases 的 chart tgz（argoproj.github.io 不可达时用）
#
# 幂等: 已安装走 helm upgrade。脚本末尾打印访问地址 / 账号 / 初始密码 / 验证命令。
# 退出码: 0=成功, 1=失败
set -euo pipefail

# ---------------- 参数（环境变量覆盖）----------------
NAMESPACE="${NAMESPACE:-argocd}"
RELEASE="${RELEASE:-argocd}"
CHART_SOURCE="${CHART_SOURCE:-repo}"          # repo | release
CHART_VERSION="${CHART_VERSION:-}"            # 留空 = 取最新稳定 chart
ARGOCD_VERSION="${ARGOCD_VERSION:-}"          # 留空 = 取 chart 的 appVersion
CHART_DIR="${CHART_DIR:-/root/argocd-deploy}" # release 模式的下载/解压目录
NODE_IP="${NODE_IP:?need NODE_IP, e.g. 192.168.40.189}"
NODEPORT_HTTP="${NODEPORT_HTTP:-30700}"
NODEPORT_HTTPS="${NODEPORT_HTTPS:-30701}"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
VALUES_FILE="${VALUES_FILE:-/tmp/argocd-values.yaml}"
REDIS_IMAGE_REPO="${REDIS_IMAGE_REPO:-docker.m.daocloud.io/library/redis}"
REDIS_IMAGE_TAG="${REDIS_IMAGE_TAG:-8.6.4-alpine}"
# 可选：声明式登记 Git 仓库凭据（推荐，见手册 6.3；留空则不写）
GITLAB_REPO_URL="${GITLAB_REPO_URL:-}"
GITLAB_REPO_USER="${GITLAB_REPO_USER:-}"
GITLAB_REPO_PASS="${GITLAB_REPO_PASS:-}"
export KUBECONFIG

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------- 1. 前置检查（只读）----------------
log "前置检查"
command -v kubectl >/dev/null 2>&1 || die "kubectl 未安装"
command -v helm    >/dev/null 2>&1 || die "helm 未安装"
kubectl get --raw='/readyz' >/dev/null 2>&1 || die "apiserver 不可达（检查 KUBECONFIG）"

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
# 新增/修改 certs.d 一般无需重启；若拉取仍失败再重启（会影响共用 containerd 的 Docker 容器）：
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

# ---------------- 3. 获取 chart 与版本 ----------------
CHART_REF=""
if [ "$CHART_SOURCE" = "release" ]; then
  [ -n "$CHART_VERSION" ] || die "CHART_SOURCE=release 需要显式 CHART_VERSION（如 10.18.0）"
  mkdir -p "$CHART_DIR"
  TGZ="$CHART_DIR/argo-cd-${CHART_VERSION}.tgz"
  URL="https://github.com/argoproj/argo-helm/releases/download/argo-cd-${CHART_VERSION}/argo-cd-${CHART_VERSION}.tgz"
  if [ ! -s "$TGZ" ]; then
    log "下载 chart（GitHub Releases）: $URL"
    curl -sL --max-time 240 -o "$TGZ" "$URL" \
      || curl -sL --max-time 240 -o "$TGZ" "https://ghfast.top/$URL" \
      || die "chart 下载失败（可手动放入 $TGZ）"
  fi
  rm -rf "$CHART_DIR/argo-cd"
  tar xzf "$TGZ" -C "$CHART_DIR"
  if [ ! -d "$CHART_DIR/argo-cd/charts/redis-ha" ]; then
    log "拉取子 chart（redis-ha，默认关闭但 Chart.yaml 声明了依赖）"
    ( cd "$CHART_DIR" && helm dependency update ./argo-cd ) \
      || die "helm dependency update 失败（redis-ha 仓库 dandydeveloper.github.io 不可达，见手册 3.2）"
  fi
  CHART_REF="$CHART_DIR/argo-cd"
  [ -z "$ARGOCD_VERSION" ] && ARGOCD_VERSION=$(sed -n 's/^appVersion:[[:space:]]*//p' "$CHART_REF/Chart.yaml" | tr -d '"')
else
  log "添加 helm 仓库"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  if ! helm repo update argo >/dev/null 2>&1; then
    log "argoproj.github.io 不可达 → 自动切换 CHART_SOURCE=release"
    CHART_SOURCE=release
    exec bash "$0" "$@"
  fi
  if [ -z "$CHART_VERSION" ]; then
    CHART_VERSION=$(helm search repo argo/argo-cd --versions | awk 'NR>1 && $2 !~ /-/ {print $2; exit}')
    [ -n "$CHART_VERSION" ] || die "无法解析 chart 版本"
    log "自动选择最新稳定 chart: $CHART_VERSION"
  fi
  [ -z "$ARGOCD_VERSION" ] && ARGOCD_VERSION=$(helm show chart argo/argo-cd --version "$CHART_VERSION" | sed -n 's/^appVersion:[[:space:]]*//p' | tr -d '"')
  CHART_REF="argo/argo-cd --version $CHART_VERSION"
fi
[ -n "$ARGOCD_VERSION" ] || die "无法解析 appVersion"

echo "将安装: chart ${CHART_VERSION} / app ${ARGOCD_VERSION}（来源: ${CHART_SOURCE}）"
case "$ARGOCD_VERSION" in
  *-rc*|*-beta*) die "ARGOCD_VERSION 是预发布版本（$ARGOCD_VERSION），生产环境请用稳定版" ;;
esac

# ---------------- 4. 生成 values ----------------
log "生成 values: $VALUES_FILE"
{
cat <<EOF
# 由 kubernetes-argocd-install.sh 生成（含访问配置与仓库凭据，勿提交仓库）
global:
  image:
    imagePullPolicy: IfNotPresent

server:
  replicas: 1
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
  image:
    repository: ${REDIS_IMAGE_REPO}   # chart 默认 ecr-public.aws.com，国内建议改 docker.m.daocloud.io
    tag: ${REDIS_IMAGE_TAG}
redis-ha:
  enabled: false                 # chart 默认即 false；显式声明，避免误开 HA 子 chart

configs:
  params:
    server.insecure: true        # 注意：v10 chart 用 configs.params，不是 server.insecure
EOF
if [ -n "$GITLAB_REPO_URL" ]; then
cat <<EOF
  repositories:
    lan-gitlab-k8s-apps:
      url: ${GITLAB_REPO_URL}
      name: lan-gitlab-k8s-apps
      type: git
      username: ${GITLAB_REPO_USER}
      password: ${GITLAB_REPO_PASS}
EOF
fi
} > "$VALUES_FILE"

# ---------------- 5. 渲染校验（先校验再安装）----------------
log "渲染校验（helm template）"
helm template "$RELEASE" $CHART_REF -n "$NAMESPACE" -f "$VALUES_FILE" > /tmp/argocd-rendered.yaml \
  || die "helm template 渲染失败"
grep -q "image: quay.io/argoproj/argocd:${ARGOCD_VERSION}" /tmp/argocd-rendered.yaml \
  || die "渲染出的 argocd 镜像 tag 不是 ${ARGOCD_VERSION}（chart 与 app 版本不匹配，见第 3.2 节）"
grep -q 'kind: StatefulSet' /tmp/argocd-rendered.yaml \
  || die "渲染结果缺少 StatefulSet（application-controller）"
grep -q 'server.insecure: "true"' /tmp/argocd-rendered.yaml \
  || die "渲染结果未启用 server.insecure（检查 configs.params 写法）"
if grep -q 'dexidp/dex' /tmp/argocd-rendered.yaml; then
  die "dex 未成功禁用（渲染结果仍含 dexidp/dex 镜像）"
fi
log "渲染校验通过：argocd:${ARGOCD_VERSION}"

# ---------------- 6. 安装 / 升级（幂等）----------------
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if helm -n "$NAMESPACE" list 2>/dev/null | grep -q "^${RELEASE}"; then
  log "已安装 → helm upgrade"
  helm upgrade "$RELEASE" $CHART_REF -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 600s
else
  log "helm install"
  helm install "$RELEASE" $CHART_REF -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 600s
fi

# ---------------- 7. 等待就绪 ----------------
log "等待组件就绪（最长 300s）"
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis; do
  kubectl -n "$NAMESPACE" rollout status "deploy/${d}" --timeout=300s >/dev/null 2>&1 || log "警告: deploy/${d} 未在超时内就绪"
done
kubectl -n "$NAMESPACE" rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null 2>&1 \
  || log "警告: statefulset/argocd-application-controller 未在超时内就绪"
kubectl -n "$NAMESPACE" get pods -o wide

# ---------------- 8. 验证 ----------------
log "验证服务"
sleep 5
# 注意：Argo CD 3.x 的健康检查端点是 /healthz（/api/health 已 404）
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${NODE_IP}:${NODEPORT_HTTP}/healthz" || echo 000)
[ "$CODE" = "200" ] || log "警告: /healthz 返回 ${CODE}（可能仍在启动）"
BODY=$(curl -s "http://${NODE_IP}:${NODEPORT_HTTP}/healthz" || true)
echo "healthz: ${BODY}"
# 实测 3.x 的 /healthz 返回 200 + 正文 ok（不是 {"status":"healthy"}）
echo "$BODY" | grep -q '^ok$' || log "警告: healthz 未返回 ok"

# ---------------- 9. 结果 ----------------
ADMIN_PASS=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "<未生成>")
cat <<EOF

================ Argo CD 安装完成 ================
地址:   http://${NODE_IP}:${NODEPORT_HTTP}        # 注意用 http（server.insecure=true）
账号:   admin
密码:   ${ADMIN_PASS}
版本:   ${ARGOCD_VERSION}（chart ${CHART_VERSION}，来源 ${CHART_SOURCE}）
values: ${VALUES_FILE}
CLI:    argocd login ${NODE_IP}:${NODEPORT_HTTP} --plaintext --username admin --password '${ADMIN_PASS}'
CLI 二进制（GitHub Releases，建议走国内代理）:
  curl -sL -o argocd https://ghfast.top/https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
  chmod +x argocd && ./argocd version --client   # 必须能打印版本，否则是截断文件
下一步: 按手册第 6 章登记 Git 仓库凭据并创建 root Application / ApplicationSet
==================================================
EOF
```

> 上文的脚本块即仓库根 `kubernetes-argocd-install.sh`（两者保持逐字一致）。

### 0.3 脚本做了什么（步骤对应）

| 步骤 | 章节 | 说明 |
| --- | --- | --- |
| 1. 前置检查 | 第 2 章 | 工具/可达性/NodePort 占用（排除自身命名空间） |
| 2. 镜像源 | 第 4 章 | 检测并（经确认后）配置 `certs.d/quay.io` → `quay.m.daocloud.io` |
| 3. 获取 chart | 第 3.2 章 | `repo`（自动解析版本）或 `release`（GitHub tgz + `helm dependency update`），失败自动降级 |
| 4. 生成 values | 第 5.2 章 | NodePort + `configs.params.server.insecure` + redis 镜像改国内源 + 可选 `configs.repositories` |
| 5. 渲染校验 | 第 5.3 章 | 核对镜像 tag / StatefulSet / insecure / dex 禁用，**先校验再安装** |
| 6. 安装/升级 | 第 5.3 章 | 幂等：已装走 `upgrade`，否则 `install` |
| 7. 等待就绪 | 第 5.4 章 | 4 个 Deployment + 1 个 StatefulSet 逐个 rollout |
| 8. 验证 | 第 6.6 节 | `/healthz` = healthy（**不是** `/api/health`） |
| 9. 结果 | 第 6.1 节 | 打印地址/账号/初始密码/CLI 登录与下载命令 |

### 0.4 实测安装记录（2026-11-15）

```text
命令:  cd /root/argocd-deploy && helm install argocd ./argo-cd -n argocd --create-namespace -f argocd-values.yaml --timeout 600s
chart:  argo-cd-10.18.0（GitHub Releases tgz，helm dependency update 拉取 redis-ha 4.38.0）
app:    v3.6.1
镜像:   quay.io/argoproj/argocd:v3.6.1（quay.m.daocloud.io 映射，首拉约 89s/201MB）
        docker.m.daocloud.io/library/redis:8.6.4-alpine（覆盖 chart 默认 ecr-public）
结果:   5/5 Pod Running；http://192.168.40.189:30700/healthz → 200 ok
```

> **注意**：Pod 被调度到哪个节点，该节点就要能拉到镜像。实测 repo-server 重启后落到控制面 `ubuntu`，首次拉 `argocd` 镜像耗时 **3m56s**（init container）——国内镜像源可用但大镜像首拉慢，`--timeout` 要给足（脚本用 300s rollout，必要时调大）。

---

## 1. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `argocd` | 命名空间 |
| `RELEASE` | `argocd` | Helm release 名 |
| `CHART_SOURCE` | `repo` | `repo`=helm 仓库；`release`=GitHub Releases tgz（仓库不达时自动降级） |
| `CHART_VERSION` | 自动（repo 模式）/ 必填（release 模式） | Helm Chart 版本，实测 `10.18.0` |
| `ARGOCD_VERSION` | 自动（chart 的 appVersion） | Argo CD 应用版本，实测 `v3.6.1`；**必须为稳定版**（非 rc/beta） |
| `CHART_DIR` | `/root/argocd-deploy` | release 模式的下载/解压目录 |
| `NODE_IP` | 必填 | 集群节点 IP（NodePort 对外地址） |
| `NODEPORT_HTTP` | `30700` | server HTTP NodePort（`server.insecure=true` 时用这个访问 UI） |
| `NODEPORT_HTTPS` | `30701` | server HTTPS NodePort（当前留作后续上 TLS） |
| `KUBECONFIG` | `/root/.kube/config` | kubeconfig 路径 |
| `VALUES_FILE` | `/tmp/argocd-values.yaml` | 生成的 values 文件路径（**勿提交仓库**，含仓库凭据） |
| `REDIS_IMAGE_REPO` | `docker.m.daocloud.io/library/redis` | redis 镜像仓库（chart 默认 `ecr-public.aws.com/docker/library/redis`） |
| `REDIS_IMAGE_TAG` | `8.6.4-alpine` | redis 镜像 tag（须与 chart 默认版本兼容） |
| `GITLAB_REPO_URL` / `GITLAB_REPO_USER` / `GITLAB_REPO_PASS` | 空 | 可选：声明式登记 Git 仓库凭据（见 6.3） |
| `MIRROR_QUAY` | `quay.m.daocloud.io` | `quay.io` 主镜像源（containerd `certs.d`） |
| `MIRROR_QUAY_BACKUP` | `quay.nju.edu.cn` | `quay.io` 备用镜像源 |
| `STORAGE_CLASS` | 不需要 | Argo CD 无状态（redis 不持久化），不依赖 PVC |

> **端口占用现状**：`30002/30003`（Harbor）、`30080`（GitLab，hostPort）。`30700/30701` 为新增，执行前确认未被占用。

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

# 5) 上游连通性（决定 CHART_SOURCE 与 CLI 下载方式）
curl -s -o /dev/null -w 'argoproj.github.io: %{http_code}\n' --max-time 15 https://argoproj.github.io/argo-helm/index.yaml
curl -s -o /dev/null -w 'github.com:         %{http_code}\n' --max-time 15 https://github.com
curl -s -o /dev/null -w 'ghfast.top:         %{http_code}\n' --max-time 15 https://ghfast.top
curl -s -o /dev/null -w 'quay.m.daocloud.io:  %{http_code}\n' --max-time 15 https://quay.m.daocloud.io/v2/
curl -s -o /dev/null -w 'dandydeveloper:     %{http_code}\n' --max-time 15 https://dandydeveloper.github.io/charts/

# 6) 实际拉一个 Argo CD 镜像验证（走 containerd 镜像源；首拉约 1–4 分钟）
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d quay.io/argoproj/argocd:v3.6.1
```

判定逻辑：

- `helm -n argocd list` 有记录 → 已安装，跳到 5.3 用 `helm upgrade` 更新，不要重复 `install`。
- `argoproj.github.io` 不可达 → 用 `CHART_SOURCE=release`（GitHub Releases tgz）；GitHub 也不可达时用 `https://ghfast.top/<原 URL>` 代理。
- `quay.io` 镜像拉取失败 → 按第 4 章配置/换源后重试。
- 端口被占用 → 换 `NODEPORT_HTTP` / `NODEPORT_HTTPS`。

## 3. 架构与版本选型

### 3.1 组件构成（本部署形态，dex/notifications/redis-ha 关闭）

| 组件 | 作用 | 类型 | 镜像 |
| --- | --- | --- | --- |
| `argocd-server` | API + Web UI | Deployment | `quay.io/argoproj/argocd` |
| `argocd-repo-server` | Git/Helm/Kustomize 渲染 | Deployment | `quay.io/argoproj/argocd` |
| `argocd-application-controller` | 协调循环（比较期望/实际状态） | **StatefulSet** | `quay.io/argoproj/argocd` |
| `argocd-applicationset-controller` | ApplicationSet 控制器 | Deployment | `quay.io/argoproj/argocd` |
| `argocd-redis` | 缓存/状态（无持久化） | **Deployment**（v10 chart 起不再是 StatefulSet） | 默认 `ecr-public.aws.com/docker/library/redis`，已改 `docker.m.daocloud.io/library/redis` |
| `argocd-dex-server` | SSO（**默认关闭**） | Deployment | `ghcr.io/dexidp/dex` |
| `argocd-notifications-controller` | 通知（**默认关闭**） | Deployment | `quay.io/argoproj/argocd` |
| `redis-ha`（子 chart） | Redis HA（**默认关闭**） | —— | `ecr-public.aws.com/docker/library/redis` |

> **渲染校验基准**：`kind: StatefulSet` = **1**（application-controller）、`kind: Deployment` = **4**、`kind: PersistentVolumeClaim` = **0**。
> **与 GitLab CI 的职责边界**：GitLab CI 负责 build + push Harbor；Argo CD 只负责把 manifests 仓库的状态同步到集群。**同一批 K8s 资源不要同时用 `helm upgrade` 和 Argo CD 管理**（会互相覆盖），二选一。

### 3.2 版本选型（chart 与 app 版本不同步）

Helm 仓库 `https://argoproj.github.io/argo-helm` 的 chart 与 Argo CD app 版本**并非一一对应**，且该域名在国内**不稳定**。截至 2026-11-15 实测：

| 想要的版本 | 做法 | 风险 |
| --- | --- | --- |
| **chart 10.18.0 / app v3.6.1**（已实测，推荐） | `CHART_SOURCE=release` + `CHART_VERSION=10.18.0` | 低 |
| 仓库最新稳定 | `CHART_SOURCE=repo`，`CHART_VERSION` 自动解析 | 中：依赖 `argoproj.github.io` 可达 |
| 指定旧版本 | 显式 `ARGOCD_VERSION` + 对应 chart | 中：需确认 chart 模板兼容 |

> **取 chart 的三种途径**（按优先级）：
> 1. `helm repo add argo https://argoproj.github.io/argo-helm`（可达时最省事）；
> 2. GitHub Releases tgz：`https://github.com/argoproj/argo-helm/releases/download/argo-cd-<ver>/argo-cd-<ver>.tgz`（**不依赖 GitHub Pages**，实测稳定）；
> 3. 上述地址加国内代理前缀 `https://ghfast.top/`。
>
> **子 chart 依赖**：`Chart.yaml` 声明了 `redis-ha`（repository `https://dandydeveloper.github.io/charts/`）。即使 `redis-ha.enabled=false`，`helm install` 仍要求依赖存在，需先 `helm dependency update ./argo-cd`（脚本已自动处理；该域名实测 200 可达）。
>
> 交叉核对命令：
> ```bash
> helm search repo argo/argo-cd --versions | head -5
> curl -s https://api.github.com/repos/argoproj/argo-cd/releases?per_page=5
> ```

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
  timeout 180 ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d \
    "$m/argoproj/argocd:v3.6.1" >/dev/null 2>&1 && echo OK || echo FAIL
done
```

> 详见 [linux-kubernetes.md](linux-kubernetes.md) 4.2。**坑**：`ctr -n k8s.io images pull` 默认**不读** CRI 的 `config_path`，验证时必须加 `--hosts-dir /etc/containerd/certs.d`。

**其他镜像源注意**：

- **redis**：chart 默认 `ecr-public.aws.com/docker/library/redis`（AWS ECR Public，国内慢/不稳），实测改为 `docker.m.daocloud.io/library/redis:8.6.4-alpine`（OK）。
- **大文件下载校验**：GitHub Releases 上的 `argocd` CLI（约 266MB）直连易被截断，截断文件会 **segfault**（`too large section header offset`）。下载后**必须** `./argocd version --client` 自检；推荐走 `https://ghfast.top/` 代理。

## 5. 安装步骤（手动，备查）

### 5.1 获取 chart

```bash
# 方式一：helm 仓库（可达时）
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || echo "repo exists"
helm repo update argo

# 方式二：GitHub Releases tgz（推荐，实测稳定）
mkdir -p /root/argocd-deploy && cd /root/argocd-deploy
V=10.18.0
curl -sL --max-time 240 -o argo-cd-$V.tgz \
  https://github.com/argoproj/argo-helm/releases/download/argo-cd-$V/argo-cd-$V.tgz \
  || curl -sL --max-time 240 -o argo-cd-$V.tgz \
     https://ghfast.top/https://github.com/argoproj/argo-helm/releases/download/argo-cd-$V/argo-cd-$V.tgz
tar xzf argo-cd-$V.tgz
helm dependency update ./argo-cd      # 拉取 redis-ha 子 chart
grep -E '^(appVersion|version):' argo-cd/Chart.yaml
```

### 5.2 values 模板

保存为 `/root/argocd-deploy/argocd-values.yaml`（**勿提交仓库**，含仓库凭据）。参数含义见第 1 章。

```yaml
# Argo CD values —— 参数区见第 1 章（2026-11-15 实测）
global:
  image:
    imagePullPolicy: IfNotPresent

server:
  replicas: 1
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
  image:
    repository: docker.m.daocloud.io/library/redis   # chart 默认 ecr-public.aws.com，国内慢
    tag: 8.6.4-alpine
redis-ha:
  enabled: false                    # chart 默认即 false，显式声明

configs:
  params:
    server.insecure: true           # ⚠️ v10 chart：不是 server.insecure
  repositories:                     # 可选：声明式登记 Git 仓库凭据（见 6.3）
    lan-gitlab-k8s-apps:
      url: http://192.168.40.189:30080/ops/k8s-apps.git
      name: lan-gitlab-k8s-apps
      type: git
      username: argocd-bot
      password: '<PAT>'
```

> **key 名以实际 chart 为准**：`helm show values argo/argo-cd | grep -n 'insecure\|nodePortHttp'`。
> **不需要 nodeSelector**：Argo CD 无本地卷（redis 不持久化），Pod 漂移无副作用——这是它比 Harbor/GitLab 省心之处。
> **应用命名空间**：Application CR 默认只能放在 `argocd` 命名空间（controller 日志 `Enabled application namespace patterns: argocd`）。若要把 Application CR 放到别的命名空间，给 controller 加参数：`controller.extraArgs: ["--application-namespaces=*"]`（生产建议列明确名单，如 `--application-namespaces=argocd,prod`）。

### 5.3 渲染校验并安装（幂等）

**先渲染校验，再安装**——提前发现镜像 tag 不匹配、dex 未禁用等问题：

```bash
helm template argocd ./argo-cd -n argocd -f argocd-values.yaml > /tmp/argocd-rendered.yaml
grep -oE 'image: [^ ]+' /tmp/argocd-rendered.yaml | sort -u     # 应含 argoproj/argocd:${ARGOCD_VERSION}
printf 'StatefulSet=%s Deployment=%s PVC=%s\n' \
  "$(grep -c 'kind: StatefulSet' /tmp/argocd-rendered.yaml)" \
  "$(grep -c 'kind: Deployment' /tmp/argocd-rendered.yaml)" \
  "$(grep -c 'kind: PersistentVolumeClaim' /tmp/argocd-rendered.yaml)"   # 期望 1 / 4 / 0
grep -n 'dexidp/dex' /tmp/argocd-rendered.yaml                    # 应无输出
grep -n 'server.insecure: "true"' /tmp/argocd-rendered.yaml       # 应有输出

# 安装（或升级）
if helm -n argocd list | grep -q '^argocd'; then
  helm upgrade argocd ./argo-cd -n argocd -f argocd-values.yaml --timeout 600s
else
  helm install argocd ./argo-cd -n argocd --create-namespace -f argocd-values.yaml --timeout 600s
fi
```

### 5.4 等待就绪

```bash
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis; do
  kubectl -n argocd rollout status deploy/$d --timeout=300s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd get pods -o wide
```

> 若某节点首次拉 `argocd` 镜像耗时接近 4 分钟，`--timeout=300s` 可能不够，调大到 600s。

## 6. 客户端配置与使用

### 6.1 访问 UI 与初始密码

```bash
NODE_IP=192.168.40.189; PORT=30700
# 初始管理员密码（首次登录后请立即修改；密码只从 Secret 读取，不写仓库）
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# 浏览器打开（注意是 http，不是 https）
echo "http://${NODE_IP}:${PORT}"
# 健康检查（Argo CD 3.x 的端点是 /healthz，返回 200 + 正文 ok；/api/health 返回 404）
curl -s "http://${NODE_IP}:${PORT}/healthz"; echo
```

### 6.2 安装 argocd CLI 并登录

```bash
# 下载 CLI（GitHub Releases，建议走国内代理；版本与 app 一致）
ARGOCD_VERSION=v3.6.1
curl -sL -o argocd "https://ghfast.top/https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
  || curl -sL -o argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
chmod +x argocd
./argocd version --client        # ⚠️ 必须能打印版本；segfault/无输出 = 文件被截断，需重下

PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
./argocd login 192.168.40.189:30700 --plaintext --username admin --password "$PASS"
./argocd cluster list          # 应看到 https://kubernetes.default.svc
./argocd app list              # 应为空（尚未创建应用）
```

> **坑**：Argo CD 3.x 的 server 不再提供 `/downloads/argocd-linux-amd64`（实测 404），CLI 需自行从 GitHub Releases 获取；`/v1/messages` 等接口不受影响。
> `--plaintext` 对应 `server.insecure=true`。

### 6.3 接入 GitLab 仓库（私有库凭据）

**实测结论（2026-11-15，Argo CD v3.6.1）**：

- **credential template（`argocd.argoproj.io/secret-type: repository` 的 Secret）**：`url` 写**主机前缀**（如 `http://192.168.40.189:30080`）时**不生效**（A/B 实测：前缀 → Sync Unknown；逐字改成完整仓库 URL → Synced）。且 **ApplicationSet 的 git generator 完全不走 credential template**。
- **可靠做法**：用 `configs.repositories`（声明式，随 values 走）或 `argocd repo add`（写入 `repo-<hash>` Secret）**显式登记仓库 + 凭据**。本手册采用前者。

**步骤 1：建机器人账号与 PAT**（在 GitLab 所在集群的 toolbox Pod 里执行一次即可）：

```bash
# 1) 用 root 建一个引导 PAT（用完即删）
ROOTPAT=$(kubectl -n gitlab exec gitlab-toolbox-<pod> -- gitlab-rails runner "
u = User.find_by_username('root')
t = u.personal_access_tokens.find_by(name: 'bootstrap-argocd') || u.personal_access_tokens.create!(name: 'bootstrap-argocd', scopes: ['api'], expires_at: 1.year.from_now)
puts \"ROOTPAT=\#{t.token}\"" 2>&1 | grep -oE 'ROOTPAT=glpat-[A-Za-z0-9._-]+' | cut -d= -f2)

# 2) 建机器人用户（或复用已有）
BOTPASS=$(openssl rand -hex 18)
curl -s -X POST -H "PRIVATE-TOKEN: $ROOTPAT" "http://192.168.40.189:30080/api/v4/users" \
  --data-urlencode "username=argocd-bot" --data-urlencode "name=Argo CD Bot" \
  --data-urlencode "email=argocd-bot@lab.local" --data-urlencode "password=$BOTPASS" \
  --data-urlencode "skip_confirmation=true" --data-urlencode "admin=false" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])"

# 3) 给机器人建 PAT（scopes: api, read_repository, write_repository）
BOTPAT=$(curl -s -X POST -H "PRIVATE-TOKEN: $ROOTPAT" \
  "http://192.168.40.189:30080/api/v4/users/<UID>/personal_access_tokens" \
  --data-urlencode "name=argocd" --data-urlencode "scopes[]=api" \
  --data-urlencode "scopes[]=read_repository" --data-urlencode "scopes[]=write_repository" \
  --data-urlencode "expires_at=2027-11-15" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

# 4) 建组与项目，并把机器人加为成员（否则 git push 报 project not found）
GID=$(curl -s -X POST -H "PRIVATE-TOKEN: $ROOTPAT" "http://192.168.40.189:30080/api/v4/groups" \
  --data-urlencode "name=ops" --data-urlencode "path=ops" --data-urlencode "visibility=private" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -s -X POST -H "PRIVATE-TOKEN: $ROOTPAT" "http://192.168.40.189:30080/api/v4/projects" \
  --data-urlencode "name=k8s-apps" --data-urlencode "path=k8s-apps" \
  --data-urlencode "namespace_id=$GID" --data-urlencode "visibility=private" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id'))"
curl -s -X POST -H "PRIVATE-TOKEN: $ROOTPAT" "http://192.168.40.189:30080/api/v4/groups/$GID/members" \
  --data-urlencode "user_id=<UID>" --data-urlencode "access_level=50" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_level'))"

# 5) 引导 PAT 用完即删
TID=$(curl -s -H "PRIVATE-TOKEN: $ROOTPAT" "http://192.168.40.189:30080/api/v4/personal_access_tokens" \
  | python3 -c "import sys,json;print([t['id'] for t in json.load(sys.stdin) if t['name']=='bootstrap-argocd'][0])")
curl -s -o /dev/null -w "revoke: %{http_code}\n" -X DELETE -H "PRIVATE-TOKEN: $ROOTPAT" \
  "http://192.168.40.189:30080/api/v4/personal_access_tokens/$TID"
```

**步骤 2：把凭据写进 values 并升级**（推荐，声明式、可复现）：

```yaml
# argocd-values.yaml
configs:
  repositories:
    lan-gitlab-k8s-apps:
      url: http://192.168.40.189:30080/ops/k8s-apps.git
      name: lan-gitlab-k8s-apps
      type: git
      username: argocd-bot
      password: '<BOTPAT>'
```

```bash
helm upgrade argocd ./argo-cd -n argocd -f argocd-values.yaml --timeout 300s
kubectl -n argocd get secrets | grep repo-          # 应出现 argocd-repo-lan-gitlab-k8s-apps
./argocd repo list                                    # 目标仓库 CREDS=true, STATUS=Successful
```

> **凭据只进 values（本地）/ K8s Secret，不入 Git**。values 文件放在 `/root/argocd-deploy/` 并确保不被提交。
> **等价的手动命令**（不写 values 时）：`argocd repo add <url> --username argocd-bot --password '<BOTPAT>'`。

### 6.4 创建 root Application（ApplicationSet 模式）

**⚠️ 先纠正一个常见误解**：app-of-apps 的 root Application 指向的目录里放的是 **Application CR**，而不是任意 manifests；Argo CD **不会**把"每个子目录"自动变成 Application。10 个应用的规模，推荐 **ApplicationSet + git directory generator**（自动为 `apps/*` 每个目录生成一个 Application），这也是本部署实测通过的方案。

GitLab 仓库 `ops/k8s-apps` 结构（实测）：

```text
k8s-apps/
├── README.md
├── bootstrap/
│   ├── root.yaml            # root Application → path: bootstrap
│   └── applicationset.yaml  # ApplicationSet：扫描 apps/* 生成 Application
└── apps/
    └── 99-smoke/            # 一个应用 = 一个目录（Kustomize 或原始清单）
        ├── kustomization.yaml
        ├── configmap.yaml
        └── deployment.yaml
```

`bootstrap/root.yaml`：

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
    path: bootstrap
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`bootstrap/applicationset.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: root
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: http://192.168.40.189:30080/ops/k8s-apps.git
        revision: main
        directories:
          - path: apps/*
  template:
    metadata:
      name: "{{.path.basename}}"
    spec:
      project: default
      source:
        repoURL: http://192.168.40.189:30080/ops/k8s-apps.git
        targetRevision: main
        path: "{{.path.path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**bootstrap（root.yaml 需要手动执行一次，它管理的是 `bootstrap/` 目录，不含自己，避免自引用）**：

```bash
git clone http://argocd-bot:'<BOTPAT>'@192.168.40.189:30080/ops/k8s-apps.git
kubectl -n argocd apply -f k8s-apps/bootstrap/root.yaml
./argocd app list                       # 应出现 root
sleep 20
./argocd app list                       # 应出现 99-smoke（由 ApplicationSet 生成）
./argocd app sync root
```

**实测结果**：`root` 与 `99-smoke` 均 `Synced / Healthy`，`99-smoke` 命名空间被自动创建、Deployment `1/1 Running`；ApplicationSet 条件 `ResourcesUpToDate=True`。

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
    - kustomize edit set image smoke=docker.m.daocloud.io/library/alpine:${CI_COMMIT_SHORT_SHA} 2>/dev/null \
        || sed -i "s#image: .*/alpine:.*#image: docker.m.daocloud.io/library/alpine:${CI_COMMIT_SHORT_SHA}#" apps/*/deployment.yaml
    - git commit -am "chore: bump image to ${CI_COMMIT_SHORT_SHA}"
    - git push origin main
  only: [main]
```

**实测**：修改 `apps/99-smoke/deployment.yaml`（replicas 1→2）与 ConfigMap 后 push，**约 120s 内** Argo CD 自动检测到并完成 sync（replicas=2、新 ConfigMap 生效）。

> **避免循环**：CI 只改 manifests，由 Argo CD 负责 sync；**不要**在 CI 里同时调 `argocd app sync` 又改 manifest。若确需立即同步，可给 Argo CD 配 webhook，并确保幂等。
> **镜像拉取凭据**：应用 Pod 从 Harbor 拉镜像需要 `imagePullSecrets`，建议在目标命名空间把凭据设为 ServiceAccount 默认（见 [kubernetes-harbor.md](kubernetes-harbor.md) 6.5）。

### 6.6 快速验证脚本（一键检查）

保存为 `argocd_verify.sh`，只读检查。退出码 `0` = 通过。

```bash
#!/bin/bash
# Argo CD 快速验证：Pod / 健康端点 / 初始密码 / root 应用 / 自愈
# 用法: NODE_IP=192.168.40.189 PORT=30700 bash argocd_verify.sh
set -u
NODE_IP="${NODE_IP:-192.168.40.189}"
PORT="${PORT:-30700}"
NS="${NS:-argocd}"
PASS=0; FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

chk "全部 Pod Running/Completed" "test \$(kubectl -n $NS get pods --no-headers | grep -cE 'Running|Completed') -eq \$(kubectl -n $NS get pods --no-headers | wc -l)"
chk "健康端点 /healthz"        "curl -s http://${NODE_IP}:${PORT}/healthz | grep -qx ok"
chk "初始密码 Secret 存在"     "test -n \"\$(kubectl -n $NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null)\""
chk "server 为 NodePort"       "kubectl -n $NS get svc argocd-server -o jsonpath='{.spec.type}' | grep -q NodePort"
chk "root Application 存在"    "kubectl -n $NS get application root --no-headers | grep -q ."
chk "ApplicationSet 就绪"      "kubectl -n $NS get applicationset root -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -q 'ResourcesUpToDate=True'"

echo "=== 结果: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

> 首次安装后预期 **4/6 PASS**（root 与 ApplicationSet 尚未创建）；完成 6.3/6.4 后应为 **6/6 PASS**。

**漂移自愈验证**（可选，实测通过）：

```bash
kubectl -n 99-smoke scale deploy/smoke --replicas=3      # 手工改
sleep 45; kubectl -n 99-smoke get deploy smoke -o jsonpath='{.spec.replicas}'   # 回到 1
kubectl -n 99-smoke delete configmap smoke-config         # 手工删
sleep 40; kubectl -n 99-smoke get configmap smoke-config -o jsonpath='{.data.origin}'  # 被重建
```

## 7. 最佳实践与踩坑总结

> 换环境复用时**先通读本章**。带 ⚠️ 的是本环境实测踩到的坑。

| # | 实践 | 原因 / 做法 |
| --- | --- | --- |
| 1 | ⚠️ **chart 走 GitHub Releases，不依赖 `argoproj.github.io`** | 该域名国内时通时断； Releases tgz 稳定。脚本内置自动降级 |
| 2 | ⚠️ **`helm dependency update` 必须先做** | `Chart.yaml` 声明了 `redis-ha`（`dandydeveloper.github.io/charts/`），即使关闭也要求依赖存在，否则 `helm install` 直接失败 |
| 3 | ⚠️ **insecure 写在 `configs.params.server.insecure`** | v10 chart 已无 `server.insecure` 键；写错会静默不生效（UI 变成 HTTPS 握手失败） |
| 4 | ⚠️ **健康端点是 `/healthz`，不是 `/api/health`** | 3.x 实测 `/api/health` 返回 404；`/healthz` 返回 200 + 正文 `ok` |
| 5 | ⚠️ **redis 用 Deployment + 镜像改国内源** | chart 默认 `ecr-public.aws.com/docker/library/redis`（国内慢）；改 `docker.m.daocloud.io/library/redis:8.6.4-alpine` |
| 6 | ⚠️ **仓库凭据用 `configs.repositories` 声明式登记** | credential template 前缀 URL 不生效、ApplicationSet git generator 不走 template（均实测） |
| 7 | ⚠️ **CLI 需自行下载并自检** | server 的 `/downloads/...` 已 404；GitHub 大文件易截断 → segfault，下载后必须 `argocd version --client` |
| 8 | **chart 与 app 版本交叉核对** | chart≠app；用 `helm search repo` / GitHub Releases API / `Chart.yaml` 的 `appVersion` 核对，只用稳定版 |
| 9 | **先渲染再安装** | `helm template` 后核对镜像 tag、`StatefulSet=1 / Deployment=4 / PVC=0`、dex 已禁用、insecure 已生效 |
| 10 | **幂等安装** | `helm -n argocd list` 判断 install / upgrade |
| 11 | **镜像源用 containerd `certs.d` 透明映射** | 不改 chart 仓库地址，保留主/备回退；`quay.io` → `quay.m.daocloud.io` 为主、`quay.nju.edu.cn` 为备 |
| 12 | **`ctr` 验证镜像源要加 `--hosts-dir`** | 不加会直连上游误判 |
| 13 | **上生产前换 HTTPS** | `server.insecure=true` 仅 lab；生产用 Ingress + cert-manager（见 8.2） |
| 14 | **职责单一** | 同一批资源只由 Argo CD 或 `helm upgrade` 之一管理，不要并用 |
| 15 | **CI 改 manifest、Argo CD 做 sync** | 避免循环；CI 不直接 `kubectl`/`helm` 操作集群 |
| 16 | **root Application 加 finalizer** | `resources-finalizer.argcd.argoproj.io` 保证删除级联正确（建议用带 `/` 的域名限定写法） |
| 17 | **`prune: true` 谨慎启用** | 首次建议先手动 sync 观察，确认无"误删手工资源"后再开自动 prune |
| 18 | **凭据只进 Secret / 本地 values** | 仓库 PAT、Harbor 凭据都放 K8s Secret / CI Variables，不入 Git |
| 19 | **Redis 不持久化** | 缓存丢了可重建；避免无谓的 PVC 与 local-path 节点绑定 |
| 20 | **dex/notifications 按需开启** | 默认关闭可省 2 个组件；上 SSO 时再开 dex（需 ghcr 镜像与 OIDC 配置） |
| 21 | **大镜像首拉慢，超时给足** | 实测新节点拉 `argocd` 镜像约 4 分钟；rollout `--timeout` 建议 600s |
| 22 | **ApplicationSet 的 git generator 需要已登记仓库** | 与 Application 的凭据解析路径不同（实测），务必先 `configs.repositories` / `argocd repo add` |
| 23 | **升级前备份 Application 定义** | `kubectl -n argocd get applications -o yaml > backup.yaml`；manifests 仓库本身即事实来源 |

## 8. 排障

### 8.1 Pod 一直 Pending / ImagePullBackOff

```bash
kubectl -n argocd describe pod <pod>        # 看 Events 真实拉取地址与错误
```

- `quay.io` 超时 → 检查 `/etc/containerd/certs.d/quay.io/hosts.toml` 主备顺序，按第 4 章选源方法重测；必要时 `sudo systemctl restart containerd`（影响 Docker 业务容器，先确认）。
- 新节点首次拉镜像慢（实测 ~4 分钟）→ 调大 rollout `--timeout`，或提前用 `ctr images pull` 预热。
- `manifest unknown / not found` → 确认 `${ARGOCD_VERSION}` 镜像真实存在（第 2 章第 6 步）。

### 8.2 UI 打不开 / 登录页异常

- `server.insecure=true` 时**必须用 `http://` 访问**（用 https 会握手失败）；访问地址为 `http://<NODE_IP>:30700`。
- 若 values 里写成了 `server.insecure`（错误键），渲染不会报错但服务端仍是 HTTPS → 用 `grep 'server.insecure: "true"' /tmp/argocd-rendered.yaml` 校验。
- CLI 报 TLS 错误 → 加 `--plaintext`。
- 端口不通 → 确认 NodePort 未被占用、防火墙放行（`ss -ltnp | grep 30700`）。

### 8.3 应用一直 OutOfSync / SyncFailed / ComparisonError

```bash
kubectl -n argocd get application <app> -o jsonpath='{.status.conditions}'   # 看具体 message
kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i error
```

- `authentication required: HTTP Basic: Access denied` → 仓库凭据问题：
  - 确认已用 `configs.repositories` / `argocd repo add` 登记（**不要只依赖 credential template**，见 6.3）；
  - 确认 PAT scope 含 `read_repository`，`url` 与 `repoURL` 完全一致（含 `http://` 与端口）；
  - GitLab 机器人必须是项目/群组成员，否则 git 报 `project not found`。
- `ApplicationSet` 报 `error generating params from git` → 同上（git generator 不走 template）；看 `kubectl -n argocd get applicationset <name> -o jsonpath='{.status.conditions}'`。
- Helm chart 拉取失败 → chart 仓库（如 Harbor）需单独配凭据。

### 8.4 漂移 / 自愈不生效

确认 Application 的 `syncPolicy.automated.selfHeal: true`；手工 `kubectl edit` 改过的资源若不在 Git 声明中，`selfHeal` 会把它改回 Git 状态——**这是特性不是故障**，但开启前确认 Git 里的声明是完整的。

### 8.5 升级 Argo CD 版本

```bash
# 1) 备份 Application 定义
kubectl -n argocd get applications -o yaml > /root/argocd-deploy/applications-backup.yaml
# 2) 交叉核对目标 chart/app 版本（第 3.2 节）
# 3) 重跑脚本（CHART_SOURCE=release CHART_VERSION=<新> ARGOCD_VERSION=<新> bash kubernetes-argocd-install.sh）
# 4) 重跑第 6.6 节验证脚本
```

> 跨小版本升级前阅读官方 upgrading 文档（2→3 有破坏性变更先例，如弃用参数、CRD 版本）。

## 9. Agent 执行注意事项

- **先检查再执行**：第 2 章全只读；`helm -n argocd list` 有记录就走 `upgrade`，不要重复 `install`。
- **参数先确认**：执行前向用户确认第 1 章参数（尤其 `NODE_IP`、`CHART_VERSION`、`ARGOCD_VERSION`、端口、仓库凭据）。
- **优先用一键脚本**：`kubernetes-argocd-install.sh` 已封装检查/镜像源/取 chart/校验/安装/验证全流程；手动分步用于排障。
- **危险操作必须确认**：`systemctl restart containerd`（影响 Docker 业务容器）、`helm uninstall`、删除 namespace，逐项征求同意。
- **版本红线**：拒绝安装 `rc`/`beta` 版本（脚本已内置拦截）；升级前先备份 Application 定义。
- **凭据管理**：初始 admin 密码、GitLab PAT、Harbor 凭据只存 Secret / 本地 values / CI Variables，**不写入仓库、Issue、日志**；引导 PAT 用完即删（实测已删）。
- **失败即停**：拉取失败先看 Events 真实地址，不盲目重试。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 10. 卸载（可选，破坏性，需用户确认）

```bash
# 1) 先导出所有 Application 定义（备份）
kubectl -n argocd get applications -o yaml > /root/argocd-deploy/applications-backup.yaml

# 2) 卸载 release（Argo CD 管理的业务应用不会被自动删除——它们不在本 release 内）
helm -n argocd uninstall argocd

# 3) 删除残留资源与命名空间
kubectl -n argocd delete secret argocd-repo-lan-gitlab-k8s-apps --ignore-not-found
kubectl delete ns argocd
```

> Argo CD 卸载**不会**删除它部署的业务应用（Application 的 `destination` 资源独立存在）；如需一并清理，先 `kubectl -n argocd get applications -o jsonpath=...` 逐个 `kubectl delete`，谨慎操作。

## 11. 复用 checklist 与已知遗留

**换环境复用清单（逐项确认）**

- [ ] 集群已就绪（kubectl/helm 可用、节点 Ready）。
- [ ] `NODE_IP` = 对外可访问的节点 IP；`NODEPORT_HTTP/HTTPS` 未被占用。
- [ ] containerd `certs.d/quay.io` 已配并**按本机实测**定主备顺序。
- [ ] 版本：`CHART_VERSION` 与 `ARGOCD_VERSION` 已交叉核对，且为稳定版。
- [ ] chart 来源可达（helm 仓库 / GitHub Releases / `ghfast.top`），`helm dependency update` 成功。
- [ ] 渲染校验通过（镜像 tag / `StatefulSet=1` / `Deployment=4` / `PVC=0` / dex 禁用 / insecure 生效）。
- [ ] 安装后跑 `argocd_verify.sh`。
- [ ] Git 仓库凭据已用 `configs.repositories` 登记；root Application + ApplicationSet 已 bootstrap。
- [ ] CI 侧只更新 manifests（第 6.5 节），未与 Argo CD 并管同一批资源。

**已知遗留**

- 本部署为 **HTTP 明文**（`server.insecure=true`），仅适用内网 lab；上生产前必须换 Ingress + TLS（第 7 章第 13 条）。
- **未接 SSO**：仅 admin 本地账号；多人使用需开 dex + GitLab OAuth（第 7 章第 20 条）。初始 admin 密码仍在 `argocd-initial-admin-secret`，建议登录后改密。
- **未配监控/告警**：Argo CD 暴露 `:8082`/`:8083` 指标，需要时接 Prometheus。
- **Redis 无持久化**：重启后缓存重建，属预期。
- **`99-smoke` 验证应用仍在集群**（命名空间 `99-smoke`，1 Pod）；确认不需要后可按 6.4 的方式从 `k8s-apps` 删除目录并同步。

---

## 附录 A：当前部署的目录与文件

目标节点：`192.168.40.189`

```text
/root/argocd-deploy/
├── argo-cd-10.18.0.tgz          # chart 包（release 模式）
├── argo-cd/                     # 解压后的 chart（含 charts/redis-ha）
├── argocd-values.yaml           # Helm values（含仓库凭据，勿提交）
├── argocd-cli                   # argocd CLI（v3.6.1）
├── k8s-apps/                    # GitOps 配置仓库本地克隆（推回 GitLab ops/k8s-apps）
├── .botpat / .botpass           # 机器人凭据（勿提交）
└── applications-backup.yaml     # 升级前备份（按需生成）
```

> 敏感信息仅用于本次部署与后续维护，不应放入 Git 仓库。

## 附录 B：实测部署记录（2026-11-15，192.168.40.189）

| 项 | 实测值 |
| --- | --- |
| chart / app | `argo-cd-10.18.0` / **v3.6.1**（BuildDate 2026-11-04） |
| 镜像 | `quay.io/argoproj/argocd:v3.6.1`（`quay.m.daocloud.io` 映射，首拉 89s/201MB）；`docker.m.daocloud.io/library/redis:8.6.4-alpine` |
| 组件 | 5/5 Running（4 Deployment + 1 StatefulSet），PVC 0 |
| 访问 | `http://192.168.40.189:30700`；`/healthz` → 200 `ok`；UI `/` 200 |
| CLI | `argocd v3.6.1+94037c4`，`--plaintext` 登录成功，`cluster list` 正常 |
| GitLab | 组 `ops`（id 20）、项目 `ops/k8s-apps`（id 3）、机器人 `argocd-bot`（id 16，PAT 至 2027-11-15） |
| GitOps | `root`（Application）+ `root`（ApplicationSet）→ 子应用 `99-smoke`，均 Synced/Healthy |
| 自动 sync | push 后 ≤120s 检测到并完成同步（replicas 1→2、ConfigMap 更新） |
| 自愈 | `replicas` 手工改 3 → 45s 内回到 1；删除的 ConfigMap 40s 内重建 |
| 凭据 | `configs.repositories` 声明式登记（Secret `argocd-repo-lan-gitlab-k8s-apps`）；引导 PAT 已撤销（204） |

## 附录 C：`ops/k8s-apps` 仓库模板

```text
k8s-apps/
├── README.md
├── bootstrap/
│   ├── root.yaml              # Application → path: bootstrap
│   └── applicationset.yaml    # ApplicationSet（git directories: apps/*）
└── apps/
    └── <name>/                # 一个应用一个目录
        ├── kustomization.yaml  # 或 Chart.yaml + values（Helm 应用）
        └── *.yaml
```

新增应用 = 在 `apps/` 下加一个目录并 push，ApplicationSet 自动生成 Application（实测）。**不要**在 `bootstrap/` 里加业务应用，避免 root 自引用。
