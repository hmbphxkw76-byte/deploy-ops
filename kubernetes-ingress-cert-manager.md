# ingress-nginx + cert-manager on Kubernetes 部署手册（已实测）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在 **Kubernetes 集群** 上部署 **ingress-nginx**（七层入口）与 **cert-manager**（自动证书），并用**自建 CA** 签发证书（CA 由 [kubernetes-argocd.md](kubernetes-argocd.md) 第 3.3 节生成）。文档与 [kubernetes-harbor.md](kubernetes-harbor.md) 等同格式：**参数区 → 前置检查 → 幂等执行 → 验证 → 排障 → Agent 注意事项**。

**为什么需要它们**：Argo CD 已用 NodePort 暴露（`https://192.168.40.189:30701`），但缺少**域名 + 标准 443 + 自动证书**。ingress-nginx 提供统一入口，cert-manager 用自建 CA 自动签发/续期，客户端只需信任一次 CA。

**实测基线（2026-11-15，于 `192.168.40.189`）**：

| 项 | 值 |
| --- | --- |
| ingress-nginx | chart `4.15.1` / controller `v1.15.1`，ns `ingress-nginx` |
| cert-manager | chart `v1.21.3`，ns `cert-manager` |
| 入口 | **`https://argocd.lan`**（hostPort 443；HTTP 30081 自动 308 跳转 HTTPS） |
| 证书 | `ClusterIssuer lab-ca`（CA 类型，自建 CA），`Certificate argocd-server-tls` Ready |
| 验证 | `curl --cacert ca.crt https://argocd.lan/healthz` → 200 `ok`；UI `/` → 200 |

> 前置依赖：集群已按 [linux-kubernetes.md](linux-kubernetes.md) 部署；镜像源已配 `quay.io`；Argo CD 见 [kubernetes-argocd.md](kubernetes-argocd.md)。

---

## 1. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `INGRESS_NS` | `ingress-nginx` | ingress-nginx 命名空间 |
| `CERTMANAGER_NS` | `cert-manager` | cert-manager 命名空间 |
| `INGRESS_CHART_VERSION` | `4.15.1` | ingress-nginx chart 版本 |
| `CERTMANAGER_CHART_VERSION` | `1.21.3` | cert-manager chart 版本 |
| `INGRESS_HOST` | `argocd.lan` | 对外域名（需 hosts/DNS 指向节点 IP） |
| `NODE_IP` | `192.168.40.189` | 入口所在节点 IP（hostPort 生效处） |
| `HOSTPORT_HTTPS` | `443` | 宿主机 HTTPS 端口（**须空闲**） |
| `HOSTPORT_HTTP` | `30081` | 宿主机 HTTP 端口（仅用于跳转；80 被占用时用 NodePort） |
| `NODEPORT_HTTPS` | `30443` | controller Service HTTPS NodePort |
| `PIN_NODE` | `ubuntu` | controller 固定到的节点（`kubernetes.io/hostname`） |
| `MIRROR_K8S` | `k8s.m.daocloud.io` | `registry.k8s.io` 镜像源 |
| `MIRROR_QUAY` | `quay.m.daocloud.io` | `quay.io` 镜像源（cert-manager 镜像） |
| `CA_DIR` | `/root/argocd-deploy/tls` | 自建 CA 目录（含 `ca.crt` / `ca.key`） |

> **端口占用现状**：宿主机 `80` 被 Docker 容器 `aivp-web-1` 占用、`443` 空闲；NodePort 已用 `30002/30003/30700/30701/30888`。

## 2. 前置检查（只读，不修改系统）

```bash
export KUBECONFIG=/root/.kube/config

# 1) 工具与集群
kubectl get nodes -o wide
helm version --short

# 2) 端口占用（关键：443 必须空闲）
ss -ltnp | grep -E ":443 |:80 " || echo "443/80 空闲"
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace} {range .spec.ports[*]}{.nodePort} {end}{"\n"}{end}' \
  | tr " " "\n" | grep -E "^[0-9]+$" | sort -un | tr "\n" " "; echo

# 3) 是否已安装
helm -n ingress-nginx list; kubectl -n ingress-nginx get pods
helm -n cert-manager list; kubectl -n cert-manager get pods

# 4) 上游可达性
curl -s -o /dev/null -w 'kubernetes.github.io: %{http_code}\n' --max-time 15 https://kubernetes.github.io/ingress-nginx/index.yaml
curl -s -o /dev/null -w 'charts.jetstack.io:  %{http_code}\n' --max-time 15 https://charts.jetstack.io
curl -s -o /dev/null -w 'github.com:         %{http_code}\n' --max-time 15 https://github.com

# 5) CA 是否就绪（见 kubernetes-argocd.md 3.3）
ls -l /root/argocd-deploy/tls/ca.crt /root/argocd-deploy/tls/ca.key
```

## 3. 架构与版本选型

### 3.1 组件

| 组件 | 命名空间 | 类型 | 镜像源 |
| --- | --- | --- | --- |
| `ingress-nginx-controller` | `ingress-nginx` | Deployment（+ admission webhook Job） | `registry.k8s.io/ingress-nginx/*` → `k8s.m.daocloud.io` |
| `cert-manager` / `-cainjector` / `-webhook` | `cert-manager` | Deployment ×3 | `quay.io/jetstack/*` → `quay.m.daocloud.io` |
| `ClusterIssuer lab-ca` | 集群级 | cert-manager CA 签发器 | 用自建 CA，无 ACME |

### 3.2 暴露方式（为什么 hostPort 只开 443）

宿主机 80 已被占用，443 空闲。方案：

- **hostPort 443**：标准 HTTPS 端口，域名 `https://argocd.lan` 直接可用；
- **hostPort/NodePort 30081**：HTTP 入口，仅用于 `308` 跳转到 HTTPS；
- controller 用 `nodeSelector` 固定到控制面节点，保证「域名 → IP」稳定（换环境时改成实际的 443 空闲节点）。

> 如果换到一台 80/443 都空闲的机器：把 `HOSTPORT_HTTP` 改成 `80` 即可，域名访问更自然。

## 4. 镜像源最佳实践

沿用 containerd `certs.d` 透明映射，不改 chart 的镜像地址：

```bash
# registry.k8s.io（ingress-nginx）
sudo mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat <<'EOF' | sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# quay.io（cert-manager）——见 kubernetes-argocd.md 第 4 章，通常已配

# 验证（必须带 --hosts-dir，否则直连上游误判）
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d registry.k8s.io/ingress-nginx/controller:v1.15.1
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
```

**chart 获取**（GitHub 大文件易截断，逐个重试并校验）：

```bash
cd /root/argocd-deploy
curl -sL --max-time 120 -o ingress-nginx-4.15.1.tgz \
  https://github.com/kubernetes/ingress-nginx/releases/download/helm-chart-4.15.1/ingress-nginx-4.15.1.tgz
curl -sL --max-time 120 -o cert-manager-v1.21.3.tgz \
  https://charts.jetstack.io/charts/cert-manager-v1.21.3.tgz
tar tzf ingress-nginx-4.15.1.tgz >/dev/null && tar tzf cert-manager-v1.21.3.tgz >/dev/null && echo "charts OK"
```

## 5. 安装步骤（幂等）

### 5.1 安装 ingress-nginx

values 见仓库 [ingress/ingress-nginx-values.yaml](ingress/ingress-nginx-values.yaml)：

```bash
cd /root/argocd-deploy
if helm -n ingress-nginx list | grep -q ingress-nginx; then ACT=upgrade; else ACT=install; fi
helm $ACT ingress-nginx ./ingress-nginx-4.15.1.tgz -n ingress-nginx --create-namespace \
  -f ingress-nginx-values.yaml --timeout 600s
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

# 监听验证：443 返回 404（无 Ingress 时是默认后端），说明入口已通
curl -sk -o /dev/null -w 'https 443 -> %{http_code}\n' https://192.168.40.189:443/
curl -s  -o /dev/null -w 'http 30081 -> %{http_code}\n' http://192.168.40.189:30081/
```

### 5.2 安装 cert-manager

values 见仓库 [ingress/cert-manager-values.yaml](ingress/cert-manager-values.yaml)：

```bash
if helm -n cert-manager list | grep -q cert-manager; then ACT=upgrade; else ACT=install; fi
helm $ACT cert-manager ./cert-manager-v1.21.3.tgz -n cert-manager --create-namespace \
  -f cert-manager-values.yaml --timeout 600s
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=240s
kubectl get apiservices | grep cert-manager       # 两个 APIService 均 Available
```

### 5.3 创建自建 CA 的 ClusterIssuer

```bash
# 1) CA 密钥对 Secret（放在 cert-manager 命名空间）
kubectl -n cert-manager create secret tls lab-ca-key-pair \
  --cert=/root/argocd-deploy/tls/ca.crt --key=/root/argocd-deploy/tls/ca.key

# 2) ClusterIssuer（仓库文件 ingress/clusterissuer-lab-ca.yaml）
kubectl apply -f ingress/clusterissuer-lab-ca.yaml
sleep 8
kubectl get clusterissuer lab-ca -o jsonpath='{.status.conditions}'; echo   # 期望 Ready=True / KeyPairVerified
```

### 5.4 为 Argo CD 创建 Ingress（域名 + 自动证书）

清单见仓库 [ingress/argocd-ingress.yaml](ingress/argocd-ingress.yaml)：

```bash
grep -q "argocd.lan" /etc/hosts || echo "192.168.40.189 argocd.lan" >> /etc/hosts
kubectl apply -f argocd-ingress.yaml
sleep 20
kubectl -n argocd get certificate            # READY=True
kubectl -n argocd get ingress argocd-server
```

> **后端协议**：`nginx.ingress.kubernetes.io/backend-protocol: HTTPS` —— Argo CD server 自身已启用 TLS，ingress 终结外层证书后以 HTTPS 回源。
> **CLI**：仍走 NodePort `https://192.168.40.189:30701`（gRPC 需要单独的 `backend-protocol: GRPC` Ingress，本部署未启用）。

## 6. 验证

```bash
# 1) 域名 + 证书（用自建 CA 校验）
curl -s --cacert /root/argocd-deploy/tls/ca.crt https://argocd.lan/healthz; echo    # ok
curl -s --cacert /root/argocd-deploy/tls/ca.crt -o /dev/null -w 'UI / -> %{http_code}\n' https://argocd.lan/
echo | openssl s_client -connect argocd.lan:443 -servername argocd.lan 2>/dev/null \
  | openssl x509 -noout -issuer -ext subjectAltName | head -4

# 2) HTTP 跳转
curl -s -o /dev/null -w 'http 30081 -> %{http_code} %{redirect_url}\n' http://argocd.lan:30081/healthz

# 3) 一键验证脚本（见下方）
bash /root/argocd-deploy/ingress_verify.sh
```

`ingress_verify.sh`（只读，退出码 0 = 通过）：

```bash
#!/bin/bash
set -u
NODE_IP="${NODE_IP:-192.168.40.189}"
HOST="${HOST:-argocd.lan}"
CA="${CA:-/root/argocd-deploy/tls/ca.crt}"
P=0; F=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; P=$((P+1)); else echo "FAIL: $1"; F=$((F+1)); fi; }

chk "ingress-nginx Running"  "test \$(kubectl -n ingress-nginx get pods --no-headers | grep -c Running) -ge 1"
chk "cert-manager Running"  "test \$(kubectl -n cert-manager get pods --no-headers | grep -c Running) -ge 3"
chk "ClusterIssuer Ready"   "kubectl get clusterissuer lab-ca -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
chk "Certificate Ready"     "kubectl -n argocd get certificate argocd-server-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
chk "域名 healthz"          "curl -s --cacert $CA https://${HOST}/healthz | grep -qx ok"
chk "UI 200"                "test \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://${HOST}/) = 200"
chk "HTTP→HTTPS 跳转"       "curl -s -o /dev/null -w '%{http_code}' http://${HOST}:30081/healthz | grep -q 308"

echo "=== 结果: $P 通过, $F 失败 ==="
[ "$F" -eq 0 ] && exit 0 || exit 1
```

## 7. 最佳实践与踩坑总结

| # | 实践 | 原因 / 做法 |
| --- | --- | --- |
| 1 | ⚠️ **先确认 443 空闲** | 80 被 Docker 容器占用时无碍——只开 443 hostPort，HTTP 用 NodePort 跳转 |
| 2 | ⚠️ **controller 固定节点** | hostPort 只在 Pod 所在节点生效；`nodeSelector` 锁定 443 空闲的节点，域名→IP 才稳定 |
| 3 | ⚠️ **chart 从 GitHub Releases 下载要重试 + `tar tzf` 校验** | 实测 `unexpected EOF`；cert-manager chart 用 `charts.jetstack.io/charts/<name>-<ver>.tgz` 更稳 |
| 4 | **自建 CA 做 `ca` 类型 ClusterIssuer** | 内网无 ACME/公网域名时最省事；客户端信任一次 CA 即可 |
| 5 | **CA Secret 放 cert-manager 命名空间** | `ca` Issuer 只从自身命名空间读取 `secretName` |
| 6 | **回源用 `backend-protocol: HTTPS`** | Argo CD server 自身已启用 TLS；用 HTTP 回源会 502/握手失败 |
| 7 | **别把 CA 私钥提交仓库** | `ca.crt` 可公开但**不再入库**（原 `certs/lab-argocd-ca.crt` 已移除，仅存节点 `/root/argocd-deploy/tls/ca.crt`），`ca.key` 只留节点 |
| 8 | **证书域名写进 SAN** | `argocd.lan` 必须在 SAN 中，否则浏览器/curl 报 hostname 不匹配 |
| 9 | **客户端信任** | Linux `update-ca-certificates`；Windows 需管理员 `certutil -addstore Root`（详见 Argo CD 手册 3.3） |
| 10 | **CLI 与 UI 分开** | UI 走域名 443；Argo CD CLI（gRPC）继续走 NodePort 30701，避免为 gRPC 单独配 Ingress |

## 8. 排障

### 8.1 controller Pod 一直 Pending / ImagePullBackOff

```bash
kubectl -n ingress-nginx describe pod -l app.kubernetes.io/component=controller | tail -12
```
- 镜像拉取失败 → 检查 `certs.d/registry.k8s.io/hosts.toml`（第 4 章），重测 `ctr ... --hosts-dir`。
- 节点无法绑定 hostPort → 换 `PIN_NODE` 到 443 空闲的节点。

### 8.2 访问域名 404 / 证书错误

- `404` 且无证书 → Ingress 规则没生效：确认 `ingressClassName: nginx`、controller 日志 `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep argocd`。
- `certificate not found` / Certificate 一直 Pending → `kubectl -n argocd describe certificate argocd-server-tls`，多为 ClusterIssuer 未 Ready 或 Secret 不在 cert-manager 命名空间。
- 浏览器告警 → 未导入 `ca.crt`（第 7 章第 9 条）。

### 8.3 UI 能开但 CLI 连不上

CLI 走 gRPC：本部署用 NodePort `https://192.168.40.189:30701` + `argocd login`。若确实要走域名 gRPC，需另建一个 `backend-protocol: GRPC` 的 Ingress（同一 host，注意与 UI Ingress 的路径冲突，建议 gRPC 用单独子域，如 `grpc.argocd.lan`）。

### 8.4 升级

```bash
kubectl -n cert-manager get certificates -o yaml > /root/argocd-deploy/certificates-backup.yaml
helm upgrade ... （用同一 values；chart 版本变化先核对 appVersion）
```

## 9. Agent 执行注意事项

- **先检查再执行**：第 2 章全只读；`helm -n <ns> list` 有记录走 `upgrade`。
- **端口先确认**：`ss -ltnp | grep 443` 必须空闲；被占用先与用户确认换端口，不要强改。
- **节点固定**：`PIN_NODE` 必须是 443 空闲的节点；换环境时先探测。
- **危险操作确认**：`systemctl restart containerd`、删除 namespace、卸载 release 需用户同意。
- **私钥红线**：`ca.key` 不入库、不打印到日志；只在节点本地使用。
- **失败即停**：镜像/图表下载失败先看真实错误，重试要带校验（`tar tzf`）。

## 10. 复用 checklist 与已知遗留

**换环境复用清单**

- [ ] `kubectl`/`helm` 可用；节点 Ready。
- [ ] 宿主机 **443 空闲**（否则改 `HOSTPORT_HTTPS` 或换节点）。
- [ ] `certs.d/registry.k8s.io` → `k8s.m.daocloud.io` 已配并验证拉取。
- [ ] 两个 chart 下载并通过 `tar tzf` 校验。
- [ ] 自建 CA 就绪（`ca.crt`/`ca.key`），`ClusterIssuer` Ready=True。
- [ ] `kubectl get certificate` READY=True，域名 `curl --cacert` 200。
- [ ] 客户端已导入 `ca.crt`（否则有告警）。

**已知遗留**

- **HTTP 80 未占用**：宿主机 80 被 `aivp-web-1` 占用，HTTP 入口是 30081（自动跳转 HTTPS）；若换机可改回 80。
- **CLI 未走域名**：Argo CD CLI（gRPC）仍用 NodePort 30701；未配置 gRPC Ingress。
- **证书由自建 CA 签发**：公网/跨组织使用应换 Let's Encrypt（ACME Issuer）或企业 CA。
- **`argocd.lan` 需 hosts/DNS**：集群内与节点已加 `/etc/hosts`；其他客户端需自行添加或用 `--resolve`。

---

## 附录 A：实测部署记录（2026-11-15，192.168.40.189）

| 项 | 值 |
| --- | --- |
| ingress-nginx | chart 4.15.1 / controller v1.15.1；hostPort 443 + 30081；nodeSelector `kubernetes.io/hostname=ubuntu` |
| cert-manager | chart v1.21.3；3 个 Deployment 全 Running；APIService `v1.cert-manager.io` / `v1.acme.cert-manager.io` Available |
| ClusterIssuer | `lab-ca`（ca 类型，Secret `cert-manager/lab-ca-key-pair`）→ Ready `KeyPairVerified` |
| Certificate | `argocd/argocd-server-tls` READY=True，SAN `DNS:argocd.lan`，issuer `O=Lab, CN=Lab Argo CD CA` |
| 入口验证 | `https://argocd.lan/healthz` → 200 `ok`；`/` → 200（Argo CD UI）；`http://argocd.lan:30081` → 308 跳转 HTTPS |
|  workstation | `curl --resolve argocd.lan:443:192.168.40.189` → 200（信任需管理员导入 CA） |

## 附录 B：相关文件

```text
ingress/
├── ingress-nginx-values.yaml     # controller values（hostPort 443、固定节点、NodePort）
├── cert-manager-values.yaml      # cert-manager values
├── clusterissuer-lab-ca.yaml     # CA 类型 ClusterIssuer
└── argocd-ingress.yaml           # Argo CD 域名入口 + cert-manager 注解
/root/argocd-deploy/tls/ca.crt     # 自建 CA 证书（客户端导入用，仅存节点，未入库）
/root/argocd-deploy/tls/ca.key     # CA 私钥（仅节点本地，勿提交）
```
