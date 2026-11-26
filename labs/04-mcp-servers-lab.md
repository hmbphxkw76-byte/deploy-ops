# 04 · vulnerable-mcp-servers-lab（漏洞 MCP 服务器集）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· Node ≥ 18（建议 20+）、Python 3.10+ · **端口**：remote MCP 3100、wikipedia 8100

- **来源**：`vulnerable-mcp-servers-lab-main.zip`
- **形态**：9 个独立子项目（7 个 Node + 2 个 Python），多数为 stdio，2 个为 HTTP
- **依赖**：Node ≥ 18（建议 20+）、Python 3.10+

## 1. 安装依赖

```bash
cd "$LAB_ROOT/src/vulnerable-mcp-servers-lab-main"
for d in vulnerable-mcp-server-*; do
  [ -f "$d/package.json" ] && (cd "$d" && npm install --no-audit --no-fund)
done
```

npm 源：`npm config set registry https://registry.npmmirror.com`

Python 服务建议独立 venv（避免污染全局）：

```bash
python3 -m venv "$LAB_ROOT/venvs/mcplab"
"$LAB_ROOT/venvs/mcplab/bin/pip" config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
"$LAB_ROOT/venvs/mcplab/bin/pip" install "mcp[cli]>=1.0,<2.0" httpx uvicorn
```

## 2. 分类与运行

### stdio 型（默认，供 MCP 客户端拉起）

```bash
cd vulnerable-mcp-server-<name>
node index.js            # 或 python <server>.py
```

冒烟测试（stdin 关闭应快速退出）：

```bash
timeout 8 node index.js </dev/null; echo "rc=$?"
```

涉及：indirect-prompt-injection、malicious-code-exec、malicious-tools、
namespace-typosquatting、outdated-pacakges、secrets-pii。

### HTTP 型（常驻服务）

```bash
# remote MCP（端口可用 PORT 调整）
cd vulnerable-mcp-server-indirect-prompt-injection-remote-mcp
PORT=3100 node index.js
# 访问 http://<HOST>:3100/mcp （SSE；curl 会保持连接属正常）

# wikipedia HTTP MCP（代码内默认 8000，可复制副本改端口）
mkdir -p "$LAB_ROOT/run/wikipedia-mcp"
cp vulnerable-mcp-server-wikipedia-http-streamable/wikipedia-mcp.py "$LAB_ROOT/run/wikipedia-mcp/"
sed -i 's/port=8000/port=8100/' "$LAB_ROOT/run/wikipedia-mcp/wikipedia-mcp.py"
"$LAB_ROOT/venvs/mcplab/bin/python" "$LAB_ROOT/run/wikipedia-mcp/wikipedia-mcp.py"
# 访问 http://<HOST>:8100/mcp ，GET 返回 406 属正常（需 MCP 请求头）
```

## 3. 端口选择建议

| 服务 | 建议端口 | 说明 |
|---|---|---|
| remote MCP | 3100（原 3000） | 3000 常留给 Web 前端 |
| wikipedia MCP | 8100（原 8000） | 8000 常留给 API 服务 |

## 4. 常驻方式

```bash
ssh -f <host> 'cd <dir> && PORT=3100 exec node index.js'
# 或本地：setsid nohup env PORT=3100 node index.js >/var/log/mcp-remote.log 2>&1 </dev/null &
```

## 5. 验证清单

- `curl -o /dev/null -w '%{http_code}' http://<HOST>:3100/mcp` → 2xx（SSE 建连）
- `curl http://<HOST>:8100/mcp` → 406（缺头）即证明服务存活
- 每个 stdio 服务器 `timeout 8 ... </dev/null` 正常退出

## 6. 清理

```bash
rm -rf vulnerable-mcp-server-*/node_modules
```

## 7. 注意事项

- stdio 型仅供 MCP 客户端拉起，**不要对外暴露端口**；HTTP 型（remote / wikipedia）常驻时用 `ssh -f` 或 `setsid nohup` 落盘日志（§4）。
- 停止进程按端口精确取 PID；如必须用 pkill，采用 `pkill -f '[n]ode index.js'` 括号技巧，避免正则匹配到自身命令行。
- `npm install` 前确认 registry 已切 npmmirror（`npm config set registry https://registry.npmmirror.com`）。
- `node_modules` 为可再生目录，可直接删除。
