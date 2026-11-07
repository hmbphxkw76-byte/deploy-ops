# Docker 部署手册（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 Ubuntu 上自动安装配置 Docker、配置 Windows Docker Desktop 镜像加速，以及执行日常空间清理。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；安装部分幂等，已完成的步骤会自动跳过。清理属于破坏性维护操作，必须先经用户确认。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `TARGET_OS` | `ubuntu` | 目标环境：`ubuntu`（走第 1~2 章）或 `windows`（走第 3 章） |
| `DOCKER_APT_MIRROR` | `https://download.docker.com/linux/ubuntu` | Docker apt 仓库地址；国内网络对官方源报 `Could not handshake` 时改用 `https://mirrors.aliyun.com/docker-ce/linux/ubuntu`（GPG key 仍可用官方地址下载） |
| `REGISTRY_MIRRORS` | `https://docker.xuanyuan.me`、`https://docker.m.daocloud.io`、`https://docker.imgdb.de` | Ubuntu 侧镜像加速地址列表 |
| `DOCKER_MIRRORS_WIN` | `https://docker.xuanyuan.me`、`https://docker.1ms.run`、`https://docker.m.daocloud.io` | Windows Docker Desktop 镜像加速地址列表 |
| `RUN_CLEANUP` | `false` | 是否执行第 4 章清理；默认不执行，需用户显式确认 |

## 1. 前置检查（只读，不修改系统）

### Ubuntu 环境

按顺序执行并记录结果：

```bash
# 1) 系统版本与架构
cat /etc/os-release && dpkg --print-architecture

# 2) Docker 是否已安装
docker --version 2>/dev/null || echo "NOT_INSTALLED"

# 3) 服务状态（已安装时）
systemctl is-active docker 2>/dev/null || true
```

判定逻辑：

- Docker 已安装且服务 active → 跳过第 2 章安装，仅按需检查镜像加速（2.2）。
- Docker 未安装 → 继续第 2 章。
- 当前用户无 sudo 权限 → 提示用户提供具备 sudo 权限的账户，不要继续。

### Windows 环境

```powershell
docker version
```

- 若命令可用 → 跳过第 3 章安装，仅按需检查镜像加速配置。
- 若 Docker Desktop 未安装 → 提示用户从官网下载安装（GUI 安装需用户手动完成），Agent 不代替执行。

## 2. Ubuntu 安装与配置（对应原 docker_install.sh）

### 2.1 安装 Docker Engine

逐步执行，每步失败即停止并报告：

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# 添加 Docker 官方 GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 添加 apt 仓库（自动适配当前发行版代号与架构）
# 国内网络对官方源报 "Could not handshake" 时，先 export DOCKER_APT_MIRROR=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_APT_MIRROR:-https://download.docker.com/linux/ubuntu}
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 2.2 配置镜像加速

检查逻辑：若 `/etc/docker/daemon.json` 已包含 `REGISTRY_MIRRORS` 中的地址，则跳过；否则写入并重启服务。

```bash
sudo mkdir -p /etc/docker

sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.xuanyuan.me",
    "https://docker.m.daocloud.io",
    "https://docker.imgdb.de"
  ]
}
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

> 若用户已有自定义 daemon.json（如配置了 data-root 等），Agent 应先读取现有内容并合并 registry-mirrors，禁止直接覆盖。

### 2.3 服务自启与用户组

```bash
sudo systemctl start docker
sudo systemctl enable docker

# 将当前用户加入 docker 组（免 sudo 使用 docker，重新登录后生效）
sudo usermod -aG docker $(whoami)
```

> usermod 幂等，重复执行安全。执行后需提醒用户重新登录（或 `newgrp docker`）才能免 sudo 使用 docker。

## 3. Windows Docker Desktop 镜像加速

Docker Desktop 的配置通过其 GUI 或 settings 文件管理，Agent 步骤：

1. 确认 Docker Desktop 已启动（`docker version` 可用）。
2. 提示用户打开 Docker Desktop → Settings → Docker Engine，将以下 JSON 合并/替换进配置（若已有其他自定义项需合并而非覆盖）：

```json
{
  "builder": {
    "gc": {
      "defaultKeepStorage": "20GB",
      "enabled": true
    }
  },
  "experimental": false,
  "registry-mirrors": [
    "https://docker.xuanyuan.me",
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io"
  ]
}
```

3. 用户点击 "Apply & Restart" 后，Agent 执行验证命令确认生效。

## 4. 验证部署

```bash
docker --version
systemctl is-active docker          # Ubuntu
docker info | grep -A 5 "Registry Mirrors"
docker run --rm hello-world
```

### 4.1 快速验证脚本（一键检查，含详细日志与自动重试）

保存为 `docker_verify.sh`（Ubuntu 下使用；Windows 侧可手动执行第 4 章开头命令）。脚本只读检查 + 一次 hello-world 拉取运行，不修改任何配置，Agent 可直接执行并按输出判定。

日志说明：

- 所有输出带时间戳与级别（`INFO/PASS/FAIL/WARN/SKIP`），实时打印并同时写入日志文件。
- 日志文件默认生成在脚本同目录：`docker_verify_<时间戳>.log`，可通过环境变量覆盖：`LOG_FILE=/path/to/xx.log bash docker_verify.sh`。
- 每个检查项失败时，会把失败命令的关键输出（stderr 摘要）写入日志，便于 Agent 直接定位原因。

自动重试说明：

- daemon 检查与 hello-world 运行内置自动重试（应对服务未就绪、网络抖动、拉取偶发失败）。
- 重试参数可通过环境变量调整：`RETRY_MAX`（最大尝试次数，默认 3）、`RETRY_DELAY`（重试间隔秒数，默认 5），例如：`RETRY_MAX=5 RETRY_DELAY=10 bash docker_verify.sh`。
- 每次尝试的结果与输出摘要均写入日志，最终失败时日志中可看到全部尝试记录。

超时控制说明：

- 所有命令均由 `timeout` 包裹执行：单条检查命令默认超时 60 秒（`CMD_TIMEOUT`），hello-world 单次尝试默认 120 秒（`HW_TIMEOUT`），可用环境变量调整，例如：`CMD_TIMEOUT=30 HW_TIMEOUT=180 bash docker_verify.sh`。
- 超时的退出码为 124，日志中会标注"超时"；带重试的命令超时后自动进入下一次尝试，不中断脚本。
- 脚本汇总时输出总耗时，便于 Agent 判断是否卡在慢速网络环节。

```bash
#! /bin/bash
# Docker 快速验证脚本：安装、服务、镜像加速、run 能力、compose 插件（含详细日志、自动重试与超时控制）
# 用法:   bash docker_verify.sh [镜像加速地址1 地址2 ...]
#         LOG_FILE=/path/to/xx.log bash docker_verify.sh          # 自定义日志路径
#         RETRY_MAX=5 RETRY_DELAY=10 bash docker_verify.sh        # 自定义重试参数
#         CMD_TIMEOUT=30 HW_TIMEOUT=180 bash docker_verify.sh     # 自定义超时参数
# 退出码: 0=全部通过, 1=存在失败项

set -u
MIRRORS=("$@")   # 不传参则跳过镜像地址逐一比对，仅检查是否配置了加速
PASS=0; FAIL=0; SKIP=0
RETRY_MAX="${RETRY_MAX:-3}"        # 最大尝试次数
RETRY_DELAY="${RETRY_DELAY:-5}"    # 重试间隔（秒）
RETRY_OUT=""                       # 最近一次 retry 命令的输出（供调用方读取）
CMD_TIMEOUT="${CMD_TIMEOUT:-60}"   # 单条检查命令超时（秒）
HW_TIMEOUT="${HW_TIMEOUT:-120}"    # hello-world 单次尝试超时（秒）
START_TS=$(date +%s)               # 脚本开始时间（用于统计总耗时）

# ---------- 日志基础设施 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/docker_verify_$(date +%Y%m%d_%H%M%S).log}"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null   # 无写权限时退化为仅屏幕输出

log() {  # log <级别> <消息...>
  local level="$1"; shift
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

log_run() {  # 记录正在执行的命令
  log INFO "执行: $*"
}

show_tail() {  # show_tail <输出内容> [行数] —— 打印输出摘要（首尾各几行）
  local out="$1" n="${2:-5}"
  local lines; lines=$(echo "$out" | sed '/^\s*$/d')
  local total; total=$(echo "$lines" | wc -l)
  if [ "$total" -eq 0 ]; then
    log WARN "  （无输出）"
  elif [ "$total" -le $((n*2)) ]; then
    echo "$lines" | while IFS= read -r l; do log INFO "  | $l"; done
  else
    echo "$lines" | head -n "$n" | while IFS= read -r l; do log INFO "  | $l"; done
    log INFO "  | ...（省略 $((total - n*2)) 行，完整输出见日志文件）..."
    echo "$lines" | tail -n "$n" | while IFS= read -r l; do log INFO "  | $l"; done
  fi
}

rc_desc() {  # rc_desc <退出码> —— 将特殊退出码转为可读说明
  case "$1" in
    124) echo "超时(124)";;
    137) echo "被强制终止(137, 可能OOM)";;
    *)   echo "退出码: $1";;
  esac
}

check() {  # check <描述> <命令...> —— 执行命令（带超时）并记录结果与输出
  local desc="$1"; shift
  log_run "$@"
  log INFO "  超时上限: ${CMD_TIMEOUT}s"
  local out rc
  out=$(timeout "$CMD_TIMEOUT" "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    log PASS "$desc"
    [ -n "$out" ] && show_tail "$out" 2
    PASS=$((PASS+1))
  else
    log FAIL "$desc ($(rc_desc "$rc"))"
    show_tail "$out" 5
    FAIL=$((FAIL+1))
  fi
  return 0   # 不中断后续检查
}

retry() {  # retry <描述> <最大次数> <间隔秒> <命令...> —— 带超时的自动重试，最近一次输出存入全局 RETRY_OUT
  local desc="$1" max="$2" delay="$3"; shift 3
  local i out rc
  for i in $(seq 1 "$max"); do
    log INFO "执行(第 $i/$max 次, 超时 ${CMD_TIMEOUT}s): $*"
    out=$(timeout "$CMD_TIMEOUT" "$@" 2>&1); rc=$?
    RETRY_OUT="$out"
    if [ $rc -eq 0 ]; then
      log PASS "$desc (第 $i 次尝试成功)"
      [ -n "$out" ] && show_tail "$out" 2
      return 0
    fi
    log WARN "第 $i/$max 次尝试失败 ($(rc_desc "$rc"))"
    show_tail "$out" 3
    if [ "$i" -lt "$max" ]; then
      log INFO "等待 ${delay}s 后重试..."
      sleep "$delay"
    fi
  done
  log FAIL "$desc 重试 $max 次后仍失败"
  return 1
}

check_retry() {  # check_retry <描述> <最大次数> <间隔秒> <命令...> —— 带重试的检查项
  local desc="$1"; shift
  if retry "$desc" "$@"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
  return 0
}

# ---------- 开始 ----------
log INFO "=== Docker 快速验证开始 ==="
log INFO "主机: $(hostname 2>/dev/null || echo unknown) | 用户: $(whoami) | 内核: $(uname -r 2>/dev/null || echo unknown)"
log INFO "日志文件: $LOG_FILE"

# 1. 已安装
check "docker 已安装" docker --version

# 2. 服务运行中（Ubuntu）
if command -v systemctl >/dev/null 2>&1; then
  check "docker 服务运行中" systemctl is-active --quiet docker
else
  log SKIP "无 systemctl（非 Ubuntu/WSL 环境），跳过服务检查"; SKIP=$((SKIP+1))
fi

# 3. daemon 可响应（带重试：服务可能仍在启动中）
check_retry "docker daemon 可响应" "$RETRY_MAX" "$RETRY_DELAY" docker info

# 4. 镜像加速已配置
MIRROR_INFO=$(docker info 2>&1) || true
if echo "$MIRROR_INFO" | grep -q "Registry Mirrors"; then
  log PASS "已配置镜像加速"
  PASS=$((PASS+1))
  echo "$MIRROR_INFO" | grep -A 5 "Registry Mirrors" | while IFS= read -r l; do
    [ -n "$l" ] && log INFO "  | $l"
  done
  if [ ${#MIRRORS[@]} -gt 0 ]; then
    for m in "${MIRRORS[@]}"; do
      if echo "$MIRROR_INFO" | grep -q "$m"; then
        log PASS "加速地址生效: $m"; PASS=$((PASS+1))
      else
        log FAIL "加速地址未生效: $m（检查 daemon.json 与服务是否重启）"; FAIL=$((FAIL+1))
      fi
    done
  else
    log INFO "未传入比对地址，跳过逐项比对"
  fi
else
  log FAIL "未配置镜像加速（参考第 2.2 章 daemon.json 配置）"
  show_tail "$MIRROR_INFO" 3
  FAIL=$((FAIL+1))
fi

# 5. compose 插件（可选，缺失只提示不算失败）
if docker compose version >/dev/null 2>&1; then
  log PASS "docker compose 插件可用 ($(docker compose version --short 2>/dev/null || echo unknown))"; PASS=$((PASS+1))
else
  log SKIP "docker compose 插件未安装（可执行第 2.1 章安装）"; SKIP=$((SKIP+1))
fi

# 6. 拉取并运行 hello-world（验证端到端可用，带超时与重试）
log INFO "运行 hello-world（单次超时 ${HW_TIMEOUT}s，自动重试最多 $RETRY_MAX 次，间隔 ${RETRY_DELAY}s）..."
RETRY_OUT=""
if retry "hello-world 运行成功" "$RETRY_MAX" "$RETRY_DELAY" timeout "$HW_TIMEOUT" docker run --rm hello-world; then
  PASS=$((PASS+1))
else
  log FAIL "hello-world 最终失败，多为网络/加速问题（详见上方各次尝试的输出摘要）"
  FAIL=$((FAIL+1))
fi

# ---------- 汇总 ----------
ELAPSED=$(( $(date +%s) - START_TS ))
log INFO "=== 结果: $PASS 通过, $FAIL 失败, $SKIP 跳过 (总耗时 ${ELAPSED}s) ==="
log INFO "完整日志已保存: $LOG_FILE"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
```

Agent 判定规则：

- 退出码 `0` → 部署验证通过，向用户汇报各项 PASS 结果。
- 退出码 `1` → 读取日志文件（路径见日志末行），逐项分析 FAIL 的输出摘要，按第 6 章排障（先查 `journalctl -u docker`），不要盲目重试。
- `hello-world` 失败但其余通过 → 多为网络/加速问题，优先检查 registry-mirrors 配置与网络连通性。

### 4.2 调用方式

**方式一：交给 AI IDE / Agent 执行（推荐）**

在任意支持 Agent 的 IDE（Trae、Qoder、WorkBuddy 等）中直接下达指令即可，例如：

```text
按 docker/docker.md 第 4.1 章的快速验证脚本验证 Docker 部署，
从参数区读取 REGISTRY_MIRRORS 作为比对地址，执行后汇报结果与日志路径。
```

Agent 的工作流程：从本手册提取脚本 → 保存为 `docker_verify.sh` → 执行 `bash docker_verify.sh <参数区镜像地址...>` → 按退出码与日志汇报。

**方式二：手动在终端执行**

```bash
# 1. 将 4.1 章脚本内容保存为 docker_verify.sh（放在任意有写权限的目录）

# 2. 基础调用（重试/超时/日志全部使用默认值）
bash docker_verify.sh

# 3. 传入参数区的镜像加速地址，逐项验证是否生效
bash docker_verify.sh https://docker.xuanyuan.me https://docker.m.daocloud.io https://docker.imgdb.de

# 4. 按需覆盖参数：更多重试、更长间隔、更短单命令超时、自定义日志路径
LOG_FILE=/tmp/verify.log RETRY_MAX=5 RETRY_DELAY=10 CMD_TIMEOUT=30 HW_TIMEOUT=180 \
  bash docker_verify.sh https://docker.xuanyuan.me
```

执行后查看 `[FAIL]` 行定位问题，完整输出在同目录 `docker_verify_<时间戳>.log`。

## 5. 空间清理（破坏性操作，默认不执行）

> 仅当 `RUN_CLEANUP=true` 或用户明确要求时才执行。第 4、5 步可能删除重要数据，执行前必须逐项向用户确认。

```bash
# 1. 查看当前 Docker 空间占用
docker system df

# 2. 清理悬空镜像（安全）
docker image prune -f

# 3. 清理已停止的容器（安全）
docker rm $(docker ps -aq -f status=exited) 2>/dev/null || true

# 4. 清理未使用的卷（危险：卷中可能包含重要数据，逐个确认后执行）
docker volume prune -f

# 5. 清理构建缓存（安全，但会降低后续构建速度）
docker builder prune -f

# 6. 再次查看清理后的空间占用，向用户汇报释放量
docker system df
```

### 终极清理（慎用）

```bash
docker system prune -a
```

> 会删除所有停止的容器、未被使用的镜像、网络和构建缓存。Agent 必须先列出将被删除的资源（`docker system prune -a --dry-run` 不支持，可用 `docker images`、`docker ps -a` 代替查看），经用户明确确认后才执行。

## 6. Agent 执行注意事项

- Ubuntu 侧命令需要 sudo；Agent 应使用非交互方式执行 sudo 命令（如终端已授权），避免卡在密码输入。
- **`download.docker.com` TLS 握手失败**（国内网络常见，apt update 报 `Could not handshake`）：将 `/etc/apt/sources.list.d/docker.sources` 中的 `https://download.docker.com/linux/ubuntu` 替换为阿里云镜像 `https://mirrors.aliyun.com/docker-ce/linux/ubuntu`，GPG key 可继续沿用官方地址（curl 下载通常可用）。
- **dpkg 锁被 `unattended-upgr` 占用**（`E: Could not get lock /var/lib/dpkg/lock-frontend`）：新装 Ubuntu 22.04 首次启动会自动跑安全更新。等待其自然结束；若长时间无进展（进程 CPU 时间持续增长、网络不佳）可 `systemctl stop unattended-upgrades`，必要时 kill 进程；该服务被 apt-daily 触发会自动重启抢锁，需一并 `systemctl disable unattended-upgrades apt-daily.timer apt-daily-upgrade.timer` 后再继续安装。
- **安装即自启**：`apt install docker-ce` 会自动启动 docker 服务，若 daemon.json 在安装之后才写入，必须 `systemctl restart docker` 镜像加速才生效（`docker info | grep -A 4 "Registry Mirrors"` 验证）。
- 修改 daemon.json 前必须先读取现有内容，合并配置而不是覆盖。
- 服务操作（restart/enable）失败时，用 `journalctl -u docker --no-pager -n 50` 查看日志并报告原因，不要盲目重试。
- 每完成一章，向用户汇报当前状态与下一步计划。
