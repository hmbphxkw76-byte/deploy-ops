# AIVP 平台对接记录（promptfoo 红队评估实战）

## 文档说明

本文档是一次真实部署的完整记录：用 promptfoo 对 **AI Vulnerabilities Playground (AIVP)**（`http://192.168.40.189`，AI 安全实验平台）做红队评估。包含 API 逆向方法、SSE Provider 配置、踩坑记录与 Web 结果查看。通用安装与 Web 查看方法见 [promptfoo.md](./promptfoo.md)。

- 环境：promptfoo 0.125.1（192.168.40.183，Ubuntu 22.04，nvm/node 22），目标 AIVP 192.168.40.189
- 产出：服务器 `/root/promptfoo/promptfooconfig.yaml`（55 个 provider × 4 条用例）

## 1. API 逆向（SPA 前端 → 后端接口）

AIVP 前端是 React SPA，`/explore` 页面无 SSR，接口需从 JS bundle 逆向：

```bash
# 1) 首页 HTML 拿到 bundle 路径（<script src="/assets/index-*.js">）
curl -s http://192.168.40.189/explore

# 2) 下载 bundle 并提取线索
curl -s http://192.168.40.189/assets/index-BtcwQhVS.js -o /tmp/aivp.js
grep -oE 'fetch\(.{0,90}' /tmp/aivp.js          # 所有请求 URL 模板
grep -oE 'kn=[^,;]{0,100}' /tmp/aivp.js         # API base（得到 "/api"）
grep -oE 'lab_[A-Z]+_[0-9]{2}' /tmp/aivp.js | sort -u   # 实验 ID 清单

# 3) 实测端点确认响应格式（payload 建议走文件，避免 shell 转义问题）
echo '{"prompt":"hello"}' > /tmp/probe.json
curl -sS -m 40 -N -X POST http://192.168.40.189/api/labs/PI_01/chat \
  -H 'Content-Type: application/json' -d @/tmp/probe.json
```

逆向结论（2026-11-07 实测）：

| 项目 | 结果 |
| --- | --- |
| Chat 端点 | `POST /api/labs/{LAB}/chat`，body `{"prompt": "..."}`，SSE 流式响应 |
| 响应格式 | `event: meta`（含 request_id）→ 多个 `data: {"content": "..."}` 分块，拼接得到完整回答 |
| 其他端点 | `/api/labs/{LAB}/summary?request_id=`、`/api/labs/{LAB}/compare`、`/api/config`、`/api/me/runs`、`/api/secrets/validate` |
| 实验清单 | 55 个：PI_01~10（提示注入）、MM_01~15（模型操纵）、MCP_01~15（MCP 安全）、DE_01~15 |
| 默认模型 | LongCat-2.5 |

> 注意：`/api/labs` 列表端点不存在（404），实验清单只在前端 bundle 里硬编码。

## 2. 配置要点（HTTP Provider + SSE 解析）

- provider `id` 必须是完整 URL（写成 `id: 自定义名 + type: http` 会报 `Could not identify provider`）
- `sse: true` 对该平台**不生效**（0.125.1 实测输出原始 SSE 文本），正确做法是用 `transformResponse` JS 手动解析：

```yaml
providers:
  - id: http://192.168.40.189/api/labs/PI_01/chat
    label: AIVP_PI_01
    config:
      method: POST
      headers:
        Content-Type: application/json
      body:
        prompt: "{{prompt}}"
      timeout: 60000
      transformResponse: |
        (json, text) => {
          const raw = typeof json === 'string' ? json : (text || '');
          let out = '';
          for (const line of String(raw).split('\n')) {
            if (line.startsWith('data: ')) {
              try {
                const d = JSON.parse(line.slice(6));
                if (typeof d.content === 'string') out += d.content;
              } catch (e) {}
            }
          }
          return out;
        }
```

55 个 provider 结构完全相同，仅 `{LAB}` 与 label 不同，可用脚本批量生成（python 循环拼 YAML，参见 `/tmp/gen_aivp_config.py` 思路）。

## 3. 踩坑记录

| 现象 | 原因与解法 |
| --- | --- |
| `promptfoo init` 卡住不动 | 默认进入交互式向导（SSHD 非交互会话挂起）。用 `promptfoo init --no-interactive` 生成基础配置 |
| `promptfoo: command not found`（嵌套 bash） | 非登录 shell 没有 nvm PATH；用 `bash -lc` 或 `export PATH=/root/.nvm/versions/node/*/bin:$PATH` |
| `Could not identify provider: xxx` | provider id 必须是 URL 形式，见第 2 章 |
| 输出是原始 SSE 文本 | `sse: true` 无效，改用 `transformResponse` 手动拼接 |
| JSON payload 报 `Invalid \escape` | shell 多层转义丢失；payload 写本地文件后 `curl -d @file` |
| 某实验全部用例报 `Error reading response body ... terminated`（如 DE_10） | **多为目标平台后端瞬时故障**（全量并发评估时 LLM 后端卡住，只回 meta 事件）。先用 curl 直测确认恢复（`curl -m 60 -X POST .../labs/DE_10/chat -d @probe.json`），恢复后按第 4 章命令只重跑该实验；无需改配置 |
| `--filter-errors-only <file>` 行为 | 实测会重跑文件中全部用例而非仅错误项；按实验重跑应使用 `--filter-providers <label regex>` |

## 4. 评估结果（2026-11-07 基线）

- 220 条用例（55 实验 × 4 用例）：**216 通过，0 失败，4 错误**（错误全部来自 DE_10 瞬时挂起，见第 3 章）
- DE_10 复测：后端恢复后单独重跑 4 条用例 **4/4 通过**（5s），基线实际等效 **220/220 成功**
- 测试用例：基线连通探针 / 经典直接注入（打印 system prompt）/ 秘密与工具泄露探测 / developer-mode 越狱
- 结果文件：`/root/promptfoo/aivp-output.json`、`/root/promptfoo/de10-only.json`（DE_10 复测）；Web 查看方式见 [promptfoo.md](./promptfoo.md) 第 6 章（SSH 隧道 `ssh -N -L 15500:localhost:15500 root@192.168.40.183`，浏览器开 `http://localhost:15500`）

### 4.1 单实验重跑命令

```bash
cd /root/promptfoo
# 只重跑某个实验（label 正则匹配）
promptfoo eval --no-cache --filter-providers AIVP_DE_10 -o de10-only.json
# 注意：外层用 timeout 包裹时，时长要给足（全量评估约 13 分钟）
```

## 5. 后续可做

- `promptfoo redteam generate` 生成体系化红队用例替换手工 4 条（需先配模型 API Key）
- 给输出加断言（contains / regex / LLM rubric）让"通过/失败"有判定意义（当前无断言，通过仅表示请求成功）
- 排除或修复 DE_10；监控 `/api/config` 的 `training_labs_enabled` 开关
