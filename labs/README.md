# labs · 安全实验环境部署指南（组件化）

> 版本：v2.0 ｜ 更新：2026-11-26
> 特点：**与具体服务器 / IP 解耦**，所有步骤适用于任意 Ubuntu 主机（20.04 / 22.04 / 24.04）。
> 来源：2026-11-17-Labs 实验包在真实环境中的完整落地经验。
>
> 本目录是 deploy-ops 仓库的实验环境手册集：既可整体按编号成体系推进，也可**单篇独立使用**——每篇文档已内联所需公共步骤，本索引仅作导航。

## 1. 文档索引

| 文件 | 组件 | 说明 |
|---|---|---|
| [00-prerequisites.md](labs/00-prerequisites.md) | 通用前置 | Docker / 镜像源 / 目录规范 / 端口与带宽约定（**先读**） |
| [01-vulhub.md](labs/01-vulhub.md) | vulhub | 334 个 Web 漏洞场景（Docker Compose） |
| [02-dvmcp.md](labs/02-dvmcp.md) | damn-vulnerable-MCP-server | MCP 挑战平台（Docker） |
| [03-dvar-agentic-rag.md](labs/03-dvar-agentic-rag.md) | DVAR | Agentic RAG（含 LLM / 嵌入接入） |
| [04-mcp-servers-lab.md](labs/04-mcp-servers-lab.md) | vulnerable-mcp-servers-lab | 9 个漏洞 MCP 服务器（Node / Python） |
| [05-a2a-helloworld.md](labs/05-a2a-helloworld.md) | a2a-samples Helloworld | A2A 协议入门 Agent |
| [06-a2asecbench.md](labs/06-a2asecbench.md) | A2ASecBench | Agent 安全基准（离线 / 在线） |
| [07-kubernetes-goat.md](labs/07-kubernetes-goat.md) | kubernetes-goat | K8s 攻击场景集（独立 k3d 集群） |
| [08-ml-toolchain.md](labs/08-ml-toolchain.md) | vec2text / embedding-inversion | 机器学习演示工具链 |
| [99-troubleshooting.md](labs/99-troubleshooting.md) | 排障与运维 | 现象→原因→解法、清理、速查 |

## 2. 通用约定

- **工作根目录**：`LAB_ROOT=/opt/security-labs`（可按需修改，各手册以 `$LAB_ROOT` 指代）。
- **上游源码零改动**：定制一律发生在 `$LAB_ROOT/build/<组件>`（构建副本）或 `$LAB_ROOT/run/<组件>`（运行副本）。
- **凭据集中**：放各组件 `.env`，root 权限；文档只写变量名，不写明文。
- **端口即资源**：部署前用 `ss -ltnp` 检查冲突；被占用时改用备用端口并在本文「端口规划总表」登记。
- **后台任务**：远程执行长任务用 `ssh -f host 'cmd'` 或 `setsid nohup ... </dev/null >/dev/null 2>&1 &`，避免 SSH 挂死。

## 3. 端口规划总表（建议）

| 组件 | 默认端口 | 备注 |
|---|---|---|
| vulhub 场景 | 场景自定义（常见 8080 等） | 每场景独立 |
| DVAR 前端 / API | 3000 / 8000 | 另有 pg 5432、chroma 8200、redis 6379 |
| dvmcp Dashboard | 8081（冲突时 18081） | 挑战口 9001–9015 |
| MCP lab remote / wikipedia | 3000 / 8000（冲突时 3100 / 8100） | 均可用环境变量调整 |
| a2a Helloworld | 9999 | 代码内 `--port` |
| kubernetes-goat | 1230–1236（入口 1234） | 由 access 脚本固定 |

> 实验过程中如改用备用端口，请直接更新上表对应行（增设备注），保持索引与实际一致。

## 4. 来源映射（2026-11-17-Labs 压缩包 → 组件）

| zip | 组件文档 |
|---|---|
| vulhub-master.zip | [01](labs/01-vulhub.md) |
| GOAD-main.zip | **不适用**（需嵌套虚拟化承载 VM；无 KVM 环境请跳过） |
| kubernetes-goat-master.zip | [07](labs/07-kubernetes-goat.md) |
| DVAR-Damn-Vulnerable-Agentic-RAG-main.zip | [03](labs/03-dvar-agentic-rag.md) |
| damn-vulnerable-MCP-server-main.zip | [02](labs/02-dvmcp.md) |
| vulnerable-mcp-servers-lab-main.zip | [04](labs/04-mcp-servers-lab.md) |
| a2a-samples-main.zip | [05](labs/05-a2a-helloworld.md) |
| A2ASecBench-main.zip | [06](labs/06-a2asecbench.md) |
| vec2text-master.zip / embedding-inversion-demo-main.zip | [08](labs/08-ml-toolchain.md) |

## 5. 快速开始

```bash
# 0) 通用前置（所有组件共用）：阅读并执行 00-prerequisites.md
sudo mkdir -p /opt/security-labs && sudo chown "$USER" /opt/security-labs

# 1) 解压实验包到源码目录
cd /opt/security-labs/src && unzip -q /path/to/vulhub-master.zip

# 2) 按编号阅读并执行各组件文档
```

## 6. 维护

- 本目录手册遵循 deploy-ops 仓库统一约定：参数先确认、幂等执行、验证后汇报、破坏性操作逐项征求同意。
- 仓库门禁为根目录 `scripts/validate.sh`（Shell 语法 / 死链 / 孤儿文件 / 敏感信息 / 残留扫描）；新增或改名手册后请确保索引表同步更新，避免孤儿检测失败。
