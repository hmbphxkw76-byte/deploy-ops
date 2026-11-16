# Windows kubectl 安装与集群直连最佳实践（供 AI IDE / Agent 执行）

## 文档说明

本文档面向 **Windows 10/11（x64）**，用于安装 `kubectl`、获取并配置 kubeconfig，**直连既有 Kubernetes 集群**，并沉淀日常操作、安全与排障的最佳实践。适用于任意 AI IDE 或 AI Agent（Trae、Qoder、WorkBuddy、妙手等）按手册执行；安装与配置幂等，重复运行安全。

**落地实例**：集群 `https://192.168.40.189:6443`（v1.37.2，三节点：control-plane `192.168.40.189` + worker `192.168.40.183` / `192.168.40.187`，详见 [linux-kubernetes.md](linux-kubernetes.md)）。kubeconfig 来源为该 control-plane 上的 `/etc/kubernetes/admin.conf`。

> **实测基线（2026-11-16）**：`winget install Kubernetes.kubectl --version 1.37.2` 一次成功；kubeconfig 经 SSH 取回后，PowerShell 与 git bash 均可直连，`kubectl auth can-i --list` 返回 `*.* [*]`（cluster-admin）；`admin.conf` 客户端证书到期日 **2027-11-15**（约 363 天）。当前 `kubectl get nodes -o wide` 输出见第 4 节。
>
> 跨组件的集群部署、镜像源与节点排障见 [linux-kubernetes.md](linux-kubernetes.md)；集群上的 GitOps 交付见 [kubernetes-argocd.md](kubernetes-argocd.md)。

### 可复用性说明（配置到类似 Windows 环境时必读）

- 正文中的具体路径、IP、版本仅为**本实例**；**所有 `.kube/config` 路径以参数区 `KUBECONFIG_PATH` 为准**，复用到其他 Windows 环境时，逐一替换参数区的 `REPO_DIR`、`CLUSTER_API`、`SSH_SOURCE`、`KUBECTL_VERSION` 即可，流程与命令不变。
- **建议英文路径**（如 `C:\kube\config`）。中文路径实测可用，但部分旧脚本/工具对非 ASCII 路径处理不佳；若必须使用，注意第 6 节的引号与编码细节。
- 命令同时给出 **PowerShell** 与 **git bash** 两种写法；两者共享同一 `kubectl` 二进制与 kubeconfig。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `KUBECTL_VERSION` | `v1.37.2` | 客户端版本；**必须与服务端 minor 版本对齐**（本集群服务端 v1.37.2） |
| `KUBECTL_PKG` | `Kubernetes.kubectl` | winget 包 ID（源 `winget`） |
| `CLUSTER_API` | `https://192.168.40.189:6443` | API Server 地址，取自 kubeconfig `server` 字段 |
| `KUBE_CONTEXT` | `kubernetes-admin@kubernetes` | 默认 context 名 |
| `REPO_DIR` | `D:\文档\GitHub\deploy-ops` | 当前 Windows 工作目录，复用时替换 |
| `KUBECONFIG_PATH` | `<REPO_DIR>\.kube\config` | 本仓库约定路径（见第 3 节）；标准路径为 `%USERPROFILE%\.kube\config` |
| `SSH_SOURCE` | `root@192.168.40.189:/etc/kubernetes/admin.conf` | kubeconfig 来源；需本机已配置免密登录 |
| `KUBECONFIG_ENV` | `User` 级环境变量 | 指向 `KUBECONFIG_PATH`，使 kubectl 免 `--kubeconfig` 直连 |
| `SHELL` | `pwsh` / `git bash` | 影响传参与文件重定向写法（第 6 节） |

> **版本对齐原则**：kubectl 官方支持「客户端至多比服务端高/低一个小版本」。本手册统一**客户端 = 服务端 minor**，避免 `kubectl` 与 API 行为差异（如服务端校验、server-side apply 字段、资源版本）。升级集群后同步升级本机 kubectl，并跑第 4 节的漂移检查。

### 复用清单（Checklist）

```text
□ 确认参数区（版本 / 集群地址 / kubeconfig 路径 / 来源）
□ 安装 kubectl 并确认 minor 与服务端对齐（第 2 章）
□ 取回 kubeconfig → KUBECONFIG_PATH（第 3.1 章）
□ 设置用户级 KUBECONFIG 环境变量（第 3.2 章）
□ 运行第 4 章验证，确认节点 Ready、权限符合预期
□ icacls 加固文件 ACL，并备份 kubeconfig（第 3.3 / 7 章）
```

## 1. 前置检查（只读，不修改系统）

```powershell
# 1) 是否已安装 kubectl
Get-Command kubectl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
kubectl version --client

# 2) 服务端可达（期望 200）
curl.exe -sk -m 8 -o NUL -w "%{http_code}\n" https://192.168.40.189:6443/healthz

# 3) 免密登录 control-plane（期望输出 OK 与 hostname）
ssh -o BatchMode=yes root@192.168.40.189 "echo OK; hostname"

# 4) 本机是否已有 kubeconfig
Test-Path "$env:USERPROFILE\.kube\config"
Test-Path ".kube\config"
```

判定逻辑：

- `kubectl` 已安装且 `Client Version` 的 minor 与服务端一致 → 跳过第 2 章。
- 服务端 `/healthz` 非 200 或 SSH 失败 → 先按 [linux-kubernetes.md](linux-kubernetes.md) 第 8 章排障，不要继续。
- 已有可用 kubeconfig 且第 4 章验证通过 → 跳过第 3 章。

## 2. 安装 kubectl（Windows）

### 2.1 方式 A：winget（推荐）

```powershell
winget install --id Kubernetes.kubectl --version 1.37.2 --exact `
  --accept-source-agreements --accept-package-agreements --disable-interactivity
```

> winget 会从官方 `dl.k8s.io` 下载并校验哈希，安装后**自动修改用户 PATH**。安装器提示「重启 shell 以使用新值」——**新开一个终端**即生效；当前会话可用第 2.3 节的命令手动刷新。
> 幂等：已安装同版本时 winget 提示已安装，不重复下载；升级用 `winget upgrade --id Kubernetes.kubectl`（升级属变更操作，先向用户确认）。

### 2.2 方式 B：官方 exe 直装（无 winget 时）

```powershell
$ver  = "1.37.2"
$dest = "$env:LOCALAPPDATA\kubectl"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Invoke-WebRequest -Uri "https://dl.k8s.io/release/v$ver/bin/windows/amd64/kubectl.exe" `
  -OutFile "$dest\kubectl.exe"

# 若该目录不在用户 PATH 上，追加（幂等：先检查）
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -notlike "*$dest*") {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
}
```

> 校验哈希（可选）：官方校验文件位于 `https://dl.k8s.io/release/v$ver/bin/windows/amd64/kubectl.exe.sha256`。

### 2.3 刷新 PATH（安装后当前会话立即生效）

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
Get-Command kubectl | Select-Object -ExpandProperty Source
kubectl version --client
```

> 该刷新只影响当前进程；**新终端**自动带上 winget/手动写入的用户 PATH。

## 3. 获取并配置 kubeconfig

### 3.1 从 control-plane 取回 admin.conf

```bash
# 在 git bash / WSL 中执行（避免 PowerShell 管道改写字节）
mkdir -p .kube
ssh root@192.168.40.189 "cat /etc/kubernetes/admin.conf" > .kube/config
chmod 600 .kube/config
```

> **为什么用重定向而非 PowerShell 管道**：`ssh ... | Set-Content`/`Out-File` 会按文本处理，可能引入 BOM 或换行转换，导致 YAML 解析失败；`ssh ... > file` 保留原始字节。PowerShell 中如需一行搞定，用 `cmd /c "ssh root@192.168.40.189 cat /etc/kubernetes/admin.conf > .kube\config"`。
> 该文件含**客户端私钥与 cluster-admin 凭据**，属敏感文件；不要经聊天/邮件/工单传输。

### 3.2 本仓库约定：`.kube/config` + 用户级 KUBECONFIG

```powershell
# 1) 环境变量指向 kubeconfig（User 级，新开终端生效）
#    在仓库根目录执行；复用时把 $KUBE_CFG 换成实际绝对路径
$KUBE_CFG = "$PWD\.kube\config"
[Environment]::SetEnvironmentVariable('KUBECONFIG', $KUBE_CFG, 'User')

# 2) 当前会话立即生效
$env:KUBECONFIG = $KUBE_CFG

# 3) 确认 kubectl 已识别（应输出 server 地址）
kubectl config view -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

`.gitignore` 已含 `.kube/`，确保凭据不入库（见仓库根 `.gitignore`）。

> **标准方案（可选）**：若希望走 kubectl 默认路径，把文件放到 `%USERPROFILE%\.kube\config` 即可，无需设置 `KUBECONFIG`。本仓库采用 `.kube/config` + `KUBECONFIG` 的好处是**凭据与仓库集中管理、多项目互不干扰**；代价是路径非默认时需留意第 6 节的传参细节。
> **查找优先级**：`--kubeconfig` 命令行参数 > `KUBECONFIG` 环境变量 > 默认 `%USERPROFILE%\.kube\config`。

### 3.3 文件权限（Windows ACL）

```powershell
icacls .kube\config /inheritance:r /grant:r "$env:USERNAME:(R)"
```

### 3.4 多集群 / 多环境（可选）

```powershell
# 方式一：KUBECONFIG 支持分号分隔多个文件（Windows），kubectl 按顺序合并
$KUBE_CFG = "$PWD\.kube\config;$env:USERPROFILE\.kube\other"
[Environment]::SetEnvironmentVariable('KUBECONFIG', $KUBE_CFG, 'User')

# 方式二：把新集群合并进单个文件（--kubeconfig 指定目标文件）
kubectl config set-cluster lab --server=https://192.168.40.189:6443 --kubeconfig .kube\other
kubectl config use-context <name> --kubeconfig .kube\other
```

**命名规范（建议）**：context 用 `<环境>-<集群>`（如 `lab-kubernetes`），cluster 用 `<环境>-api`，避免默认名 `kubernetes-admin@kubernetes` 在多环境下混淆。重命名：

```powershell
kubectl config rename-context kubernetes-admin@kubernetes lab-kubernetes
kubectl config get-contexts
kubectl config use-context lab-kubernetes
kubectl config set-context --current --namespace=default   # 设默认命名空间，减少误操作
```

## 4. 验证连接

```powershell
kubectl version                 # Client / Server 均为 v1.37.2
kubectl cluster-info            # control plane 与 CoreDNS 地址
kubectl config current-context  # kubernetes-admin@kubernetes
kubectl get nodes -o wide       # 三节点 Ready
kubectl auth can-i '*' '*' --all-namespaces   # cluster-admin 期望 yes
```

本实例 `kubectl get nodes -o wide` 实测输出：

```text
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP      EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
ubunt-dev      Ready    worker          24h   v1.37.2   192.168.40.183   <none>        Ubuntu 22.04 LTS     5.15.0-25-generic (amd64)   containerd://2.4.2
ubuntu         Ready    control-plane   25h   v1.37.2   192.168.40.189   <none>        Ubuntu 24.04.2 LTS   6.8.0-147-generic (amd64)   containerd://2.4.2
ubuntu-stage   Ready    worker          15h   v1.37.2   192.168.40.187   <none>        Ubuntu 24.04.2 LTS   6.8.0-149-generic (amd64)   containerd://2.4.2
```

一键验证脚本（保存为 `kubectl_verify.ps1`，只读，退出码 `0` = 通过）：

```powershell
# kubectl 连接快速验证：版本漂移 / 集群信息 / 节点 / 权限
# 用法: powershell -ExecutionPolicy Bypass -File kubectl_verify.ps1
$KUBE_CFG = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $PWD '.kube\config' }
$env:KUBECONFIG = $KUBE_CFG
$fail = 0

function Check($name, $cmd) {
  Write-Host "== $name =="
  $out = Invoke-Expression $cmd 2>&1
  $code = $LASTEXITCODE
  $out | Out-Host
  if ($code -eq 0) { Write-Host "[PASS] $name" } else { Write-Host "[FAIL] $name (exit $code)"; $script:fail++ }
}

Check "client version"   "kubectl version --client"
Check "server version"   "kubectl version"
Check "cluster-info"     "kubectl cluster-info"
Check "nodes"            "kubectl get nodes -o wide"
Check "admin permission" "kubectl auth can-i '*' '*' --all-namespaces"

# 版本漂移检查：客户端与服务端 minor 必须一致
$v = kubectl version -o json | ConvertFrom-Json
$cm = ($v.clientVersion.gitVersion -replace '^v','' -replace '\.\d+$','')
$sm = ($v.serverVersion.gitVersion -replace '^v','' -replace '\.\d+$','')
if ($cm -eq $sm) { Write-Host "[PASS] version skew (client/server minor = $cm)" }
else { Write-Host "[FAIL] version skew: client=$cm server=$sm"; $fail++ }

if ($fail -eq 0) { Write-Host "ALL PASS"; exit 0 } else { Write-Host "$fail FAILED"; exit 1 }
```

Agent 判定：`version` 的 Client/Server minor 一致、节点全部 `Ready`、`auth can-i` 权限符合预期即视为直连可用。

## 5. 常用命令与最佳实践（速查）

### 5.1 通用约定

- **显式命名空间**：始终带 `-n <namespace>`，避免在 `default` 误操作；用 `kubectl config set-context --current --namespace=<ns>` 设默认。
- **显式 context**：多集群时用 `--context <name>`，不要依赖当前 context。
- **声明式优先**：变更用 `kubectl apply -f`，不用 `create`（不可重复执行）；清单纳入 Git，由 GitOps（如 Argo CD）或 CI 统一交付。
- **服务端 Apply 与字段管理**：团队/工具协同时用 `kubectl apply --server-side --field-manager=<name> -f`，避免客户端 Apply 的 `last-applied` 注解冲突与字段所有权争夺。
- **变更前预览**：`kubectl diff -f` 看差异；写操作用 `--dry-run=server`（API 校验，最准）或 `--dry-run=client`（本地，快）。
- **标签与选择器**：用 `-l key=value` 而非名称前缀；变更元数据用 `kubectl label` / `kubectl annotate`，不要手改清单外字段。
- **重启而非删 Pod**：应用重启用 `kubectl rollout restart deploy/<name>`；`delete pod` 仅用于强制恢复，且需确认自愈控制器存在。
- **稳定 API**：清单使用稳定 API（`apps/v1`、`batch/v1`），避免已废弃版本导致 apply 失败。
- **输出控制**：排查用 `-o wide` / `describe`；脚本用 `-o jsonpath` / `-o json` / `-o custom-columns`；加 `--no-headers` 便于管道。

### 5.2 查询与调试

```powershell
kubectl get pods -n <ns> -o wide --show-labels
kubectl -n <ns> get pods -l app=<name> -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
kubectl -n <ns> get events --sort-by=.lastTimestamp | Select-Object -Last 20
kubectl -n <ns> describe pod <pod>                 # 看 Events 定位调度/拉取/探针问题
kubectl -n <ns> logs <pod> --tail=100 -f            # 多容器加 -c <container>；上一次崩溃加 -p
kubectl -n <ns> exec -it <pod> -- bash             # 无 bash 用 sh
kubectl -n <ns> wait --for=condition=Ready pod/<pod> --timeout=120s
kubectl -n <ns> port-forward svc/<svc> 8080:80     # 本地访问集群内服务
kubectl proxy --port=8001                          # 本地访问 API（http://localhost:8001/api）
kubectl get --raw "/api/v1/namespaces/<ns>/pods/<pod>/log?container=<c>&tailLines=100"
kubectl top nodes; kubectl top pods -n <ns>        # 需 metrics-server
kubectl -n <ns> debug pod/<pod> -it --image=busybox:1.36 --target=<container>  # 临时调试容器（可选）
```

### 5.3 变更操作（执行前确认影响面）

```powershell
kubectl diff -f manifest.yaml                              # 变更前预览
kubectl apply -f manifest.yaml                             # 声明式 Apply
kubectl apply --server-side --field-manager=<name> -f m.yaml
kubectl create deployment nginx --image=nginx:1.27 --dry-run=client -o yaml > manifest.yaml  # 生成清单（注意编码，见下）
kubectl -n <ns> scale deploy/<name> --replicas=3
kubectl -n <ns> rollout status deploy/<name> --timeout=180s
kubectl -n <ns> rollout undo deploy/<name>                 # 回滚
kubectl -n <ns> patch deploy/<name> -p '{"spec":{"replicas":1}}'
kubectl -n <ns> delete -f manifest.yaml --wait=true
kubectl -n <ns> delete ns <test-ns>                        # 级联清理测试命名空间
```

> **编码提醒**：PowerShell 的 `>` 重定向默认写 UTF-16，直接生成 YAML 会导致 kubectl 解析失败。用 `kubectl ... -o yaml | Out-File -Encoding ascii manifest.yaml`，或改用 git bash 重定向。
> 破坏性操作（`delete`、`scale` 到 0、`rollout restart`、`drain`、`edit` 生产资源）**必须先向用户确认**；`edit` 直接改集群、绕过 GitOps，生产环境应禁用或审计。

### 5.4 自省与插件

```powershell
kubectl api-resources -o wide --namespaced=true        # 发现资源与短名
kubectl explain pod.spec --recursive                    # 查看字段结构
kubectl options                                         # 全局选项
kubectl krew list                                      # 插件管理（可选，winget: Kubernetes.krew）
kubectl config view --raw                              # 查看完整配置（含私钥，勿外发）
```

可选增强工具（均为 winget 包）：`ahmetb.kubectx` / `ahmetb.kubens`（context / namespace 快速切换）、`Kubernetes.krew`（插件包管理器）。

## 6. PowerShell 注意事项（本机实测踩坑）

1. **`--kubeconfig` 的变量必须加引号**。`kubectl --kubeconfig $k version` 在 PowerShell 7 下会**丢失参数**并回退到默认路径 `%USERPROFILE%\.kube\config`；正确写法是 `kubectl --kubeconfig "$k" version`。等号形式 `--kubeconfig=$k` 同样建议带引号。
2. **路径含空格也必须引号**（如 `C:\Users\liude\.kube\config` 无空格可省略，但 `C:\Program Data\...` 必须引）。
3. **环境变量对子进程生效**：`$env:KUBECONFIG = "<path>"` 后，同会话的 `kubectl` 立即读取；用户级变量（第 3.2 节）在**新开终端**生效。在 CatPaw/妙手等宿主内，宿主进程的环境快照可能早于变量设置，需在同一条命令内显式 `$env:KUBECONFIG = ...`。
4. **PS 版本差异**：PowerShell 7（推荐）与 Windows PowerShell 5.1 对原生命令参数的传递规则不同（`PSNativeCommandArgumentPassing`）。本手册命令以 PowerShell 7 验证；5.1 下如出现参数丢失，一律给路径/值加引号。
5. **中文路径可用**：`D:\文档\GitHub\deploy-ops\.kube\config` 作为 `--kubeconfig` 值与 `KUBECONFIG` 值均实测正常（前提是第 1 条的引号）。
6. **执行策略**：若脚本受 `Restricted` 策略阻止，用 `powershell -ExecutionPolicy Bypass -File <script>` 或临时 `Set-ExecutionPolicy -Scope Process RemoteSigned`；不要全局放宽。
7. **别名与补全**（可选，写入 `$PROFILE` 持久化）：
   ```powershell
   Set-Alias kg kubectl
   Set-Alias kd kubectl
   kubectl completion powershell | Out-String | Invoke-Expression
   ```

## 7. 安全与凭据治理

- **`admin.conf` = cluster-admin**，拥有集群全部权限。仅用于个人实验集群；生产环境应改用**最小权限**凭据：
  - 为使用方创建 `ServiceAccount` + 限定 `Role`/`ClusterRoleBinding`，用 `kubectl config set-credentials` + token；或使用 `kubeadm` 签发的客户端证书（限定 `Org`/CN）。
  - 按需收窄 `kubectl auth can-i --list` 的权限面，定期审计。
- **凭据不入库**：`.kube/` 已在 `.gitignore`；禁止把 kubeconfig 内容粘贴进仓库、日志或聊天；`kubectl config view --raw` 输出同样含私钥。
- **本机文件保护**：用 `icacls` 去除继承并仅授权当前用户（第 3.3 节）；不要放在共享目录；多用户机器上避免使用 admin.conf。
- **备份**：`kubectl config view --raw > <安全位置>\kubeconfig-backup.yaml`（含私钥，按敏感文件管理，加密存储）。
- **证书有效期**：`admin.conf` 客户端证书到期日 **2027-11-15**（control-plane 上 `kubeadm certs check-expiration` 查看）；到期前需在 control-plane 轮换并重新取回，否则报 `Unauthorized`。

## 8. 排障

| 现象 | 常见原因 | 处理 |
| --- | --- | --- |
| `kubectl 不是内部或外部命令` | PATH 未刷新 / 未重启终端 | 新开终端；或第 2.3 节手动刷新 PATH |
| `Unable to connect to the server: dial tcp ... connection refused` | 网络不通 / 6443 未放行 / apiserver 未启动 | `curl.exe -sk -o NUL -w "%{http_code}" https://192.168.40.189:6443/healthz`；检查防火墙与 kubelet |
| `connection reset by peer` / `TLS handshake timeout` | 网络抖动 / 中间设备拦截 | 重试并观察是否持续；`ping` / `curl` 复核链路 |
| `--kubeconfig` 被忽略，仍读默认路径 | PowerShell 未加引号传参（第 6 节） | 改为 `--kubeconfig "$k"`；或设 `$env:KUBECONFIG` |
| `error loading config file ... yaml: invalid leading UTF-8 octet` | kubeconfig 被 PowerShell 管道写入 BOM/换行 | 用 `ssh ... > file` 原始字节重取（第 3.1 节） |
| `x509: certificate signed by unknown authority` | kubeconfig 的 CA 与集群不匹配 | 重新取回 `admin.conf`；不要混用不同集群的配置 |
| `You must be logged in to the server (Unauthorized)` | 客户端证书过期或凭据无效 | `kubeadm certs check-expiration`；到期先 `kubeadm certs renew` 再重取 |
| `Forbidden` / `is forbidden: User ... cannot list` | RBAC 权限不足 | 确认所用凭据；生产按第 7 章申请最小权限 |
| `error: the server doesn't have a resource type "..."` | 资源拼写错误 / CRD 未安装 / API 未注册 | `kubectl api-resources` 核对；安装对应 CRD |
| `no matches for kind "..." in version "..."` | 清单 API 版本与集群不匹配 | 改用稳定 API（`apps/v1` 等）或升级清单 |
| `context "..." does not exist` | KUBECONFIG 指向错误或多文件顺序问题 | `kubectl config get-contexts`；`kubectl config use-context <name>` |
| `kubectl top` 报 `Metrics API not available` | 未部署 metrics-server | 部署 metrics-server，或改用 `kubectl get --raw /apis/metrics.k8s.io/...` 排查 |
| Pod `ImagePullBackOff` / `ErrImagePull` | 镜像源问题 | 按 [linux-kubernetes.md](linux-kubernetes.md) 第 8.1 章处理（本集群 `.189` 需 `docker.1ms.run` 优先） |

## 9. Agent 执行注意事项

- **先检查再执行**：每章先做只读检查，已安装 / 已配置自动跳过。
- **参数先确认**：执行前向用户确认 `KUBECTL_VERSION`、`KUBECONFIG_PATH`、`SSH_SOURCE`。
- **危险操作必须确认**：`delete`、`drain`、`scale`、`rollout restart/undo`、`edit`/`patch` 生产资源、`kubeadm certs renew`，逐项征求同意；变更前先 `kubectl diff` 或 `--dry-run=server`。
- **凭据安全**：kubeconfig 只经 SSH 取回、落盘 `.kube/`，不打印内容、不入库、不外发。
- **版本对齐**：升级 kubectl 前确认服务端版本；跨 minor 不做写操作，先跑第 4 节漂移检查。
- **不跨 repo 修改**：本手册只操作本机客户端与当前仓库；集群侧变更（证书、RBAC、镜像源）单独授权后执行。
- 每完成一章，向用户汇报当前状态与下一步计划。

## 10. 卸载（可选，需用户确认）

```powershell
winget uninstall --id Kubernetes.kubectl
Remove-Item .kube\config            # 凭据清理
[Environment]::SetEnvironmentVariable('KUBECONFIG', $null, 'User')   # 移除用户级变量
```

> 卸载 kubectl 不影响集群；清理 `KUBECONFIG` 环境变量后，默认回到 `%USERPROFILE%\.kube\config`。
