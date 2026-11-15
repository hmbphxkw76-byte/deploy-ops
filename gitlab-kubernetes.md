# GitLab on Kubernetes 部署文档

> 目标：在现有 Kubernetes 集群上部署最新稳定版 GitLab（极狐 GitLab / JiHu GitLab），镜像源优先使用国内源，使用官方 Helm Chart 与外置 PostgreSQL / Redis / MinIO，并提供可复用的安装、验证、排障与卸载流程。
>
> 本文基于 2026-11-15 的实际部署记录整理。部署时集群为 Kubernetes v1.37.2，控制面节点 `ubuntu`（192.168.40.189，24C/62G），另有工作节点 `ubunt-dev`（8C/17G）。

---

## 0. 复用指南（先读这里）

本节面向后续重复安装与迁移。首次部署、升级或在新集群复用时，只修改下面的参数区，然后按第 3 章顺序执行即可。

### 0.1 参数区

```bash
# ---- 目标集群与节点 ----
NODE_NAME="ubuntu"                 # GitLab 主组件固定调度的节点名
CLUSTER_HOST="192.168.40.189"     # 集群对外 IP

# ---- GitLab 访问 ----
GITLAB_NS="gitlab"
GITLAB_PORT="30080"              # 宿主机 hostPort，需避开 80/8080/22/6443 等
GITLAB_URL="http://${CLUSTER_HOST}:${GITLAB_PORT}"

# ---- 版本 ----
GITLAB_VERSION="19.5.5"          # 极狐 GitLab 应用版本
CHART_VERSION="10.5.6"            # gitlab-cn/gitlab Chart 版本
POSTGRES_IMAGE="docker.m.daocloud.io/library/postgres:17-bookworm"
REDIS_IMAGE="docker.m.daocloud.io/library/redis:8-bookworm"

# ---- 工作目录 ----
WORK_DIR="/root/gitlab-deploy"
```

> 复用原则：标准配置进入 Helm values；必要的安装后补丁集中记录在第 3.8 节，升级后必须重放。不要临时手改集群对象而不回写文档。

### 0.2 前置检查（一键执行）

```bash
set -euo pipefail

# 1) 集群与节点
kubectl get nodes -o wide
kubectl get sc

# 2) Helm 版本（建议 3.18+）
helm version --short

# 3) 端口冲突检查：30080 必须可用
if ss -ltnp | grep -q ':30080\b'; then
  echo "ERROR: 30080 已被占用" >&2
  exit 1
fi

# 4) 镜像源连通性
for u in \
  https://registry.gitlab.cn/v2/ \
  https://docker.m.daocloud.io/v2/ \
  https://dl.minio.org.cn/server/minio/release/linux-amd64/minio; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$u" || true)
  echo "$u -> $code"
done

# 5) 确认参数
echo "NODE_NAME=$NODE_NAME CLUSTER_HOST=$CLUSTER_HOST GITLAB_PORT=$GITLAB_PORT"
read -r -p "参数确认无误？[y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || exit 1
```

### 0.3 复用步骤（按顺序执行）

1. **安装 local-path-provisioner**：第 3.1 节。
2. **准备密码与依赖清单**：第 3.2 节。密码必须随机生成，禁止写入 Git。
3. **构建 MinIO 本地镜像**：第 3.3 节。若已有 `gitlab-minio:local` 可跳过。
4. **部署 PostgreSQL / Redis / MinIO**：第 3.4 节。PostgreSQL 必须带 `max_locks_per_transaction=256`。
5. **准备 GitLab values 与对象存储 Secret**：第 3.5、3.6 节。
6. **安装 / 升级 GitLab**：第 3.7 节。
7. **执行安装后补丁**：第 3.8 节。这一步是复用成败关键，不能跳过。
8. **验收**：第 4 章。健康检查、root 登录、MinIO 桶、对象存储配置全部通过后才算完成。

### 0.4 最佳实践清单

- **版本固定**：`global.gitlabVersion` 与 Chart 版本同时固定，不用 `latest`；升级前先看 Chart release notes。
- **镜像国内源优先**：GitLab 用 `registry.gitlab.cn/cng-images`；PostgreSQL / Redis 用 `docker.m.daocloud.io/library`；MinIO 用 `dl.minio.org.cn` 二进制。
- **依赖外置**：PostgreSQL 17、Redis 8、MinIO 独立部署，避免使用 Chart 外部默认值或嵌入式数据库。
- **存储声明**：所有有状态组件使用 `local-path` 并固定容量；生产环境替换为共享存储。
- **密码随机化**：PostgreSQL / Redis / MinIO / GitLab root 全部随机生成，保存到 Secret 或本地 `.secrets`，不入库。
- **副本最小化**：实验环境 webservice 固定 1 副本，避免 `hostPort` 冲突；生产环境去掉 `hostPort`，改用 Ingress/LoadBalancer。
- **HPA 与 hostPort 冲突**：使用 `hostPort` 时必须把对应 HPA 的 `maxReplicas` 固定为 1。
- **配置与补丁分离**：Chart values 负责标准配置；`hostPort`、ConfigMap 端口等补丁集中记录，升级后重放。
- **先验证后交付**：健康检查、root 登录、对象存储、MinIO 桶、迁移状态全部通过后才交付。

### 0.5 验收标准

- `kubectl -n gitlab get pods` 全部 `Running`/`Completed`，无长期 `CrashLoopBackOff`。
- `/-/health`、`/-/readiness`、`/-/liveness` 返回 `200`。
- `/users/sign_in` 返回 `200`，root 可登录并进入 `/dashboard/projects`。
- PostgreSQL `schema_migrations` 迁移完整，无失败 Job。
- MinIO 7 个桶全部存在。
- GitLab `gitlab.yml` 中 `object_store.enabled=true` 且 endpoint 正确。

### 0.6 复用安装脚本（文件就绪后直接执行）

前提：`/root/gitlab-deploy/` 下已存在 `dependencies.yaml`、`gitlab-values.yaml`、对象存储连接文件与 MinIO 本地镜像。首次部署按第 3 章生成这些文件；之后重新安装、修复或升级可直接运行本脚本。

```bash
set -euo pipefail

# ---- 参数 ----
GITLAB_NS="gitlab"
NODE_NAME="ubuntu"
CLUSTER_HOST="192.168.40.189"
GITLAB_PORT="30080"
CHART_VERSION="10.5.6"
WORK_DIR="/root/gitlab-deploy"

# ---- 1. 存储 ----
if ! kubectl get sc local-path >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml -o /tmp/local-path-storage.yaml
  sed -i 's#image: rancher/local-path-provisioner:v0.0.31#image: docker.m.daocloud.io/rancher/local-path-provisioner:v0.0.31#' /tmp/local-path-storage.yaml
  kubectl apply -f /tmp/local-path-storage.yaml
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
fi
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null 2>&1 || true

# ---- 2. 依赖 ----
kubectl create namespace "$GITLAB_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$GITLAB_NS" apply -f "$WORK_DIR/manifests/dependencies.yaml"
kubectl -n "$GITLAB_NS" wait --for=condition=ready pod -l app=postgresql --timeout=300s
kubectl -n "$GITLAB_NS" wait --for=condition=ready pod -l app=redis-master --timeout=300s
kubectl -n "$GITLAB_NS" wait --for=condition=ready pod -l app=minio --timeout=300s

# ---- 3. GitLab ----
helm repo add gitlab-cn https://charts.gitlab.cn/ >/dev/null 2>&1 || true
helm repo update gitlab-cn >/dev/null 2>&1 || true
helm upgrade --install gitlab gitlab-cn/gitlab \
  --version "$CHART_VERSION" \
  -n "$GITLAB_NS" \
  -f "$WORK_DIR/gitlab-values.yaml" \
  --timeout 900s

# ---- 4. 安装后补丁（必需） ----
kubectl -n "$GITLAB_NS" patch deployment gitlab-webservice-default --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/ports/0/hostPort","value":'"$GITLAB_PORT"'}
]'
kubectl -n "$GITLAB_NS" scale deploy gitlab-webservice-default --replicas=1
kubectl -n "$GITLAB_NS" patch hpa gitlab-webservice-default -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'

export CLUSTER_HOST GITLAB_PORT
python3 - <<'PY'
import json, os, subprocess, sys
host = os.environ["CLUSTER_HOST"]
port = os.environ["GITLAB_PORT"]
for name in ["gitlab-webservice", "gitlab-sidekiq"]:
    raw = subprocess.check_output(["kubectl", "-n", "gitlab", "get", "configmap", name, "-o", "json"])
    obj = json.loads(raw)
    key = "gitlab.yml.erb"
    text = obj["data"][key]
    old = f"  gitlab:\n    host: {host}\n"
    new = f"  gitlab:\n    host: {host}\n    port: {port}\n"
    if f"    port: {port}\n" not in text:
        if old not in text:
            print("host line not found in", name, file=sys.stderr)
            sys.exit(1)
        obj["data"][key] = text.replace(old, new, 1)
        subprocess.run(["kubectl", "-n", "gitlab", "apply", "-f", "-"],
                       input=json.dumps(obj).encode(), check=True)
        print("patched", name)
PY

kubectl -n "$GITLAB_NS" delete pod -l app=webservice --force --grace-period=0 >/dev/null 2>&1 || true
kubectl -n "$GITLAB_NS" delete pod -l app=sidekiq --force --grace-period=0 >/dev/null 2>&1 || true

# ---- 5. 验证 ----
for p in -/health -/readiness -/liveness; do
  printf '%s ' "$p"
  curl -sS -o /dev/null -w 'http=%{http_code}\n' --max-time 10 "http://${CLUSTER_HOST}:${GITLAB_PORT}/$p"
done
curl -sS -L -o /dev/null -w 'login_page=%{http_code}\n' --max-time 20 "http://${CLUSTER_HOST}:${GITLAB_PORT}/users/sign_in"
kubectl -n "$GITLAB_NS" get pods -o wide
echo "GitLab URL: http://${CLUSTER_HOST}:${GITLAB_PORT}"
```

> 该脚本为幂等设计：已存在的 StorageClass、Secret、Deployment、Helm release 都会复用或升级；安装后补丁会重复执行，确保漂移被纠正。

---

## 1. 最终架构

| 组件 | 版本 | 部署方式 | 存储 | 备注 |
|---|---|---|---|---|
| GitLab（JiHu GitLab） | v19.5.5（Chart 10.5.6） | Helm Chart `gitlab-cn/gitlab` | Gitaly `local-path` 20Gi；Toolbox `local-path` 5Gi | 主组件固定在控制面节点 `ubuntu` |
| PostgreSQL | 17.6.0（`docker.m.daocloud.io/library/postgres:17-bookworm`） | 自维护 Deployment | `local-path` 10Gi | 调度在 `ubunt-dev`，需保证该节点稳定 |
| Redis | 8.10.3（`docker.m.daocloud.io/library/redis:8-bookworm`） | 自维护 Deployment | `local-path` 2Gi | 调度在 `ubunt-dev` |
| MinIO | RELEASE.2025-07-23T15-23-15Z | 本地构建镜像 `gitlab-minio:local` | `local-path` 10Gi | 提供 LFS / Artifacts / Uploads / Packages / Backups 桶 |
| ingress-nginx | 未启用 | - | - | 宿主机 80/8080 已被占用，改用 `hostPort: 30080` |
| cert-manager | 未启用 | - | - | 当前为 HTTP；生产环境建议接入证书与 HTTPS |
| GitLab Runner | 未启用 | - | - | 需要时再安装并注册 |
| Prometheus | 未启用 | - | - | 需要时再启用 |

### 1.1 访问地址

- Web：`http://192.168.40.189:30080`
- 登录名：`root`
- 初始密码：从 Secret 读取（见第 6 节）
- Git HTTP clone：`http://192.168.40.189:30080/<namespace>/<project>.git`
- Git SSH clone：当前未单独暴露 22 端口；如需 SSH，可另行将 `gitlab-shell` 服务暴露为 NodePort，并在客户端使用 `ssh://git@192.168.40.189:<port>/<namespace>/<project>.git`。

### 1.2 关键设计决策

1. **使用极狐 GitLab（JiHu GitLab）Chart 10.5.6**：这是当前 `charts.gitlab.cn` 提供的最新稳定版，应用版本 `v19.5.5`，默认镜像来自 `registry.gitlab.cn/cng-images`，国内拉取稳定。官方 `charts.gitlab.io` 在本机网络下不稳定。
2. **外置依赖**：GitLab 19 的 Chart 不再内置 PostgreSQL / Redis / MinIO，因此单独部署 PostgreSQL 17、Redis 8、MinIO。
3. **镜像源**：PostgreSQL / Redis 使用 `docker.m.daocloud.io/library/...`；MinIO 官方镜像在 2025-10 后停止更新且国内镜像源不稳定，因此从 `dl.minio.org.cn` 下载二进制并基于已有本地镜像构建 `gitlab-minio:local`。
4. **存储**：使用 `local-path-provisioner` 作为默认 StorageClass。单节点/双节点实验环境足够；生产环境建议换成 NFS/Ceph/Rook 等共享存储。
5. **网络暴露**：宿主机 80 端口已被 `aivp-web-1` 占用，8080 端口已有 Docker GitLab 容器占用，因此 Kubernetes GitLab 使用 `hostPort: 30080`，并把 GitLab 的 `gitlab.host` 设为 `192.168.40.189`、`gitlab.port` 设为 `30080`。
6. **副本数**：`gitlab-webservice` 固定为 1 副本，避免 `hostPort` 冲突；HPA `gitlab-webservice-default` 的 `maxReplicas` 也固定为 1。

---

## 2. 前置条件

### 2.1 集群与节点

```bash
kubectl get nodes -o wide
kubectl get sc
```

要求：

- Kubernetes >= 1.30（本次为 v1.37.2）
- 至少一个可调度节点；GitLab 主组件通过 `global.nodeSelector` 固定在 `kubernetes.io/hostname=ubuntu`
- 默认 StorageClass 存在；本部署使用 `local-path`
- Helm 3.18+（本次为 v3.22.1；Chart 提示 Helm 4 更佳）
- 节点可访问 `registry.gitlab.cn`、`docker.m.daocloud.io`、`dl.minio.org.cn`

### 2.2 端口与冲突检查

```bash
ss -ltnp | grep -E ':80\b|:8080\b|:30080\b|:5000\b'
```

本部署要求：

- `30080` 可用（GitLab Web `hostPort`）
- `9000` / `9001` 仅集群内部使用，不要求宿主机暴露
- 不与现有 Docker 容器、NodePort 服务冲突

### 2.3 镜像源连通性（可选）

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://registry.gitlab.cn/v2/
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://docker.m.daocloud.io/v2/
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://dl.minio.org.cn/server/minio/release/linux-amd64/minio
```

---

## 3. 一键部署步骤（幂等）

以下命令在目标节点上执行。假设：

- 工作目录：`/root/gitlab-deploy`
- 命名空间：`gitlab`
- 控制面节点名：`ubuntu`
- 对外地址：`192.168.40.189:30080`

### 3.1 安装 local-path-provisioner

```bash
set -e
curl -fsSL https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml -o /tmp/local-path-storage.yaml
sed -i 's#image: rancher/local-path-provisioner:v0.0.31#image: docker.m.daocloud.io/rancher/local-path-provisioner:v0.0.31#' /tmp/local-path-storage.yaml
kubectl apply -f /tmp/local-path-storage.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 3.2 准备目录、密码与依赖清单

```bash
mkdir -p /root/gitlab-deploy/manifests /root/gitlab-deploy/minio-build
```

生成随机密码并保存到 `/root/gitlab-deploy/.secrets`（该文件不要提交到 Git）：

```bash
cat > /root/gitlab-deploy/.secrets <<'EOF'
PG_PASS=<生成值>
REDIS_PASS=<生成值>
MINIO_PASS=<生成值>
EOF
source /root/gitlab-deploy/.secrets
```

依赖清单模板见本文附录 A。将其保存为 `/root/gitlab-deploy/manifests/dependencies.yaml`，并将模板中的 `PGPASS` / `REDISPASS` / `MINIOPASS` 替换为实际值：

```bash
sed -i "s/PGPASS/${PG_PASS}/g" /root/gitlab-deploy/manifests/dependencies.yaml
sed -i "s/REDISPASS/${REDIS_PASS}/g" /root/gitlab-deploy/manifests/dependencies.yaml
sed -i "s/MINIOPASS/${MINIO_PASS}/g" /root/gitlab-deploy/manifests/dependencies.yaml
```

### 3.3 构建 MinIO 本地镜像（如本地已有可跳过）

```bash
set -e
cd /root/gitlab-deploy/minio-build
curl -fsSL -o minio https://dl.minio.org.cn/server/minio/release/linux-amd64/minio
curl -fsSL -o mc https://dl.minio.org.cn/client/mc/release/linux-amd64/mc
chmod +x minio mc
cat > Dockerfile <<'EOF'
FROM docker.m.daocloud.io/rancher/local-path-provisioner:v0.0.31
COPY minio /usr/local/bin/minio
COPY mc /usr/local/bin/mc
ENTRYPOINT ["/usr/local/bin/minio"]
EOF
docker build -t gitlab-minio:local .
docker save gitlab-minio:local | ctr -n k8s.io images import -
```

> 说明：`docker.m.daocloud.io/rancher/local-path-provisioner:v0.0.31` 是已验证可拉取的国内基础镜像；MinIO 二进制来自官方国内下载域 `dl.minio.org.cn`。

### 3.4 部署 PostgreSQL / Redis / MinIO

```bash
set -e
kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f /root/gitlab-deploy/manifests/dependencies.yaml

# PostgreSQL 关键参数：GitLab 迁移需要更大的锁表
kubectl -n gitlab patch deployment postgresql --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["docker-entrypoint.sh"]},
  {"op":"add","path":"/spec/template/spec/containers/0/args","value":["postgres","-c","max_locks_per_transaction=256","-c","shared_buffers=512MB","-c","max_connections=200"]}
]'

kubectl -n gitlab rollout status deploy/postgresql --timeout=300s
kubectl -n gitlab rollout status deploy/redis-master --timeout=300s
kubectl -n gitlab rollout status deploy/minio --timeout=300s
kubectl -n gitlab wait --for=condition=complete job/minio-buckets --timeout=300s
```

> 注意：如果 `postgresql` Service 被同名 Helm release 删除过，需要重新创建：
> ```bash
> kubectl -n gitlab expose deployment postgresql --port=5432 --target-port=5432 --name=postgresql
> ```

### 3.5 准备 GitLab values

完整模板见附录 B。核心配置：

```yaml
global:
  edition: jh
  gitlabVersion: "19.5.5"
  security:
    allowInsecureImages: true
  nodeSelector:
    kubernetes.io/hostname: ubuntu
  hosts:
    domain: ""
    externalIP: 192.168.40.189
    https: false
    ssh: 192.168.40.189
    gitlab:
      name: 192.168.40.189
    registry:
      name: 192.168.40.189
  ingress:
    enabled: false
    configureCertmanager: false
    tls:
      enabled: false
  psql:
    host: postgresql.gitlab.svc.cluster.local
    port: 5432
    username: gitlab
    database: gitlabhq_production
    password:
      secret: gitlab-postgres
      key: password
      useSecret: true
    main:
      database: gitlabhq_production
      databaseTasks: true
    ci:
      database: gitlabhq_production
      databaseTasks: false
  redis:
    host: redis-master.gitlab.svc.cluster.local
    port: 6379
    auth:
      enabled: true
      secret: gitlab-redis
      key: redis-password
  appConfig:
    object_store:
      enabled: true
      connection:
        secret: gitlab-object-storage
        key: connection
      proxy_download: true
    lfs:
      bucket: git-lfs
    artifacts:
      bucket: gitlab-artifacts
    uploads:
      bucket: gitlab-uploads
    packages:
      bucket: gitlab-packages

installCertmanager: false
prometheus:
  install: false
gitlab-runner:
  install: false
nginx-ingress:
  enabled: false

registry:
  enabled: false

gitlab:
  gitaly:
    replicaCount: 1
    persistence:
      storageClass: local-path
      size: 20Gi
  toolbox:
    replicaCount: 1
    persistence:
      storageClass: local-path
      size: 5Gi
```

### 3.6 创建对象存储 Secret

```bash
kubectl -n gitlab create secret generic gitlab-object-storage \
  --from-file=connection=/root/gitlab-deploy/object-storage-connection.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n gitlab create secret generic gitlab-registry-storage \
  --from-file=config=/root/gitlab-deploy/registry-storage-config.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n gitlab create secret generic gitlab-backup-storage \
  --from-file=config=/root/gitlab-deploy/backup-s3cfg \
  --dry-run=client -o yaml | kubectl apply -f -
```

对象存储连接文件内容（不要把真实密码写入 Git）：

```yaml
provider: AWS
region: us-east-1
endpoint: http://minio.gitlab.svc.cluster.local:9000
aws_access_key_id: gitlab
aws_secret_access_key: <MINIO_PASS>
```

Registry 存储配置：

```yaml
s3:
  region: us-east-1
  bucket: gitlab-registry
  accesskey: gitlab
  secretkey: <MINIO_PASS>
  regionendpoint: http://minio.gitlab.svc.cluster.local:9000
  secure: false
```

### 3.7 安装 / 升级 GitLab

```bash
helm repo add gitlab-cn https://charts.gitlab.cn/ || true
helm repo update gitlab-cn
helm upgrade --install gitlab gitlab-cn/gitlab \
  --version 10.5.6 \
  -n gitlab \
  -f /root/gitlab-deploy/gitlab-values.yaml \
  --timeout 900s
```

> 如果之前有失败或残留 release，先清理：
> ```bash
> helm uninstall gitlab -n gitlab || true
> ```

### 3.8 安装后补丁（必需）

#### 3.8.1 为 GitLab Web 开放宿主机 30080

```bash
kubectl -n gitlab patch deployment gitlab-webservice-default --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/ports/0/hostPort","value":30080}
]'
```

#### 3.8.2 固定 webservice 副本数与 HPA

```bash
kubectl -n gitlab scale deploy gitlab-webservice-default --replicas=1
kubectl -n gitlab patch hpa gitlab-webservice-default -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
```

#### 3.8.3 让 GitLab 使用 30080 作为对外端口

GitLab Chart 的 `gitlab.yml` 模板不直接暴露 `gitlab.port`，需要给 ConfigMap 增加一行：

```bash
python3 - <<'PY'
import json, subprocess, sys
for name in ["gitlab-webservice", "gitlab-sidekiq"]:
    raw = subprocess.check_output(["kubectl", "-n", "gitlab", "get", "configmap", name, "-o", "json"])
    obj = json.loads(raw)
    key = "gitlab.yml.erb"
    text = obj["data"][key]
    old = "  gitlab:\n    host: 192.168.40.189\n"
    new = "  gitlab:\n    host: 192.168.40.189\n    port: 30080\n"
    if "    port: 30080\n" not in text:
        if old not in text:
            print("host line not found in", name, file=sys.stderr)
            sys.exit(1)
        obj["data"][key] = text.replace(old, new, 1)
        subprocess.run(["kubectl", "-n", "gitlab", "apply", "-f", "-"],
                       input=json.dumps(obj).encode(), check=True)
        print("patched", name)
PY

kubectl -n gitlab delete pod -l app=webservice --force --grace-period=0
kubectl -n gitlab delete pod -l app=sidekiq --force --grace-period=0
```

---

## 4. 一键验证脚本

```bash
set -e
echo "== pods =="
kubectl -n gitlab get pods -o wide

echo "== health =="
for p in -/health -/readiness -/liveness; do
  printf '%s ' "$p"
  curl -sS -o /dev/null -w 'http=%{http_code}\n' --max-time 10 "http://192.168.40.189:30080/$p"
done

echo "== login page =="
curl -sS -L -o /dev/null -w 'http=%{http_code} final=%{url_effective}\n' \
  --max-time 20 "http://192.168.40.189:30080/users/sign_in"

echo "== root password =="
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d
echo

echo "== minio buckets =="
MINIO_PASS=$(kubectl -n gitlab get secret gitlab-minio -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n gitlab exec deploy/minio -- /usr/local/bin/mc alias set local \
  http://127.0.0.1:9000 gitlab "$MINIO_PASS" >/dev/null
kubectl -n gitlab exec deploy/minio -- /usr/local/bin/mc ls local

echo "== object store config =="
kubectl -n gitlab exec gitlab-webservice-default-$(kubectl -n gitlab get pod -l app=webservice -o jsonpath='{.items[0].metadata.name}' | cut -d- -f4-) \
  -c webservice -- grep -A8 'object_store:' /srv/gitlab/config/gitlab.yml | head -12
```

### 4.1 root 登录验证

```bash
PASS=$(kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d)
rm -f /tmp/gitlab-cookies.txt
curl -sS -c /tmp/gitlab-cookies.txt -b /tmp/gitlab-cookies.txt -o /tmp/gitlab-login.html \
  http://192.168.40.189:30080/users/sign_in
TOKEN=$(grep -o 'csrf-token" content="[^"]*' /tmp/gitlab-login.html | head -1 | sed 's/.*content="//')
curl -sS -c /tmp/gitlab-cookies.txt -b /tmp/gitlab-cookies.txt -X POST \
  http://192.168.40.189:30080/users/sign_in \
  --data-urlencode "authenticity_token=${TOKEN}" \
  --data-urlencode "user[login]=root" \
  --data-urlencode "user[password]=${PASS}" \
  -o /dev/null -w 'http=%{http_code}\n'
curl -sS -c /tmp/gitlab-cookies.txt -b /tmp/gitlab-cookies.txt -L \
  -o /tmp/gitlab-home.html http://192.168.40.189:30080/
grep -o '<title>[^<]*</title>' /tmp/gitlab-home.html | head -1
```

预期结果：标题为 `Projects · JiHu GitLab`，说明 root 登录成功。

---

## 5. 当前部署的验证结果

- `http://192.168.40.189:30080/-/health`：200
- `/-/readiness`：200
- `/-/liveness`：200
- `http://192.168.40.189:30080/users/sign_in`：200
- root 登录后跳转到 `/dashboard/projects`，页面标题 `Projects · JiHu GitLab`
- PostgreSQL 数据库迁移完成，`schema_migrations` 记录数 1396
- MinIO 桶：`git-lfs`、`gitlab-artifacts`、`gitlab-backups`、`gitlab-packages`、`gitlab-registry`、`gitlab-tmp`、`gitlab-uploads`
- GitLab `gitlab.yml` 中 `object_store.enabled=true`，endpoint 为 `http://minio.gitlab.svc.cluster.local:9000`

---

## 6. 密码与密钥获取

所有敏感信息都保存在 Kubernetes Secret 中，不要写入 Git。

```bash
# GitLab root 初始密码
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo

# PostgreSQL
kubectl -n gitlab get secret gitlab-postgres -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n gitlab get secret gitlab-postgres -o jsonpath='{.data.postgres-password}' | base64 -d; echo

# Redis
kubectl -n gitlab get secret gitlab-redis -o jsonpath='{.data.redis-password}' | base64 -d; echo

# MinIO root
kubectl -n gitlab get secret gitlab-minio -o jsonpath='{.data.root-user}' | base64 -d; echo
kubectl -n gitlab get secret gitlab-minio -o jsonpath='{.data.root-password}' | base64 -d; echo
```

> 建议首次登录后立即修改 root 密码，并创建个人访问令牌（PAT）用于 API / CLI。

---

## 7. 排障

### 7.1 `postgresql` Service 不存在

现象：GitLab 初始化报 `could not translate host name "postgresql"` 或 `connection refused`。

原因：如果曾用 Helm 安装过同名 `postgresql` release，`helm uninstall` 会把同名的 Service 一并删除。

处理：

```bash
kubectl -n gitlab expose deployment postgresql --port=5432 --target-port=5432 --name=postgresql
kubectl -n gitlab delete pod -l app=webservice --force --grace-period=0
```

### 7.2 PostgreSQL `out of shared memory` / `max_locks_per_transaction`

现象：迁移报 `ERROR: out of shared memory` 或 `HINT: You might need to increase max_locks_per_transaction`。

处理：

```bash
kubectl -n gitlab patch deployment postgresql --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["docker-entrypoint.sh"]},
  {"op":"add","path":"/spec/template/spec/containers/0/args","value":["postgres","-c","max_locks_per_transaction=256","-c","shared_buffers=512MB","-c","max_connections=200"]}
]'
kubectl -n gitlab rollout status deploy/postgresql --timeout=300s
kubectl -n gitlab delete pod -l app=migrations --force --grace-period=0
```

### 7.3 `database "gitlabhq_production" does not exist` 但 `pg_database` 又提示重复

原因：PVC 中残留了旧 PostgreSQL 数据目录，镜像认为已初始化但数据库不完整。

处理：换用新的 `PGDATA` 子目录，避免旧数据：

```bash
kubectl -n gitlab patch deployment postgresql --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/env/3/value","value":"/var/lib/postgresql/data/pgdata2"}
]'
```

如仍异常，最干净的做法是删除 `postgresql-data` PVC 并重建（会丢失数据）。

### 7.4 `gitlab.yml` 报 `bad component(expected host component)`

原因：`global.hosts.gitlab.name` 不能写成 `192.168.40.189:30080`，GitLab 把 `host` 当作纯主机名解析。

处理：

```yaml
global:
  hosts:
    gitlab:
      name: 192.168.40.189
```

端口通过第 3.8.3 节的 ConfigMap 补丁写入 `gitlab.port: 30080`。

### 7.5 `Many configurations (main, ci) share the same database` / `The 'ci' ... should share database with 'main'`

GitLab 19 的校验规则：

- `ci.databaseTasks=true`：`ci` 必须使用独立数据库。
- `ci.databaseTasks=false`：`ci` 必须与 `main` 共用数据库。

本部署采用共用数据库：

```yaml
global:
  psql:
    database: gitlabhq_production
    main:
      database: gitlabhq_production
      databaseTasks: true
    ci:
      database: gitlabhq_production
      databaseTasks: false
```

如果选择独立 CI 库，需要额外创建 `gitlabhq_production_ci` 并设置 `ci.databaseTasks=true`。

### 7.6 `gitlab-object-storage` / `gitlab-registry-storage` / `gitlab-backup-storage` 不存在

原因：命名空间被删除或 Secret 未创建。

处理：

```bash
kubectl -n gitlab create secret generic gitlab-object-storage --from-file=connection=/root/gitlab-deploy/object-storage-connection.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl -n gitlab create secret generic gitlab-registry-storage --from-file=config=/root/gitlab-deploy/registry-storage-config.yaml --dry-run=client -o yaml | kubectl apply -f -
kubectl -n gitlab create secret generic gitlab-backup-storage --from-file=config=/root/gitlab-deploy/backup-s3cfg --dry-run=client -o yaml | kubectl apply -f -
kubectl -n gitlab delete pod -l app=webservice --force --grace-period=0
```

### 7.7 webservice 副本 Pending：`didn't have free ports for the requested pod ports`

原因：`hostPort` 是节点级端口，同一节点只能有一个 Pod 使用；Chart 默认 webservice 副本数为 2，且 HPA 会拉高副本。

处理：

```bash
kubectl -n gitlab scale deploy gitlab-webservice-default --replicas=1
kubectl -n gitlab patch hpa gitlab-webservice-default -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
```

### 7.8 命名空间一直 Terminating

如果命名空间删除卡在 `kubernetes` finalizer，且确认内部已无资源，可以强制移除 finalizer：

```bash
kubectl patch ns gitlab --type=merge -p '{"metadata":{"finalizers":[]}}'
```

> 该操作会绕过命名空间控制器，仅在确认命名空间内无重要资源时使用。

### 7.9 镜像拉取慢 / 401 / 超时

- `docker.m.daocloud.io` 适合 Docker Hub 官方 `library/*` 镜像与部分镜像。
- `registry.gitlab.cn` 适合 GitLab CNG / JiHu GitLab 镜像。
- `dl.minio.org.cn` 提供 MinIO 二进制。
- `docker.1panel.live` 与 `docker.1ms.run` 在本机网络下不稳定，不建议作为唯一源。
- 若 containerd 需要新的 registry 证书配置，可编辑 `/etc/containerd/certs.d/<registry>/hosts.toml` 后重启 containerd；重启会影响 Docker 容器，需先确认无关键业务。

---

## 8. Agent 注意事项

1. 不要提交 `/root/gitlab-deploy/.secrets`、`object-storage-connection.yaml`、`registry-storage-config.yaml`、`backup-s3cfg` 等含明文密码的文件。
2. 不要使用 `md2html` 或通用模板覆盖 GitLab 配置；GitLab 的配置由 Helm Chart 渲染。
3. 不要直接 `docker restart` / `docker stop` 宿主机上的 Docker 容器；宿主机上已有 `aivp-*` 和 Docker GitLab 容器，避免影响现有服务。
4. 修改 GitLab Chart values 后，`helm upgrade` 会覆盖 `hostPort`、HPA、ConfigMap 端口等安装后补丁；升级后必须重新执行第 3.8 节。
5. 升级 GitLab 版本前，先备份 PostgreSQL、Gitaly 数据与 MinIO 桶，并在测试环境验证 Chart 版本与 Kubernetes 版本兼容性。
6. 不要把 `root` 密码写入仓库、Issue、PR 或日志。
7. 生产环境应启用 HTTPS（cert-manager + Let's Encrypt 或内部 CA）、独立 CI 数据库、共享存储、备份策略与监控。

---

## 9. 卸载

```bash
# 1. 卸载 GitLab Chart
helm uninstall gitlab -n gitlab || true

# 2. 删除依赖组件与数据卷（会丢失数据）
kubectl -n gitlab delete deployment postgresql redis-master minio --ignore-not-found
kubectl -n gitlab delete job minio-buckets --ignore-not-found
kubectl -n gitlab delete pvc postgresql-data redis-data minio-data --ignore-not-found
kubectl -n gitlab delete pvc repo-data-gitlab-gitaly-0 gitlab-toolbox-tmp --ignore-not-found

# 3. 删除命名空间（如卡住，参考 7.8）
kubectl delete ns gitlab

# 4. 可选：移除 local-path-provisioner
kubectl delete -f /tmp/local-path-storage.yaml
```

---

## 10. 升级、备份与复用迁移

### 10.1 升级 GitLab 版本

1. 备份 PostgreSQL、Gitaly PVC、MinIO 桶与 GitLab 配置。
2. 查询目标 Chart 版本与应用版本：

```bash
helm search repo gitlab-cn/gitlab --versions | head
```

3. 更新 `gitlab-values.yaml` 中的 `global.gitlabVersion`，确认 Chart 版本。
4. 执行 `helm upgrade`：

```bash
helm upgrade --install gitlab gitlab-cn/gitlab \
  --version <CHART_VERSION> \
  -n gitlab \
  -f /root/gitlab-deploy/gitlab-values.yaml \
  --timeout 900s
```

5. **升级后必须重放第 3.8 节补丁**，否则 `hostPort`、HPA、端口配置会被 Chart 默认值覆盖。
6. 升级后重新执行第 4 章验收。

### 10.2 备份

- PostgreSQL：使用 `pg_dump` 或存储快照。
- Gitaly：备份 `repo-data-gitlab-gitaly-0` PVC。
- MinIO：使用 `mc mirror` 备份 7 个桶。
- GitLab 配置：导出 `gitlab-rails-secret`、`gitlab-postgres`、`gitlab-redis`、`gitlab-object-storage`、`gitlab-backup-storage`。
- 建议至少每周备份一次，并在升级前做一次全量备份。

### 10.3 迁移到新集群

1. 在新集群执行第 3.1 节安装 local-path。
2. 执行第 3.2、3.3 节准备依赖与 MinIO 镜像。
3. 部署 PostgreSQL / Redis / MinIO，并恢复数据。
4. 执行第 3.5、3.6、3.7 节安装 GitLab。
5. 执行第 3.8 节补丁。
6. 执行第 4 章验收。
7. 切换 DNS / 负载均衡到新集群地址。

### 10.4 回滚

- GitLab 应用回滚：`helm rollback gitlab <REVISION> -n gitlab`，然后重放第 3.8 节补丁。
- 数据库回滚：从备份恢复 `gitlabhq_production`；不要在数据库版本不匹配时直接回滚应用。
- 若 `hostPort` 或端口变更，确认新端口未被占用。

---

## 附录 A：依赖组件清单模板

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-postgres
  namespace: gitlab
type: Opaque
stringData:
  password: PGPASS
  postgres-password: PGPASS
---
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-redis
  namespace: gitlab
type: Opaque
stringData:
  redis-password: REDISPASS
---
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-minio
  namespace: gitlab
type: Opaque
stringData:
  root-user: gitlab
  root-password: MINIOPASS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
  namespace: gitlab
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
  namespace: gitlab
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: gitlab
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: gitlab
  labels:
    app: postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      securityContext:
        fsGroup: 999
      containers:
      - name: postgresql
        image: docker.m.daocloud.io/library/postgres:17-bookworm
        command: ["docker-entrypoint.sh"]
        args: ["postgres", "-c", "max_locks_per_transaction=256", "-c", "shared_buffers=512MB", "-c", "max_connections=200"]
        env:
        - name: POSTGRES_USER
          value: gitlab
        - name: POSTGRES_DB
          value: gitlabhq_production
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitlab-postgres
              key: password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata2
        ports:
        - containerPort: 5432
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "gitlab", "-d", "gitlabhq_production"]
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            memory: 1Gi
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: postgresql-data
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: gitlab
spec:
  selector:
    app: postgresql
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-master
  namespace: gitlab
  labels:
    app: redis-master
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-master
  template:
    metadata:
      labels:
        app: redis-master
    spec:
      securityContext:
        runAsUser: 999
        fsGroup: 999
      containers:
      - name: redis
        image: docker.m.daocloud.io/library/redis:8-bookworm
        command: ["redis-server", "--requirepass", "$(REDIS_PASSWORD)", "--appendonly", "yes"]
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitlab-redis
              key: redis-password
        ports:
        - containerPort: 6379
        readinessProbe:
          exec:
            command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: redis-data
---
apiVersion: v1
kind: Service
metadata:
  name: redis-master
  namespace: gitlab
spec:
  selector:
    app: redis-master
  ports:
  - name: redis
    port: 6379
    targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: gitlab
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: docker.io/library/gitlab-minio:local
        command: ["/usr/local/bin/minio", "server", "/data", "--address", ":9000", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: gitlab-minio
              key: root-user
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitlab-minio
              key: root-password
        - name: MINIO_BROWSER
          value: "off"
        ports:
        - containerPort: 9000
          name: s3
        - containerPort: 9001
          name: console
        readinessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: gitlab
spec:
  selector:
    app: minio
  ports:
  - name: s3
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
---
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-buckets
  namespace: gitlab
spec:
  backoffLimit: 4
  template:
    metadata:
      labels:
        app: minio-buckets
    spec:
      restartPolicy: Never
      containers:
      - name: mc
        image: docker.io/library/gitlab-minio:local
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          /usr/local/bin/mc alias set local http://minio.gitlab.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
          for b in git-lfs gitlab-artifacts gitlab-uploads gitlab-packages gitlab-backups gitlab-tmp gitlab-registry; do
            /usr/local/bin/mc mb --ignore-existing "local/$b"
          done
          /usr/local/bin/mc ls local
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: gitlab-minio
              key: root-user
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitlab-minio
              key: root-password
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi
```

---

## 附录 B：GitLab values 模板

```yaml
global:
  edition: jh
  gitlabVersion: "19.5.5"
  security:
    allowInsecureImages: true
  nodeSelector:
    kubernetes.io/hostname: ubuntu
  hosts:
    domain: ""
    externalIP: 192.168.40.189
    https: false
    ssh: 192.168.40.189
    gitlab:
      name: 192.168.40.189
    registry:
      name: 192.168.40.189
  ingress:
    enabled: false
    provider: nginx
    class: nginx
    configureCertmanager: false
    tls:
      enabled: false
  gatewayApi:
    enabled: false
    installEnvoy: false
    configureCertmanager: false
  gitaly:
    enabled: true
  psql:
    host: postgresql.gitlab.svc.cluster.local
    port: 5432
    username: gitlab
    database: gitlabhq_production
    password:
      secret: gitlab-postgres
      key: password
      useSecret: true
    preparedStatements: false
    databaseTasks: true
    main:
      host: postgresql.gitlab.svc.cluster.local
      port: 5432
      username: gitlab
      database: gitlabhq_production
      password:
        secret: gitlab-postgres
        key: password
        useSecret: true
      databaseTasks: true
    ci:
      host: postgresql.gitlab.svc.cluster.local
      port: 5432
      username: gitlab
      database: gitlabhq_production
      password:
        secret: gitlab-postgres
        key: password
        useSecret: true
      databaseTasks: false
  redis:
    host: redis-master.gitlab.svc.cluster.local
    port: 6379
    auth:
      enabled: true
      secret: gitlab-redis
      key: redis-password
  appConfig:
    object_store:
      enabled: true
      connection:
        secret: gitlab-object-storage
        key: connection
      proxy_download: true
    lfs:
      enabled: true
      bucket: git-lfs
    artifacts:
      enabled: true
      bucket: gitlab-artifacts
    uploads:
      enabled: true
      bucket: gitlab-uploads
    packages:
      enabled: true
      bucket: gitlab-packages
    externalDiffs:
      enabled: false
    dependencyProxy:
      enabled: false
    terraformState:
      enabled: false
  registry:
    enabled: false
  pages:
    enabled: false

installCertmanager: false
certmanager:
  install: false
prometheus:
  install: false
gitlab-runner:
  install: false
nginx-ingress:
  enabled: false

registry:
  enabled: false

gitlab:
  gitaly:
    replicaCount: 1
    persistence:
      enabled: true
      storageClass: local-path
      size: 20Gi
  toolbox:
    replicaCount: 1
    persistence:
      enabled: true
      storageClass: local-path
      size: 5Gi
    backups:
      objectStorage:
        backend: s3
        config:
          secret: gitlab-backup-storage
          key: config
```

---

## 附录 C：当前实际部署的目录与文件

目标节点：`192.168.40.189`

```text
/root/gitlab-deploy/
├── .secrets                         # 明文密码（勿提交）
├── gitlab-values.yaml               # GitLab Helm values（含密码引用）
├── object-storage-connection.yaml   # 对象存储连接（含密码，勿提交）
├── registry-storage-config.yaml     # Registry 存储配置（含密码，勿提交）
├── backup-s3cfg                      # Toolbox 备份配置（含密码，勿提交）
├── minio-build/
│   ├── minio
│   ├── mc
│   └── Dockerfile
└── manifests/
    └── dependencies.yaml            # PostgreSQL / Redis / MinIO / Job
```

> 这些文件包含敏感信息，仅用于本次部署与后续维护，不应放入 Git 仓库。
