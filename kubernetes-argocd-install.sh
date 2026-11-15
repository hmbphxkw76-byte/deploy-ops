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
