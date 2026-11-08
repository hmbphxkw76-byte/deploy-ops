# OSAI (AI-300) 考前靶机与工具精选（精简版，2026-11-08）

> 对齐 OffSec OSAI / AI-300 考纲（LLM 攻击、agentic、multi-agent/A2A、RAG/向量库、MCP、供应链、AI 基础设施、AI 云安全、报告取证）。
> 选型原则：官方出品（OWASP / Microsoft / 顶会官方代码）优先，同等场景下取质量最高者；主靶场 1 + 专项靶机 ≤3，全部本地可复现。
> 约束：靶机仅用于**考前本地训练与验证**；考试 24h 监考 VPN 内不部署靶机、不装重依赖，只回写验证证据。

---

## 1. 靶机（1 主 + 3 专项 + 1 补充）

| 定位 | 靶机 | 出品方 | 覆盖 | GitHub 官方仓库 | 许可 |
|---|---|---|---|---|:---:|
| **主靶场** | **OWASP AI Vulnerabilities Playground (AIVP)** | OWASP | 4 阶段（PI 提示注入 / DE agentic 泄露 / MM 模型操纵 / **MCP 信任边界**）50+ 场景，动态 flag + 逐场景验证；本地 Docker + Ollama（Llama 3.1），无云依赖 | [OWASP/AI-Vulnerabilities-Playground](https://github.com/OWASP/AI-Vulnerabilities-Playground) | MIT |
| **专项① Agentic** | **OWASP FinBot CTF**（"The Juice Shop for Agentic AI"） | OWASP GenAI Security Project | 真实多 agent 金融平台（vendor / fraud / invoice / payment），真实 MCP 工具访问；提示注入、策略绕过、工具投毒、数据外带、RCE；事件驱动自动判分；映射 OWASP LLM Top 10 / Agentic Top 10 / CWE / MITRE ATLAS | [GenAI-Security-Project/finbot-ctf](https://github.com/GenAI-Security-Project/finbot-ctf) | Apache-2.0 |
| **专项② MCP** | **vulnerable-mcp-servers-lab** | Appsecco | 故意脆弱 MCP server 合集：路径遍历+RCE、间接提示注入（本地 stdio / 远程 HTTP+SSE）、eval 注入、恶意工具输出、命名空间抢注、过时依赖供应链、密钥/PII 泄露；每个 server 独立 README + 攻击复现 | [appsecco/vulnerable-mcp-servers-lab](https://github.com/appsecco/vulnerable-mcp-servers-lab) | MIT |
| **专项③ RAG/向量库** | **PoisonedRAG**（USENIX Security 2025 官方代码） | Zou et al. | 首个知识库污染攻击：5 篇投毒文档 97% 劫持率 / GPT-4 90%+ ASR；黑盒（LM_targeted）+ 白盒（hotflip）；含 BEIR 数据集管线 | [sleeepeer/PoisonedRAG](https://github.com/sleeepeer/PoisonedRAG) | MIT |
| 补充（Infra/Cloud） | Microsoft AI Red Teaming Playground Labs | Microsoft（Black Hat USA 2024 起源） | 12 级渐进挑战：元提示提取、Crescendo、间接注入、凭据窃取、SSRF；Docker/K8s 基础设施，补齐基础设施与云侧侦察 | [microsoft/AI-Red-Teaming-Playground-Labs](https://github.com/microsoft/AI-Red-Teaming-Playground-Labs) | MIT |

---

## 2. 靶机 × OSAI 场景覆盖矩阵（全覆盖）

场景缩写：**LLM**=Attacking LLMs｜**Agt**=AI agents｜**MA**=multi-agent/A2A｜**RAG**=RAG 管线｜**Emb**=Embeddings/向量库｜**MCP**=MCP/tool surfaces｜**SC**=AI/ML 供应链｜**Infra**=AI 基础设施/编排框架｜**Cloud**=AI 云安全｜**Rep**=报告/证据。●=直接覆盖，◐=部分，—=不覆盖。

| 资产 | LLM | Agt | MA | RAG | Emb | MCP | SC | Infra | Cloud | Rep |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| **[AIVP（主）](https://github.com/OWASP/AI-Vulnerabilities-Playground)** | ● | ● | ◐ | ● | ◐ | ● | ◐ | ◐ | ◐ | ◐ |
| [FinBot CTF（agentic）](https://github.com/GenAI-Security-Project/finbot-ctf) | ● | ● | ● | — | — | ● | ◐ | ◐ | — | ◐ |
| [vulnerable-mcp-servers-lab（MCP）](https://github.com/appsecco/vulnerable-mcp-servers-lab) | ◐ | ● | — | ◐ | — | ● | ● | ● | — | ◐ |
| [PoisonedRAG（RAG）](https://github.com/sleeepeer/PoisonedRAG) | ◐ | — | — | ● | ● | — | ● | — | — | ◐ |
| [MS AIRT Playground Labs（补充）](https://github.com/microsoft/AI-Red-Teaming-Playground-Labs) | ◐ | ◐ | — | ◐ | — | ◐ | ◐ | ● | ● | ◐ |
| 工具组合（PyRIT / promptfoo / A2ASecBench / mcp-scan 等，见第 3 节） | ● | ● | ● | ● | ● | ● | ● | ◐ | ● | ● |
| **∪ 合计** | **●** | **●** | **●** | **●** | **●** | **●** | **●** | **●** | **●** | **●** |

**结论**：10 个考纲场景全部有 ● 级覆盖——LLM/Agt/MCP/RAG 由 AIVP + FinBot 双保险；MA 由 FinBot 多 agent 平台 + A2ASecBench；Emb 由 PoisonedRAG + vec2text；SC/Infra 由 Appsecco MCP lab + ModelScan/agentic-radar；Cloud 由 MS AIRT + PyRIT（Azure OpenAI 目标）；Rep 由 PyRIT/promptfoo 自动化证据产出。训练顺序：AIVP 全通 → FinBot agentic 实战 → Appsecco MCP 专项 → PoisonedRAG 投毒 → MS AIRT 补 Infra/Cloud。

---

## 3. 配套工具精选（官方出品 / 高热度开源）

### 3.1 通用 LLM 攻击与评估

| 工具 | 定位 | GitHub 官方仓库 | 许可 |
|---|---|---|:---:|
| **Microsoft PyRIT** | 微软官方 AI 红队框架，业界事实标准；多轮攻击编排（Crescendo 等）、自动化评分与报告，可直接打 Azure OpenAI 端点 | [microsoft/PyRIT](https://github.com/microsoft/PyRIT) | MIT |
| **NVIDIA garak** | NVIDIA 官方 LLM 漏洞扫描器，50+ 探针（注入、泄露、越狱、毒性） | [NVIDIA/garak](https://github.com/NVIDIA/garak) | Apache-2.0 |
| **promptfoo** | 高热度红队评估平台：RAG/agent 攻击插件 + `redteam.yaml` 固定用例 + CI 集成 + 结构化报告 | [promptfoo/promptfoo](https://github.com/promptfoo/promptfoo) | MIT |

### 3.2 Multi-agent / A2A

| 工具 | 定位 | GitHub 官方仓库 | 许可 |
|---|---|---|:---:|
| **A2ASecBench**（ICLR 2026 官方代码） | 协议感知 A2A 安全基准：六类攻击、三领域 ASR、冻结用例 + 可插拔 SUT、本地可执行 | [SaFo-Lab/A2ASecBench](https://github.com/SaFo-Lab/A2ASecBench) | MIT |
| **Cisco a2a-scanner** | Cisco AI Defense 官方：YARA / Spec / Heuristic / Endpoint 四分析器，可喂恶意 Agent Card 样本 | [cisco-ai-defense/a2a-scanner](https://github.com/cisco-ai-defense/a2a-scanner) | Apache-2.0 |
| A2A 协议 / SDK / samples（靶标基座） | Google 发起、已捐赠 Linux Foundation；协议规范 + Python SDK + multiagent 编排样例 | [a2aproject/A2A](https://github.com/a2aproject/A2A) ｜ [a2aproject/a2a-python](https://github.com/a2aproject/a2a-python) ｜ [a2aproject/a2a-samples](https://github.com/a2aproject/a2a-samples) | Apache-2.0 |

### 3.3 MCP / Agent 工作流

| 工具 | 定位 | GitHub 官方仓库 | 许可 |
|---|---|---|:---:|
| **mcp-scan**（Tool Poisoning 原始披露方 Invariant Labs，已并入 Snyk） | 静态 + 运行时扫描：rug pull / cross-server shadowing / 提示注入 | [snyk/agent-scan](https://github.com/snyk/agent-scan)（原 [invariantlabs-ai/mcp-scan](https://github.com/invariantlabs-ai/mcp-scan)） | Apache-2.0 |
| **Cisco mcp-scanner** | Cisco AI Defense 官方 MCP server 风险扫描器 | [cisco-ai-defense/mcp-scanner](https://github.com/cisco-ai-defense/mcp-scanner) | Apache-2.0 |
| **agentic-radar** | 高热度 agent 工作流静态扫描 + 可视化（LangGraph / CrewAI / N8N / OpenAI Agents / AutoGen），OWASP 映射 + CI/CD | [splx-ai/agentic-radar](https://github.com/splx-ai/agentic-radar) | Apache-2.0 |
| MCP Inspector / Python SDK（协议基座） | 工具枚举、程序化调用、协议级 recon | [modelcontextprotocol/inspector](https://github.com/modelcontextprotocol/inspector) ｜ [modelcontextprotocol/python-sdk](https://github.com/modelcontextprotocol/python-sdk) | MIT / 自定义 LICENSE |

### 3.4 RAG / 向量库

| 工具 | 定位 | GitHub 官方仓库 | 许可 |
|---|---|---|:---:|
| **AgentPoison**（NeurIPS 2024 官方实现） | agent 记忆 / RAG 知识库后门投毒（ReAct / EHRAgent），桥接 RAG 与 agent 两面 | [AI-secure/AgentPoison](https://github.com/AI-secure/AgentPoison) | MIT |
| **vec2text** | embedding inversion：从向量反演原文（OWASP LLM08 敏感信息泄露核心实证） | [vec2text/vec2text](https://github.com/vec2text/vec2text) | 自定义 LICENSE |

### 3.5 供应链 / 基础设施

| 工具 | 定位 | GitHub 官方仓库 | 许可 |
|---|---|---|:---:|
| **Protect AI ModelScan** | 高热度模型扫描器：pickle/PyTorch/TF 恶意代码检测（供应链投毒） | [protectai/modelscan](https://github.com/protectai/modelscan) | Apache-2.0 |
| **IBM ART** | IBM Research 官方攻击库：evasion / poisoning / extraction / inference 全覆盖 | [Trusted-AI/adversarial-robustness-toolbox](https://github.com/Trusted-AI/adversarial-robustness-toolbox) | MIT |

---

## 4. GitHub 官方链接索引

| 项目 | 完整 URL |
|---|---|
| OWASP AIVP（主靶场） | https://github.com/OWASP/AI-Vulnerabilities-Playground |
| OWASP FinBot CTF（agentic） | https://github.com/GenAI-Security-Project/finbot-ctf |
| Appsecco vulnerable-mcp-servers-lab（MCP） | https://github.com/appsecco/vulnerable-mcp-servers-lab |
| PoisonedRAG（RAG，USENIX Sec'25） | https://github.com/sleeepeer/PoisonedRAG |
| Microsoft AI Red Teaming Playground Labs（补充） | https://github.com/microsoft/AI-Red-Teaming-Playground-Labs |
| Microsoft PyRIT | https://github.com/microsoft/PyRIT |
| NVIDIA garak | https://github.com/NVIDIA/garak |
| promptfoo | https://github.com/promptfoo/promptfoo |
| A2ASecBench（ICLR 2026） | https://github.com/SaFo-Lab/A2ASecBench |
| Cisco a2a-scanner | https://github.com/cisco-ai-defense/a2a-scanner |
| A2A 协议（Linux Foundation） | https://github.com/a2aproject/A2A |
| A2A Python SDK | https://github.com/a2aproject/a2a-python |
| A2A Samples | https://github.com/a2aproject/a2a-samples |
| mcp-scan → Snyk Agent Scan | https://github.com/snyk/agent-scan |
| Cisco mcp-scanner | https://github.com/cisco-ai-defense/mcp-scanner |
| SplxAI agentic-radar | https://github.com/splx-ai/agentic-radar |
| MCP Inspector | https://github.com/modelcontextprotocol/inspector |
| MCP Python SDK | https://github.com/modelcontextprotocol/python-sdk |
| AgentPoison（NeurIPS 2024） | https://github.com/AI-secure/AgentPoison |
| vec2text | https://github.com/vec2text/vec2text |
| Protect AI ModelScan | https://github.com/protectai/modelscan |
| IBM ART | https://github.com/Trusted-AI/adversarial-robustness-toolbox |

> 链接核验：2026-11-08 经 WebFetch 实测 AIVP / finbot-ctf / vulnerable-mcp-servers-lab / PoisonedRAG 均有效；其余沿用 2026-11-07 GitHub API 实测结果。FinBot CTF 许可核实为 Apache-2.0。
