# Harbor on Kubernetes 部署手册（最佳实践 · 可直接安装）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在 **Kubernetes 集群** 上以 **Helm Chart** 部署 **Harbor**（私有 OCI 镜像仓库），并优先使用**国内镜像源**拉取镜像。文档汇总了 2026-11-15 在真实集群上的完整安装经验与踩坑，**可直接照装**：

- **最快路径**：用 [kubernetes-harbor-install.sh](kubernetes-harbor-install.sh) 一键安装（第 0 章），一条命令完成前置检查 → 生成 values → 渲染校验 → 安装/升级 → 等待就绪 → 导出 CA → 验证 → 打印账号密码。
- **手动路径**：第 1～6 章分步说明，便于排障与二次开发。
- **经验总结**：第 7 章集中列出最佳实践与踩坑，换环境复用时先看这一章。

**部署形态**：Helm（官方 chart `harbor/harbor`），命名空间 `harbor`，release 名 `harbor`；暴露方式 **NodePort**（无需 Ingress，与现有 GitLab 的"节点 IP + 无 ingress"形态一致）；**自签 HTTPS**（chart 自动生成 CA/证书，CN=节点 IP）；镜像保持 `docker.io/goharbor/*`，由 containerd `certs.d` 透明走国内源。

**落地实例**（2026-11-15）：集群 `192.168.40.189`（control-plane，hostname `ubuntu`，Ubuntu 24.04 / 24C / 62G）+ `192.168.40.183`（worker，hostname `ubunt-dev`，Ubuntu 22.04 / 8C / 16G），K8s v1.37.2，默认 StorageClass `local-path`。结果：**Harbor v2.15.5**，访问 `https://192.168.40.189:30003`；验证脚本 7/7 PASS，`docker login/push/pull` 全链路通过。

> 前置依赖：集群已按 [linux-kubernetes.md](linux-kubernetes.md) 部署（含 containerd 镜像源、flannel、local-path）。若镜像走其他加速方式，只要第 2 章的镜像源检查通过即可。

---

## 0. 快速安装（一键脚本）

### 0.1 用法

```bash
# 把 kubernetes-harbor-install.sh 放到集群可执行节点（如 control-plane），然后：
NODE_IP=192.168.40.189 PIN_NODE=ubuntu bash kubernetes-harbor-install.sh
```

常用覆盖项：

```bash
HARBOR_VERSION=v2.15.5 TRIVY_ENABLED=true \
STORAGE_CLASS=local-path REGISTRY_SIZE=50Gi \
ADMIN_PASSWORD='固定密码' SECRET_KEY='固定密钥' \
bash kubernetes-harbor-install.sh
```

- `NODE_IP` 必填（无默认值）；其余均有默认值，见第 1 章参数区。
- 不传 `ADMIN_PASSWORD` / `SECRET_KEY` 时**随机生成**（脚本末尾打印）。
- **幂等**：已安装则自动走 `helm upgrade`，可重复执行。

### 0.2 脚本（kubernetes-harbor-install.sh）

```bash
#!/bin/bash
# Harbor on Kubernetes 一键安装（NodePort + 自签 HTTPS + 国内镜像源）
# 用法:
#   NODE_IP=192.168.40.189 PIN_NODE=ubuntu bash kubernetes-harbor-install.sh
#   HARBOR_VERSION=v2.15.5 TRIVY_ENABLED=true bash kubernetes-harbor-install.sh
#   ADMIN_PASSWORD='固定密码' SECRET_KEY='固定密钥' bash kubernetes-harbor-install.sh   # 不传则随机生成
#   VALUES_FILE=/root/harbor-values.yaml bash kubernetes-harbor-install.sh
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
# 由 kubernetes-harbor-install.sh 生成
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
```

### 0.3 脚本做了什么（步骤对应）

| 步骤 | 章节 | 说明 |
| --- | --- | --- |
| 1. 前置检查 | 第 2 章 | 工具/可达性/StorageClass/NodePort 占用（排除自身命名空间） |
| 2. 生成 values | 第 5.2 章 | 随机密码与密钥、固定节点、trivy 开关 |
| 3. 渲染校验 | 第 5.3 章 | `helm template` 核对镜像 tag 与 StatefulSet 数量，**先校验再安装** |
| 4. 安装/升级 | 第 5.3 章 | 幂等：已装走 `upgrade`，否则 `install` |
| 5. 等待就绪 | 第 5.4 章 | 滚动等待；jobservice 启动竞争自愈 |
| 6. 导出 CA | 第 6.1 章 | 写入 `/etc/docker/certs.d/<IP:端口>/ca.crt` |
| 7. 验证 | 第 6.4 章 | portal 200 + health healthy |

> 脚本在 **control-plane 节点**上以 root 执行（需要 `kubectl`/`helm`/docker `certs.d` 写权限）。若客户端是别的机器，CA 需按第 6.1 章单独下发。

---

## 1. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `HARBOR_VERSION` | `v2.15.5` | Harbor 应用版本（各组件镜像 tag） |
| `CHART_VERSION` | `1.19.4` | Helm Chart 版本；官方仓库当前最新，原生对应 app `2.15.4` |
| `NAMESPACE` | `harbor` | 命名空间 |
| `RELEASE` | `harbor` | Helm release 名 |
| `EXPOSE_TYPE` | `nodePort` | 暴露方式；`nodePort` / `ingress` / `clusterIP` / `loadBalancer` |
| `NODE_IP` | `192.168.40.189` | 集群节点 IP（NodePort 对外地址，也是证书 CN） |
| `NODEPORT_HTTPS` | `30003` | HTTPS NodePort（UI / API / registry 统一入口） |
| `NODEPORT_HTTP` | `30002` | HTTP NodePort（仅用于跳转，见 8.4） |
| `EXTERNAL_URL` | `https://192.168.40.189:30003` | Harbor core 对外 URL（**含端口**） |
| `STORAGE_CLASS` | `local-path` | 存储类（本地 PV，见 8.5 的节点绑定注意） |
| `PIN_NODE` | `ubuntu` | 组件固定调度到的节点 hostname（避免 local-path 跨节点卷迁移；留空则不固定） |
| `REGISTRY_SIZE` | `20Gi` | registry PVC 大小（镜像存储按量调整） |
| `ADMIN_PASSWORD` | 随机生成 | 管理员（`admin`）初始密码，写入 values 文件 |
| `SECRET_KEY` | 随机生成 | Harbor `secretKey`（≥16 位） |
| `TRIVY_ENABLED` | `false` | 是否启用 Trivy 漏洞扫描（默认关闭，见 8.6） |
| `MIRROR_DOCKER` | `docker.1ms.run` | `docker.io` 主镜像源（containerd `certs.d`） |
| `MIRROR_DOCKER_BACKUP` | `docker.m.daocloud.io` | `docker.io` 备用镜像源 |

## 2. 前置检查（只读，不修改系统）

```bash
export KUBECONFIG=/root/.kube/config

# 1) 客户端工具
kubectl version --client --short 2>/dev/null || kubectl version --client
helm version --short

# 2) 集群可达、节点 Ready
kubectl get nodes -o wide
kubectl get --raw='/readyz' | tail -1

# 3) 默认 StorageClass（Harbor 需要动态卷）
kubectl get sc

# 4) 是否已安装 Harbor（存在则走 5.3 的 upgrade 分支）
helm -n harbor list
kubectl -n harbor get pods

# 5) NodePort 端口占用（默认 30002/30003 不能被占用；排除 harbor 自身）
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {range .spec.ports[*]}{.nodePort} {end}{"\n"}{end}' | grep -E ' (30002|30003)$' | grep -v '^harbor ' || echo "30002/30003 空闲"

# 6) 镜像源是否可达（应返回 401=需 token，属正常可达）
curl -s -o /dev/null -w 'docker.1ms.run: %{http_code}\n' \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  https://docker.1ms.run/v2/goharbor/harbor-core/manifests/v2.15.5

# 7) 实际拉一个 Harbor 镜像验证（走 containerd CRI 镜像源；耗时约 20-60s）
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/goharbor/harbor-portal:v2.15.5
```

判定逻辑：

- `helm -n harbor list` 有记录 → 已安装，跳到 5.3 用 `helm upgrade` 更新，不要重复 `install`。
- 无默认 StorageClass 或没有 `local-path` → 先解决存储（见 8.5），否则 PVC 会 Pending。
- 镜像源探测失败 → 回到第 4 章重配或换源（参考 [linux-kubernetes.md](linux-kubernetes.md) 4.2 的选源方法）。

## 3. 架构与版本选型

### 3.1 组件构成

| 组件 | 作用 | 类型 |
| --- | --- | --- |
| `harbor-nginx` | 统一入口（UI / API `/api/` / registry `/v2/` / token `/service/`） | Deployment |
| `harbor-portal` | Web UI | Deployment |
| `harbor-core` | API / 业务逻辑 / token 服务 | Deployment |
| `harbor-jobservice` | 异步任务（复制、保留、扫描、GC） | Deployment |
| `harbor-registry` | 镜像存储（含 `registryctl` 容器） | Deployment（2 容器） |
| `harbor-database` | 内置 PostgreSQL | StatefulSet |
| `harbor-redis` | 内置 Valkey/Redis（队列/缓存） | StatefulSet |
| `harbor-trivy` | 漏洞扫描（默认禁用） | StatefulSet |

> NodePort 模式下，**docker push/pull 与 UI/API 共用同一入口**：nginx 把 `/v2/` 转发到 core，再由 core 代理到 registry。

### 3.2 版本选型（chart 与 app 版本不同步）

Helm 官方仓库（`https://helm.goharbor.io`）的 chart 与 Harbor app **并非同步发布**。截至 2026-11-15：

| 想要的版本 | 做法 | 风险 |
| --- | --- | --- |
| **v2.15.5**（推荐） | chart `1.19.4` + 覆盖各组件 `image.tag` | 低（同属 2.15 线） |
| v2.15.4 | chart 原生，删除 values 的 `image.tag` 覆盖 | 最低 |
| v2.16.0（最新 GA） | chart `1.19.4` + 覆盖 tag | **高**：chart 未官方验证，模板/配置可能不匹配 |

> 选型前用两条命令交叉核对：`helm search repo harbor/harbor --versions` 与 `curl -s https://api.github.com/repos/goharbor/harbor/releases?per_page=8`。**生产环境建议"紧随上一个稳定补丁"**（如 2.15.x 的最新补丁），不要追最新 GA 首版。

## 4. 镜像源最佳实践（containerd `certs.d`）

Harbor 全部组件镜像都在 `docker.io/goharbor/*`。**不要**改 chart 的镜像仓库地址，保持 `docker.io/...`，由 containerd 的 `certs.d` 做透明映射——这样保留主/备回退能力，且 chart 升级不受影响。

```bash
# 已配置则跳过（主备顺序按本机实测调整，见下）
sudo mkdir -p /etc/containerd/certs.d/docker.io
cat <<'EOF' | sudo tee /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://docker.io"

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# 若修改了配置才需要重启；重启会短暂影响共用 containerd 的 Docker 容器
sudo systemctl restart containerd
```

**选源方法（部署前必做）**：同一镜像源在不同机器上链路可能不同。先测再选：

```bash
for m in docker.m.daocloud.io docker.1ms.run; do
  printf '%s: ' "$m"
  timeout 120 ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d \
    "$m/library/alpine:3.20" >/dev/null 2>&1 && echo OK || echo FAIL
done
```

> 详见 [linux-kubernetes.md](linux-kubernetes.md) 4.2。**坑**：`ctr -n k8s.io images pull` 默认**不读** CRI 的 `config_path`，验证镜像源是否生效时必须加 `--hosts-dir /etc/containerd/certs.d`。

## 5. 安装步骤（手动，备查）

### 5.1 添加 Helm 仓库

```bash
helm repo add harbor https://helm.goharbor.io 2>/dev/null || echo "repo exists"
helm repo update harbor
helm search repo harbor/harbor --versions | head -3   # 确认能拿到 1.19.4
```

> 若 `helm.goharbor.io` 拉取慢，可 `helm pull harbor/harbor --version 1.19.4` 先下载 tgz，再 `helm install harbor ./harbor-1.19.4.tgz ...`。

### 5.2 values 模板

保存为 `harbor-values.yaml`（**含密码，勿提交仓库**；本仓库约定用 `.tmp-` 前缀）。参数含义见第 1 章。

```yaml
# Harbor values —— 参数区见第 1 章
expose:
  type: nodePort
  tls:
    enabled: true
    certSource: auto
    auto:
      commonName: 192.168.40.189          # 节点 IP（NodePort 模式必填）
  nodePort:
    ports:
      http:
        nodePort: 30002
      https:
        nodePort: 30003

externalURL: https://192.168.40.189:30003   # 含端口

harborAdminPassword: "<ADMIN_PASSWORD>"
secretKey: "<SECRET_KEY>"

trivy:
  enabled: false

persistence:
  enabled: true
  resourcePolicy: keep                 # helm delete 时保留 PVC
  persistentVolumeClaim:
    registry:
      storageClass: local-path
      size: 20Gi
    jobservice:
      jobLog:
        storageClass: local-path
        size: 2Gi
    database:
      storageClass: local-path
      size: 2Gi
    redis:
      storageClass: local-path
      size: 2Gi
    trivy:
      storageClass: local-path
      size: 5Gi

# 镜像 tag 统一覆盖为 v2.15.5（chart 1.19.4 原生为 v2.15.4）
nginx:   { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
portal:  { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
core:    { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
jobservice: { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
registry:
  registry:  { image: { tag: v2.15.5 } }
  controller: { image: { tag: v2.15.5 } }
  nodeSelector: { kubernetes.io/hostname: ubuntu }
database:
  internal: { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
redis:
  internal: { image: { tag: v2.15.5 }, nodeSelector: { kubernetes.io/hostname: ubuntu } }
# 注意：trivy 只在上面出现过一次（enabled: false），此处不要再重复 trivy 键
```

> **YAML 陷阱**：`trivy` 等键只能出现一次。若前半段写了 `trivy.enabled: false`、后半段又写 `trivy.image.tag`，后者会覆盖前者导致 Trivy 仍被部署（本次安装踩过）。上面的写法已合并，照抄即可。
> **节点固定**：`local-path` 是节点本地存储，把组件固定到同一节点可避免 Pod 漂移后 PVC 无法挂载（见 8.5）。`ubuntu` 请替换为 `PIN_NODE`。

### 5.3 渲染校验并安装（幂等）

**先渲染校验，再安装**——这一步能提前发现镜像 tag、trivy 开关、重复键等问题：

```bash
helm template harbor harbor/harbor --version 1.19.4 -n harbor -f harbor-values.yaml > /tmp/harbor-rendered.yaml
grep -oE 'image: [^ ]+' /tmp/harbor-rendered.yaml | sort -u      # 应全部为 v2.15.5
grep -c 'kind: StatefulSet' /tmp/harbor-rendered.yaml            # 应为 2（database / redis；trivy 已禁用）
grep -n 'harbor-trivy' /tmp/harbor-rendered.yaml                 # 仅应出现在 env / NO_PROXY 中

# 安装（或升级）
if helm -n harbor list | grep -q '^harbor'; then
  helm upgrade harbor harbor/harbor --version 1.19.4 -n harbor -f harbor-values.yaml
else
  helm install harbor harbor/harbor --version 1.19.4 -n harbor --create-namespace -f harbor-values.yaml
fi
```

### 5.4 等待就绪

```bash
kubectl -n harbor rollout status deploy/harbor-core --timeout=300s
kubectl -n harbor rollout status deploy/harbor-jobservice --timeout=300s
kubectl -n harbor get pods -o wide
```

> **正常现象**：`harbor-jobservice` 首次启动时 core 可能尚未就绪，会 `CrashLoopBackOff` 几次后自愈（日志为 `Failed on load rest config ... connection refused`）。若持续超过 5 分钟不恢复，按 8.1 排查。

## 6. 客户端配置与使用

### 6.1 提取 CA 并让 Docker 信任（每个客户端节点执行一次）

Harbor 用自签 CA 签发证书，Docker 默认不信任。把 CA 放到 Docker 的 `certs.d` 目录即可（**无需重启 Docker**）：

```bash
NODE_IP=192.168.40.189; PORT=30003
kubectl -n harbor get secret harbor-nginx -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/harbor-ca.crt
sudo mkdir -p /etc/docker/certs.d/${NODE_IP}:${PORT}
sudo cp /tmp/harbor-ca.crt /etc/docker/certs.d/${NODE_IP}:${PORT}/ca.crt
```

> 证书 CN/SAN 为节点 IP，所以 `docker login` 的地址必须用 **IP:端口**（用域名会因 SAN 不匹配报错）。

### 6.2 登录、建项目、推送与拉取

```bash
H=192.168.40.189:30003
docker login $H -u admin -p '<ADMIN_PASSWORD>'

# 建项目（API；Harbor 不会自动建 library，push 前必须先有项目）
curl -sk -u "admin:<ADMIN_PASSWORD>" -X POST "https://$H/api/v2.0/projects" \
  -H 'Content-Type: application/json' -d '{"project_name":"demo","public":false}'

# 推一个测试镜像
docker tag docker.m.daocloud.io/library/alpine:3.20 $H/demo/alpine:3.20
docker push $H/demo/alpine:3.20

# 拉回来验证
docker rmi $H/demo/alpine:3.20
docker pull $H/demo/alpine:3.20
```

### 6.3 健康检查

```bash
curl -sk -u "admin:<ADMIN_PASSWORD>" "https://192.168.40.189:30003/api/v2.0/health"
# 期望：{"status":"healthy","components":[core, database, jobservice, portal, redis, registry, registryctl]}
```

### 6.4 快速验证脚本（一键检查）

保存为 `harbor_verify.sh`，只读检查 + 一次 push/pull 冒烟，不修改集群配置。退出码 `0` = 通过（本次实测 **7/7 PASS**）。

```bash
#!/bin/bash
# Harbor 快速验证：服务 / 健康 / 证书 / 推送拉取
# 用法: ADMIN_PASSWORD=xxx bash harbor_verify.sh
set -u
HARBOR_HOST="${HARBOR_HOST:-192.168.40.189:30003}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?need ADMIN_PASSWORD}"
PASS=0; FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

chk "portal 可达"            "curl -sk -o /dev/null -w '%{http_code}' https://$HARBOR_HOST/ | grep -q 200"
chk "API systeminfo"        "curl -sk https://$HARBOR_HOST/api/v2.0/systeminfo | grep -q auth_mode"
chk "health healthy"        "curl -sk -u admin:$ADMIN_PASSWORD https://$HARBOR_HOST/api/v2.0/health | grep -q '\"status\":\"healthy\"'"
chk "证书 CN=节点IP"        "echo | openssl s_client -connect $HARBOR_HOST 2>/dev/null | openssl x509 -noout -subject | grep -q 192.168.40.189"
chk "全部 Pod Running"      "test \$(kubectl -n harbor get pods --no-headers | grep -c 'Running') -eq \$(kubectl -n harbor get pods --no-headers | wc -l)"
chk "PVC 全部 Bound"        "test -z \"\$(kubectl -n harbor get pvc --no-headers | grep -v Bound)\""

# push/pull 冒烟（先幂等建项目；已存在返回 409，忽略）
curl -sk -u "admin:$ADMIN_PASSWORD" -X POST "https://$HARBOR_HOST/api/v2.0/projects" \
  -H 'Content-Type: application/json' -d '{"project_name":"demo","public":false}' >/dev/null 2>&1
docker login "$HARBOR_HOST" -u admin -p "$ADMIN_PASSWORD" >/dev/null 2>&1 \
  && docker pull docker.m.daocloud.io/library/alpine:3.20 >/dev/null 2>&1 \
  && docker tag docker.m.daocloud.io/library/alpine:3.20 "$HARBOR_HOST/demo/alpine:verify" \
  && docker push "$HARBOR_HOST/demo/alpine:verify" >/dev/null 2>&1 \
  && docker rmi "$HARBOR_HOST/demo/alpine:verify" >/dev/null 2>&1 \
  && docker pull "$HARBOR_HOST/demo/alpine:verify" >/dev/null 2>&1 \
  && { echo "PASS: push/pull 冒烟"; PASS=$((PASS+1)); } \
  || { echo "FAIL: push/pull 冒烟"; FAIL=$((FAIL+1)); }

echo "=== 结果: $PASS 通过, $FAIL 失败 ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

> 冒烟会在 Harbor 里留下 `demo/alpine:verify`；验证完可删除：
> `curl -sk -u admin:$ADMIN_PASSWORD -X DELETE "https://$HARBOR_HOST/api/v2.0/projects/demo/repositories/alpine"`，再删项目 `demo`。

### 6.5 让 Kubernetes 从 Harbor 拉镜像

集群内 Pod 拉 `192.168.40.189:30003/...` 需要两件事：**信任 Harbor 自签 CA** + **拉取凭据**（项目默认私有）。

**1) 信任 CA**：在 containerd 的 `certs.d` 下为该仓库建目录（目录名 = `IP:端口`），用 `hosts.toml` 的 `ca` 指向 CA（也可用 `skip_verify = true` 跳过校验，仅测试环境）：

```bash
REG=192.168.40.189:30003
sudo mkdir -p /etc/containerd/certs.d/$REG
sudo tee /etc/containerd/certs.d/$REG/hosts.toml <<EOF
server = "https://$REG"

[host."https://$REG"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/$REG/ca.crt"
EOF
sudo cp /tmp/harbor-ca.crt /etc/containerd/certs.d/$REG/ca.crt
# 新增/修改 certs.d 下的配置一般无需重启 containerd（按需重新加载）；
# 若拉取仍报证书错误，再重启：sudo systemctl restart containerd（会影响共用 containerd 的 Docker）
```

**2) 拉取凭据**（推荐用 `imagePullSecrets`，不要把密码写进 hosts.toml）：

```bash
kubectl -n <your-ns> create secret docker-registry harbor-pull \
  --docker-server=192.168.40.189:30003 --docker-username=admin \
  --docker-password='<ADMIN_PASSWORD>'
# 在 Pod / ServiceAccount 上引用：
# imagePullSecrets: [{ name: harbor-pull }]
# 或设为命名空间默认：kubectl -n <your-ns> patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-pull"}]}'
```

> 若改用 hosts.toml 内嵌凭据，可加 `[host."https://$REG".auth] username = "..." password = "..."`（hosts.toml 支持 `server / capabilities / ca / client / skip_verify / auth / header / override_path`）。

### 6.6 admin 密码一致性检查（values / secret / DB）

**机制（重要）**：Harbor 的 admin 密码**以 DB 为准**。core 启动时若 DB 已有密码，会忽略 `HARBOR_ADMIN_PASSWORD`，日志见 `main.go:108`：

> `Admin password from config (HARBOR_ADMIN_PASSWORD) ignored: password already exists in database. Use Harbor UI or API to change.`

所以 values / secret 里的 `harborAdminPassword` **只在首次初始化生效**；重启 Pod、`helm upgrade` 都不会改密码。改密要么走 Harbor UI / API，要么直接改 DB。

只读一致性检查：

```bash
H=192.168.40.189:30003
# 1) values 里的密码
helm -n harbor get values harbor -o json | jq -r '.harborAdminPassword'
# 2) secret 里的密码
kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d; echo
# 3) 实测哪个密码能登录（权威判定）
curl -sk -o /dev/null -w '%{http_code}\n' -u "admin:<密码>" https://$H/api/v2.0/users/current   # 200=生效, 401=已失效
# 4) DB 里 admin 的密码版本 / 更新时间
kubectl -n harbor exec harbor-database-0 -- env PGPASSWORD=changeit \
  psql -U postgres -d registry -tAc \
  "SELECT username,password_version,update_time FROM harbor_user WHERE user_id=1;"
```

> **values/secret 与实际登录密码不一致时**：不影响登录（DB 为准），但「从 values 取回密码」的方法会失效，容易误判为「密码被改」。改密后建议同步 values + `helm upgrade`，保持三者一致。
>
> **经验：之前为什么误判为「密码被改」**
> - **现象**：某次登录突然 401，而 values / secret 里的 `harborAdminPassword` 明明没动过，看起来像「Harbor 把密码自动改了」。
> - **根因**：密码其实以 **DB 为准**；当时是有人**直接改了 DB**（或走了 GUI 改密），values/secret 仍是旧值，于是「values 里的密码」失效。Harbor **不会**自动重置密码。
> - **判据**：core 日志出现 `Admin password from config ... ignored: password already exists in database` 即证明 core 已忽略 values；再用上面第 3 步实测哪个密码能登录。
> - **结论**：遇到 401 先分清「DB 密码」与「values 密码」是两个来源，**别把 values 当权威**；改密要么走 UI/API，要么直改 DB 并同步 values。
>
> **直接改 DB 的哈希算法**（Harbor 2.15，源码 `src/common/utils/encrypt.go`）：
> `PBKDF2-HMAC-SHA256(password, salt, 600000, keylen=16) → hex`（32 字符），`password_version='pbkdf2_sha256'`。
> 注意 `salt` 是 32 位 hex 字符串，**按其 ASCII 字节**参与计算（不是 hex 解码成 16 字节）——实测只有 ASCII 口径能与 Harbor 校验对齐。

---

## 7. 最佳实践与踩坑总结（本次安装的实战经验）

> 换环境复用时**先通读本章**，可避开大部分坑。

| # | 实践 | 原因 / 做法 |
| --- | --- | --- |
| 1 | **chart 与 app 版本分开确认** | 官方仓库 chart 落后于 app（chart 1.19.4 ↔ app 2.15.4，而 app 已到 2.15.5/2.16.0）。用 `helm search repo` + GitHub Releases API 交叉核对；2.15.5 用覆盖 tag 的方式安装 |
| 2 | **先渲染再安装** | `helm template` 后核对：镜像 tag、StatefulSet 数量（2 或 3）、`WITH_TRIVY`；能提前发现重复键/开关失效 |
| 3 | **幂等安装** | 用 `helm -n harbor list` 判断 install / upgrade，脚本可重复执行 |
| 4 | **values 同一键只写一次** | YAML 重复键后者覆盖前者；`trivy` 写两处会让 `enabled: false` 失效，Trivy 仍被部署 |
| 5 | **镜像源用 containerd `certs.d` 透明映射** | 不改 chart 仓库地址，保留主/备回退；`docker.io` 主 `docker.1ms.run`、备 `docker.m.daocloud.io`（按节点实测调序） |
| 6 | **`ctr` 验证镜像源要加 `--hosts-dir`** | `ctr` 默认不读 CRI 的 `config_path`，不加会直连上游误判 |
| 7 | **`externalURL` 含端口** | NodePort 模式下必须是 `https://<节点IP>:<https端口>`，否则 token realm / 门户命令会指向错误端口 |
| 8 | **证书 CN = 节点 IP** | `expose.tls.auto.commonName` 必填；客户端必须用 **IP:端口** 访问（域名会 SAN 不匹配） |
| 9 | **客户端 CA 放 `certs.d/<IP:端口>/ca.crt`** | 无需重启 Docker；比 `insecure-registries` 更安全 |
| 10 | **组件固定调度到单节点** | `local-path` 是节点本地 PV，Pod 漂移会导致 PVC 无法挂载 → `Pending`；用 `nodeSelector` 固定到 `PIN_NODE` |
| 11 | **`resourcePolicy: keep`** | `helm uninstall` 默认删 PVC；设 keep 防误删数据，卸载时再手动删 |
| 12 | **密码/密钥随机生成且不入库** | `harborAdminPassword` / `secretKey` 用 `openssl rand -hex`；values 放 `.tmp-` 文件，勿提交 |
| 13 | **Trivy 默认关闭** | 首次扫描从 GitHub 下载漏洞库（几十 MB），国内可能慢/失败；按需开启 |
| 14 | **jobservice 启动竞争自愈** | 首次 `CrashLoopBackOff` 属正常（core 未就绪），不要急着"修"；看日志 `connection refused` 即此因 |
| 15 | **push 前先建项目** | Harbor 不会自动建 `library`；用 API `POST /api/v2.0/projects` 建项目 |
| 16 | **冒烟后清理测试产物** | 删 `demo` 项目需先删仓库（`DELETE /projects/demo/repositories/alpine`），否则 412 |
| 17 | **集群内拉取要配 `ca` + 凭据** | 自签 CA 要进 containerd `certs.d`；私有项目要 `imagePullSecrets` |
| 18 | **admin 密码以 DB 为准，不会自动重置** | core 启动检测到 DB 已有密码就忽略 `HARBOR_ADMIN_PASSWORD`（日志 `main.go:108`）；values/secret 仅在首次初始化生效。改密走 UI/API 或直改 DB，改 values 无效。详见 6.6 |

---

## 8. 排障

### 8.1 jobservice 反复重启（CrashLoopBackOff）

```bash
kubectl -n harbor logs -l component=jobservice --tail=30 --previous
kubectl -n harbor describe pod -l component=jobservice | tail -20
```

- 日志出现 `Failed on load rest config ... connection refused`（`harbor-core:80`）→ core 当时未就绪，属启动竞争，等待自愈；若 core 本身不健康，先修 core。
- 日志出现数据库/Redis 连接失败 → 检查 `harbor-database-0` / `harbor-redis-0` 是否 Ready，以及 PVC 是否 Bound。

### 8.2 镜像拉取失败（ImagePullBackOff）

```bash
kubectl -n harbor describe pod <pod>        # 看 Events 真实拉取地址与错误
```

- `docker.io` 超时/407 → 检查 `/etc/containerd/certs.d/docker.io/hosts.toml` 主备顺序，按 [linux-kubernetes.md](linux-kubernetes.md) 4.2 选源方法重测后重启 containerd。
- `manifest unknown / not found` → 确认 `HARBOR_VERSION` 镜像真实存在（`ctr ... --hosts-dir /etc/containerd/certs.d docker.io/goharbor/harbor-core:<tag>`）。

### 8.3 证书 / 登录报错（x509）

```bash
echo | openssl s_client -connect 192.168.40.189:30003 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```

- `x509: certificate is valid for ..., not for ...` → 用了域名而非 IP 访问，或 `expose.tls.auto.commonName` 与实际地址不一致。
- `certificate signed by unknown authority` → 客户端未导入 CA（见 6.1）。

### 8.4 HTTP 端口跳转不带端口

`http://192.168.40.189:30002/` 会 301 跳转到 `https://192.168.40.189/...`（**不含 NodePort**），而 443 上没有监听，浏览器会失败。这是 chart 的固定行为（`return 301 https://$host$request_uri;`）。**请使用 `https://192.168.40.189:30003` 直接访问**，或改用 Ingress 暴露。

### 8.5 存储：local-path 的节点绑定

`local-path` 是**节点本地**存储，PV 带节点亲和。若 Pod 漂移到另一节点，原 PVC 无法挂载 → Pod `Pending`。因此 values 里用 `nodeSelector` 把 Harbor 组件固定到 `PIN_NODE`。
若要去掉固定，需改用 RWX/对象存储（S3/OSS/MinIO）或外部数据库/Redis，并自行处理多副本。

### 8.6 Trivy

默认 `trivy.enabled=false`。启用时首次扫描会从 GitHub 下载漏洞库（几十 MB，国内可能慢/失败）：

```yaml
trivy:
  enabled: true
```

启用后若扫描报 `trivy-adapter` 相关错误，检查 `kubectl -n harbor logs -l component=trivy`，必要时配置 `SCANNER_TRIVY_DB_REPOSITORY` / 代理，或预置漏洞库。**注意 values 里 `trivy` 键只能有一个**（见 5.2 陷阱）。

### 8.7 证书到期

自签证书有效期 1 年（`harbor-ca`）。到期前轮换：删除 secret `harbor-nginx` 触发 chart 重签，或改用正式证书（`expose.tls.certSource: secret` + `expose.tls.secret.secretName`），避免长期依赖自签。

### 8.8 登录 401 / 误以为「admin 密码被改」

```bash
# 1) core 是否忽略了 values 里的密码
kubectl -n harbor logs deploy/harbor-core | grep 'password already exists'
# 2) 实测候选密码（200=生效，401=失效）
curl -sk -o /dev/null -w '%{http_code}\n' -u "admin:<候选密码>" https://192.168.40.189:30003/api/v2.0/users/current
# 3) 看 DB 密码版本 / 更新时间
kubectl -n harbor exec harbor-database-0 -- env PGPASSWORD=changeit \
  psql -U postgres -d registry -tAc \
  "SELECT username,password_version,update_time FROM harbor_user WHERE user_id=1;"
```

- core 日志有 `Admin password from config (HARBOR_ADMIN_PASSWORD) ignored: password already exists in database` → 密码**以 DB 为准**，values/secret 不生效，**不是被自动改**（机制见 6.6）。
- DB `update_time` 比 values 修改时间新 → 说明有人改过 DB（GUI / API / 直接 `UPDATE`）。
- 处理：用 UI/API 改密，或按 6.6 直改 DB（注意 salt 按 ASCII 口径）；改完同步 values + `helm upgrade`。

---

## 9. Agent 执行注意事项

- **先检查再执行**：第 2 章全只读；`helm -n harbor list` 有记录就走 `upgrade`，不要重复 `install`。
- **参数先确认**：执行前向用户确认第 1 章参数（尤其 `NODE_IP`、`PIN_NODE`、`ADMIN_PASSWORD`、`TRIVY_ENABLED`）。
- **优先用一键脚本**：`kubernetes-harbor-install.sh` 已封装检查/校验/安装/验证全流程；手动分步用于排障。
- **密码与密钥**：`harborAdminPassword` / `secretKey` 必须随机生成，写入 values 文件且**不要提交仓库**（本仓库用 `.tmp-` 前缀）；汇报时告知用户密码位置。
- **危险操作必须确认**：`systemctl restart containerd`（影响 Docker 业务容器）、`helm uninstall`、删除 PVC/项目，逐项征求同意。
- **YAML 重复键**：values 中同一键只能出现一次（尤其 `trivy`），改完用 `helm template` 核对渲染结果。
- **失败即停**：拉取失败先按第 8.2 看 Events 真实地址，不盲目重试。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 10. 卸载（可选，破坏性，需用户确认）

```bash
# 1) 卸载 release（PVC 因 resourcePolicy=keep 会保留，需手动删）
helm -n harbor uninstall harbor

# 2) 删除残留 PVC / 命名空间
kubectl -n harbor delete pvc --all
kubectl delete ns harbor

# 3) 清理客户端信任与本地测试镜像（各客户端节点）
sudo rm -rf /etc/docker/certs.d/192.168.40.189:30003
```

> `resourcePolicy: keep` 意味着 `helm uninstall` **不会**删 PVC；确认不再需要数据后再手动删。

## 11. 复用 checklist 与已知遗留

**换环境复用清单（逐项确认）**

- [ ] 集群已就绪（kubectl/helm 可用、节点 Ready、有默认 StorageClass）。
- [ ] `NODE_IP` = 对外可访问的节点 IP；`PIN_NODE` = 该节点 hostname（local-path 场景）。
- [ ] NodePort `30002/30003` 未被其它命名空间占用。
- [ ] containerd `certs.d/docker.io` 已配并**按本机实测**定主备顺序。
- [ ] 版本：`HARBOR_VERSION` 与 `CHART_VERSION` 已交叉核对（见 3.2）。
- [ ] `ADMIN_PASSWORD` / `SECRET_KEY` 已生成，values 文件不入库。
- [ ] 渲染校验通过（镜像 tag / StatefulSet 数量 / `WITH_TRIVY`）。
- [ ] 安装后跑 `harbor_verify.sh`（应 7/7 PASS）。
- [ ] 客户端已导入 CA；集群内拉取已配 `certs.d/<IP:端口>` + `imagePullSecrets`（如需）。
- [ ] 记录访问地址/账号/密码/CA 路径与 values 文件位置。

**已知遗留**

- `harbor-jobservice` 首次启动可能重启数次（启动竞争），会自愈；`RESTARTS` 计数非 0 不代表异常。
- HTTP NodePort `30002` 跳转不带端口（见 8.4），正式访问用 `30003`。
- Trivy 默认关闭；启用需处理漏洞库下载。
- 存储为单节点 `local-path`，非高可用；组件固定调度到 `PIN_NODE`。
- 证书为自签（`harbor-ca`，有效期 1 年），到期需轮换（见 8.7）。
