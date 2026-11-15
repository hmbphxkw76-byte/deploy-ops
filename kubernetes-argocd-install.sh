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
