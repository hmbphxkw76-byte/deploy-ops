#!/bin/bash
# Harbor on Kubernetes 一键安装（NodePort + 自签 HTTPS + 国内镜像源）
# 用法:
#   NODE_IP=192.168.40.189 PIN_NODE=ubuntu bash harbor-kubernetes-install.sh
#   HARBOR_VERSION=v2.15.4 TRIVY_ENABLED=true bash harbor-kubernetes-install.sh
#   ADMIN_PASSWORD='固定密码' SECRET_KEY='固定密钥' bash harbor-kubernetes-install.sh   # 不传则随机生成
#   VALUES_FILE=/root/harbor-values.yaml bash harbor-kubernetes-install.sh
# 说明: 幂等。已安装则走 helm upgrade；脚本末尾打印访问地址 / 账号 / 密码 / CA 路径。
# 退出码: 0=成功, 1=失败
set -euo pipefail

# ---------------- 参数（环境变量覆盖）----------------
NAMESPACE="${NAMESPACE:-harbor}"
RELEASE="${RELEASE:-harbor}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.15.5}"
CHART_VERSION="${CHART_VERSION:-1.19.4}"
NODE_IP="${NODE_IP:?need NODE_IP, e.g. 192.168.40.189}"
NODEPORT_HTTPS="${NODEPORT_HTTPS:-30003}"
NODEPORT_HTTP="${NODEPORT_HTTP:-30002}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
PIN_NODE="${PIN_NODE:-}"                       # 组件固定调度的节点 hostname；留空则不固定
TRIVY_ENABLED="${TRIVY_ENABLED:-false}"
REGISTRY_SIZE="${REGISTRY_SIZE:-20Gi}"
VALUES_FILE="${VALUES_FILE:-/tmp/harbor-values.yaml}"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

EXTERNAL_URL="https://${NODE_IP}:${NODEPORT_HTTPS}"
H="${NODE_IP}:${NODEPORT_HTTPS}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -hex 12)}"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 16)}"
CERT_DIR="/etc/docker/certs.d/${H}"
NGINX_SECRET="${RELEASE}-nginx"

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------- 1. 前置检查（只读）----------------
log "前置检查"
command -v kubectl >/dev/null 2>&1 || die "kubectl 未安装"
command -v helm    >/dev/null 2>&1 || die "helm 未安装"
kubectl get --raw='/readyz' >/dev/null 2>&1 || die "apiserver 不可达（检查 KUBECONFIG）"
[ -n "$PIN_NODE" ] && { kubectl get node "$PIN_NODE" >/dev/null 2>&1 || die "节点 $PIN_NODE 不存在（PIN_NODE 填 hostname）"; }
[ -n "$STORAGE_CLASS" ] && { kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 || log "警告: StorageClass $STORAGE_CLASS 不存在，PVC 可能 Pending"; }

# 检查 NodePort 是否被其它命名空间占用（本 release 命名空间内的不算冲突）
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

# ---------------- 2. 生成 values ----------------
log "生成 values: $VALUES_FILE"
ns_flow() { [ -n "$PIN_NODE" ] && echo ", nodeSelector: { kubernetes.io/hostname: $PIN_NODE }" || echo ""; }
{
cat <<EOF
# 由 harbor-kubernetes-install.sh 生成
expose:
  type: nodePort
  tls:
    enabled: true
    certSource: auto
    auto:
      commonName: ${NODE_IP}
  nodePort:
    ports:
      http:  { nodePort: ${NODEPORT_HTTP} }
      https: { nodePort: ${NODEPORT_HTTPS} }
externalURL: ${EXTERNAL_URL}
harborAdminPassword: "${ADMIN_PASSWORD}"
secretKey: "${SECRET_KEY}"
trivy:
  enabled: ${TRIVY_ENABLED}
persistence:
  enabled: true
  resourcePolicy: keep
  persistentVolumeClaim:
    registry:   { storageClass: ${STORAGE_CLASS}, size: ${REGISTRY_SIZE} }
    jobservice:
      jobLog:   { storageClass: ${STORAGE_CLASS}, size: 2Gi }
    database:   { storageClass: ${STORAGE_CLASS}, size: 2Gi }
    redis:      { storageClass: ${STORAGE_CLASS}, size: 2Gi }
    trivy:      { storageClass: ${STORAGE_CLASS}, size: 5Gi }
nginx:       { image: { tag: ${HARBOR_VERSION} }$(ns_flow) }
portal:      { image: { tag: ${HARBOR_VERSION} }$(ns_flow) }
core:        { image: { tag: ${HARBOR_VERSION} }$(ns_flow) }
jobservice:  { image: { tag: ${HARBOR_VERSION} }$(ns_flow) }
registry:    { registry: { image: { tag: ${HARBOR_VERSION} } }, controller: { image: { tag: ${HARBOR_VERSION} } }$(ns_flow) }
database:    { internal: { image: { tag: ${HARBOR_VERSION} }$(ns_flow) } }
redis:       { internal: { image: { tag: ${HARBOR_VERSION} }$(ns_flow) } }
EOF
} > "$VALUES_FILE"

# ---------------- 3. 渲染校验 ----------------
log "渲染校验（helm template）"
helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null 2>&1 || true
helm template "$RELEASE" harbor/harbor --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE" > /tmp/harbor-rendered.yaml \
  || die "helm template 渲染失败"
grep -q "image: docker.io/goharbor/harbor-core:${HARBOR_VERSION}" /tmp/harbor-rendered.yaml \
  || die "core 镜像 tag 不是 ${HARBOR_VERSION}（渲染结果不符）"
EXPECTED_STS=2; [ "$TRIVY_ENABLED" = "true" ] && EXPECTED_STS=3
GOT_STS=$(grep -c 'kind: StatefulSet' /tmp/harbor-rendered.yaml)
[ "$GOT_STS" -eq "$EXPECTED_STS" ] || die "StatefulSet 数量应为 ${EXPECTED_STS}，实际 ${GOT_STS}（trivy 开关或 values 重复键问题）"
grep -q 'WITH_TRIVY:' /tmp/harbor-rendered.yaml && log "WITH_TRIVY=$(grep -oE 'WITH_TRIVY: \"?(true|false)' /tmp/harbor-rendered.yaml | head -1)"

# ---------------- 4. 安装 / 升级（幂等）----------------
if helm -n "$NAMESPACE" list 2>/dev/null | grep -q "^${RELEASE}"; then
  log "已安装 → helm upgrade"
  helm upgrade "$RELEASE" harbor/harbor --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE"
else
  log "helm install"
  helm install "$RELEASE" harbor/harbor --version "$CHART_VERSION" -n "$NAMESPACE" --create-namespace -f "$VALUES_FILE"
fi

# ---------------- 5. 等待就绪 ----------------
log "等待组件就绪（最长 300s，jobservice 首次可能重启几次后自愈）"
for d in harbor-core harbor-jobservice harbor-nginx harbor-portal harbor-registry; do
  kubectl -n "$NAMESPACE" rollout status "deploy/${d}" --timeout=300s >/dev/null 2>&1 || log "警告: deploy/${d} 未在超时内就绪"
done
for s in harbor-database harbor-redis; do
  kubectl -n "$NAMESPACE" rollout status "statefulset/${s}" --timeout=300s >/dev/null 2>&1 || log "警告: statefulset/${s} 未在超时内就绪"
done
kubectl -n "$NAMESPACE" get pods -o wide

# ---------------- 6. 客户端 CA 信任 ----------------
log "导出 CA 并写入 ${CERT_DIR}/ca.crt"
kubectl -n "$NAMESPACE" get secret "$NGINX_SECRET" -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/harbor-ca.crt
mkdir -p "$CERT_DIR"
cp /tmp/harbor-ca.crt "${CERT_DIR}/ca.crt"

# ---------------- 7. 验证 ----------------
log "验证服务"
sleep 5
CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${H}/" || echo 000)
[ "$CODE" = "200" ] || die "portal 返回 ${CODE}"
HEALTH=$(curl -sk -u "admin:${ADMIN_PASSWORD}" "https://${H}/api/v2.0/health" || true)
echo "$HEALTH" | grep -q '"status":"healthy"' || log "警告: health 未返回 healthy（可能仍在启动）"

# ---------------- 8. 结果 ----------------
cat <<EOF

================ Harbor 安装完成 ================
地址:   ${EXTERNAL_URL}
账号:   admin
密码:   ${ADMIN_PASSWORD}
CA:     /tmp/harbor-ca.crt（已复制到 ${CERT_DIR}/ca.crt）
values: ${VALUES_FILE}
镜像:   docker.io/goharbor/*:${HARBOR_VERSION}（由 containerd certs.d 走国内源）
验证:   curl -sk -u admin:${ADMIN_PASSWORD} ${EXTERNAL_URL}/api/v2.0/health
客户端: docker login ${H} -u admin -p '${ADMIN_PASSWORD}'
==================================================
EOF
