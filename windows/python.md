# Python 环境部署手册（uv）— Windows（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 **Windows** 上自动完成基于 uv 的 Python 项目环境搭建、国内镜像配置与安全工具包安装。
Agent 应按"前置检查 → 执行 → 验证"的模式逐步操作；初始化与安装类步骤幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `PYTHON_VERSION` | `3.13` | uv 使用的 Python 版本 |
| `PYPI_INDEX` | `https://mirrors.tuna.tsinghua.edu.cn/pypi/simple` | 国内 PyPI 镜像源 |
| `SECURITY_PACKAGES` | `pyrit deepeval garak adversarial-robustness-toolbox counterfit trufflehog fickling giskard` | 要安装的安全评估工具包列表 |
| `PROJECT_DIR` | 当前目录 | uv 项目根目录 |

## 1. 前置检查（只读，不修改系统）

```powershell
# uv 是否已安装
uv --version; if (-not $?) { echo "UV_NOT_INSTALLED" }

# 执行策略（PowerShell）
Get-ExecutionPolicy -Scope CurrentUser

# 项目是否已初始化
Test-Path "$PROJECT_DIR/pyproject.toml" ? "PROJECT_EXISTS" : "NO_PROJECT"
```

判定逻辑：

- uv 未安装 → 先执行 2.1。
- 执行策略为 `Restricted` → 先执行 2.2。
- 项目已有 `pyproject.toml` → 跳过第 3 章。

## 2. 环境准备

### 2.1 安装 uv（未安装时）

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

安装后新开终端使 `uv` 生效，用 `uv --version` 验证。

### 2.2 设置执行策略（仅当前用户，需 PowerShell）

```powershell
# 已是 RemoteSigned/Unrestricted 时跳过
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

> 仅设置 `CurrentUser` 作用域，避免影响系统全局策略；如需全局设置请提示用户以管理员执行。

## 3. 初始化 Python 项目环境

```powershell
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

```powershell
# pip 侧（已是 PYPI_INDEX 时跳过）
pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/simple

# uv 侧（uv 不读取 pip 配置，通过环境变量生效）
# 当前会话：
$env:UV_DEFAULT_INDEX = "https://mirrors.tuna.tsinghua.edu.cn/pypi/simple"
# 持久化（当前用户）：
[Environment]::SetEnvironmentVariable("UV_DEFAULT_INDEX", "https://mirrors.tuna.tsinghua.edu.cn/pypi/simple", "User")
```

## 5. 安装安全评估工具包

```powershell
uv pip install pyrit deepeval garak adversarial-robustness-toolbox counterfit trufflehog fickling
uv pip install giskard
```

验证：

```powershell
uv pip list | Select-String -Pattern "pyrit|deepeval|garak|giskard"
```

> 部分包体积较大或依赖系统库，安装失败时逐个排查：先单独安装失败包，将报错反馈给用户。

## 6. Agent 执行注意事项

- `uv init` 会生成示例文件，仅在空目录或用户确认时执行。
- `uv pip install` 安装进项目虚拟环境；在项目外执行时会装入当前激活的环境，Agent 应先确认目标环境。
- 镜像源修改前先读取当前值（`pip config get global.index-url`），避免覆盖用户自定义配置。
- 每完成一章，向用户汇报当前状态与下一步计划。
