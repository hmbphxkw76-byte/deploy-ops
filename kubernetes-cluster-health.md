# Kubernetes 集群健康排查与自愈手册（最佳实践）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在**已部署完成的 Kubernetes 集群**上做**只读体检 → 症状分类 → 定位根因 → 低风险修复**。内容来自 2026-11-16 在真实集群（`192.168.40.189` 三节点，K8s v1.37.2）上的一次完整故障处置：

- **主因**：Harbor admin 密码被凭据轮换后，集群内三份 `harbor-creds` 未同步 → 镜像拉取全部 `401 Unauthorized` → `ai-weekly` 滚动发布卡死 → Argo CD 应用 Degraded；
- **叠加**：节点重启后 containerd 遗留同名容器（`CreateContainerError`）、CNI 系统 Pod 探针卡住。

文档把这两类问题的**判别方法、定位命令、幂等修复与预防措施**沉淀为可复用流程。

**配套脚本**：[kubernetes-cluster-audit.sh](kubernetes-cluster-audit.sh)（只读审计，可单独运行或纳入周期任务）。

> 前置依赖：集群已按 [linux-kubernetes.md](linux-kubernetes.md) 部署。组件细节见 [kubernetes-harbor.md](kubernetes-harbor.md)、[kubernetes-argocd.md](kubernetes-argocd.md)、[kubernetes-gitlab-runner.md](kubernetes-gitlab-runner.md)、[kubernetes-ingress-cert-manager.md](kubernetes-ingress-cert-manager.md)。

---

## 0. 快速路径（一键只读体检）

```bash
# 基础体检：apiserver / 节点 / 异常 Pod / 关键 DaemonSet / Argo CD
bash kubernetes-cluster-audit.sh

# 追加凭据一致性：全命名空间 harbor-creds 是否与基准一致 + registry 实测认证
bash kubernetes-cluster-audit.sh --secrets
```

- 退出码 `0` = 无 FAIL，`1` = 存在 FAIL，可直接作为门禁。
- 覆盖能力见第 1 章参数区；只读，不修改任何资源。

---

## 1. 参数区

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `REGISTRY` | `192.168.40.189:30003` | Harbor 地址（`HOST:PORT`） |
| `SECRET_NS` | `default` | 凭据基准 secret 所在命名空间（脚本以其为准比对全集群） |
| `SECRET_NAME` | `harbor-creds` | 凭据基准 secret 名 |
| `ARGOCD_NS` | `argocd` | Argo CD 命名空间（不存在则跳过该检查） |
| `KUBECONFIG` | 环境/默认 | 客户端配置；本机直连见 [windows-kubectl.md](windows-kubectl.md) |

覆盖示例：

```bash
REGISTRY=10.0.0.1:5000 SECRET_NS=default SECRET_NAME=harbor-creds \
  bash kubernetes-cluster-audit.sh --secrets
```

---

## 2. 症状速查表

先跑这一条，把「哪些 Pod 不健康」一次列清：

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded,status.phase!=Completed
```

| 症状 | 典型报错 | 常见根因 | 跳转 |
| --- | --- | --- | --- |
| 镜像拉取失败 | `ImagePullBackOff` + `401 Unauthorized` | **凭据过期/漂移**（密码轮换、机器人账号被删） | 第 3 章 |
| 镜像拉取失败 | `ImagePullBackOff` + `404` / `MANIFEST_UNKNOWN` | 认证通过但 manifest 不存在（tag 被删、保留策略 GC、推到了别的 project） | 3.1 / 3.3 |
| 应用不健康 | Argo CD `Degraded` / `Progressing` | 上述任一导致滚动发布卡住 | 3.4 / 3.5 |
| 容器起不来 | `CreateContainerError: failed to reserve container name` | containerd 残留同名容器（多见节点/容器运行时重启后） | 4.1 |
| Pod 一直 NotReady | 系统 Pod（flannel / kube-proxy / speaker） | CNI `subnet.env` 缺失或探针结果卡住 | 4.2 |
| 多 Pod 同时重启 | — | 节点或 containerd 重启 | 4.3 |

> 警告事件往往已经把结论写在消息里，先看：
> ```bash
> kubectl get events -A --field-selector=type=Warning --sort-by=.lastTimestamp | tail -30
> ```

---

## 3. 场景一：凭据漂移（401 / ImagePullBackOff）

### 3.1 先分清 401 与 404

镜像拉取失败时，**状态码是第一个分水岭**：

| 状态码 | 含义 | 方向 |
| --- | --- | --- |
| `401 Unauthorized` | 认证被拒 | 凭据问题（密码/账号/权限），走 3.2 |
| `404 Not Found` / `MANIFEST_UNKNOWN` | 认证通过，但 manifest 不存在 | 镜像/标签问题，走 3.3 |

> 实测踩坑：`401` 时 Harbor 不会告诉你「密码错了」，它只是反复回 `unauthorized`；而 `deploy` 类应用会继续用**缓存过的旧镜像**跑着，只有**新建 Pod**（滚动发布、扩容、节点迁移）才会暴露。因此「老 Pod 正常、新 Pod 拉不动」是凭据漂移的典型信号。

### 3.2 三条命令确认凭据是否有效

```bash
REGISTRY=192.168.40.189:30003
REGISTRY_USER=admin
REGISTRY_PASSWORD='<当前密码>'     # 不写入仓库，仅本地会话使用

# ① /v2/ 是否认证通过：200 = 通过
curl -sk -o /dev/null -w '%{http_code}\n' -u "$REGISTRY_USER:$REGISTRY_PASSWORD" "https://$REGISTRY/v2/"

# ② 身份是否被认可：200 且 username 正确 = 密码有效
curl -sk -u "$REGISTRY_USER:$REGISTRY_PASSWORD" "https://$REGISTRY/api/v2.0/users/current"

# ③ 令牌是否带 pull 权限：actions 必须非空
TOKEN=$(curl -sk -u "$REGISTRY_USER:$REGISTRY_PASSWORD" \
  "https://$REGISTRY/service/token?service=harbor-registry&scope=repository:<project>/<repo>:pull" \
  | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
# 期望 "actions":["pull",...]；若为 "actions":[] 说明被当作匿名/无权限
```

判读：

- ① 非 200 → 密码/账号错；
- ① 200 但 ② 失败 → 账号状态异常（被禁用/锁定）；
- ①② 正常但 ③ `actions` 为空 → 权限问题（项目私有且该账号无成员身份）。

### 3.3 定位最近一次密码变更

确认「密码被改过」比「猜新密码」更可靠。三处证据：

```bash
# 证据 1：core 日志里的认证失败（会显示来源 IP 与 UA，便于判断是谁在试）
kubectl -n harbor logs deploy/harbor-core --tail=200 | grep -i 'Invalid credentials'

# 证据 2：数据库里 admin 的密码更新时间（password_version 也应一致）
kubectl -n harbor exec harbor-database-0 -c database -- \
  psql -U postgres -d registry -c \
  "select user_id,username,password_version,update_time from harbor_user where username='admin';"

# 证据 3：确认项目/仓库仍在（404 场景用）
kubectl -n harbor exec harbor-database-0 -c database -- \
  psql -U postgres -d registry -c "select project_id,name,deleted from project;"
kubectl -n harbor exec harbor-database-0 -c database -- \
  psql -U postgres -d registry -c "select repository_id,name,project_id from repository;"
```

> **不要直接改 `harbor_user.password`**。Harbor 2.x 使用 `pbkdf2_sha256`，需要精确复刻盐值与迭代参数，手工构造极易失败，且会让凭据更难追溯。正确做法是**找到当前有效密码，同步所有消费者**（3.4）；密码来源见第 6 章轮换清单。

### 3.4 修复：同步集群内全部 `harbor-creds`

以当前有效密码重建基准 secret，再对齐其余命名空间（幂等，可重复执行）：

```bash
REGISTRY=192.168.40.189:30003
REGISTRY_USER=admin
REGISTRY_PASSWORD='<当前密码>'

# 先确认基准（default/harbor-creds）——它是脚本比对的锚点
kubectl -n default create secret docker-registry harbor-creds \
  --docker-server="$REGISTRY" --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# 再对齐所有使用该 registry 的命名空间
for ns in default nginx-gateway ai-weekly; do
  kubectl -n "$ns" create secret docker-registry harbor-creds \
    --docker-server="$REGISTRY" --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

> `--dry-run=client -o yaml | kubectl apply -f -` 会补 `last-applied-configuration` 注解，重复执行安全。
> **注意 secret key**：kubectl 的 `.dockerconfigjson` 键带前导点，取值时 jsonpath 不便转义，推荐用
> `kubectl get secret <name> -o go-template='{{index .data ".dockerconfigjson"}}'`（审计脚本即采用此写法）。

### 3.5 验证与回归

```bash
# 凭据层面
bash kubernetes-cluster-audit.sh --secrets

# 集群层面：删掉卡在 ImagePullBackOff 的 Pod，让 ReplicaSet 用新凭据重建
kubectl -n ai-weekly delete pod <imagepullbackoff-pod>

# 观察滚动收敛（旧 RS 应缩到 0）
kubectl -n ai-weekly get rs
kubectl -n argocd get application ai-weekly \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
```

期望：`ImagePullBackOff` 消失、各 Deployment `UP-TO-DATE` 与 `READY` 一致、Argo CD 回到 `Synced + Healthy`。

---

## 4. 场景二：节点重启后的运行时残留

节点重启（或 containerd/kubelet 重启）后，偶发两类「非凭据」异常。

### 4.1 `CreateContainerError`：容器名被预留

**症状**：Pod 一直 `CreateContainerError`，事件形如

```
failed to reserve container name "speaker_speaker-xxx_metallb-system_<uid>_4";
check if another CreateContainer request is in progress
```

**根因**：containerd 内存里仍保留着**同名的旧容器**（旧容器可能还 RUNNING），kubelet 复用同一名字创建新容器时被拒。多见于节点重启后 kubelet 与 containerd 状态不同步。

**定位**：

```bash
# 看 Pod 事件与容器状态
kubectl -n metallb-system describe pod <speaker-pod> | tail -20

# 节点上确认是否存在同名残留容器（ctr 随 containerd 自带）
ctr -n k8s.io containers ls | grep <container-name>
ctr -n k8s.io tasks ls | grep <container-id>
```

**修复（先低风险）**：删除卡住的 Pod，由 DaemonSet 重建，让 kubelet 重新走一遍清理 + 创建：

```bash
kubectl -n metallb-system delete pod <speaker-pod>
```

**仍复现时**：说明 containerd 元数据残留未清，需重启 containerd：

```bash
systemctl restart containerd     # 影响该节点上全部容器（会重建），先评估影响面
```

> 处置前先确认节点是否刚重启过（4.3），并记录 `ctr`/`crictl` 上的残留容器 ID 以便回溯。

### 4.2 CNI 系统 Pod 探针卡住（flannel）

**症状**：`kube-flannel-ds-*` 一直 `0/1 Running`，但节点 `NetworkUnavailable=False`（说明 flannel 实际已就绪，只是探针结果没刷新）。

**排查**：

```bash
# 1) 节点上 subnet.env 是否存在（CNI 插件依赖它）
ls -l /run/flannel/subnet.env && cat /run/flannel/subnet.env

# 2) 直接探测健康端点（hostNetwork 时 Pod IP = 节点 IP）
curl -s -o /dev/null -w '%{http_code}\n' http://<podIP>:8081/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://<podIP>:8081/healthz
```

**修复**：删除该节点上的 flannel Pod，由 DaemonSet 重建，探针状态即可恢复：

```bash
kubectl -n kube-flannel delete pod <flannel-pod-on-that-node>
```

> 若 `subnet.env` 缺失，删除 Pod 会让 flannel 重新写入；若同时发现同节点**其他 Pod 无法创建沙箱**（日志报 `failed to load flannel 'subnet.env'`），同样以重建 flannel Pod 收尾。

### 4.3 判断节点是否刚重启 / 时钟是否被校正

多 Pod **同一时刻**集体重启（`lastState.terminated.exitCode=255`、`reason=Unknown`），通常不是各自的故障，而是节点级事件：

```bash
uptime                                                    # 开机时长 → 最近重启时间
systemctl show kubelet    -p ActiveEnterTimestamp -p NRestarts
systemctl show containerd -p ActiveEnterTimestamp -p NRestarts
journalctl -u kubelet --no-pager | grep -iE 'subnet.env|CreateContainer|reserve container name'
```

**时钟陷阱**：若 NTP 曾把时钟回拨，`systemd` 的 `ActiveEnterTimestamp` 与 Pod 的 `state.running.startedAt` 可能出现「**未来时间**」（如当前 `05:44 UTC` 却记录 `09:11Z`）。看到这种值不要误判为异常，它是时钟跳变的痕迹；以 `uptime`（单调时钟）为准判断重启时刻。

---

## 5. 通用排查顺序（决策树）

```text
1) 列出异常 Pod
   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
2) 看 Warning 事件（消息常已给出结论）
   kubectl get events -A --field-selector=type=Warning --sort-by=.lastTimestamp
3) 看 GitOps 应用健康（若装了 Argo CD）
   kubectl get applications -n argocd
4) 按报错分类：
   ├─ ImagePullBackOff + 401  → 3.2 确认凭据 → 3.3 定位变更 → 3.4 同步
   ├─ ImagePullBackOff + 404  → 3.3 确认项目/仓库/标签是否存在
   ├─ CreateContainerError    → 4.1 查 containerd 残留容器 → 删 Pod 重建
   ├─ 系统 Pod NotReady        → 4.2 查 subnet.env 与探针端点 → 删 Pod 重建
   └─ 多 Pod 同时重启          → 4.3 判断节点/运行时重启与时钟跳变
5) 修复后必跑：bash kubernetes-cluster-audit.sh --secrets
```

---

## 6. 预防：凭据轮换清单与定期审计

### 6.1 凭据轮换必须同步的消费者

一次 Harbor admin / 机器人密码轮换，至少涉及以下位置（本仓库实测踩坑即漏掉前三项）：

| # | 位置 | 说明 |
| --- | --- | --- |
| 1 | `default/harbor-creds` | 集群凭据**基准**（审计脚本以它为准） |
| 2 | `nginx-gateway/harbor-creds` | 网关命名空间 |
| 3 | `ai-weekly/harbor-creds` | 业务命名空间（每个用 Harbor 的 ns 都要） |
| 4 | GitLab CI 变量 `HARBOR_PASSWORD` / `HARBOR_USER` | 漏改会导致 **CI 推送镜像失败** |
| 5 | 各节点 `docker login` / `/root/.docker/config.json` | 手工推送凭证 |
| 6 | CI 仓库里的 values / manifests 引用 | 只引用 secret 名，不写明文 |

> 更完整的轮换 runbook（含 API 重置密码步骤、12 处消费者核对表、回滚方式）见内部文档《凭据轮换与历史清理-runbook》；本仓库只承载集群侧的标准动作。

### 6.2 把审计做成例行门禁

```bash
# 建议纳入周期任务（如每日一次）或 CI：凭据漂移与组件异常清零
bash kubernetes-cluster-audit.sh --secrets
```

### 6.3 监控建议

- kube-state-metrics + Prometheus 告警：`ImagePullBackOff` / `CreateContainerError` 计数、`kube_daemonset_status_number_ready < desired`；
- Argo CD：应用 `health != Healthy` 或 `sync != Synced` 持续超过阈值即告警；
- 凭据：每次轮换后人工触发一次 `--secrets` 审计并留档。

---

## 7. Agent 注意事项

- **只读优先**：先用第 0 章脚本与第 5 章命令定位，再动资源。
- **凭据先溯源、后修改**：用 3.3 的三处证据确认「密码被改过」，不要凭猜测改数据库密码哈希。
- **改凭据用声明式命令**：`create ... --dry-run=client -o yaml | kubectl apply -f -`，幂等且可回溯。
- **影响面前置**：删除 Pod、重启 containerd、重启节点前，先说明会影响哪些工作负载。
- **凭据不入库**：仓库 `scripts/validate.sh` 会扫描明文令牌/私钥；密码只进 Secret 与本地会话。
- **失败即停**：命令失败先看日志定位，不盲目重试。
- **危险操作必须确认**：`systemctl restart containerd`、`kubeadm reset`、重启节点、删除 PV 等。
