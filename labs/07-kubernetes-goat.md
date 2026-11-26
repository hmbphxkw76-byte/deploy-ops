# 07 · kubernetes-goat（K8s 攻击场景集）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / k3d / helm）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· Docker + k3d + kubectl · **端口**：1230–1236（入口 1234）

- **来源**：`kubernetes-goat-master.zip`
- **形态**：约 40 个场景清单，部署到**隔离的 K8s 集群**（推荐 k3d，无需嵌套虚拟化）
- **访问端口**：1230–1236（入口 1234）

> 隔离建议：不要在有生产负载的共享集群里直接部署；用独立 k3d/kind 集群承载。

## 1. 工具准备

```bash
# k3d（GitHub Releases，国内可加镜像前缀尝试）
VER=$(curl -sS https://api.github.com/repos/k3d-io/k3d/releases/latest \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])")
for u in "https://github.com/k3d-io/k3d/releases/download/${VER}/k3d-linux-amd64" \
         "https://ghfast.top/https://github.com/k3d-io/k3d/releases/download/${VER}/k3d-linux-amd64"; do
  curl -fsSL -o /usr/local/bin/k3d "$u" && break
done
chmod +x /usr/local/bin/k3d

# helm
HVER=$(curl -sS https://api.github.com/repos/helm/helm/releases/latest \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])")
curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-${HVER}-linux-amd64.tar.gz"
tar -xzf /tmp/helm.tgz -C /tmp && install -m0755 /tmp/linux-amd64/helm /usr/local/bin/helm
```

## 2. ghcr.io 组件处理

k3d 依赖 `ghcr.io/k3d-io/k3d-tools` 与 `k3d-proxy`，公共网络常不可达：

- **proxy**：建集群时加 `--no-lb` 跳过；
- **tools**：用仓库源码自建（tools 是独立 Go module 且自带 `vendor/`，可离线编译）。
  自定义 Dockerfile 要点：

```dockerfile
FROM golang:<go-ver>-alpine<ver> AS builder
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories \
 && apk update && apk add --no-cache bash git make
WORKDIR /build
COPY . /
RUN cd /tools && GOFLAGS=-mod=vendor CGO_ENABLED=0 go build -ldflags '-w -s' -o /tmp/k3d-tools .
FROM alpine:latest
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories \
 && apk update && apk add --no-cache bash
COPY --from=builder /tmp/k3d-tools /app/k3d-tools
ENTRYPOINT ["/app/k3d-tools"]
```

```bash
docker build -t ghcr.io/k3d-io/k3d-tools:<k3d版本号> -f k3d-tools.Dockerfile <k3d仓库根>
```

## 3. 创建集群

```bash
k3d cluster create goat --servers 1 --agents 0 \
  --api-port 127.0.0.1:6550 --no-lb --wait --timeout 900s
kubectl get nodes -o wide        # Ready 即可
```

单节点即可运行全部场景；RAM ≥ 8 GB 更稳。

## 4. 预置镜像（关键步骤）

公共源拦截 `madhuakula/*`；且 k3s 节点默认直连 `registry-1.docker.io`。
可靠做法是宿主机拉取后**直接注入节点容器运行时**：

```bash
# 1) 收集清单涉及的全部镜像
grep -rhoE 'image:[[:space:]]*"?[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?' \
  --include='*.yaml' scenarios | sed 's/image:[[:space:]]*//; s/"//g' | sort -u > /tmp/goat_images.txt
# 追加系统镜像：rancher/mirrored-pause、klipper-helm、klipper-lb、local-path-provisioner、
#              mirrored-coredns-coredns、mirrored-metrics-server、mirrored-library-traefik、busybox

# 2) 宿主机逐個拉取（被拦时走 1ms.run 并重打标签）
for img in $(cat /tmp/goat_images.txt); do
  docker image inspect "$img" >/dev/null 2>&1 && continue
  timeout 900 docker pull "docker.m.daocloud.io/$img" || timeout 900 docker pull "docker.1ms.run/$img"
  docker tag "docker.m.daocloud.io/$img" "$img" 2>/dev/null || true
done

# 3) 注入节点（替换 <node> 为实际节点容器名，如 k3d-goat-server-0）
for img in $(cat /tmp/goat_images.txt); do
  docker save "$img" | docker exec -i <node> ctr -n k8s.io images import -
done
```

> `k3d image import` 在部分版本/工具镜像组合下不可靠，优先使用上面的 `ctr` 直注。

## 5. 修正 imagePullPolicy

很多清单写 `imagePullPolicy: Always`，即使本地有镜像也会回源失败。统一改 `IfNotPresent`：

```bash
kubectl get deployments,statefulsets,daemonsets,jobs -A -o json > /tmp/wl.json
python3 - <<'PY'
import json, subprocess
d = json.load(open('/tmp/wl.json'))
for it in d.get('items', []):
    spec = it.get('spec',{}).get('template',{}).get('spec',{})
    conts = spec.get('containers',[]) + spec.get('initContainers',[])
    if not any(c.get('imagePullPolicy')=='Always' for c in conts): continue
    for c in conts: c['imagePullPolicy'] = 'IfNotPresent'
    patch = {"spec":{"template":{"spec":{"containers":spec.get('containers',[]),
                                          "initContainers":spec.get('initContainers',[])}}}}
    subprocess.run(['kubectl','patch',it['kind'].lower(),it['metadata']['name'],
                    '-n',it['metadata'].get('namespace','default'),
                    '--type','strategic','-p',json.dumps(patch)], capture_output=True)
PY
```

Job 的 pod 模板**不可原地 patch**：改 `scenarios/<name>/*.yaml` 后
`kubectl delete job <name> -n default && kubectl apply -f <file>`。

## 6. 部署场景并暴露访问

```bash
cd "$LAB_ROOT/src/kubernetes-goat-master"
bash setup-kubernetes-goat.sh          # 元数据服务 + 各场景
bash access-kubernetes-goat.sh         # 端口转发 0.0.0.0:1230-1236
```

验证：

```bash
for p in 1230 1231 1232 1233 1234 1235 1236; do
  printf "%s -> " $p; curl -s -o /dev/null -w '%{http_code}\n' http://<HOST>:$p/
done
kubectl get pods -A | grep -v Running | head     # 关注非 Running  Pod
```

浏览器入口：`http://<HOST>:1234`（Kubernetes Goat 导航页）。

## 7. 常见坑位速记

| 现象 | 处理 |
|---|---|
| 所有 Pod `ContainerCreating` + failed to get sandbox image | 注入 `rancher/mirrored-pause:<ver>` |
| CoreDNS/-traefik `ImagePullBackOff` | 注入对应 rancher/mirrored-* 系统镜像 |
| `madhuakula/*` 拉不动 | `docker.1ms.run` + retag |
| Job Pod 一直拉取 | 改清单 imagePullPolicy 后重建 Job |
| 端口转发断连 | 重跑 `access-kubernetes-goat.sh`（建议 `ssh -f`/`setsid` 常驻） |

## 8. 清理

```bash
k3d cluster delete goat
```

## 9. 注意事项

- 仅部署在隔离的 k3d / kind 集群，禁止在有生产负载的共享集群里直接部署（见文首隔离建议）。
- ghcr.io 不可达时按 §2 用源码自建 k3d-tools，不要直连硬拉。
- Job 的 Pod 模板不可原地 patch，按 §5 删 Job 重建。
- 端口转发断连后重跑 access 脚本并常驻（§7）。
