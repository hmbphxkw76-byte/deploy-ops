# GitLab Runner 部署手册（Kali / Debian）（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent，用于在 Kali Linux（及 Debian 系发行版）上以 systemd 服务方式安装 GitLab Runner，并注册到自建 GitLab（K8s CNG 部署，见 [kubernetes-gitlab.md](kubernetes-gitlab.md)），打通「代码 → 构建 → 镜像 → 部署」的 CI 闭环。

Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；各步骤幂等，已完成的内容会自动跳过。

**本次实测基线（2026-11-15）**：Kali 2026.3（Debian trixie 基底）· GitLab v19.5.5-jh（`http://192.168.40.189:30080`）· Runner 19.5.3 · Docker 29.8.0 · 执行器 `docker` · 并发 4。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `GITLAB_URL` | `http://192.168.40.189:30080` | GitLab 根地址（内网 HTTP，必须含端口） |
| `RUNNER_NAME` | `kali-192.168.40.188` | Runner 显示名，建议 `<主机角色>-<IP>` |
| `RUNNER_TOKEN` | 空（必填） | GitLab 下发的 `glrt-` 认证令牌，见第 4 章 |
| `EXECUTOR` | `docker` | 执行器；本机已装 Docker，默认 `docker` |
| `DOCKER_IMAGE` | `alpine:latest` | docker 执行器默认镜像（job 未指定 `image:` 时使用） |
| `CONCURRENT` | `4` | 并发 job 数，写入 `config.toml`（按 CPU 核数调整） |
| `REPO_DIST` | `trixie` | Runner 官方仓库套件名，按 `/etc/debian_version`：13.x → `trixie`，12.x → `bookworm` |
| `DOCKER_MIRRORS` | `https://docker.m.daocloud.io`、`https://docker.imgdb.de` | Docker 镜像加速；必须先实测（见 3.2） |

## 1. 前置检查（只读，不修改系统）

```bash
# 系统与架构
head -n 2 /etc/os-release
cat /etc/debian_version            # 决定 REPO_DIST
dpkg --print-architecture

# 依赖组件
docker --version 2>/dev/null || echo "DOCKER_NOT_INSTALLED"
command -v gpg git curl

# Runner 是否已安装
gitlab-runner --version 2>/dev/null || echo "RUNNER_NOT_INSTALLED"
ls -la /etc/gitlab-runner/ 2>/dev/null

# GitLab 可达性（应返回 200）
curl -sS -o /dev/null -w 'gitlab_health=%{http_code}\n' --max-time 10 "${GITLAB_URL}/-/health"

# 资源
nproc; free -h | head -2; df -h / | tail -1
```

判定逻辑：

- 已安装且 `/etc/gitlab-runner/config.toml` 存在 → 跳到第 5 章验证；需重装见第 7 章。
- Docker 未安装 → 先按 [kali-docker.md](kali-docker.md) 安装。
- GitLab 不可达（非 200）→ 先恢复 GitLab，不要继续。

## 2. 安装 GitLab Runner

### 2.1 添加官方软件源

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.gitlab.com/runner/gitlab-runner/gpgkey -o /tmp/gitlab-runner.gpg.key
sudo gpg --dearmor < /tmp/gitlab-runner.gpg.key | sudo tee /etc/apt/keyrings/gitlab-runner.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/gitlab-runner.gpg] https://packages.gitlab.com/runner/gitlab-runner/debian ${REPO_DIST:-trixie} main" | sudo tee /etc/apt/sources.list.d/gitlab-runner.list
sudo apt-get update
```

> `gpg` 不存在时先 `sudo apt-get install -y gnupg`。
> 软件源同时提供 `gitlab-runner-helper-images`（约 550 MB），安装属正常现象。

### 2.2 安装

```bash
sudo apt-get install -y gitlab-runner
gitlab-runner --version
id gitlab-runner        # 包会自动创建 gitlab-runner 用户与 systemd 服务
```

## 3. 配置 Docker 与镜像加速

### 3.1 授权 Runner 使用 Docker

```bash
sudo usermod -aG docker gitlab-runner
getent group docker    # 应包含 gitlab-runner
```

### 3.2 配置镜像加速（先测后选）

```bash
# 逐个实测候选源，成功者才可写入
for m in docker.m.daocloud.io docker.1ms.run docker.imgdb.de docker.xuanyuan.me; do
  printf '%s: ' "$m"
  timeout 90 docker pull "$m/library/alpine:3.20" >/dev/null 2>&1 && echo OK || echo FAIL
done
```

合并写入 `/etc/docker/daemon.json`（**禁止覆盖已有配置**，如 `data-root`）：

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.imgdb.de"
  ]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
docker info | grep -A4 'Registry Mirrors'
```

> ⚠️ 重启 Docker 会中断正在运行的容器。执行前确认 `docker ps` 为空或已获用户同意。

## 4. 注册 Runner 到 GitLab

### 4.1 获取注册令牌（二选一）

GitLab 16 起已移除旧的 registration token，必须使用 **`glrt-` 开头的 Runner 认证令牌**。

**方式 A：Web UI（推荐）**

- 实例级（所有项目可用）：管理员登录 → Admin Area → CI/CD → Runners → New instance runner → 填描述/标签 → Create runner → 复制 `glrt-` 令牌。
- 项目级：项目 → Settings → CI/CD → Runners → New project runner。

**方式 B：API（需管理员 PAT）**

```bash
curl -sS -X POST -H "PRIVATE-TOKEN: <管理员PAT>" \
  "${GITLAB_URL}/api/v4/user/runners" \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=${RUNNER_NAME}"
# 返回 {"id":1,"token":"glrt-...","token_expires_at":null}
```

> 令牌只返回一次，立即保存；泄露后立即在 GitLab 中吊销。

### 4.2 注册

```bash
sudo gitlab-runner register --non-interactive \
  --url "${GITLAB_URL}" \
  --token "${RUNNER_TOKEN}" \
  --executor "${EXECUTOR:-docker}" \
  --docker-image "${DOCKER_IMAGE:-alpine:latest}" \
  --description "${RUNNER_NAME}" \
  --docker-privileged="false"
```

### 4.3 调整并发并重启

```bash
sudo sed -i "s/^concurrent = 1$/concurrent = ${CONCURRENT:-4}/" /etc/gitlab-runner/config.toml
sudo systemctl restart gitlab-runner
```

## 5. 验证部署

```bash
gitlab-runner status        # Service is running
gitlab-runner list          # 列出已注册 Runner
gitlab-runner verify        # 与 GitLab 握手
```

GitLab 侧确认（API）：

```bash
curl -sS -H "PRIVATE-TOKEN: <PAT>" "${GITLAB_URL}/api/v4/runners" \
  | python3 -c 'import sys,json; [print(r["id"], r["description"], r["online"], r["status"]) for r in json.load(sys.stdin)]'
# 期望：online=true status=online
```

### 5.1 端到端流水线冒烟（必做）

```bash
# 1) 建测试项目
curl -sS -X POST -H "PRIVATE-TOKEN: <PAT>" "${GITLAB_URL}/api/v4/projects" \
  --data-urlencode "name=runner-smoke" --data-urlencode "visibility=private"

# 2) 推一个最小流水线
mkdir -p /tmp/runner-smoke && cd /tmp/runner-smoke
git init -q -b main && git config user.email root@local && git config user.name root
cat > .gitlab-ci.yml <<'EOF'
stages: [smoke]
smoke:
  stage: smoke
  image: alpine:latest
  script:
    - echo SMOKE_OK
EOF
git add -A && git commit -qm "ci: smoke"
git remote add origin "http://oauth2:<PAT>@<GITLAB_HOST>/<namespace>/runner-smoke.git"
git push -q origin HEAD

# 3) 轮询结果，期望 success
curl -sS -H "PRIVATE-TOKEN: <PAT>" \
  "${GITLAB_URL}/api/v4/projects/<namespace>%2Frunner-smoke/pipelines" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["status"])'
```

判定：`status=success` 且 job 日志含 `SMOKE_OK` → CI 闭环打通。

## 6. 排障

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| `Checking for jobs... failed ... connection refused` | GitLab 不可达或正在重启 | 确认 `${GITLAB_URL}/-/health` 返回 200 |
| 注册失败 401/403 | 令牌无效或已吊销 | 重新下发 `glrt-` 令牌 |
| job 一直 `running`，Runner 日志刷 `accepted, but not yet completed` | GitLab 对象存储不可用 | 见第 9 节 |
| `docker pull` 慢/失败 | 镜像源不可达 | 按 3.2 重选源并重启 Docker |
| `gitlab-runner: Service is not running` | 服务未启动 | `systemctl status gitlab-runner`；`journalctl -u gitlab-runner -n 50` |
| 未打标签的 job 不被领取 | `run_untagged` 为 false | 在 `config.toml` 设 `run_untagged = true` 后重启 |

## 7. 卸载

```bash
sudo gitlab-runner unregister --all
sudo apt-get remove -y gitlab-runner gitlab-runner-helper-images
sudo rm -rf /etc/gitlab-runner
```

## 8. Agent 执行注意事项

- **令牌安全**：`glrt-` 令牌与 PAT 等同密码，不得写入文档、日志或仓库；用完及时吊销（`DELETE /api/v4/personal_access_tokens/:id`）。
- **幂等**：软件源、安装包、用户组、`daemon.json` 均先判断再写，重复执行不产生副作用。
- **危险操作**：重启 Docker、删除 Pod、修改 GitLab 配置前，先确认影响面并获用户同意。
- **镜像源必须实测**：不同网络环境可达性差异很大，写进 `daemon.json` 前逐个 `docker pull` 验证。
- **GitLab 16+ 令牌机制**：旧的 `--registration-token` 已不可用，脚本不要沿用旧参数。
- **Job 无法收尾不一定是 Runner 的问题**：先查 GitLab 侧（对象存储、Sidekiq），见第 9 节。

## 9. 关联：Job 卡在 running 的 GitLab 侧根因（2026-11-15 实测）

**现象**：Runner 日志反复出现

```
Submitting job to coordinator...accepted, but not yet completed  code=202 ... job-status=running
```

job 实际已执行成功（日志有 `Job succeeded`），但 GitLab 一直显示 `running`，Runner 持续退避重试。

**根因**：GitLab 对象存储（MinIO）连接未启用路径风格，AWS SDK 生成虚拟主机域名 `gitlab-artifacts.minio.gitlab.svc.cluster.local`，该域名在集群内无法解析，`Ci::BuildTraceChunkFlushWorker` 报：

```
Excon::Error::Socket: no address for gitlab-artifacts.minio.gitlab.svc.cluster.local (Resolv::ResolvError)
```

**修复**：在对象存储 connection 中加 `path_style: true` 并重启 GitLab 组件。

```bash
# 1) 更新 connection（K8s secret gitlab-object-storage 的 connection 键）
kubectl -n gitlab get secret gitlab-object-storage -o jsonpath='{.data.connection}' | base64 -d > /tmp/conn.yaml
grep -q path_style /tmp/conn.yaml || echo 'path_style: true' >> /tmp/conn.yaml
kubectl -n gitlab create secret generic gitlab-object-storage \
  --from-file=connection=/tmp/conn.yaml --dry-run=client -o yaml | kubectl apply -f -

# 2) 重启组件
kubectl -n gitlab rollout restart deploy/gitlab-webservice-default deploy/gitlab-sidekiq-all-in-1-v2
# webservice 带 hostPort(30080)，滚动更新会因端口占用卡在 Pending，此时删除旧 Pod 释放端口：
kubectl -n gitlab delete pod <旧 webservice pod 名>
kubectl -n gitlab rollout status deploy/gitlab-webservice-default --timeout=420s
```

> 验证：`kubectl -n gitlab logs deploy/gitlab-sidekiq-all-in-1-v2 -c sidekiq | grep -i 'no address'` 不再出现；重跑流水线应为 `success`。

## 10. 复用清单（新环境）

- [ ] 确认 Debian 基底 → 设置 `REPO_DIST`
- [ ] 确认 Docker 已装且 `gitlab-runner` 已在 docker 组
- [ ] 实测并写入 `DOCKER_MIRRORS`
- [ ] 从 GitLab 取 `glrt-` 令牌（UI 或 API）
- [ ] `register` 后设置 `concurrent`
- [ ] 端到端冒烟 `success`
- [ ] 吊销临时令牌，确认未落盘

## 关联文档

- [kali-docker.md](kali-docker.md)：Docker 与镜像加速
- [kubernetes-gitlab.md](kubernetes-gitlab.md)：GitLab 部署与对象存储配置
- [linux-kubernetes.md](linux-kubernetes.md)：K8s 集群与节点规划
