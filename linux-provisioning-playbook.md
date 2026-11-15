# Ubuntu 环境初始化与 Kubernetes 接入实操手册（2026-11-15 会话沉淀）

## 文档说明

本文档是 2026-11-15 一次完整实操会话的经验沉淀，覆盖**从零初始化一台 Ubuntu 服务器**（Docker / Node.js / npm / pnpm / promptfoo）到**把它加入既有 kubeadm 集群**的全过程，供后续在**类似 Ubuntu 环境**中复用。

- **定位**：跨组件的「实操要点 + 实测数据 + 踩坑速查」。各组件的完整分步手册见第 8 章「关联文档」，本文只写**最容易踩坑、最值得复用**的部分。
- **环境假设**：Ubuntu 22.04 / 24.04 x86_64，root 或具备免密 sudo 的账户，国内网络（镜像源优先国内）。
- **原则**：先只读检查再执行；安装步骤幂等；危险操作（重启 containerd、改 fstab、swapoff）先评估影响面。

## 1. 环境基线（本次会话）

| 节点 | hostname | 角色 | 系统 | 配置 | 访问 |
| --- | --- | --- | --- | --- | --- |
| `192.168.40.189` | `ubuntu` | k8s control-plane | Ubuntu 24.04.2 / kernel 6.8 | 24C / 62G / 98G | 密码（本次） |
| `192.168.40.183` | `ubunt-dev` | k8s worker | Ubuntu 22.04 / kernel 5.15 | 8C / 16G / 234G | 密码（本次） |
| `192.168.40.187` | `ubuntu-stage` | k8s worker（本次新加入） | Ubuntu 24.04.2 / kernel 6.8 | 16C / 43G / 98G | 已装公钥，免密 |

集群：kubeadm **v1.37.2** + containerd **2.4.2** + flannel（VXLAN，UDP 8472），`POD_CIDR=10.244.0.0/16`、`SERVICE_CIDR=10.96.0.0/12`，默认 StorageClass `local-path`。

本次会话在 `.187` 上装得：**Docker 29.9.3 + Compose v5.7.1**、**nvm 0.40.3 + Node v24.22.3（npm 11.19.1）+ pnpm 12.21.0**、**promptfoo 0.125.1**；并把 `.187` 以 worker 身份加入 `.189` 集群。

## 2. 接入通道：SSH 免密（Windows 本机 → Ubuntu）

Windows 本机通常只有 OpenSSH（无 `sshpass` / `plink` / `ssh-copy-id`），带密码的非交互登录用 `SSH_ASKPASS`：

```bash
# 1) 造一个 .bat 作为 askpass（Windows 版 OpenSSH 无法执行 .sh，会报 ssh_askpass: exec(...): No such file or directory）
printf '@echo off\necho "<密码>"\n' > .askpass_tmp.bat

# 2) 首次密码登录（DISPLAY 与 SSH_ASKPASS_REQUIRE=force 缺一不可）
SSH_ASKPASS="$(cygpath -w "$PWD/.askpass_tmp.bat")" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<host> "echo OK"

# 3) 分发公钥实现免密（幂等；本机无 ssh-copy-id 时用管道）
PUB=$(cat ~/.ssh/id_ed25519.pub)
ssh root@<host> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys \
  && grep -qF '$PUB' ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"

# 4) 之后用密钥执行
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@<host> "<命令>"
```

**要点**

- 目标 Ubuntu 的 `~/.ssh/authorized_keys` 权限必须是 `600`、`~/.ssh` 是 `700`，否则 sshd 拒绝。
- 首次用密码登录后**立刻装公钥**，后续所有操作不再依赖 askpass；任务结束删除 `.askpass_tmp.bat`。
- 远程执行**复杂命令**时，把脚本写到本地文件再用 `ssh host "bash -s" < 脚本.sh` 管道执行，避免多层引号转义（本次会话多次因引号嵌套失败）。
- 验证非交互会话的命令用**登录 shell**：`bash -lc 'node --version'`——Ubuntu 的 `~/.bashrc` 对非交互 shell 提前 `return`，nvm 初始化块不会执行。

## 3. 基础组件安装要点

### 3.1 Docker（详见 [linux-docker.md](linux-docker.md)）

```bash
# apt 源用阿里云（国内源优先；GPG key 与仓库同域更稳）
DOCKER_APT=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
curl -fsSL "$DOCKER_APT/gpg" -o /etc/apt/keyrings/docker.asc
# deb822 形式写入 /etc/apt/sources.list.d/docker.sources（见手册）
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**要点**

- **Ubuntu 基础源也建议一起换**（`archive.ubuntu.com` → `mirrors.aliyun.com/ubuntu`），但**备份文件不要留在 `/etc/apt/sources.list.d/`**——apt 会因扩展名不合法打印 `N: Ignoring file '...bak' ... invalid filename extension`，备份请放 `/root/apt-backups/`。
- `daemon.json` 必须配**日志轮转**：默认 `json-file` 无上限，容器日志会撑爆磁盘。
  ```json
  { "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
  ```
- `registry-mirrors` 只是声明，**最终以 `docker run --rm hello-world` 能否成功为准**。
- root 用户无需 `usermod -aG docker`。

### 3.2 Node.js / npm / pnpm（详见 [linux-npm.md](linux-npm.md)）

```bash
# nvm：raw.githubusercontent.com 不可达时整体加代理前缀（github.com 可达，install.sh 内部走 git clone）
NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh"
curl -fsSL -m 30 -o /tmp/nvm-install.sh "$NVM_INSTALL_URL" \
  || curl -fsSL -m 90 -o /tmp/nvm-install.sh "https://ghfast.top/${NVM_INSTALL_URL}"
bash /tmp/nvm-install.sh
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node/
nvm install 24 && nvm alias default 24
npm config set registry https://registry.npmmirror.com
npm install -g pnpm@latest --allow-scripts=pnpm
```

**要点**

- **nvm 初始化要写进 `~/.profile`**（不是只靠 `.bashrc`），否则 SSH 非交互会话里 `node`/`nvm` 不可用。
- `raw.githubusercontent.com` 在国内**经常性超时（HTTP 000）**，`github.com` 通常可达——所以 nvm 的 `install.sh` 即使 raw 域名失败也常能装成功；仍失败就用 `ghfast.top` 前缀。
- npm ≥ 11 默认不跑依赖安装脚本，全局装包加 `--allow-scripts=<pkg>`（旧版报 `Unknown cli config` 则去掉）。
- 安装前**先探测镜像连通性**（`curl -s -o /dev/null -w '%{http_code} %{time_total}\n' <镜像>`），不要照抄文档默认值。

### 3.3 promptfoo（详见 [linux-promptfoo.md](linux-promptfoo.md)）

```bash
npm install -g promptfoo --registry=https://registry.npmmirror.com --allow-scripts
promptfoo --version                       # 实测 0.125.1
promptfoo init --no-interactive           # Agent/SSH 非交互环境必须加 --no-interactive
```

**要点**

- `promptfoo init` 默认是**交互式向导**，Agent 直接跑会挂起等待输入；加 `--no-interactive`。
- 生成的是 **`promptfooconfig.yaml`**（新版默认名），不是旧文档常说的 `promptfoo.yaml`——存在性检查两个名字都要看。
- `init` 结束后可能打印 `telemetry.shutdown() timed out during shutdown`，属正常噪声。
- Node 版本建议用 **LTS 主版本**（实测 Node 24 LTS 可用），不要用 `stable`（镜像可能解析到预发布版）。

## 4. Kubernetes 节点接入要点（详见 [linux-kubernetes.md](linux-kubernetes.md)）

```bash
# 控制面生成 join 命令（token 24h 有效）
kubeadm token create --print-join-command
# 新节点执行（显式指定 containerd socket）
kubeadm join 192.168.40.189:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket unix:///run/containerd/containerd.sock
```

**要点（按踩坑顺序）**

1. **k8s apt 仓库路径用 minor 版本**（`.../core:/stable:/v1.37/deb`），写成 `v1.37.2` 会 **404**。
2. **官方 `pkgs.k8s.io` 会 302 到 CloudFront，间歇 403**（同一 URL 用 curl 可能 200，apt 却 403）。改用**清华/中科大镜像**：`https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.37/deb`。`Release.key` 同样重试下载。
3. **新节点 hostname 必须唯一且 `getent hosts $(hostname)` 可解析**，否则 kubelet 以同名注册导致节点冲突。
4. **containerd 与 Docker 共用**：Docker 29 装完自带 containerd，但配置是精简版（`disabled_plugins = ["cri"]`）。需 `containerd config default` 重新生成，改 `SystemdCgroup = true` 与 `config_path = '/etc/containerd/certs.d'`，再重启 containerd（会短暂影响同机 Docker 容器，先确认影响面）。
5. **swap 必须禁用**（`swapoff -a` + 注释 `/etc/fstab`），`br_netfilter` 必须加载。
6. **镜像源用 containerd `certs.d` 透明映射**，不要用 kubeadm `imageRepository`（会丢掉 `coredns/` 命名空间路径）。
7. **重启 containerd 前评估影响面**：控制面节点上往往跑着 GitLab / Harbor / ArgoCD 等，重启会短暂中断 API 与这些负载。
8. **跨节点连通**依赖 flannel VXLAN（UDP 8472）与节点间防火墙放行。
9. 冒烟测试建议 `imagePullPolicy: IfNotPresent` + **节点已缓存**的镜像，避免镜像源抖动掩盖真实网络问题。

## 5. 国内镜像源实测（2026-11-15）

> **重要结论：免费镜像源会「分钟级」波动，同一节点同一镜像可能此刻 1.5s、彼时 1.5 KiB/s。因此①配置多源回退；②排障时先重测再下结论。**

### 5.1 docker.io（containerd `certs.d`）

| 镜像源 | `.187` | `.183` | `.189` | 备注 |
| --- | --- | --- | --- | --- |
| `hub.rat.dev` | 1.5s ✅ | 0.9s ✅ | 间歇 FAIL | 波动大 |
| `docker.1panel.live` | 21.8s ✅ | 1.7s ✅ | 2.1s ✅ | 三节点都可用 |
| `docker.xuanyuan.me` | 14.8s ✅ | 8.3s ✅ | 14.4s ✅ | 三节点都可用 |
| `docker.1ms.run` | 0.7s ✅ / 也出现 1.5 KiB/s ❌ | 0.7s ✅ | 0.6s ✅ | 波动极大，曾返回 `UNAUTHORIZED` |
| `docker.m.daocloud.io` | 曾 10.7s / 慢 ❌ | 7.2s ✅ | 0.6s ✅ | 波动 |
| `dockerpull.org` / `docker.nju.edu.cn` / `docker.mirrors.ustc.edu.cn` / `hub.littlediary.cn` / `docker.hlmirror.com` / `docker.rainbond.cc` | ❌ | — | ❌ | 实测不可达/不稳定 |
| `docker.imgdb.de` | ❌（`failed precondition`） | ❌ | ❌ | 不稳定 |

**推荐配置（三节点统一，按序回退）**：

```toml
server = "https://docker.io"
[host."https://docker.1ms.run"]      capabilities = ["pull", "resolve"]
[host."https://docker.m.daocloud.io"] capabilities = ["pull", "resolve"]
[host."https://hub.rat.dev"]          capabilities = ["pull", "resolve"]
[host."https://docker.1panel.live"]   capabilities = ["pull", "resolve"]
[host."https://docker.xuanyuan.me"]   capabilities = ["pull", "resolve"]
```

**选源方法**：用**未缓存的较大镜像**（如 `nginx:1.28`）测，小镜像（alpine）会被边缘缓存导致测速失真：

```bash
for m in docker.1ms.run docker.m.daocloud.io hub.rat.dev docker.1panel.live docker.xuanyuan.me; do
  printf '%-24s ' "$m"
  s=$(date +%s%N)
  timeout 60 ctr -n k8s.io images pull "$m/library/nginx:1.28" >/tmp/m.log 2>&1 \
    && echo "OK $(( ($(date +%s%N)-s)/1000000 ))ms" || echo "FAIL"
  ctr -n k8s.io images rm "$m/library/nginx:1.28" >/dev/null 2>&1
done
```

> 注意：`ctr -n k8s.io images pull` **默认不读** CRI 的 `config_path`，验证 `certs.d` 是否生效要加 `--hosts-dir /etc/containerd/certs.d`。

### 5.2 k8s 组件 apt 源

| 源 | 结果 |
| --- | --- |
| `https://pkgs.k8s.io/core:/stable:/v1.37/deb` | 可达但间歇 403（CloudFront） |
| `https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.37/deb` | ✅ 实测可用 |
| `https://mirrors.ustc.edu.cn/kubernetes/core:/stable:/v1.37/deb` | ✅ 实测可用 |
| `https://mirrors.aliyun.com/kubernetes/apt` | ❌ 对 22.04/24.04 支持不全 |

### 5.3 其他

| 上游 | 可用源 |
| --- | --- |
| `registry.k8s.io` | `k8s.m.daocloud.io`（保留完整仓库路径，如 `coredns/coredns`） |
| `ghcr.io` | `ghcr.m.daocloud.io` |
| `quay.io` | `quay.m.daocloud.io`、`quay.nju.edu.cn` |
| npm | `https://registry.npmmirror.com` |
| Node 二进制 | `https://npmmirror.com/mirrors/node/` |
| Harbor（集群内私有仓库） | `https://192.168.40.189:30003`（自签 CA，见 [kubernetes-harbor.md](kubernetes-harbor.md)） |

## 6. 共性踩坑与排障速查

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| `ssh_askpass: exec(...): No such file or directory` | Windows OpenSSH 无法执行 `.sh` 作为 askpass | 改用 `.bat`/`.cmd`，并设 `SSH_ASKPASS_REQUIRE=force` + `DISPLAY=:0` |
| apt 备份文件触发 `N: Ignoring file ... invalid filename extension` | 备份留在 `/etc/apt/sources.list.d/` | 移到 `/root/apt-backups/` 等目录 |
| `Release.key` / `InRelease` 403 | `pkgs.k8s.io` → CloudFront 间歇拒绝 | 换清华/中科大镜像；key 下载加重试 |
| k8s apt `404` | 仓库路径用了 `v1.37.2` | 改 minor 版本 `v1.37` |
| npm 全局安装报 `npm warn install-scripts` | npm ≥ 11 默认不跑安装脚本 | 加 `--allow-scripts=<pkg>` |
| SSH 非交互会话 `node`/`nvm` 不存在 | `~/.bashrc` 提前 return，初始化没执行 | 初始化写 `~/.profile`；验证用 `bash -lc` |
| `promptfoo init` 卡住不动 | 交互式向导等待输入 | 加 `--no-interactive` |
| Pod 长时间 `ContainerCreating`、事件停在 `Pulling image` | 镜像源劣化 / kubelet 拉取串行排队 | 看 `journalctl -u kubelet` 的 `totalImagesPullingTime`；按第 5 章重测换源 |
| 测试 Pod 报 `AlreadyExists ... being deleted` | 上一次测试 Pod 还在 Terminating，重名冲突 | 测试 Pod 用唯一名（如带序号/时间戳） |
| 跨节点测试偶发失败 | 测试镜像未缓存 + 镜像源抖动 | 加 `imagePullPolicy: IfNotPresent` + 已缓存镜像 |
| `systemctl restart containerd` 后业务中断 | containerd 重启会杀容器 | 先确认节点上运行负载与重启策略，选低峰期；Docker 容器通常按 restart 策略自愈 |

## 7. 复用清单（换环境时逐项确认）

- [ ] 本机 SSH 通道：askpass 首次登录 → 装公钥 → 全程密钥。
- [ ] 目标机系统版本/架构/资源确认；hostname 唯一且可解析。
- [ ] 镜像连通性**先探测再安装**（apt、docker.io、registry.k8s.io、ghcr、npm）。
- [ ] Docker：apt 源 + `daemon.json`（镜像加速 + **日志轮转**）。
- [ ] Node：`~/.profile` 初始化 + 国内 registry + pnpm。
- [ ] promptfoo：`--allow-scripts`、`init --no-interactive`。
- [ ] k8s：apt **minor 版本路径** + containerd CRI（`SystemdCgroup`、`config_path`）+ 禁 swap + `br_netfilter`。
- [ ] 加入集群：`kubeadm join --cri-socket ...`；验证节点 Ready、flannel/kube-proxy Running、跨节点 Pod 互通。
- [ ] 危险操作（重启 containerd、改 fstab、swapoff）已评估影响面并获确认。
- [ ] 任务收尾：删除临时脚本/日志，文档回写实测数据。

## 8. 关联文档

| 文档 | 内容 |
| --- | --- |
| [linux-docker.md](linux-docker.md) | Docker 安装 / 镜像加速 / 空间清理 |
| [linux-npm.md](linux-npm.md) | Node.js（nvm）/ npm / pnpm 安装与排障 |
| [linux-promptfoo.md](linux-promptfoo.md) | promptfoo 安装、初始化与验证 |
| [linux-kubernetes.md](linux-kubernetes.md) | kubeadm + containerd + flannel 部署与节点加入 |
| [kubernetes-harbor.md](kubernetes-harbor.md) | 集群内 Harbor 私有仓库部署 |
