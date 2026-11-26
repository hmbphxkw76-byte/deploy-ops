# 01 · vulhub（Web 漏洞场景集）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· 依赖 Docker + Compose v2 · **端口**：场景自定义（常见 8080）

- **来源**：`vulhub-master.zip`
- **形态**：每个子目录一个场景，`docker compose up -d` 即可运行
- **依赖**：Docker + Compose v2
- **规模**：约 334 个场景 / 331 个唯一镜像

## 1. 安装

```bash
LAB_ROOT=/opt/security-labs
mkdir -p "$LAB_ROOT/src"
unzip -q vulhub-master.zip -d "$LAB_ROOT/src/"
cd "$LAB_ROOT/src/vulhub-master"
```

无需全局安装；镜像在运行时按需拉取。

## 2. 运行单个场景

```bash
cd "$LAB_ROOT/src/vulhub-master/nginx/CVE-2017-7529"
docker compose up -d
docker compose ps
# 访问 compose 中映射的端口，例如 http://<HOST>:8080
docker compose down      # 结束
```

## 3. 镜像获取策略（重要）

公共镜像源常拦截 `vulhub/*`。推荐助手脚本自动“白名单绕行”：

```bash
#!/bin/bash
# vulhub-run.sh <scenario-path>  例如 nginx/CVE-2017-7529
SCEN="${1:?usage: vulhub-run.sh <scenario>}"
DIR="$LAB_ROOT/src/vulhub-master/$SCEN"
[ -f "$DIR/docker-compose.yml" ] || { echo "场景不存在: $DIR"; exit 1; }

cd "$DIR"
for img in $(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' docker-compose.yml \
             | tr -d "\"' " | sort -u); do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "HAVE $img"
  elif timeout 900 docker pull "docker.1ms.run/$img" >/dev/null 2>&1; then
    docker tag "docker.1ms.run/$img" "$img"; echo "PULLED $img"
  else
    echo "MISS $img（可能为本地构建镜像）"
  fi
done

docker compose up -d
docker compose ps
grep -A6 '^ports:' docker-compose.yml || true
```

## 4. 全量镜像预缓存（可选）

带宽充足时预拉全部镜像；务必带磁盘保护：

```bash
grep -rh '^[[:space:]]*image:' --include='docker-compose.yml' . \
  | sed 's/.*image:[[:space:]]*//; s/["'"'"']//g' | sort -u > /tmp/vh_images.txt
# 并发 3–4，逐行 docker pull（失败重试一次），每轮检查 df -BG / 剩余 > 6G
```

## 5. 验证

任选一个场景启动后 `curl -I http://<HOST>:<端口>/`，期望 2xx/3xx。

## 6. 注意事项

- 部分场景用 `build:` 本地构建，不需要也无法拉取其 `image:`。
- 端口按场景而异，以各自 `docker-compose.yml` 为准；常见默认 8080。
- 跑完及时 `down`，避免端口/资源占用影响其他实验。
