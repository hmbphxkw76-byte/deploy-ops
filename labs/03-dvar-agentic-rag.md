# 03 · DVAR（Damn Vulnerable Agentic RAG）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· 依赖 Docker + Compose v2 · **默认端口**：前端 3000 / API 8000 / pg 5432 / chroma 8200 / redis 6379

- **来源**：`DVAR-Damn-Vulnerable-Agentic-RAG-main.zip`
- **形态**：Docker Compose 全栈（backend / frontend / postgres / chromadb / redis / internal-flag-service）
- **默认端口**：前端 `3000`、API `8000`、Postgres `5432`、Chroma `8200`、Redis `6379`

## 1. 构建副本并注入镜像源

```bash
LAB_ROOT=/opt/security-labs
mkdir -p "$LAB_ROOT/build"
cp -a "$LAB_ROOT/src/DVAR-Damn-Vulnerable-Agentic-RAG-main" "$LAB_ROOT/build/dvar"
```

构建期 `apt/pip/npm` 不继承宿主机加速，需在各 Dockerfile（backend/frontend/internal-flag-service）的
`FROM` 之后注入：

```dockerfile
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ENV PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn
ENV npm_config_registry=https://registry.npmmirror.com
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' \
        /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; true
```

复制环境文件：`cp .env.example .env`，然后按 §2 填写。

## 2. LLM 与嵌入配置（.env）

两种互斥方案，二选一：

```bash
# 方案 A：任意 OpenAI 兼容服务（推荐，密钥只填这里）
OPENAI_API_KEY=<your-key>
OPENAI_BASE_URL=https://<provider>/openai/v1     # 以服务商文档为准
OPENAI_MODEL_ID=<model-name>                     # 需支持 tool_calls

# 方案 B：AWS Bedrock（原默认）
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=qwen.qwen3-32b-v1:0
BEDROCK_EMBEDDING_MODEL_ID=amazon.titan-embed-text-v1

# 可选：独立的嵌入服务（OpenAI 风格 /embeddings 接口）
EMBEDDING_API_URL=https://<provider>/v1/embeddings
EMBEDDING_API_KEY=
EMBEDDING_MODEL=<embedding-model>
```

> 注意：部分服务商的嵌入路径是复数 `/v1/embeddings`；部署前用 `curl` 先验证一次。

## 3. 代码适配（仅当使用非 Bedrock 方案时）

在构建副本中修改三处（不动 `$LAB_ROOT/src` 上游源码）：

| 文件 | 改动要点 |
|---|---|
| `backend/app/config.py` | 新增字段 `openai_api_key/openai_base_url/openai_model_id/embedding_api_url/embedding_api_key/embedding_model`（pydantic-settings 自动读同名大写环境变量） |
| `backend/app/services/llm_service.py` | 有 `OPENAI_API_KEY` 时走 httpx 直连 `<base_url>/chat/completions`；把系统提示、历史消息（Bedrock `[{"text":...}]` 结构）转换为 OpenAI 消息格式；`tool_calls` 往返转换后调用原有 `TOOL_HANDLERS`，无 Key 时保留原 Bedrock 分支 |
| `backend/app/services/rag_service.py` | `get_embedding()` 优先 POST `EMBEDDING_API_URL`（JSON `{"model":..., "input":[text]}`，取 `data[0].embedding`），失败回退 Bedrock Titan |

要点：工具定义是 Bedrock `toolSpec` 结构，需转成 OpenAI `{"type":"function","function":{name,description,parameters}}`；
`parameters` 直接取 `toolSpec.inputSchema.json`。

## 4. 启动

```bash
cd "$LAB_ROOT/build/dvar"
docker compose up -d --build
docker compose ps
```

> 更换嵌入模型维度后必须清库重建，否则 Chroma 报维度不匹配：
> `docker compose down -v && docker compose up -d --build`

## 5. 验证

```bash
curl -s http://<HOST>:8000/api/v1/health                       # 200
curl -s "http://<HOST>:8000/api/v1/documents/search?q=policy"  # 命中已灌入文档
curl -s http://<HOST>:8000/api/v1/chat -H 'Content-Type: application/json' \
     -d '{"message":"What is the remote work policy?","session_id":"demo"}'
curl -s -o /dev/null -w '%{http_code}\n' http://<HOST>:3000/    # 前端 200
```

## 6. 访问与使用

浏览器打开 `http://<HOST>:3000`（AskPJ 对话界面）；API 文档 `http://<HOST>:8000/docs`。
挑战目标是让 Agent 泄露 flag / 越权调用工具，属于预期会“被攻破”的靶场。

## 7. 停止 / 清理

```bash
docker compose down      # 保留数据
docker compose down -v   # 清空 pg/chroma/redis 卷
```

## 8. 注意事项

- `.env` 中 LLM / 嵌入凭据只填在服务器本地，保持占位符、不写入仓库；部分服务商嵌入路径为复数 `/v1/embeddings`，部署前先 `curl` 验证一次。
- 更换嵌入模型维度后必须 `down -v` 清库重建，否则 Chroma 报维度不匹配（§4）。
- `docker compose down -v` 会清空 pg / chroma / redis 卷，破坏性操作执行前先确认。
- 该靶场预期会被攻破（泄露 flag / 越权调用工具），仅在隔离实验环境运行。
