# 06 · A2ASecBench（Agent 安全基准）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Docker / 镜像源 / 目录）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· Python 3.10+ · **形态**：CLI（无 Web 页面，结果以文件交付）

- **来源**：`A2ASecBench-main.zip`
- **形态**：Python CLI 基准工具（离线确定性基线 / 在线 LLM SUT）
- **依赖**：Python 3.10+、pytest（dev）

## 1. 安装

```bash
python3 -m venv "$LAB_ROOT/venvs/a2asecbench"
cd "$LAB_ROOT/src/A2ASecBench-main"
"$LAB_ROOT/venvs/a2asecbench/bin/pip" config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
"$LAB_ROOT/venvs/a2asecbench/bin/pip" install -e ".[dev]"
```

## 2. 离线模式（无需 LLM）

```bash
"$LAB_ROOT/venvs/a2asecbench/bin/python" orchestration.py --config configs/offline/as.yaml --trials 1
"$LAB_ROOT/venvs/a2asecbench/bin/python" orchestration.py --config configs/offline/cc_whitebox.yaml --mode whitebox --trials 1
```

## 3. 在线模式（LLM SUT）

设置环境变量（任意 OpenAI 兼容服务均可）：

```bash
export SUT_API_BASE=https://<provider>/openai/v1
export SUT_API_KEY=<your-key>
export SUT_MODEL=<model-name>
export SUT_TEMPERATURE=0
export SUT_TIMEOUT_S=120
```

先跑样例，再跑全量：

```bash
"$LAB_ROOT/venvs/a2asecbench/bin/python" orchestration.py --config configs/llm/as_sample.yaml --trials 1
"$LAB_ROOT/venvs/a2asecbench/bin/python" orchestration.py --config configs/llm/cc_blackbox_sample.yaml --mode blackbox --trials 1
```

## 4. 结果

- 每次运行：`results/run_<timestamp>.jsonl`
- 最新汇总：`results/summary.json`（含 ASR/成功率）

## 5. 校验

```bash
"$LAB_ROOT/venvs/a2asecbench/bin/python" -m pytest
"$LAB_ROOT/venvs/a2asecbench/bin/python" scripts/validate_release.py
```

## 6. 说明

- 该组件没有 Web 页面，结果以文件形式交付。
- “离线 ASR”用于回归对照；“在线 ASR”依赖具体模型能力，数值仅供横向比较。

## 7. 注意事项

- 在线模式需要任意 OpenAI 兼容服务；凭据通过环境变量传入（§3），不写入仓库。
- 结果文件（`results/run_<timestamp>.jsonl`、`results/summary.json`）是交付物，清理前先备份。
- 主动安全测试（黑盒 / 白盒攻击 SUT）仅限针对自有或授权目标。
