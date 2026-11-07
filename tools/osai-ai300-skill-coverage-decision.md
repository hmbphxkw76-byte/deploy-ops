## 1. 靶机总表

### 1.1 官方 / 成熟团队靶机总表（按 OSAI 场景覆盖排序）

| 靶机 | 出品方 | 覆盖的 OSAI 场景 | GitHub repo | 许可 | 资质 |
|---|---|---|---|:---:|:---:|
| **OWASP AI Vulnerabilities Playground (AIVP)** | OWASP Incubator | **最全**：4 阶段 50+ 场景（提示注入、agent 利用、模型操纵、MCP 信任边界 MCP_03/06/08/11、PI_01 提示提取）；本地 Docker + Ollama | `OWASP/AI-Vulnerabilities-Playground` | MIT | ◎ |
| OWASP GenAI Red Team Lab | OWASP GenAI Security Project | sandbox + exploit 代码 + 教程（Promptfoo 利用链）；Podman 隔离 | `GenAI-Security-Project/GenAI-Red-Team-Lab`（作者源 `felipepenha/GenAI-Red-Team-Lab`） | Apache-2.0 | ◎ |
| Microsoft AI Red Teaming Playground Labs | Microsoft（Black Hat USA 2024 起源） | 12 级渐进挑战：元提示提取、Crescendo、间接注入、凭据窃取、SSRF；含 Docker/K8s 基础设施 | `microsoft/AI-Red-Teaming-Playground-Labs` | MIT | ◎ |
| OWASP FinBot CTF | OWASP Agentic Security Initiative | **agentic 专项**：真实金融 agent 平台、授权/审批绕过、工具滥用、计分 | `GenAI-Security-Project/finbot-ctf` | OWASP 对齐 | ◎ |
| ControlArena | UK AI Security Institute + Redwood Research | **agent 控制/破坏**：red team 隐蔽副任务 vs blue team 监控协议，基于 Inspect AI | `UKGovernmentBEIS/control-arena` | MIT | ◎ |
| AI Vulnerable Agent 类 CTF 合集（DEF CON） | AI Village | CTFd 驱动的 LLM prompt attack 关卡（`llm_verification`） | `aivillage/llm_verification` | 无 LICENSE 文件 | ◎ |
| AIRTBench-Code | Dreadnode | 自主 AI 红队能力基准（arXiv 2506.14682） | `dreadnode/AIRTBench-Code` | Apache-2.0 | ◐ |
| Damn Vulnerable LLM Agent | Reversec Labs（原 WithSecure Labs） | **agent 专项**：LangChain ReAct、Thought/Action/Observation 注入；本地 Ollama 免云 API | `ReversecLabs/damn-vulnerable-llm-agent` | Apache-2.0 | ◐ |
| DVLAA | 社区（中文） | LLM + Agent 综合：Docker 沙箱、随机 flag、防御/绕过对照 | `Tcotl/DVLAA` | 无 LICENSE 文件 | ○ |
| MyLLMAuto | Arcanum-Sec | 多链 / 跨链 prompt injection，5 flag | `Arcanum-Sec/MyLLMAuto` | 无 LICENSE 文件 | ◐ |
| vulnerable-mcp-servers-lab | Appsecco | **MCP 专项**：路径遍历、无沙箱 RCE、间接提示注入、密钥泄露、供应链 | `appsecco/vulnerable-mcp-servers-lab` | MIT | ◐ |
| MCP Attack Labs | 社区 | MCP/agentic 本地可复现，攻击 + 防御成对，映射 OWASP Agentic Top 10 | `aminrj-labs/mcp-attack-labs` | 自定义 LICENSE（NOASSERTION） | ○ |
| ASB (Agent Security Bench) | 浙江大学 + Rutgers（ICLR 2025 官方代码） | agent 攻防基准：10 场景、直接/间接注入、记忆投毒，84.30% ASR；**主要单智能体** | `agiresearch/ASB` | MIT | ◎ |
| A2ASecBench | SaFo-Lab（ICLR 2026 官方代码） | **A2A / multi-agent 协议感知攻击**：六类攻击、三领域 ASR、可插拔 SUT、本地可执行 | `SaFo-Lab/A2ASecBench` | MIT | ◎ |
| swarm-test | 社区 | multi-agent 可靠性混沌测试（静态、无 LLM 调用）——**非攻击工具** | `surajkumar811/swarm-test` | MIT | ○ |

### 1.2 官方验证靶场补充（不进主表，仅用于考前训练）

| 资产 | 用途 | GitHub 来源 |
|---|---|---|
| `AI-Red-Teaming-Playground-Labs` | Black Hat USA 2024 起源，12 级渐进挑战 + Docker/K8s 基础设施 | `microsoft/AI-Red-Teaming-Playground-Labs` |
| `GenAI-Red-Team-Lab` | OWASP sandbox + exploit 代码 + 教程（含 Semantic Kernel CVE 路径穿越） | `GenAI-Security-Project/GenAI-Red-Team-Lab` |
| `GenAI-LLM-Top10` / `aibom-generator` / `Insecure Agent Samples` | OWASP 风险标准、AI BOM、不安全 agent 样例（LangGraph / AutoGPT / CrewAI） | `genai-security-project`（组织）/ `genai.owasp.org/resource/insecure-agent-samples/` |
| `adversarial-robustness-toolbox` | IBM Research 官方攻击库（evasion / poisoning / extraction / inference），MIT | `Trusted-AI/adversarial-robustness-toolbox` |
| `PurpleLlama` / `garak` / `aws-security-cards` | Meta CyberSecEval、NVIDIA 探针库、SageMaker 攻击卡片 | `meta-llama/PurpleLlama`、`NVIDIA/garak`、`TocConsulting/aws-security-cards` |
| `awesome-security-skills` / `Claude-Red` | 技能索引（**无 LICENSE 文件**）；78 个红队 SKILL.md（MIT，云深度不足） | `securityfortech/awesome-security-skills`、`SnailSploit/Claude-Red` |

### 1.3 靶机 × OSAI 场景覆盖矩阵（定性）

场景缩写：**LLM**=Attacking LLMs｜**Agt**=AI agents｜**MA**=multi-agent/A2A｜**RAG**=RAG 管线｜**Emb**=Embeddings/向量库｜**MCP**=MCP/tool surfaces｜**SC**=AI/ML 供应链｜**Infra**=AI 基础设施/编排框架｜**Cloud**=AI 云安全｜**Rep**=报告/证据。●=直接覆盖，◐=部分，—=不覆盖。

| 靶机 | LLM | Agt | MA | RAG | Emb | MCP | SC | Infra | Cloud | Rep |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **OWASP AIVP** | ● | ● | ◐ | ● | ◐ | ● | ◐ | ◐ | ◐ | ◐ |
| OWASP GenAI Red Team Lab | ● | ● | ◐ | ● | ◐ | ● | ● | ◐ | — | ● |
| Microsoft AIRT Playground | ● | ◐ | — | ◐ | — | ◐ | ◐ | ● | ◐ | ◐ |
| OWASP FinBot CTF | ● | ● | ● | ◐ | — | ● | ◐ | ◐ | — | ◐ |
| ControlArena (UK AISI) | ◐ | ● | ● | ◐ | — | ● | ◐ | ● | ◐ | ● |
| ASB / A2ASecBench | ◐ | ● | ● | ◐ | — | ● | ◐ | — | — | ● |
| DVLA / DVLAA / MyLLMAuto | ● | ● | ◐ | ◐ | — | ● | — | ◐ | — | ◐ |
| vulnerable-mcp-servers-lab / MCP Attack Labs | ◐ | ● | ◐ | ◐ | — | ● | ● | ● | — | ◐ |
| PoisonedRAG / AgentPoison / rag-redteam | ◐ | ● | — | ● | ● | — | ● | — | — | ◐ |
| TryHackMe AI System Recon（非 GitHub） | ◐ | — | — | — | — | — | ◐ | ● | ● | ◐ |
| Dreadnode Crucible / Lakera Agent Breaker（非 GitHub） | ● | ● | ◐ | ● | — | ◐ | — | — | — | ◐ |

**结论**：单一覆盖最广是 **OWASP AIVP**（50+ 场景 / 4 阶段，几乎触及全部 8 面），且是本 harness 已验证 skill 的现成靶场——`agentic-tool-abuse` → `aivp-mcp (local Docker AIVP lab, Phase 4 MCP_03/06/08/11, llama3.2 via Ollama)`，`prompt-extraction` → `aivp-lan (192.168.40.189 AIVP lab, PI_01)`。基础设施/云侦察由 AIRT Labs + TryHackMe 补，A2A/multi-agent 由 A2ASecBench + ControlArena + FinBot 补，MCP 由 Appsecco lab 补，RAG/向量库由 PoisonedRAG/AgentPoison 补。

### 1.4 Agent / Multi-Agent 专项靶机

| 层级 | 靶机 / 框架 | 关键能力 | GitHub repo | 资质 |
|---|---|---|---|:---:|
| 单 agent 入门 | Damn Vulnerable LLM Agent | LangChain ReAct；Thought/Action/Observation 注入；2 flag（越权查他人交易）；本地 Ollama | `ReversecLabs/damn-vulnerable-llm-agent` | ◐ |
| 单 agent 综合 | DVLAA | LLM + Agent 全栈，Docker 沙箱，随机 flag，源码含防御逻辑便于理解绕过点 | `Tcotl/DVLAA` | ○ |
| 单 agent 利用升级 | Vulnerable AI Agent Lab | 本地 Ollama（llama3.1 / qwen2.5），提示注入升级为 **RCE / LFI / SSRF**，PWNED 矩阵，映射 OWASP LLM Top 10 | repo 待核（2026-11-07 复查仍未确认官方仓库，仅二手介绍） | ○ |
| 多链 / 跨链 | MyLLMAuto | 多链 LLM 应用，5 flag **cross-chain prompt injection**，Docker Compose | `Arcanum-Sec/MyLLMAuto` | ◐ |
| agentic 平台实战 | OWASP FinBot CTF | 真实 agent 平台、审批绕过、工具滥用、guardrail 挑战、计分引擎 | `GenAI-Security-Project/finbot-ctf` | ◎ |
| agent 攻防基准 | ASB | 10 场景、直接/间接注入、记忆投毒，84.30% ASR（主要单 agent） | `agiresearch/ASB` | ◎ |
| agent 控制 / 隐蔽破坏 | ControlArena | red team 隐蔽副任务 vs blue team 监控协议；Inspect AI 构建 | `UKGovernmentBEIS/control-arena` | ◎ |
| **A2A 多智能体基准** | **A2ASecBench** | **协议感知攻击**（ICLR 2026）：六类 A2A 攻击、三领域 ASR、可插拔 SUT、本地可执行 | `SaFo-Lab/A2ASecBench` | ◎ |
| agent 工作流扫描 | agentic-radar | 静态扫描 + 运行时对抗测试（LangGraph / CrewAI / N8N / OpenAI Agents / AutoGen），OWASP 映射 + CI/CD | `splx-ai/agentic-radar` | ◐ |
| 多智能体可靠性 | swarm-test | CrewAI / LangGraph / AutoGen 可靠性静态测试（**非攻击**，理解级联失效） | `surajkumar811/swarm-test` | ○ |
| agent 混沌测试 | Khaos | 6 个不安全示例 agent + `discover/run/ci` CLI + 安全/韧性 eval packs | `ExordexLabs/khaos-sdk`、`ExordexLabs/khaos-examples` | ○（**BSL 1.1，非 OSI 开源，仅 source-available**） |
| 综合实验台 | VEP (dros-vep-lite) | 热插拔 LangGraph/AutoGen/CrewAI + 模型 + 对抗向量（RFC-010、MITRE ATLAS 脚本） | `top-celestial-company-ltd/dros-vep-lite` | ○ |

补充知识源：promptfoo **LM Security DB**（https://www.promptfoo.dev/lm-security-db/ ，2026-11-07 核实**无公开 GitHub 仓库**）的 **Cascading Agent False Consensus**（LLM-MAS 级联错误放大 / 共识腐化）是 multi-agent 特有攻击模式，可作 `rt9-multi-agent` 用例补充。

### 1.5 非 GitHub 托管的官方 / 商业靶场（补充，不计入选型主表）

| 平台 | 覆盖 | 入口 |
|---|---|---|
| OffSec AI-300 官方 Labs / Challenge Labs + Capstone | **最贴近考试**；部分实验在真实 Azure 上（需订阅与管理员权限，注意计费与资源组清理） | `offsec.com/courses/ai-300/` |
| Lakera Gandalf + **Agent Breaker** | 8 级提示注入；Agent Breaker 提供 **10 个仿生产 agentic 应用**（RAG 管线、tool-using agents） | `gandalf.lakera.ai` |
| TryHackMe **AI System Reconnaissance** room | MLflow GraphQL 未认证枚举、Jupyter、Prometheus、部署拓扑与元数据提取（AML.T0069 / T1046）；**基础设施侦察最贴考纲** | `tryhackme.com/room/aisystemreconnaissance` |
| PortSwigger Web Security Academy: Web LLM attacks | LLM 与 Web/API 交叉面、过度代理、输出处理 | `portswigger.net/web-security/llm-attacks` |
| Dreadnode Crucible | 持续性 AI 安全挑战赛 | `crucible.dreadnode.io` |
| HackAPrompt / PromptTrace / Prompt Airlines | 提示注入 CTF；PromptTrace 含 RAG 投毒与工具调用劫持关卡 | `hackaprompt.com`、`prompttrace.airedlab.com` |
| AI Village CTF (DEF CON) / HackTheBox AI Challenges | 综合 AI 安全 CTF | `aivillage.org`、`hackthebox.com` |
| OWASP Insecure Agent Samples (ASI) | 故意不安全的 LangGraph / AutoGen / CrewAI agent 样例 | `genai.owasp.org/resource/insecure-agent-samples/` |

### 1.6 靶机选用优先级（按 OSAI 24h 收益排序）

> 本节 `P0/P1/P2` 指**靶机投入顺序**，与原第 3 节主决策表「最该补」列的 `P0–P3`（**skill 补齐顺序**）是两套独立优先级，不可混用。

- **P0**：**OWASP AIVP** 为主靶场——覆盖 8 面最广、MIT、本地 Docker + Ollama 无云依赖，且 `agentic-tool-abuse` / `prompt-extraction` 已在其上验证过，新移植 skill 的 `validated_against` 统一指向 AIVP 场景编号（MCP_03/06/08/11、PI_01…）；用 **MS AIRT Playground Labs + TryHackMe AI System Recon** 补基础设施/云侦察（原主表第 8 面 E/F 最弱）。
- **P1**：**A2ASecBench + ControlArena + FinBot CTF** 补 multi-agent / A2A（协议层 / 控制层 / 平台层）；**Appsecco vulnerable-mcp-servers-lab + mcp-attack-labs** 补 MCP（配 `mcp-scan` 前后对照）；**PoisonedRAG + AgentPoison + rag-redteam** 补 RAG/向量库。
- **P2**：`damn-vulnerable-llm-agent` / `DVLAA` / `MyLLMAuto` 做 agent 单点到跨链手工链攻训练；OffSec 官方 Labs / Capstone 留考前冲刺（最贴考试形态，但耗 Azure 额度且不可复现）。
- **约束**：靶机均为**考前本地训练与验证**用途；24h 监考 VPN 内不部署靶机、不装重依赖，只把验证产出的 `validated_against` / `last_validated` / 原始证据路径写回 skill 契约。

---

## 2. 专项攻击工具（A2A / MCP / RAG）

### 2.1 A2A 协议专业攻击工具

| 工具 | 定位 | GitHub repo | 资质 / 许可 |
|---|---|---|:---:|
| **A2ASecBench** | ICLR 2026 官方代码，协议感知安全基准；冻结用例 + 可插拔 SUT + 本地可执行环境，六类攻击与三领域 ASR | `SaFo-Lab/A2ASecBench` | ◎ / MIT |
| **a2a-scanner** | Cisco AI Defense 官方；YARA（模式）/ Spec（协议合规）/ Heuristic（逻辑）/ Endpoint（活体端点）四分析器，可喂入恶意 **Agent Card** 样本 | `cisco-ai-defense/a2a-scanner` | ◎ / Apache-2.0 |
| **AgentHound** | "BloodHound for the agentic stack"：agentic 基础设施攻击面 recon、凭据掠夺、模型外带、投毒、**攻击路径分析**，横跨 MCP / **A2A** / gateway / AI 服务 | `adithyan-ak/AgentHound` | ○ / Apache-2.0 |
| a2a_attack | 针对 Google A2A ADK 的 `attacks` / `defenses` / `demos` / `reports` / `scripts` 完整实验目录（2025-11） | `Farayabaig/a2a_attack` | ○ / 无 LICENSE 文件 |
| A2A 协议本体 / 样例 | Google 发起、**已捐赠 Linux Foundation**；协议规范 + `a2a-python` SDK + 官方 samples（含 `hosts/multiagent` 编排样例）——作**靶标与协议参照**，非攻击工具。samples 仓已迁移至 `a2aproject/a2a-samples`（原 `google-a2a/a2a-samples`） | `a2aproject/A2A`、`a2aproject/a2a-python`、`a2aproject/a2a-samples` | ◎ / Apache-2.0 |

公开 A2A 攻击面锚点（**二手安全研究，编号与细节需核实**）：Agent Card 抢注/仿冒、`jku` 验签信任注入、有状态会话指令走私、执行中任务恶意回调注册（结果外带 + SSRF）、推送通知 SSRF（CVE-2026-90790，`a2a-python` ≤1.1.3）、IBM ContextForge A2A 端点 DNS rebinding SSRF（CVE-2026-77822）、`python-a2a` ≤0.5.5 路径穿越（CVE-2025-6167）——对应原 2.2 节考纲的 impersonation / relay / replay 与 schema / serialization 缺陷。

### 2.2 MCP 专业攻击工具与靶机

| 工具 | 定位 | GitHub repo | 资质 / 许可 |
|---|---|---|:---:|
| **mcp-scan** | Tool Poisoning **原始披露方** Invariant Labs（已并入 Snyk）；静态 + 运行时扫描：rug pull / cross-server shadowing / 提示注入，含 WhatsApp 外泄实战链 | `invariantlabs-ai/mcp-scan`（现址 `snyk/agent-scan`） | ◐ / **Apache-2.0** |
| **vulnerable-mcp-servers-lab** | 故意脆弱 MCP server 集合：路径遍历、无沙箱 RCE、间接提示注入、密钥暴露、供应链，独立 README + 复现步骤 | `appsecco/vulnerable-mcp-servers-lab` | ◐ / **MIT** |
| **mcp-attack-labs** | 本地可复现 MCP/agentic 攻击 lab，攻击 + 防御成对，映射 OWASP Agentic Top 10 | `aminrj-labs/mcp-attack-labs` | ○ / 自定义 LICENSE（NOASSERTION） |
| **agentic-radar** | agent 工作流静态扫描 + 可视化 + OWASP 映射 + 运行时对抗测试，CI/CD 集成 | `splx-ai/agentic-radar` | ◐ / **Apache-2.0** |
| Snyk Agent Scan | 自动扫描 agent 组件（MCP server / harness / skills）15+ 风险；**需 Snyk API token**；即原 mcp-scan 的 Snyk 版 | `snyk/agent-scan`（2026-11-07 确认） | ◐ / **Apache-2.0** |
| Cisco mcp-scanner / skill-scanner | Cisco AI Defense 系列的 MCP 与 Skill 扫描器 | `cisco-ai-defense/mcp-scanner`、`cisco-ai-defense/skill-scanner` | ◎ / Apache-2.0、自定义 LICENSE（NOASSERTION） |
| NVIDIA SkillSpector | Claude Code / Codex / Gemini CLI 的 Agent Skill 扫描器：AST/YARA/污点 + LLM 语义复核，输出 SARIF/JSON/MD | `NVIDIA/SkillSpector`（2026-11-07 确认） | ◎ / **Apache-2.0** |
| AI-Infra-Guard | 腾讯朱雀实验室全栈 AI 红队平台：Agent / Skill / MCP / AI 基础设施扫描 + LLM 越狱评估 | `Tencent/AI-Infra-Guard`（2026-11-07 确认） | ◎ / **Apache-2.0** |
| MCP 官方 SDK / Inspector | 工具枚举、程序化调用、协议级 recon（**靶标与侦察基座**，非攻击工具） | `modelcontextprotocol/python-sdk`、`modelcontextprotocol/inspector` | ◎ / MIT、自定义 LICENSE（NOASSERTION） |
| MCP 标准 / workshop | OWASP MCP Top 10（MCP03 Tool Poisoning）；MCP 安全 workshop（含 Invariant 披露索引） | `owasp.org/www-project-mcp-top-10`、`SamMorrowDrums/mcp-security-workshop` | ◎ / ○ |
| 工具索引 | 2026 MCP/agent 扫描器全景清单 | `scadastrangelove/awesome-ai-security-tools`、`8kSec/awesome-ai-security` | ○ |

### 2.3 RAG / 向量库专业攻击工具

| 工具 | 定位 | GitHub repo | 资质 / 许可 |
|---|---|---|:---:|
| **PoisonedRAG** | USENIX Security 2025 官方代码，首个知识库污染攻击；5 篇投毒文档 97% 劫持率 / GPT-4 上 90%+ ASR | `sleeepeer/PoisonedRAG` | ◎ / **MIT** |
| **AgentPoison** | NeurIPS 2024 官方实现（PyTorch），**agent 记忆 / RAG 知识库后门投毒**（ReAct / EHRAgent），桥接 RAG 与 agent 两面 | `AI-secure/AgentPoison` | ◎ / **MIT** |
| **rag-redteam** | CI 内 RAG 红队：间接提示注入 + 源文档泄露，检索文档本身即攻击面 | `Srivatsa03/rag-redteam` | ○ / **Apache-2.0** |
| promptfoo / garak | promptfoo：RAG/agent 攻击插件 + `redteam.yaml` 固定用例；garak：50+ 探针含 RAG/泄露类 | `promptfoo/promptfoo`、`NVIDIA/garak` | ◎ / MIT、**Apache-2.0** |
| vec2text | embedding inversion，从向量反演原文（OWASP LLM08 核心实证） | `vec2text/vec2text` | ◎ / 自定义 LICENSE（NOASSERTION） |
| RAG 测试 SKILL.md | `testing-prompt-injection-in-rag-pipelines`（RoE、非生产环境约束、向量库枚举与指纹识别） | `peteedoo` 技能库 / `adriannoes/awesome-agentic-ai`（镜像，MIT，2026-11-07 实测） | ○ / 待核（原库） |
| 论文级攻击（**无已确认 repo**） | ConfusedPilot（M365 Copilot confused deputy）、HijackRAG、BadRAG（0.04% 语料投毒）、InceptionRAG（多跳逻辑陷阱）、One Shot Dominance | 待核 | ◎ 学术 |

公开 RAG 漏洞锚点（**二手来源，需核实**）：EchoLeak CVE-2025-32711（M365 Copilot 零点击提示注入，CVSS 9.3）、Open WebUI 知识库越权写入 CVE-2026-28788 / CVE-2026-44554（只读用户可覆盖他人语料）——对应原主表第 4/5 面的「跨租户隔离」缺口。

---

## 3. GitHub 来源索引

> 合并自原选型来源与 2026-11-05 靶机 / 专项工具补编，已去重；许可列均为 2026-11-07 经 GitHub API 实测核验的结果。

### 3.1 选型与靶机 / 专项工具来源

**◎ 官方 / 机构级**

| 项目 | 完整 URL | 许可 |
|---|---|---|
| Microsoft PyRIT | https://github.com/microsoft/PyRIT | MIT |
| Microsoft AI Red Teaming Playground Labs | https://github.com/microsoft/AI-Red-Teaming-Playground-Labs | MIT（2026-11-07 实测） |
| NVIDIA garak | https://github.com/NVIDIA/garak | Apache-2.0（2026-11-07 实测） |
| promptfoo | https://github.com/promptfoo/promptfoo | MIT |
| Meta PurpleLlama / CyberSecEval | https://github.com/meta-llama/PurpleLlama | Meta 自定义许可 |
| IBM ART | https://github.com/Trusted-AI/adversarial-robustness-toolbox | MIT |
| ETH Zurich SPY Lab AgentDojo | https://github.com/ethz-spylab/agentdojo | MIT |
| UK AISI Inspect AI | https://github.com/UKGovernmentBEIS/inspect_ai ※ | MIT |
| OWASP GenAI Security Project（组织） | https://github.com/genai-security-project | 各仓单独 |
| OWASP FinBot CTF | https://github.com/GenAI-Security-Project/finbot-ctf | OWASP 对齐许可 |
| OWASP GenAI Red Team Lab | https://github.com/GenAI-Security-Project/GenAI-Red-Team-Lab | Apache-2.0（2026-11-07 实测） |
| OWASP MCP Top 10 | https://owasp.org/www-project-mcp-top-10/ | OWASP |
| OWASP AI Testing Guide (AITG) | https://github.com/OWASP/www-project-ai-testing-guide | 自定义 LICENSE（NOASSERTION，须读 LICENSE 原文） |
| MITRE ATLAS 数据 | https://github.com/mitre-atlas/atlas-data | 自定义 LICENSE（NOASSERTION） |
| MITRE ATLAS 站点 | https://atlas.mitre.org/ | — |
| Protect AI ModelScan | https://github.com/protectai/modelscan | Apache-2.0（2026-11-07 实测） |
| Invariant Labs mcp-scan（Invariant 已并入 Snyk） | https://github.com/invariantlabs-ai/mcp-scan → https://github.com/snyk/agent-scan | Apache-2.0 |
| MCP Python SDK / Inspector | https://github.com/modelcontextprotocol/python-sdk ｜ https://github.com/modelcontextprotocol/inspector | MIT / 自定义 LICENSE（NOASSERTION） |
| USENIX Sec'25 PoisonedRAG | https://github.com/sleeepeer/PoisonedRAG | MIT（2026-11-07 实测） |
| vec2text | https://github.com/vec2text/vec2text | 自定义 LICENSE（NOASSERTION） |
| ICLR'25 Agent Security Bench | https://github.com/agiresearch/ASB | MIT（2026-11-07 实测） |
| TocConsulting aws-security-cards | https://github.com/TocConsulting/aws-security-cards | MIT（2026-11-07 实测） |
| securityfortech awesome-security-skills | https://github.com/securityfortech/awesome-security-skills | 无 LICENSE 文件（代码公开，默认版权保留） |
| UK AISI ControlArena | https://github.com/UKGovernmentBEIS/control-arena | MIT |
| OWASP AI Vulnerabilities Playground (AIVP) | https://github.com/OWASP/AI-Vulnerabilities-Playground | MIT |
| 同上（作者源） | https://github.com/felipepenha/GenAI-Red-Team-Lab | Apache-2.0 |
| OWASP Insecure Agent Samples | https://genai.owasp.org/resource/insecure-agent-samples/ | — |
| A2ASecBench (ICLR 2026) | https://github.com/SaFo-Lab/A2ASecBench | MIT |
| Cisco a2a-scanner | https://github.com/cisco-ai-defense/a2a-scanner | Apache-2.0 |
| Cisco mcp-scanner / skill-scanner | https://github.com/cisco-ai-defense/mcp-scanner ｜ https://github.com/cisco-ai-defense/skill-scanner | Apache-2.0 / 自定义 LICENSE |
| A2A 协议（Linux Foundation） | https://github.com/a2aproject/A2A | Apache-2.0 |
| A2A Python SDK | https://github.com/a2aproject/a2a-python | Apache-2.0 |
| A2A Samples（含 multiagent） | https://github.com/a2aproject/a2a-samples（原 `google-a2a/a2a-samples`，随项目捐赠已迁移） | Apache-2.0 |
| AgentPoison (NeurIPS 2024) | https://github.com/AI-secure/AgentPoison | MIT |
| Dreadnode AIRTBench-Code | https://github.com/dreadnode/AIRTBench-Code | Apache-2.0 |
| AI Village llm_verification | https://github.com/aivillage/llm_verification | 无 LICENSE 文件 |

**◐ 成熟安全团队**

| 项目 | 完整 URL | 许可 |
|---|---|---|
| WgpSec AboutSecurity（200+/663 个 SKILL.md） | https://github.com/wgpsec/AboutSecurity | 无 LICENSE 文件（代码公开，默认版权保留） |
| SnailSploit Claude-Red（78 skills） | https://github.com/SnailSploit/Claude-Red | MIT |
| Reversec Labs Damn Vulnerable LLM Agent | https://github.com/ReversecLabs/damn-vulnerable-llm-agent | Apache-2.0 |
| Appsecco vulnerable-mcp-servers-lab | https://github.com/appsecco/vulnerable-mcp-servers-lab | MIT |
| SplxAI agentic-radar | https://github.com/splx-ai/agentic-radar | Apache-2.0 |
| Arcanum-Sec MyLLMAuto | https://github.com/Arcanum-Sec/MyLLMAuto | 无 LICENSE 文件 |
| Arcanum-Sec ai-sec-resources（靶场索引） | https://github.com/Arcanum-Sec/ai-sec-resources | 无 LICENSE 文件 |
| 8kSec awesome-ai-security（靶场索引） | https://github.com/8kSec/awesome-ai-security | 无 LICENSE 文件 |
| scadastrangelove awesome-ai-security-tools | https://github.com/scadastrangelove/awesome-ai-security-tools | 自定义 LICENSE（NOASSERTION） |

**○ 社区 / 个人（须审计后引入）**

| 项目 | 完整 URL | 许可 |
|---|---|---|
| trustshell（RT-1…RT-9，零依赖） | https://github.com/William2333ZZ/trustshell | MIT（2026-11-07 实测） |
| Claude-BugHunter（hunt-rag-vector） | https://github.com/elementalsouls/Claude-BugHunter | MIT（2026-11-07 实测） |
| Anthropic-Cybersecurity-Skills（**非 Anthropic 官方**） | https://github.com/mukul975/Anthropic-Cybersecurity-Skills | Apache-2.0 |
| offensive-claude（ai-agent-redteam） | https://github.com/hypnguyen1209/offensive-claude | MIT（2026-11-07 实测） |
| bb-huge（curated/ai-redteam，pentest.log） | https://github.com/ShulkwiSEC/bb-huge | MIT（2026-11-07 实测） |
| rag-redteam | https://github.com/Srivatsa03/rag-redteam | Apache-2.0（2026-11-07 实测） |
| skillshub / AI Pentest | https://github.com/comeonoliver/skillshub | MIT（2026-11-07 实测） |
| OSAI-AI-300-Guide（备考 cheat sheet） | https://github.com/noccommander/OSAI-AI-300-Guide | MIT |
| DVLAA | https://github.com/Tcotl/DVLAA | 无 LICENSE 文件 |
| aminrj-labs mcp-attack-labs | https://github.com/aminrj-labs/mcp-attack-labs | 自定义 LICENSE（NOASSERTION） |
| AgentHound | https://github.com/adithyan-ak/AgentHound | Apache-2.0 |
| a2a_attack | https://github.com/Farayabaig/a2a_attack | 无 LICENSE 文件 |
| swarm-test | https://github.com/surajkumar811/swarm-test | MIT |
| VEP (dros-vep-lite) | https://github.com/top-celestial-company-ltd/dros-vep-lite | 无 LICENSE 文件 |
| SamMorrowDrums mcp-security-workshop | https://github.com/SamMorrowDrums/mcp-security-workshop | 无 LICENSE 文件 |
| hacking-ai-definitive-guide（CTF 附录） | https://github.com/randalltr/hacking-ai-definitive-guide | CC BY-NC 4.0（非商业，内容开放） |

### 3.2 官方政策与考纲（非 GitHub）

| 项目 | URL |
|---|---|
| OffSec AI-300 课程页 | https://www.offsec.com/courses/ai-300/ |
| OffSec AI Usage Policy in OffSec Exams | https://help.offsec.com/hc/en-us/articles/35549468971156 |
| OSAI/AI-300 培训大纲（含 A2A 与 multi-agent 细节） | https://www.ambient-it.net/wp-content/uploads/pdf/EN/Appendix-1-Training-sheet-osai.pdf |
| OWASP GenAI Security Project | https://genai.owasp.org/ |
| TryHackMe AI System Reconnaissance | https://tryhackme.com/room/aisystemreconnaissance |
| PortSwigger Web LLM Attacks | https://portswigger.net/web-security/llm-attacks |
| Lakera Gandalf / Agent Breaker | https://gandalf.lakera.ai/ |
| Dreadnode Crucible | https://crucible.dreadnode.io/ |
