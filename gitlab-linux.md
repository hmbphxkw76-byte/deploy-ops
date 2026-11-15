# GitLab 独立 Docker 部署手册（最佳实践）

> **目标**：在 Ubuntu + Docker Compose 上独立部署 GitLab CE，**不接入 Kubernetes**，镜像走国内源。
> **复用方式**：填写「参数区」→ 执行「前置检查」→ 执行「幂等执行步骤」→ 执行「验证部署」。
> **适用**：GitLab CE 19.x（本文以 19.5.5 为例）；其他版本只需替换镜像标签/摘要。

---

## 1. 参数区（部署前必须确认）

| 参数 | 说明 | 本次实例取值 |
| --- | --- | --- |
| `GITLAB_HOST` | 访问用主机名或 IP | `192.168.40.189` |
| `GITLAB_HTTP_PORT` | Web 端口（须避开 80/8081 等） | `8080` |
| `GITLAB_SSH_PORT` | Git SSH 端口（须避开 22） | `2222` |
| `GITLAB_REGISTRY_PORT` | 容器镜像仓库端口 | `5050` |
| `DATA_DIR` | 数据目录 | `/opt/gitlab` |
| `TZ` | 时区 | `Asia/Shanghai` |
| `PUMA_WORKERS` | Puma 工作进程数 | `4` |
| 镜像源 | 国内镜像 | `docker.m.daocloud.io/gitlab/gitlab-ce:latest` |
| 解析版本 | 2026-11-15 `:latest` 指向 | `19.5.5` |
| 镜像摘要 | 固定版本用 | `sha256:392e6bd5bf118ae520e4038261a5ae39aea05de0d2299a162b4c822a9684cf9b` |

**端口避让原则**：先 `ss -tlnp` 查看占用。GitLab 不得占用 `80`、`22`、`6443`、`10250`、`2379`、`8081`、`11434` 等既有服务 / K8s 端口。GitLab 内置的 PostgreSQL(5432)、Redis(6379)、workhorse 仅在容器内监听，不映射宿主。

---

## 2. 前置检查

```bash
ssh root@192.168.40.189

# 系统与 Docker
. /etc/os-release; echo "$PRETTY_NAME"
docker version --format '{{.Server.Version}}'; docker compose version   # 需 Compose v2+

# K8s 现状（确认共存，本次不做任何变更）
systemctl is-active kubelet; kubectl get nodes

# 端口：既有服务/K8s 占用（GitLab 需避开）
ss -tlnp | grep -E ':(80|22|6443|10250|2379|8081|11434)\b'
# GitLab 目标端口应为空闲
ss -tln | grep -E ':(8080|2222|5050)\b' || echo '8080/2222/5050 空闲'

# 无 GitLab 残留
docker ps -a --filter name=gitlab --format '{{.Names}}'
ls -d /opt/gitlab /var/opt/gitlab /etc/gitlab 2>/dev/null || echo '无 GitLab 残留'

# 镜像源连通（daemon.json 建议已配 registry-mirrors）
curl -s -o /dev/null -w '%{http_code}\n' https://docker.m.daocloud.io/v2/
```

---

## 3. 幂等执行步骤

### Step 1 · 拉取镜像（国内源）

```bash
docker pull docker.m.daocloud.io/gitlab/gitlab-ce:latest

# 校验解析版本
docker run --rm --entrypoint cat docker.m.daocloud.io/gitlab/gitlab-ce:latest \
  /opt/gitlab/version-manifest.txt | head -1    # -> gitlab-ce 19.5.5
```

> **版本策略**：daocloud 对具体版本 tag（如 `:19.5.5`）返回 `denied` 且禁用标签列表，故 compose 用 `:latest` 并记录解析版本与摘要。需要严格固定版本时用摘要拉取：
> `docker pull docker.m.daocloud.io/gitlab/gitlab-ce@sha256:392e6bd5bf118ae520e4038261a5ae39aea05de0d2299a162b4c822a9684cf9b`

### Step 2 · 创建目录与 compose 文件

```bash
mkdir -p /opt/gitlab/config /opt/gitlab/logs /opt/gitlab/data

cat > /opt/gitlab/docker-compose.yml <<'YAML'
# GitLab CE 独立 Docker 部署（不接入 Kubernetes，端口避开既有服务与 K8s）
# 镜像走国内源：docker.m.daocloud.io（2026-11-15 :latest 解析为 gitlab-ce 19.5.5）
services:
  gitlab:
    image: docker.m.daocloud.io/gitlab/gitlab-ce:latest
    container_name: gitlab
    hostname: gitlab
    restart: unless-stopped
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.168.40.189:8080'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        gitlab_rails['time_zone'] = 'Asia/Shanghai'
        gitlab_rails['backup_path'] = '/var/opt/gitlab/backups'
        gitlab_rails['backup_keep_time'] = 604800
        registry_external_url 'http://192.168.40.189:5050'
        prometheus_monitoring['enable'] = false
        gitlab_kas['enable'] = false
        puma['worker_processes'] = 4
    ports:
      - "8080:80"
      - "2222:22"
      - "5050:5050"
    volumes:
      - "/opt/gitlab/config:/etc/gitlab"
      - "/opt/gitlab/logs:/var/log/gitlab"
      - "/opt/gitlab/data:/var/opt/gitlab"
    shm_size: "256m"
YAML
```

**配置项说明**

| 配置 | 作用 |
| --- | --- |
| `external_url 'http://<host>:<port>'` | 外部地址；GitLab 生成的所有链接/克隆地址均用它。容器内 nginx 仍监听 80，由宿主端口映射对外 |
| `nginx['listen_port'] = 80` / `listen_https = false` | 显式声明容器内监听 80、关闭 HTTPS（HTTP 部署） |
| `gitlab_rails['gitlab_shell_ssh_port'] = 2222` | SSH 克隆走宿主 2222（容器内 22） |
| `gitlab_rails['time_zone']` | 时区 |
| `gitlab_rails['backup_path']` / `backup_keep_time` | 备份目录与保留天数（默认 7 天） |
| `registry_external_url` | 启用容器镜像仓库，监听宿主 5050 |
| `prometheus_monitoring['enable'] = false` | 关闭 Prometheus/Grafana 监控栈，降低资源占用 |
| `gitlab_kas['enable'] = false` | 关闭 Kubernetes Agent Server，**不建立任何 K8s 集成** |
| `puma['worker_processes'] = 4` | Web 工作进程数（按 CPU 核数调整） |

### Step 3 · 启动

```bash
cd /opt/gitlab && docker compose up -d
```

### Step 4 · 等待首次初始化（reconfigure + 数据库迁移）

```bash
for i in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' gitlab 2>/dev/null)" = "healthy" ] && break
  sleep 10
done
docker ps --filter name=gitlab --format '{{.Names}} {{.Status}} {{.Ports}}'
# 期望：gitlab Up (healthy)  0.0.0.0:8080->80/tcp, 0.0.0.0:2222->22/tcp, 0.0.0.0:5050->5050/tcp
```

> 镜像自带健康检查：`/opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10`。

### Step 5 · 获取初始 root 密码

```bash
cat /opt/gitlab/config/initial_root_password
# 首次 reconfigure 后生成，24 小时内有效；登录后立即修改
```

### Step 6 · 安全加固：关闭公开注册

GitLab 默认 **开放注册**（`application_settings.signup_enabled = true`）。该设置存于数据库，omnibus 配置只是默认值，需单独关闭：

```bash
cat > /tmp/disable_signup.rb <<'RUBY'
s = ApplicationSetting.last
s.update!(signup_enabled: false)
ApplicationSetting.clear_cache if ApplicationSetting.respond_to?(:clear_cache)
puts "signup_enabled=#{Gitlab::CurrentSettings.reload.signup_enabled}"
RUBY
docker cp /tmp/disable_signup.rb gitlab:/tmp/disable_signup.rb
docker exec gitlab gitlab-rails runner /tmp/disable_signup.rb
rm -f /tmp/disable_signup.rb
docker restart gitlab      # 让 Puma 工作进程刷新缓存
```

> 验证：`curl -s -o /dev/null -w '%{http_code}\n' http://<host>:<port>/users/sign_up` 应为 `302`（跳转登录页）。

---

## 4. 验证部署

```bash
# 1) Web 登录页（期望 200）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.40.189:8080/users/sign_in

# 2) 公开注册已关闭（期望 302）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.40.189:8080/users/sign_up

# 3) 容器镜像仓库在听（期望 401，表示服务已响应、需鉴权）
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.40.189:5050/v2/

# 4) Git SSH 端口在听
timeout 3 bash -c 'cat < /dev/null > /dev/tcp/192.168.40.189/2222' && echo SSH_OPEN

# 5) 数据库中的 root 用户
docker exec gitlab gitlab-rails runner "puts User.find_by(username: 'root').username"

# 6) API 全链路（PAT 过期日期必须晚于当天，否则 GitLab 判定为已过期）
TOKEN=$(docker exec gitlab gitlab-rails runner \
  "puts User.find_by(username: 'root').personal_access_tokens.create!(name: 'verify', scopes: [:api], expires_at: 3.days.from_now).token" \
  2>/dev/null | tail -1)
curl -s -H "PRIVATE-TOKEN: $TOKEN" http://192.168.40.189:8080/api/v4/version
# 期望：{"version":"19.5.5", ...,"kas":{"enabled":false,...}}

# 7) 确认 K8s 与既有服务未受影响
kubectl get nodes                                                # 两节点 Ready
ss -tlnp | grep -E ':(80|6443|10250|2379|8081|11434)\b'          # 原端口仍归原服务
docker ps --format '{{.Names}} {{.Status}}'                      # aivp-* 等仍在运行
```

---

## 5. 验证失败恢复

```bash
# 查看启动/初始化日志
docker logs --tail 200 gitlab

# 重置 root 密码（忘记初始密码时）
docker exec -it gitlab gitlab-rails runner -e production \
  "u=User.find_by(username:'root'); u.password='新密码'; u.password_confirmation='新密码'; u.save!"

# 重启 / 重新配置
cd /opt/gitlab && docker compose restart
docker exec gitlab gitlab-ctl reconfigure     # 手动重跑配置（改过 gitlab.rb 后）

# 完全卸载（谨慎：会删除全部仓库数据）
cd /opt/gitlab && docker compose down -v
rm -rf /opt/gitlab
```

---

## 6. 最佳实践

### 6.1 镜像与版本策略

- **必须走国内源**：`/etc/docker/daemon.json` 配置 `registry-mirrors`，compose 镜像使用 `docker.m.daocloud.io/gitlab/gitlab-ce`，不得直连 Docker Hub。
- **记录解析版本与摘要**：`:latest` 会随官方更新，部署后记录 `version-manifest.txt` 与 `RepoDigests`，便于审计与回滚。
- **升级前备份**：`docker compose pull && docker compose up -d` 会拉新镜像并重建容器；升级前先做数据备份（见 6.6）。

### 6.2 端口与网络（与 K8s 共存）

- GitLab 使用独立 bridge 网络（Compose 自动创建，如 `172.19.0.0/16`），与 K8s Pod CIDR（如 `10.244.0.0/24`）不重叠。
- 不创建任何 K8s 资源（namespace / ingress / GitLab Agent），不配置 KAS。
- 不重启 docker / containerd / kubelet，避免影响 K8s。
- 端口固定 `8080/2222/5050`，部署前用 `ss -tlnp` 确认空闲。

### 6.3 配置模型（重要，决定后续可维护性）

GitLab Docker 镜像的配置加载顺序（`/assets/gitlab.rb`）：

1. 由容器 `hostname` 生成默认 `external_url`；
2. 执行环境变量 `GITLAB_OMNIBUS_CONFIG`；
3. 加载持久化文件 `/etc/gitlab/gitlab.rb`（宿主 `DATA_DIR/config/gitlab.rb`）。

因此：

- **`GITLAB_OMNIBUS_CONFIG`（compose env）是自定义配置的推荐单一事实源**，每次 `gitlab-ctl reconfigure` 都会执行。
- 持久化的 `/etc/gitlab/gitlab.rb` 是官方模板（默认值全部注释），一般无需手改；若手改会**覆盖** env（因加载顺序在 env 之后）。
- **应用级设置**（注册开关、认证方式、项目默认值等）存于数据库 `application_settings`，omnibus 配置只是默认值；修改需走 Admin Area / API / Rails，并 `docker restart` 让 Puma 刷新缓存。

### 6.4 资源与性能

- 单实例建议 ≥ 4 核 / 8G；`puma['worker_processes']` 按核数设置（24 核取 4，留余量给 K8s 与既有服务）。
- 关闭 `prometheus_monitoring` 可显著降低内存（本例约 8.5G / 62G）。
- `shm_size: '256m'` 保证 PostgreSQL/Redis 正常。

### 6.5 安全加固清单

- [ ] 登录后立即修改 root 初始密码（初始密码 24h 失效）。
- [ ] 关闭公开注册（Step 6）。
- [ ] 如需外网访问，配置 HTTPS（`external_url 'https://...'` + `letsencrypt` 或反代），并加防火墙白名单。
- [ ] 配置 SMTP（`gitlab_rails['smtp_...']`）以启用邮件通知/找回密码。
- [ ] 按需开启 2FA、限制登录 IP、定期轮换 PAT。

### 6.6 备份与恢复

```bash
# 备份（生成 /var/opt/gitlab/backups/*.tar，宿主 DATA_DIR/data/backups/）
docker exec gitlab gitlab-rake gitlab:backup:create

# 密钥文件必须单独备份（否则恢复后无法解密 CI/CD 变量）
cp /opt/gitlab/config/gitlab-secrets.json /backup/

# 恢复
docker exec gitlab gitlab-rake gitlab:backup:restore BACKUP=<timestamp>_gitlab_backup.tar
docker restart gitlab
```

### 6.7 升级

```bash
cd /opt/gitlab
# 1. 备份
docker exec gitlab gitlab-rake gitlab:backup:create
# 2. 拉新镜像并重建
docker compose pull
docker compose up -d
# 3. 验证
docker inspect -f '{{.State.Health.Status}}' gitlab
```

### 6.8 日志与监控

- 日志目录：宿主 `DATA_DIR/logs/`（`nginx/`、`gitlab-rails/`、`postgresql/` 等）。
- 实时监控栈已关闭；如需，把 `prometheus_monitoring['enable']` 改回 `true` 并映射 `9090` 等端口（注意避让）。
- 容器健康：`docker inspect -f '{{.State.Health.Status}}' gitlab`。

---

## 7. 卸载

```bash
cd /opt/gitlab && docker compose down -v     # 删除容器与网络（保留数据卷目录）
rm -rf /opt/gitlab                           # 删除全部数据（不可逆，先备份）
docker rmi docker.m.daocloud.io/gitlab/gitlab-ce:latest   # 可选：删除镜像
```

---

## 8. Agent 注意事项

- **禁止接入 K8s**：不创建 namespace / Ingress / GitLab Agent，不配置 KAS（compose 已 `gitlab_kas['enable'] = false`）。
- **端口冲突**：`80`（aivp-web-1）、`22`（sshd）、`6443/10250/2379/8081`（K8s）、`11434`（aivp-api）不可占用；GitLab 固定 `8080/2222/5050`。
- **镜像源**：必须走 `docker.m.daocloud.io`，不得直连 Docker Hub；daocloud 对具体版本 tag 返回 `denied`，故用 `:latest` 并记录摘要。
- **配置变更**：改 compose 的 `GITLAB_OMNIBUS_CONFIG` 后 `docker compose up -d` 重建；应用级设置走 Admin/API/Rails 并重启容器。
- **破坏性操作**：`docker compose down -v`、`rm -rf /opt/gitlab`、`gitlab-rake ... restore` 必须向用户确认。
- **同机 K8s 遗留**：部署前检查是否存在遗留 `gitlab` 命名空间（NodePort 可能占用端口）；清理需用户确认。

---

## 附录 A · 命令速查

| 目的 | 命令 |
| --- | --- |
| 启动 | `cd /opt/gitlab && docker compose up -d` |
| 状态 | `docker compose -f /opt/gitlab/docker-compose.yml ps` |
| 健康 | `docker inspect -f '{{.State.Health.Status}}' gitlab` |
| 日志 | `docker logs --tail 200 gitlab` |
| 重启 | `docker compose -f /opt/gitlab/docker-compose.yml restart` |
| 重跑配置 | `docker exec gitlab gitlab-ctl reconfigure` |
| 组件状态 | `docker exec gitlab gitlab-ctl status` |
| 初始密码 | `cat /opt/gitlab/config/initial_root_password` |
| 备份 | `docker exec gitlab gitlab-rake gitlab:backup:create` |
| 重置 root 密码 | `docker exec -it gitlab gitlab-rails runner -e production "u=User.find_by(username:'root'); u.password='新密码'; u.password_confirmation='新密码'; u.save!"` |
| 版本 | `docker run --rm --entrypoint cat docker.m.daocloud.io/gitlab/gitlab-ce:latest /opt/gitlab/version-manifest.txt \| head -1` |

## 附录 B · 常见问题

**Q1：改了 `GITLAB_OMNIBUS_CONFIG` 但没生效？**
确认执行了 `docker compose up -d` 重建容器；若仍不生效，检查持久化 `/etc/gitlab/gitlab.rb` 是否有同名活动配置覆盖。

**Q2：注册关不掉？**
`signup_enabled` 是数据库应用设置，需按 Step 6 修改 `application_settings` 并重启容器。

**Q3：PAT 提示 "Token is expired"？**
GitLab 判定 `expires_at <= 当天` 即过期，创建 PAT 时过期日期要晚于当天（如 `3.days.from_now`）。

**Q4：镜像拉取慢/失败？**
确认 `daemon.json` 的 `registry-mirrors` 生效（`docker info` 可见），并优先用 `docker.m.daocloud.io`。

**Q5：端口被占用？**
`ss -tlnp` 定位占用进程，改用其他空闲端口，并同步更新 `external_url` 与 compose 映射。

**Q6：如何确认没有影响 K8s？**
`kubectl get nodes`（Ready）、`kubectl get pods -A`（无新增异常）、`ss -tlnp`（原端口归属不变）。
