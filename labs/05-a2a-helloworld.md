# 05 · a2a-samples Helloworld（A2A 协议入门）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· Python 3.10+ · **端口**：9999（代码内 `--port`）

- **来源**：`a2a-samples-main.zip` → `samples/python/agents/helloworld`
- **形态**：单文件 Starlette/uvicorn 服务，固定端口 `9999`
- **作用**：验证 A2A SDK 与协议连通性（非 LLM Agent）

## 1. 安装

```bash
SRC="$LAB_ROOT/src/a2a-samples-main/samples/python/agents/helloworld"
python3 -m venv "$SRC/.venv"
"$SRC/.venv/bin/pip" config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
"$SRC/.venv/bin/pip" install -r "$SRC/requirements.txt"   # a2a-sdk、uvicorn 等
```

## 2. 允许局域网访问（运行副本）

源码默认绑定 `127.0.0.1`。复制运行副本并改地址，保持上游源码不变：

```bash
mkdir -p "$LAB_ROOT/run"
cp -a "$SRC" "$LAB_ROOT/run/a2a-helloworld"
sed -i "s/host='127.0.0.1'/host='0.0.0.0'/" "$LAB_ROOT/run/a2a-helloworld/__main__.py"
grep -n uvicorn.run "$LAB_ROOT/run/a2a-helloworld/__main__.py"   # 确认 host/port
```

## 3. 启动

```bash
cd "$LAB_ROOT/run/a2a-helloworld"
setsid nohup .venv/bin/python __main__.py >"$LAB_ROOT/logs/a2a-helloworld.log" 2>&1 </dev/null &
sleep 5
ss -ltnp | grep ':9999'
```

## 4. 验证

```bash
curl -s http://<HOST>:9999/.well-known/agent-card.json | head -c 200
cd "$LAB_ROOT/run/a2a-helloworld" && .venv/bin/python test_client.py
```

期望：Agent Card JSON 返回；test_client 收到 greeting。

## 5. 停止

```bash
PID=$(ss -ltnp | sed -n 's/.*:9999 .*pid=\([0-9]*\).*/\1/p'); [ -n "$PID" ] && kill "$PID"
```

## 6. 扩展

`a2a-samples` 内含大量 LLM Agent 示例（crewai、langgraph、github-agent 等）。
接入自有 LLM 时，优先找读取 `OPENAI_API_KEY/BASE_URL` 或 OpenRouter 变量的示例，
按其 README 配 `.env` 后同样以“运行副本”方式启动。

## 7. 注意事项

- 源码默认绑定 `127.0.0.1`；需按 §2 复制「运行副本」改 `0.0.0.0`，保持上游源码零改动。
- 绑定 `0.0.0.0` 后服务对局域网开放，仅限实验网段使用。
- 停止用 §5 的按端口取 PID，勿用 `pkill -f` 正则（易误伤自身会话）。
