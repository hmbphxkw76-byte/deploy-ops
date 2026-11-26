# 99 · 故障排查与运维速查

> **所属**：`labs/` 实验环境部署 · **前置**：组件异常时查阅本文
> **适用**：Ubuntu 20.04 / 22.04 / 24.04 · Docker / Kubernetes（k3d）/ 远程批量操作

## 1. 通用排查表

| 现象 | 常见原因 | 解法 |
|---|---|---|
| 拉 `vulhub/*`、`madhuakula/*` 报 “not in allowlist” | 公共源白名单 | `docker pull docker.1ms.run/<img>` 后 `docker tag` 回原名 |
| 构建时 apt/pip/npm 超时 | 构建环境不走宿主机加速 | Dockerfile 注入国内源（apt/pip/npm/Alpine） |
| `ghcr.io` 镜像拉不动 | 公共网络不可达 | 跳过（`--no-lb`）或本地源码构建（k3d-tools） |
| Pod `ContainerCreating` + failed to get sandbox image | 节点缺 pause 等系统镜像 | `docker save <img> \| docker exec -i <node> ctr -n k8s.io images import -` |
| Pod `ImagePullBackOff`，本地已有镜像 | `imagePullPolicy: Always` | 改为 `IfNotPresent`（Job 需改清单重建） |
| Compose/K8s 端口起不来 | 端口被占用（含 8081 flannel、3000/8000 常见） | 改自己映射到备用口并登记 |
| 下载整体龟速 | 多机共享上行 / 多任务并发 | 暂停对端重任务，串行错峰 |
| `curl https://pypi.org` / `huggingface.co` 超时 | 国际出口受限 | 用 tuna/aliyun、`HF_ENDPOINT=hf-mirror.com` |
| `ssh` 执行后台任务不返回 | 后台进程持有通道 fd | `ssh -f host 'cmd'` 或 `setsid nohup ... </dev/null >/dev/null 2>&1 &` |
| `pkill -f xxx` 杀掉自己的会话 | 命令行里出现同名正则 | 用 `[x]xx` 括号技巧，或按端口取 PID 精确 kill |
| pip 拉到一半断流 | 带宽/源不稳定 | 重试；`-i` 指定镜像；必要时分段下载 |

## 2. 安全删除与清理

- 单组件停止：`docker compose down`（保留数据）/ `down -v`（清空卷）。
- k8s：`k3d cluster delete <name>`。
- Node 项目：`rm -rf node_modules`。
- 镜像批量清理（谨慎）：先 `docker images` 核对，再按标签删除；**禁止** `docker system prune -a` 在生产混合主机上执行。
- 文档、脚本等中间文件放 `$LAB_ROOT/logs`、`$LAB_ROOT/bin`，便于审计与复用。

## 3. 远程批量操作模板

```bash
# 单行远程命令
ssh root@<host> '<cmd>'

# 长任务后台（本地立即返回）
ssh -f root@<host> '/path/to/script.sh'

# 远端完全脱离终端
ssh root@<host> "setsid nohup /path/to/script.sh </dev/null >/path/to/log 2>&1 &"
```

## 4. 常用自检片段

```bash
# 端口
ss -ltnp | grep -E ':(3000|8000|18081|9999)\b'

# Docker 状态
docker ps --format '{{.Names}} | {{.Status}}'

# K8s 状态
kubectl get nodes; kubectl get pods -A | grep -v Running

# 资源
df -h /; free -h; nproc
```

## 5. 复用检查清单（新机器上线时逐项打勾）

- [ ] Docker + Compose v2 就绪，daemon.json 镜像加速生效
- [ ] pip / npm / HF 国内源配置完成
- [ ] `$LAB_ROOT/{src,build,run,bin,logs,venvs}` 目录建好
- [ ] 目标端口占用检查完成，冲突项已改备用端口
- [ ] 实验包解压至 `src/`，上游源码保持零改动
- [ ] 按 01–08 顺序部署并逐项验证
- [ ] 访问入口汇总更新到团队文档（IP/端口/凭据位置）
