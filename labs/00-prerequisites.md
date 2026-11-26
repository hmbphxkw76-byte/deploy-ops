# 00 · 通用前置条件（所有组件共用）

> **所属**：`labs/` 实验环境部署 · **前置**：本文为公共前置，**先读本文**
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64），root 或具备 sudo · **工作目录**：`$LAB_ROOT`（默认 `/opt/security-labs`）

目标：把一台干净 Ubuntu 主机准备成可承载全部实验组件的状态。**与具体 IP/主机无关**。

## 1. 系统与权限

- Ubuntu 20.04 / 22.04 / 24.04（x86_64）；root 或具备 sudo。
- 建议资源：≥ 4 核 / 8 GB RAM / 40 GB 可用磁盘（k8s 与 ML 组件需更多）。
- 关闭或放行防火墙对应端口（`ufw status`；云主机还需安全组放行）。

## 2. 安装 Docker 与 Compose v2

```bash
curl -fsSL https://get.docker.com | sh          # 官方脚本
systemctl enable --now docker
docker compose version                          # 需 v2+
sudo usermod -aG docker "$USER"                # 免 sudo（重新登录生效）
```

国内网络若 get.docker.com 慢，可改用 apt 安装 docker-ce（`mirrors.aliyun.com/docker-ce/linux/ubuntu`）。

## 3. 镜像加速（daemon.json）

`/etc/docker/daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.imgdb.de"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

```bash
systemctl restart docker
```

> ⚠️ 公共镜像源存在**白名单**：`vulhub/*`、`madhuakula/*` 等安全实验镜像会被拦截。
> 通用解法：`docker pull docker.1ms.run/<image>:<tag>` 然后 `docker tag` 回规范名。

## 4. 包管理镜像源

```bash
# pip（全局）
cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
extra-index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = pypi.tuna.tsinghua.edu.cn mirrors.aliyun.com
timeout = 60
EOF

# npm
npm config set registry https://registry.npmmirror.com

# HuggingFace（ML 组件）
export HF_ENDPOINT=https://hf-mirror.com
```

Docker 构建期不继承上述配置，需在 Dockerfile 内显式注入（见各组件文档）。

## 5. 目录规范

```
$LAB_ROOT/            # 默认 /opt/security-labs
├── src/              # 各组件解压源码（上游零改动）
├── build/            # 构建副本（改 Dockerfile/端口/绑定地址）
├── run/              # 运行副本（如改 host=0.0.0.0 的服务）
├── bin/              # 一键脚本（拉取器、启动器、补丁）
├── logs/             # 日志
└── venvs/            # Python 虚拟环境
```

## 6. 端口冲突检查

```bash
for p in 3000 8000 8081 5432 8200 6379 9999 9001 8080; do
  ss -ltn | grep -q ":$p\b" && echo "OCCUPIED $p" || echo "FREE $p"
done
```

冲突时的原则：**改自己，不改别人**（映射到备用端口并记录）。

## 7. 带宽与并发约定

- 多机共享同一上行时，大流量任务**串行错峰**；单机内可用 3–4 并发拉取。
- 后台任务统一落盘日志：`>> $LAB_ROOT/logs/<task>.log 2>&1`。

## 8. 一键引导脚本（可选）

将 §2–§5 固化为脚本，便于新机器快速就绪（幂等，可重复执行；已完成步骤自动跳过）：

```bash
#!/bin/bash
# labs-bootstrap.sh —— 实验环境一键就绪（幂等）
# 用法: sudo LAB_ROOT=/opt/security-labs bash labs-bootstrap.sh
set -euo pipefail
LAB_ROOT="${LAB_ROOT:-/opt/security-labs}"

# 1) 目录规范（§5）
mkdir -p "$LAB_ROOT"/{src,build,run,bin,logs,venvs}

# 2) Docker + Compose v2（§2）：已安装则跳过
if ! command -v docker >/dev/null 2>&1; then
  echo "[bootstrap] 安装 Docker ..."
  if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
    echo "[bootstrap] get.docker.com 不可达，改用阿里云镜像源安装 docker-ce"
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    sh /tmp/get-docker.sh
  fi
fi
systemctl enable --now docker
docker compose version || { echo "[bootstrap][ERROR] docker compose v2 不可用"; exit 1; }

# 3) daemon.json 镜像加速（§3）：合并写入而非覆盖；仅在变更时重启 docker
if [ -f /etc/docker/daemon.json ]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d)"
fi
before="$(cat /etc/docker/daemon.json 2>/dev/null || true)"
python3 - <<'PY'
import json
p = '/etc/docker/daemon.json'
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.setdefault('registry-mirrors', [])
for m in ('https://docker.m.daocloud.io', 'https://docker.imgdb.de'):
    if m not in d['registry-mirrors']:
        d['registry-mirrors'].append(m)
d.setdefault('log-driver', 'json-file')
d.setdefault('log-opts', {})
d['log-opts'].setdefault('max-size', '50m')
d['log-opts'].setdefault('max-file', '3')
open(p, 'w').write(json.dumps(d, indent=2) + '\n')
PY
after="$(cat /etc/docker/daemon.json 2>/dev/null || true)"
[ "$before" = "$after" ] || { echo "[bootstrap] daemon.json 变更，重启 docker"; systemctl restart docker; }

# 4) pip / npm / HuggingFace 源（§4）
if [ ! -f /etc/pip.conf ]; then
  cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
extra-index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = pypi.tuna.tsinghua.edu.cn mirrors.aliyun.com
timeout = 60
EOF
fi
command -v npm >/dev/null 2>&1 && npm config set registry https://registry.npmmirror.com
grep -q 'HF_ENDPOINT=https://hf-mirror.com' /etc/profile.d/hf-mirror.sh 2>/dev/null \
  || echo 'export HF_ENDPOINT=https://hf-mirror.com' >> /etc/profile.d/hf-mirror.sh

echo "[bootstrap] 完成。执行 §9 自检确认就绪。"
```

## 9. 验证（新机器就绪自检）

```bash
docker --version && docker compose version
systemctl is-active docker
python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')).get('registry-mirrors'))"
ls -d "$LAB_ROOT"/{src,build,run,bin,logs,venvs}
# 端口占用检查复用 §6 的循环
```

期望：Docker 与 Compose v2 就绪、镜像加速地址非空、六个目录存在。

## 10. Agent 注意事项

- 本文是 `labs/` 全部组件的公共前置；执行 `01`–`08` 任意一篇前，先完成 §1–§6。
- 镜像加速、pip / npm / HF 源默认「国内源优先」；海外环境按各节注释回退官方源。
- 写 `/etc/docker/daemon.json` 必须**合并**而非覆盖既有键；重启 docker 会影响运行中容器，先告知影响面。
- 端口冲突时「改自己，不改别人」：映射到备用端口，并在 `labs/README.md` 的端口规划总表登记。
