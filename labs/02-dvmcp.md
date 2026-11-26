# 02 · damn-vulnerable-MCP-server（MCP 挑战平台）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· 依赖 Docker + Compose v2 · **默认端口**：Dashboard 8081、挑战服务 9001–9015

- **来源**：`damn-vulnerable-MCP-server-main.zip`
- **形态**：Docker 镜像 + supervisord 常驻 15 个挑战服务
- **默认端口**：Dashboard `8081`；挑战服务 `9001–9015`

## 1. 为什么需要构建副本

镜像基于 `python:3.11-slim`，构建过程要 `apt install nodejs/npm`、`pip install`、`npm build`。
构建网络**不走宿主机镜像加速**，需在 Dockerfile 注入国内源（见 §2）。

```bash
LAB_ROOT=/opt/security-labs
mkdir -p "$LAB_ROOT/build"
cp -a "$LAB_ROOT/src/damn-vulnerable-MCP-server-main" "$LAB_ROOT/build/dvmcp"
```

## 2. Dockerfile 注入（在副本中编辑 `Dockerfile`）

在 `FROM python:3.11-slim` 之后加入：

```dockerfile
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ENV PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn
ENV npm_config_registry=https://registry.npmmirror.com
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; true
```

## 3. 端口规划

`8081` 在装有 flannel/kubelet 的机器上常被占用。在副本中改映射：

```yaml
# docker-compose.yml
ports:
  - "18081:8081"        # 原 "8081:8081"
  - "9001-9015:9001-9015"
```

## 4. 启动与验证

```bash
cd "$LAB_ROOT/build/dvmcp"
docker compose up -d --build
curl -s http://<HOST>:18081/health        # 期望 200
curl -s -o /dev/null -w '%{http_code}\n' http://<HOST>:9001/mcp   # 期望 406（需带 MCP 头）
docker compose ps
```

## 5. 使用

浏览器打开 `http://<HOST>:18081`，按 Dashboard 指引逐个挑战；挑战服务端点形如
`http://<HOST>:900X/mcp`。

## 6. 停止 / 清理

```bash
docker compose down          # 保留镜像
docker compose down -v       # 连卷删除
```

## 7. 注意事项

- 构建网络**不走宿主机镜像加速**，必须按 §2 在 Dockerfile 注入国内源，否则 apt / pip / npm 极易超时。
- `8081` 在装有 flannel / kubelet 的机器上常被占用；按 §3 改映射为备用端口（如 `18081`）并在 `labs/README.md` 的端口规划总表登记。
- `docker compose down -v` 会删除全部卷数据，执行前先确认。
