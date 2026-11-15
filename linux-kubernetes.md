# Kubernetes 部署手册（kubeadm / containerd / flannel，供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Ubuntu 22.04 / 24.04 x86_64** 上以 **kubeadm + containerd + flannel** 部署 Kubernetes 集群：支持**单节点**（单 control-plane）与**多节点**（加 worker）两种形态，并完成验证。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；安装部分幂等，已完成的步骤会自动跳过。

**镜像一律优先国内源**（见 4.2 的镜像源清单与选源方法）；k8s 组件安装包走官方 apt 源 `pkgs.k8s.io`（见第 2 章），官方源间歇 403 时改用清华/中科大镜像。

本手册的落地实例：`192.168.40.189`（Ubuntu 24.04.2 / 24C / 62G / 98G，control-plane，hostname `ubuntu`）+ `192.168.40.183`（Ubuntu 22.04 / 8C / 16G，worker，hostname `ubunt-dev`）+ `192.168.40.187`（Ubuntu 24.04.2 / 16C / 43G，worker，hostname `ubuntu-stage`），部署结果为 **v1.37.2** 三节点集群，各机器上的 Docker 与 Kubernetes **共用各自的 containerd**。

> **实测基线（2026-11-15）**：`.187` 按第 2/3/4/5.1 章加入，`kubeadm join` 一次成功，节点 `Ready` 且角色 `worker`；跨节点 Pod 互通（187↔189、187↔183）全部通过，真实工作负载 `ai-weekly` 已调度到该节点并 Running。
>
> 跨组件的实操要点、镜像源实测数据与共性踩坑速查见 [linux-provisioning-playbook.md](linux-provisioning-playbook.md)。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `K8S_VERSION` | `v1.37.2` | Kubernetes 版本；`stable` 时取 <https://dl.k8s.io/release/stable.txt> |
| `K8S_APT_REPO` | `https://pkgs.k8s.io/core:/stable:/v1.37/deb/` | k8s 官方 apt 仓库（pkgs.k8s.io），**路径用 minor 版本 `v1.37`**，不是完整版本 `v1.37.2` |
| `K8S_APT_MIRROR` | 空（用官方源） | 官方源 403 时填 `https://mirrors.tuna.tsinghua.edu.cn/kubernetes`（或 `https://mirrors.ustc.edu.cn/kubernetes`）；拼接方式 `<前缀>/core:/stable:/<minor>/deb` |
| `NODE_NAME` | `ubuntu` | 节点名，取 `hostname` |
| `ADVERTISE_IP` | `192.168.40.189` | apiserver 广播地址，取本机内网 IP |
| `POD_CIDR` | `10.244.0.0/16` | Pod 网段，需与 flannel 默认值一致 |
| `SERVICE_CIDR` | `10.96.0.0/12` | Service 网段 |
| `DISABLE_SWAP` | `true` | 是否禁用 swap（kubelet 默认拒绝在 swap 启用时启动） |
| `CNI` | `flannel` | 网络插件；`flannel` / `calico` / `none` |
| `MIRROR_K8S` | `https://k8s.m.daocloud.io` | `registry.k8s.io` 镜像源（containerd CRI 层） |
| `MIRROR_DOCKER` | `https://docker.1ms.run` | `docker.io` 镜像源 |
| `MIRROR_GHCR` | `https://ghcr.m.daocloud.io` | `ghcr.io` 镜像源（flannel CNI 插件使用） |
| `RUN_SMOKE` | `true` | 验证阶段是否部署测试工作负载（nginx） |

> 镜像源**一律优先国内源**（上表为 2026-11 实测可用值）。免费镜像源会不定期失效，失效时按 4.2 的选源方法重测、按第 8 章排障，不要盲目重试。

## 1. 前置检查（只读，不修改系统）

按顺序执行并记录结果：

```bash
# 1) 系统版本与架构
cat /etc/os-release && dpkg --print-architecture

# 2) 资源（单节点建议 ≥ 2 核 / 4G / 20G 可用）
nproc && free -h && df -h /

# 3) 是否已安装 k8s 组件
for c in kubelet kubeadm kubectl; do printf '%s: ' $c; command -v $c || echo NOT_FOUND; done

# 4) 容器运行时（kubeadm 需要 containerd / docker / crio）
command -v containerd; containerd --version 2>/dev/null
systemctl is-active containerd 2>/dev/null || true

# 5) swap 状态
swapon --show || true

# 6) 内核模块与转发
lsmod | grep -E 'br_netfilter|overlay'
sysctl net.ipv4.ip_forward

# 7) hostname 可解析（kubeadm 用它做节点名）
hostname; getent hosts $(hostname)
```

判定逻辑：

- `kubeadm`/`kubelet` 已安装且版本符合 → 跳过第 2 章；若已 `kubeadm init` 过（存在 `/etc/kubernetes/admin.conf`）→ 跳过第 5 章，只做第 7 章验证。
- 无容器运行时 → 先按 `linux-docker.md` 安装 Docker（会自带 containerd），或单独安装 containerd。
- 当前用户无 sudo 权限 → 提示用户提供具备 sudo 权限的账户，不要继续。

## 2. 安装 kubelet / kubeadm / kubectl

```bash
sudo install -m 0755 -d /etc/apt/keyrings

# 仓库路径必须用 minor 版本（v1.37）；写成 v1.37.2 会 404
K8S_MINOR="v1.37"                                     # 由 K8S_VERSION 推导: ${K8S_VERSION%.*}
K8S_APT_BASE="${K8S_APT_MIRROR:-https://pkgs.k8s.io}"  # 官方源 403 时换成清华/中科大镜像
K8S_REPO="${K8S_APT_BASE}/core:/stable:/${K8S_MINOR}/deb"

# 签名 key：pkgs.k8s.io 会 302 到 CloudFront，偶发 403/超时，必须重试
for i in 1 2 3 4 5; do
  sudo curl -fsSL -m 30 -o /tmp/k8s-release.key "${K8S_REPO}/Release.key" && break
  echo "Release.key 下载失败（第 $i 次），5s 后重试"; sleep 5
done
sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-release.key

# apt 仓库（注意结尾是 /，不是发行版代号）
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${K8S_REPO}/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl   # 防止被常规升级误升级
```

> `apt-mark hold` 幂等。**注意区分两类源**：k8s 组件*安装包*走 `pkgs.k8s.io`（或其中科大/清华镜像）；而*容器镜像*一律走 4.2 的国内源。
> **国内镜像前缀**：`https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.37/deb`、`https://mirrors.ustc.edu.cn/kubernetes/core:/stable:/v1.37/deb` 均实测可用（2026-11-15）。不要用阿里云 `mirrors.aliyun.com/kubernetes/apt`（对 22.04/24.04 支持不全）。

## 3. 系统配置（内核模块 / sysctl / swap）

```bash
# 1) 内核模块：overlay + br_netfilter
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 2) sysctl
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 3) 禁用 swap（kubelet 默认 fail-swap-on=true）
sudo swapoff -a
sudo sed -i '/\/swap.img/ s/^/#/' /etc/fstab   # 注释而非删除，保持可逆
```

> 若用户要求保留 swap，改为在 kubelet 配置中设置 `fail-swap-on=false`（`/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` 或 kubeadm 的 `nodeRegistration`），并在文档中记录该偏离。

## 4. containerd 运行时配置

> **重要（本实例的关键约束）**：该机器上 **Docker 与 Kubernetes 共用同一个 containerd**（`/run/containerd/containerd.sock`，Docker 29 使用 containerd 镜像存储）。因此：
> - 修改 `/etc/containerd/config.toml` 后重启 containerd 会**短暂影响 Docker 容器**（本例业务容器 `restart=unless-stopped`，会自动恢复）。执行前确认业务容忍度。
> - 不要 `systemctl restart docker` 之外的粗暴操作；只需保证配置同时兼容 Docker 与 CRI。

### 4.1 生成并修改配置

```bash
# 备份现有配置（可能是 Docker 安装时生成的精简版，含 disabled_plugins = ["cri"]）
sudo cp -a /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d_%H%M%S)

# 生成 containerd 默认配置（version = 4，含 CRI 插件）
containerd config default | sudo tee /etc/containerd/config.toml

# 开启 systemd cgroup 驱动（kubeadm 要求）
sudo sed -i 's/^            SystemdCgroup = false$/            SystemdCgroup = true/' /etc/containerd/config.toml

# 开启 CRI 镜像源配置目录（第一个 config_path 位于 io.containerd.cri.v1.images.registry 下）
sudo sed -i "0,/config_path = ''/s//config_path = '\/etc\/containerd\/certs.d'/" /etc/containerd/config.toml

# 校验关键项
grep -n "SystemdCgroup\|config_path" /etc/containerd/config.toml
```

> 若原配置含 `disabled_plugins = ["cri"]`，替换为默认配置后自然移除（默认 `disabled_plugins = []`）。
> containerd 2.4 无 `containerd config validate` 子命令，可跳过校验。

### 4.2 配置镜像源（certs.d）

**国内镜像源清单（优先，2026-11 实测）**

| 上游 | 推荐国内源 | 备用 | 说明 |
| --- | --- | --- | --- |
| `registry.k8s.io` | `k8s.m.daocloud.io` | `docker.imgdb.de/registry.k8s.io`（不稳定） | 保留完整仓库路径（`coredns/coredns`） |
| `docker.io` | `hub.rat.dev` | `docker.1panel.live`、`docker.xuanyuan.me`、`docker.1ms.run`、`docker.m.daocloud.io` | **按节点实测排序**，见下方选源方法。2026-11-15 实测 `hub.rat.dev` 最快（nginx:1.27 约 1.5s），`1ms`/`daocloud` 大镜像仅 1.5 KiB/s |
| `ghcr.io` | `ghcr.m.daocloud.io` | — | flannel CNI 插件镜像 |

**选源方法（部署前必做）**：同一镜像源在不同机器、不同时间段表现可能不同。**小镜像（alpine）测速会失真**——小镜像可能被镜像源边缘缓存，测出很快，但大镜像（如 nginx）仍可能只有几 KiB/s。应用**未缓存的较大镜像**测：

```bash
# 逐个测未缓存的大镜像（nginx:1.27 约 100MB），记录耗时
for m in hub.rat.dev docker.1panel.live docker.xuanyuan.me docker.1ms.run docker.m.daocloud.io; do
  printf '%-24s ' "$m"
  s=$(date +%s%N)
  timeout 90 ctr -n k8s.io images pull "$m/library/nginx:1.27" >/tmp/m.log 2>&1 \
    && echo "OK  $(( ($(date +%s%N)-s)/1000000 ))ms" || echo "FAIL/超时"
  ctr -n k8s.io images rm "$m/library/nginx:1.27" >/dev/null 2>&1
done
```

把最快的源写在 `docker.io` 的 `hosts.toml` **首位**，其余作为备用（containerd 会按顺序回退）。

> **实测记录（2026-11-15，`.187`）**：`hub.rat.dev` 1.5s、`docker.1panel.live` 21.8s、`docker.xuanyuan.me` 14.8s、`docker.1ms.run` 与 `docker.m.daocloud.io` 均 < 6 KiB/s（且 1ms 开始返回 `UNAUTHORIZED` 需联系客服）；`dockerpull.org`、`docker.nju.edu.cn`、`docker.mirrors.ustc.edu.cn` 不可达。免费镜像源会集体劣化，排障时先重测再下结论。

```bash
sudo mkdir -p /etc/containerd/certs.d/{registry.k8s.io,docker.io,ghcr.io}

# registry.k8s.io -> DaoCloud k8s 专用源（保留完整仓库路径，如 coredns/coredns）
cat <<'EOF' | sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# docker.io -> 多源回退（按节点实测排序；镜像源会分钟级波动，务必保留多个备用）
cat <<'EOF' | sudo tee /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://docker.io"

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://hub.rat.dev"]
  capabilities = ["pull", "resolve"]

[host."https://docker.1panel.live"]
  capabilities = ["pull", "resolve"]

[host."https://docker.xuanyuan.me"]
  capabilities = ["pull", "resolve"]
EOF

# ghcr.io（flannel CNI 插件镜像所在）
cat <<'EOF' | sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml
server = "https://ghcr.io"

[host."https://ghcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

sudo systemctl restart containerd
sleep 3
systemctl is-active containerd
docker ps   # 确认 Docker 与业务容器未受影响
```

> **验证镜像源是否生效**：`kubeadm config images pull --config <kubeadm 配置>`（走 CRI，会读 certs.d）。
> 注意：`ctr -n k8s.io images pull registry.k8s.io/...` **不读** CRI 的 `config_path`，会直连上游，因此不能用 ctr 判断镜像源配置是否生效。

## 5. kubeadm init 与节点加入

```bash
cat <<'EOF' | sudo tee /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.40.189
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ubuntu
  taints: null
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.37.2
clusterName: kubernetes
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
EOF

sudo systemctl enable kubelet
sudo kubeadm init --config /root/kubeadm-config.yaml
```

> **不要用 `imageRepository` 指向镜像站**：kubeadm 会把 coredns 镜像名规范化为 `<imageRepository>/coredns:vX`（丢掉 `coredns/` 命名空间），导致镜像源 403/404。正确做法是保持默认 `registry.k8s.io`，由第 4.2 章的 containerd CRI 镜像源做映射（保留 `coredns/coredns` 完整路径）。

init 成功后：

```bash
# kubeconfig
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> $HOME/.bashrc

# 去除 control-plane 污点：仅单节点 / 测试集群建议；多节点且有专用 worker 时建议保留该污点（业务只调度到 worker）
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl get nodes -o wide
```

> 若节点长时间 `NotReady`，先确认 CNI 是否已部署（第 6 章）——没有 CNI 时节点不会 Ready。

### 5.1 加入 Worker 节点（多节点扩展）

把另一台机器加入现有集群作为 worker 节点。已落地实例：`192.168.40.183`（Ubuntu 22.04 / 8C / 16G，hostname `ubunt-dev`）加入 `192.168.40.189` 的集群。

#### 5.1.1 前提检查（新节点，只读）

```bash
# 能访问 control-plane 的 advertiseAddress:6443
curl -sk -m 8 -o /dev/null -w '%{http_code}\n' https://192.168.40.189:6443/healthz   # 200
# hostname 唯一且可解析（节点名取 hostname，不能与现有节点重名）
hostname; getent hosts $(hostname)
# 容器运行时与 swap
command -v containerd; swapon --show
```

判定：若新节点 hostname 与现有节点重复（如都叫 `ubuntu`），先 `hostnamectl set-hostname <新名>` 并同步 `/etc/hosts`，否则 kubelet 会以同名注册导致节点冲突。

#### 5.1.2 新节点执行（与单机部署第 2–4 章相同）

在第 2 章（安装 kubelet/kubeadm/kubectl）、第 3 章（内核模块/sysctl/swap）、第 4 章（containerd + 镜像源）中，把 `ADVERTISE_IP` 等参数换成新节点自己的值，`kubeadm init` **不要执行**。

> **镜像源顺序按节点实测调整**：见 4.2 的选源方法。实测 `.189` 须 `docker.1ms.run` 优先（daocloud blob 被代理拦截 407），`.183` 须 `docker.m.daocloud.io` 优先（1ms 极慢 < 100 KiB/s）。

#### 5.1.3 生成并执行 join 命令

在 **control-plane**（`.189`）上生成（token 默认 24h 有效，过期重新生成）：

```bash
kubeadm token create --print-join-command
```

在 **新节点**（`.183`）上执行，显式指定 containerd socket：

```bash
kubeadm join 192.168.40.189:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket unix:///run/containerd/containerd.sock
```

成功标志：`This node has joined the cluster` 并打印 Certificate exchange。

> **实测记录（2026-11-15，`.187` 加入）**：`kubeadm join` 一次成功；新节点 hostname `ubuntu-stage` 与现有节点不重名且 `getent hosts` 可解析。join 后 flannel/kube-proxy/node-exporter 自动部署，节点 `Ready`；随后 `kubectl label node ubuntu-stage node-role.kubernetes.io/worker=""` 使 ROLES 显示 `worker`（与 `.183` 一致）。

#### 5.1.4 验证

```bash
# control-plane 上
kubectl get nodes -o wide                       # 新节点 Ready，ROLE 为 <none> 或 worker（可打标签，见 5.1.5）
kubectl -n kube-flannel get pods -o wide        # 新节点上 flannel Running
kubectl -n kube-system get pods -o wide         # 新节点上 kube-proxy Running

# 跨节点连通（flannel VXLAN）
kubectl create deployment nginx --image=nginx:1.27 --replicas=3
kubectl rollout status deployment/nginx
kubectl get pods -l app=nginx -o custom-columns=NODE:.spec.nodeName,IP:.status.podIP --no-headers
# 取一个 A 节点 Pod IP 与一个 B 节点 Pod IP，互相 wget
kubectl run xnet --image=busybox:1.36 --restart=Never --rm -i --timeout=90s \
  --overrides='{"spec":{"nodeName":"<节点A>"}}' -- sh -c "wget -qO- http://<节点B的PodIP> | head -1"
kubectl delete deploy/nginx
```

#### 5.1.5 多节点注意事项

- **join 地址**：join 命令里的 `192.168.40.189:6443` 是 control-plane 的 `advertiseAddress`，新节点必须可达；跨网段时改用对应地址或在外层做转发。
- **节点间放行**：flannel 默认 VXLAN 走 **UDP 8472**，新节点与 control-plane 之间需放行（ufw/安全组），否则 Pod 跨节点不通。
- **控制平面单点**：本集群只有 `.189` 一个 control-plane，它宕机则 apiserver/etcd 不可用（worker 上的 Pod 仍可运行但无法调度）。
- **证书**：join 后节点证书由集群自动签发；`kubeadm certs renew` 在 control-plane 上执行。
- **角色标签（可选，纯展示）**：worker 默认 ROLES 显示 `<none>`，可打标签让显示 `worker`：
  ```bash
  kubectl label node <worker节点名> node-role.kubernetes.io/worker=""
  # 撤销：kubectl label node <worker节点名> node-role.kubernetes.io/worker-
  ```

## 6. 部署 CNI（flannel）

```bash
# 官方清单（GitHub raw 可达时）
curl -fsSL -o /tmp/kube-flannel.yml \
  https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

kubectl apply -f /tmp/kube-flannel.yml

# 等待就绪
kubectl -n kube-flannel rollout status ds/kube-flannel-ds
kubectl get pods -A -o wide
kubectl get nodes        # 应变为 Ready
```

> flannel 镜像位于 `ghcr.io`（`ghcr.io/flannel-io/flannel`、`ghcr.io/flannel-io/flannel-cni-plugin`），依赖第 4.2 章的 `ghcr.io` 镜像源。
> 若使用 `calico`：`kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/calico.yaml`，并注意 Calico 默认网段与 `POD_CIDR` 的匹配。

## 7. 验证部署

```bash
export KUBECONFIG=/root/.kube/config

kubectl get nodes -o wide                     # Ready
kubectl get pods -A                           # 全部 Running
kubectl get --raw='/readyz?verbose' | tail -1 # readyz check passed
kubectl version -o short                      # Client/Server 版本一致
kubeadm version -o short

# 端到端：部署 nginx 并验证 Service / DNS / 跨 Pod
kubectl create deployment nginx --image=nginx:1.27 --replicas=2
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl rollout status deployment/nginx

P2=$(kubectl get pods -l app=nginx -o jsonpath='{.items[1].status.podIP}')
kubectl run nettest --image=busybox:1.36 --restart=Never --rm -i --timeout=90s -- \
  sh -c "wget -qO- http://$P2 | head -1; wget -qO- http://nginx | head -1"

kubectl run dnstest --image=busybox:1.36 --restart=Never --rm -i --timeout=90s -- \
  nslookup kubernetes.default.svc.cluster.local

NP=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.40.189:$NP   # 200

# 验证后清理
kubectl delete deploy/nginx svc/nginx
```

### 7.1 快速验证脚本（一键检查，含日志与重试）

保存为 `kubernetes_verify.sh`，只读检查 + 一次 nginx 冒烟（失败自动重试），不修改集群配置。退出码 `0` = 全部通过，`1` = 存在失败项。
**请以文件方式执行**（`bash kubernetes_verify.sh`）；经管道 `... | bash -s` 运行时，脚本可能在收尾输出前随 stdin 关闭而终止。

```bash
#!/bin/bash
# Kubernetes 集群快速验证脚本：版本 / 节点 / 系统 Pod / 端到端工作负载
# 用法:   bash kubernetes_verify.sh
#         KUBECONFIG=/root/.kube/config bash kubernetes_verify.sh
#         LOG_FILE=/tmp/k8s_verify.log RETRY_MAX=3 RETRY_DELAY=5 bash kubernetes_verify.sh
# 退出码: 0=全部通过, 1=存在失败项

set -u
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
RETRY_MAX="${RETRY_MAX:-3}"; RETRY_DELAY="${RETRY_DELAY:-5}"
CMD_TIMEOUT="${CMD_TIMEOUT:-60}"; SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
START_TS=$(date +%s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/kubernetes_verify_$(date +%Y%m%d_%H%M%S).log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
PASS=0; FAIL=0; SKIP=0

log() { local l="$1"; shift; local line="[$(date '+%F %T')] [$l] $*"; echo "$line"; echo "$line" >> "$LOG_FILE"; }
show() { local out="$1" n="${2:-5}"; [ -z "$out" ] && { log WARN "  （无输出）"; return; }; echo "$out" | sed '/^\s*$/d' | head -n "$n" | while IFS= read -r l; do log INFO "  | $l"; done; }
rc_desc() { case "$1" in 124) echo "超时(124)";; 137) echo "被终止(137)";; *) echo "退出码: $1";; esac; }

check() { local d="$1"; shift; log INFO "执行: $*"; local out rc; out=$(timeout "$CMD_TIMEOUT" "$@" 2>&1); rc=$?; if [ $rc -eq 0 ]; then log PASS "$d"; [ -n "$out" ] && show "$out" 3; PASS=$((PASS+1)); else log FAIL "$d ($(rc_desc $rc))"; show "$out" 5; FAIL=$((FAIL+1)); fi; }
check_retry() { local d="$1" max="$2" delay="$3"; shift 3; local i out rc; for i in $(seq 1 "$max"); do log INFO "执行(第 $i/$max 次): $*"; out=$(timeout "$CMD_TIMEOUT" "$@" 2>&1); rc=$?; if [ $rc -eq 0 ]; then log PASS "$d (第 $i 次成功)"; [ -n "$out" ] && show "$out" 3; PASS=$((PASS+1)); return 0; fi; log WARN "第 $i/$max 次失败 ($(rc_desc $rc))"; show "$out" 3; [ "$i" -lt "$max" ] && sleep "$delay"; done; log FAIL "$d 重试 $max 次后仍失败"; FAIL=$((FAIL+1)); return 1; }

log INFO "=== Kubernetes 验证开始 ==="
log INFO "主机: $(hostname) | KUBECONFIG: $KUBECONFIG | 日志: $LOG_FILE"

# 1. 客户端版本
check "kubectl 可用" kubectl version --client -o yaml
# 2. 服务端可达
check_retry "API Server 可达" "$RETRY_MAX" "$RETRY_DELAY" kubectl get --raw='/readyz'
# 3. 全部节点 Ready
node_ready=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
notready=$(printf '%s\n' "$node_ready" | grep -vc '^True$' || true)
if [ -n "$node_ready" ] && [ "${notready:-0}" -eq 0 ]; then log PASS "全部节点 Ready"; PASS=$((PASS+1)); else log FAIL "存在未 Ready 节点（Ready 状态: $(echo $node_ready | tr '\n' ' ')）"; FAIL=$((FAIL+1)); fi
# 4. 系统 Pod 全部 Running
notrun=$(kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -vc 'Running' || true)
if [ "${notrun:-0}" -eq 0 ]; then log PASS "kube-system Pod 全部 Running"; PASS=$((PASS+1)); else log FAIL "kube-system 存在非 Running Pod（$notrun 个）"; kubectl get pods -n kube-system -o wide | while IFS= read -r l; do log INFO "  | $l"; done; FAIL=$((FAIL+1)); fi
# 5. kube-proxy / coredns 存在
check "CoreDNS 已部署" kubectl -n kube-system get deploy coredns
check "kube-proxy 已部署" kubectl -n kube-system get ds kube-proxy
# 6. CNI Pod
check_retry "flannel 运行中" "$RETRY_MAX" "$RETRY_DELAY" kubectl -n kube-flannel get ds kube-flannel-ds

# 7. 端到端冒烟（nginx + Service + DNS）
smoke() {
  kubectl delete deploy/k8s-verify-nginx svc/k8s-verify-nginx --ignore-not-found >/dev/null 2>&1
  kubectl create deployment k8s-verify-nginx --image=nginx:1.27 --replicas=2 >/dev/null 2>&1 || return 1
  kubectl expose deployment k8s-verify-nginx --port=80 >/dev/null 2>&1 || return 1
  kubectl rollout status deployment/k8s-verify-nginx --timeout="${SMOKE_TIMEOUT}s" >/dev/null 2>&1 || return 1
  local p2; p2=$(kubectl get pods -l app=k8s-verify-nginx -o jsonpath='{.items[1].status.podIP}' 2>/dev/null)
  kubectl run k8s-verify-net --image=busybox:1.36 --restart=Never --rm -i --timeout=90s -- \
    sh -c "wget -qO- http://$p2 | head -1; wget -qO- http://k8s-verify-nginx | head -1" >/dev/null 2>&1 || return 1
  kubectl run k8s-verify-dns --image=busybox:1.36 --restart=Never --rm -i --timeout=90s -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 || return 1
  kubectl delete deploy/k8s-verify-nginx svc/k8s-verify-nginx --ignore-not-found >/dev/null 2>&1
  return 0
}
retry_smoke() {
  local i
  for i in $(seq 1 "$RETRY_MAX"); do
    log INFO "冒烟测试(第 $i/$RETRY_MAX 次)"
    if smoke; then log PASS "端到端冒烟（Pod 互通 + Service + DNS）(第 $i 次成功)"; PASS=$((PASS+1)); return 0; fi
    log WARN "第 $i 次冒烟失败，等待 ${RETRY_DELAY}s"
    [ "$i" -lt "$RETRY_MAX" ] && sleep "$RETRY_DELAY"
  done
  log FAIL "端到端冒烟重试 $RETRY_MAX 次后仍失败"
  FAIL=$((FAIL+1)); return 1
}
retry_smoke

ELAPSED=$(( $(date +%s) - START_TS ))
log INFO "=== 结果: $PASS 通过, $FAIL 失败, $SKIP 跳过 (总耗时 ${ELAPSED}s) ==="
log INFO "完整日志: $LOG_FILE"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

Agent 判定规则：

- 退出码 `0` → 部署验证通过，汇报各项 PASS 结果。
- 退出码 `1` → 读取日志文件（路径见末行），逐项分析 FAIL 输出摘要，按第 8 章排障，不要盲目重试。
- 节点未 Ready 但系统 Pod 正常 → 多为 CNI 未就绪，检查 `kube-flannel` 与镜像拉取。
- 冒烟失败但系统检查通过 → 多为 `docker.io` 镜像源问题（见 8.2）。

## 8. 排障

### 8.1 镜像拉取失败（ImagePullBackOff / ErrImagePull）

```bash
kubectl -n <ns> describe pod <pod>          # 看 Events 中的真实拉取地址与错误
journalctl -u kubelet --no-pager -n 50
```

常见原因与处理：

- **`registry.k8s.io` 直连超时**：说明 containerd CRI 镜像源未生效。检查 `/etc/containerd/certs.d/registry.k8s.io/hosts.toml` 是否存在、`config_path` 是否指向 `/etc/containerd/certs.d`，然后 `systemctl restart containerd`。
- **`docker.io` blob 指向 `image-mirror.r2.daocloud.vip` 超时（407/超时）**：说明本机 daocloud 的 blob 链路不通。把 `docker.io` 的 host 顺序改为 `docker.1ms.run` 在前（或按 4.2 选源方法重测）；反之若 1ms 慢则把 daocloud 提前。
- **`ghcr.io` TLS handshake timeout**：确认 `/etc/containerd/certs.d/ghcr.io/hosts.toml` 指向 `ghcr.m.daocloud.io`。
- **镜像源本身失效**：用 `curl -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' https://<mirror>/v2/<repo>/manifests/<tag>` 探测候选源（401 表示可达且需 token，200 表示有该镜像），换用可用源后重启 containerd。
- **kubelet 日志出现 `read tcp ... connection timed out` / `failed to copy`**：镜像源链路劣化。先看 `journalctl -u kubelet` 里 `totalImagesPullingTime`（排队+拉取总耗时）判断是偶发还是持续；持续则按 4.2 换源。
- **测试 Pod 长时间 ContainerCreating 而镜像已缓存**：kubelet 对镜像拉取**串行化**（`imagePullSessionsCount`），一个慢拉取会阻塞同节点后续 Pod。冒烟测试建议用 `imagePullPolicy: IfNotPresent` + 已缓存镜像（见 5.1.4）。

### 8.2 节点 NotReady

```bash
kubectl describe node ubuntu | tail -20
kubectl get pods -n kube-flannel -o wide
journalctl -u kubelet --no-pager -n 50
```

- CNI 未部署 → 执行第 6 章。
- `containerd` 未运行 / socket 不存在 → `systemctl status containerd`。
- kubelet 报 `failed to run Kubelet: misconfiguration: kubelet cgroup driver: "systemd" ...` → 确认 containerd `SystemdCgroup = true`。

### 8.3 kubeadm init 失败

```bash
kubeadm reset -f            # 仅在确认要重建时执行（会清空集群数据）
kubeadm init --config /root/kubeadm-config.yaml -v=5
```

- 证书/网段冲突：`kubeadm reset -f` 后重试。
- 端口 6443 被占用：`ss -lntp | grep 6443`。

### 8.4 Docker 受影响

重启 containerd 后 Docker 容器短暂中断。若容器未自动恢复：

```bash
systemctl restart docker
docker ps
```

> 长期方案：若不能容忍 Docker 中断，可为 k8s 单独跑一个 containerd 实例（独立 `--config`/`--root`/`--state` 与 socket），并在 kubeadm 的 `nodeRegistration.criSocket` 指向它。

### 8.5 k8s 组件安装失败（apt 源 403 / 404）

```bash
cat /etc/apt/sources.list.d/kubernetes.list   # 核对 URL
curl -sI https://pkgs.k8s.io/core:/stable:/v1.37/deb/InRelease | head -3
```

- **404 Not Found**：仓库路径用了完整版本（`v1.37.2`）。必须是 **minor 版本 `v1.37`**（见第 2 章）。
- **403 Forbidden（CloudFront）**：`pkgs.k8s.io` 会 302 到 `prod-cdn.packages.k8s.io`，间歇性拒绝 apt 请求（同一 URL 用 curl 可能 200）。改用清华/中科大镜像：把 `kubernetes.list` 的 URI 换成 `https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.37/deb/`（或 USTC），`Release.key` 同地址重下一次（已装 key 可复用，指纹 `isv:kubernetes` 一致）。
- **签名校验失败导致 `Ign: ... InRelease`**：多为 key 未装好或 URL 不匹配；用 `gpg --show-keys --with-fingerprint` 核对是否为 `isv:kubernetes`。

## 9. Agent 执行注意事项

- **先检查再执行**：每章先做只读检查，已完成内容自动跳过；`/etc/kubernetes/admin.conf` 存在即视为已 init。
- **参数先确认**：执行前向用户确认参数区参数（尤其 `DISABLE_SWAP`、`CNI`、`K8S_VERSION`）。
- **危险操作必须确认**：`kubeadm reset`、`systemctl restart containerd`（影响 Docker 业务容器）、修改 `/etc/fstab`、`swapoff -a`，执行前逐项征求同意。
- **共用 containerd 的告警**：若目标机已运行 Docker 容器，第 4 章重启 containerd 前必须告知用户影响面与业务容器重启策略。
- **不要使用 kubeadm `imageRepository` 指向镜像站**（coredns 路径丢失），改用 containerd `certs.d`。
- **不要 `apt upgrade` 升级 k8s 组件**：已 `apt-mark hold`；升级需显式 `apt-mark unhold` 并按版本逐个升级。
- **k8s apt 源用 minor 版本路径**（`v1.37` 而非 `v1.37.2`），否则 404；官方源 403 时换清华/中科大镜像（见 8.5）。
- **改镜像源后重启 containerd 前先评估影响面**：控制面节点上跑着 Harbor / ingress 等业务，重启会短暂中断；worker 节点也建议选低峰期。若只需新增/调换 `certs.d` 条目，可先不重启、观察 kubelet 是否已按新配置拉取（containerd 会按需重载），无效再重启。
- **测试镜像优先用节点已缓存的 tag**：跨节点冒烟时给测试 Pod 加 `imagePullPolicy: IfNotPresent`，避免镜像源抖动掩盖真实的网络问题。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 10. 卸载（可选，破坏性，需用户确认）

```bash
# 1) 在 control-plane 上先把每个节点排空（多节点时逐个执行）
for n in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --force
done
# 2) 然后在**每个节点**上执行 reset 与清理
kubeadm reset -f
systemctl disable --now kubelet
apt-get purge -y kubelet kubeadm kubectl
rm -rf /etc/kubernetes /var/lib/etcd /root/.kube
# CNI（control-plane 上，reset 前执行）
kubectl delete -f /tmp/kube-flannel.yml --ignore-not-found
# 恢复 swap（如不再需要禁用，每个节点）
sed -i '/^#\/swap.img/ s/^#//' /etc/fstab && swapon -a
```

> `kubeadm reset` 会删除集群全部数据（含 etcd），必须经用户明确确认后执行。
