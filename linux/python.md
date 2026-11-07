# Python 环境部署手册（uv）— Linux（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Linux / Unix（默认 Ubuntu，含 WSL 内的 Ubuntu）** 上自动完成基于 uv 的 Python 项目环境搭建、国内镜像配置与安全工具包安装。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；初始化与安装类步骤幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PYTHON_VERSION` | `3.13` | uv 使用的 Python 版本 |
| `PYPI_INDEX` | `https://mirrors.tuna.tsinghua.edu.cn/pypi/simple` | 国内 PyPI 镜像源 |
| `SECURITY_PACKAGES` | `pyrit deepeval garak adversarial-robustness-toolbox counterfit trufflehog fickling giskard` | 要安装的安全评估工具包列表 |
| `PROJECT_DIR` | 当前目录 | uv 项目根目录 |

## 1. 前置检查（只读，不修改系统）

```bash
# uv 是否已安装
uv --version 2>/dev/null || echo "UV_NOT_INSTALLED"

# 项目是否已初始化
ls "$PROJECT_DIR/pyproject.toml" 2>/dev/null || echo "NO_PROJECT"

# pip 是否已安装
pip3 --version 2>/dev/null || echo "PIP_NOT_INSTALLED"
```

判定逻辑：

- uv 未安装 → 先执行 2.1。
- 项目已有 `pyproject.toml` → 跳过第 3 章。
- `pip3` 可用 → 跳过第 5 章。

## 2. 环境准备

### 2.1 安装 uv（未安装时）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

安装后新开 shell 或 `source ~/.local/bin/env` 使 `uv` 生效，用 `uv --version` 验证。

## 3. 初始化 Python 项目环境

```bash
cd "$PROJECT_DIR"

# 已有 pyproject.toml 时跳过
uv init --python 3.13
```

验证：项目根目录生成 `pyproject.toml` 与 `.python-version`。

## 4. 依赖管理（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 添加依赖 | `uv add <package-name>` |
| 同步依赖（按 lock 文件安装到虚拟环境） | `uv sync` |
| 用 uv 直接安装包（不写入 pyproject） | `uv pip install <package-name>` |

### 4.1 配置国内 PyPI 源

```bash
# pip 侧（已是 PYPI_INDEX 时跳过）
pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/simple

# uv 侧（uv 不读取 pip 配置，通过环境变量生效）
export UV_DEFAULT_INDEX="https://mirrors.tuna.tsinghua.edu.cn/pypi/simple"
```

> 若需持久化 `UV_DEFAULT_INDEX`，写入 `~/.bashrc` 或 `~/.profile`。

## 5. 安装 pip（未安装时）

```bash
sudo apt update
sudo apt install python3-pip -y
pip3 --version   # 验证
```

## 6. 安装安全评估工具包

```bash
uv pip install pyrit deepeval garak adversarial-robustness-toolbox counterfit trufflehog fickling
uv pip install giskard
```

验证：

```bash
uv pip list | grep -E "pyrit|deepeval|garak|giskard"
```

> 部分包体积较大或依赖系统库，安装失败时逐个排查：先单独安装失败包，将报错反馈给用户。

## 7. Agent 执行注意事项

- `uv init` 会生成示例文件，仅在空目录或用户确认时执行。
- `uv pip install` 安装进项目虚拟环境；在项目外执行时会装入当前激活的环境，Agent 应先确认目标环境。
- 镜像源修改前先读取当前值（`pip config get global.index-url`），避免覆盖用户自定义配置。
- 每完成一章，向用户汇报当前状态与下一步计划。
