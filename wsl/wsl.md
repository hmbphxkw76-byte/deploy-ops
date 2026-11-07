# WSL 部署手册（供 AI IDE / Agent 执行）

## 文档说明

本文档面向任意 AI IDE 或 AI Agent（如 Trae、Qoder、WorkBuddy 等），用于在 Windows 上自动完成 WSL 的安装、发行版管理与备份迁移。
Agent 应按章节顺序执行：先做前置检查，再按"检查 → 执行 → 验证"的模式逐步操作；所有步骤幂等，已完成的内容会自动跳过。

## 0. 参数区（执行前由用户确认或使用默认值）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `WSL_DISTRO_NAME` | `Ubuntu-24.04` | 要安装/操作的发行版名称 |
| `WSL_IMAGE_PATH` | `D:\path\<image>.wsl` | 本地 .wsl 离线镜像路径（离线安装时必填） |
| `WSL_INSTALL_DIR` | `D:\WSL\<DistroName>` | import 时发行版的安装目录 |
| `BACKUP_TAR_PATH` | `D:\path\<DistroName>.tar` | export 备份文件输出路径 |

执行任何变更前，Agent 应先向用户确认以上参数。

## 1. 前置检查（只读，不修改系统）

按顺序执行并记录结果：

```powershell
# 1) 当前 WSL 状态与已装发行版
wsl --status
wsl --list --verbose

# 2) 是否以管理员身份运行（启用 Windows 功能需要管理员权限）
whoami /groups | findstr "S-1-5-32-544"
```

判定逻辑：

- 若 `wsl --status` 正常输出且目标发行版已存在 → 跳过第 2、3 章，仅按需执行第 4、5 章。
- 若 WSL 未安装或命令报错 → 继续第 2 章。
- 若未以管理员运行 → 提示用户以管理员身份重新启动 Agent 会话（启用功能必须管理员权限）。

## 2. 启用 Windows 功能与安装 WSL

每步先检查再执行，避免重复操作。

### 2.1 启用所需 Windows 功能（需管理员 PowerShell）

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

- 若功能已启用，dism 会提示"未请求任何更改"，属正常，可继续。
- 执行后如提示需重启，Agent 必须告知用户重启系统，并在重启后重新进入本手册继续执行。

### 2.2 安装 WSL 内核

```powershell
wsl --install --no-distribution
```

> 若用户希望连发行版一并联网安装，可去掉 `--no-distribution`；本手册默认使用离线镜像（见 2.4），便于版本可控。

### 2.3 设置默认版本为 WSL 2

```powershell
wsl --set-default-version 2
```

### 2.4 从离线镜像安装发行版

前置条件：`WSL_IMAGE_PATH` 指向的 .wsl 文件存在，否则提示用户提供镜像。

```powershell
wsl --install --from-file <image>.wsl
```

安装完成后，Agent 应提示用户完成发行版首次初始化（设置 UNIX 用户名/密码），此步骤需要交互，可请求用户接管终端或由用户自行输入。

## 3. 验证部署

```powershell
wsl --list --verbose
wsl -d <WSL_DISTRO_NAME> -- echo ok
```

判定：

- 目标发行版出现在列表中且 VERSION 为 2 → 部署成功。
- `wsl -d ... -- echo ok` 输出 `ok` → 发行版可正常启动与执行命令。

## 4. 日常管理（Agent 按需调用）

| 操作 | 命令 |
| --- | --- |
| 查看发行版列表 | `wsl --list --verbose` |
| 启动指定发行版 | `wsl -d <WSL_DISTRO_NAME>` |
| 停止指定发行版 | `wsl -t <WSL_DISTRO_NAME>` |
| 关闭所有实例 | `wsl --shutdown` |

在发行版内执行一次性命令（推荐 Agent 使用此方式做检查，避免进入交互会话）：

```powershell
wsl -d <WSL_DISTRO_NAME> -- <command>
```

## 5. 备份与迁移（export / import）

### 5.1 备份（导出为 tar）

前置检查：目标 tar 路径所在目录存在且有写权限；建议先 `wsl -t <WSL_DISTRO_NAME>` 停止发行版。

```powershell
wsl --export <WSL_DISTRO_NAME> <BACKUP_TAR_PATH>
```

验证：检查 tar 文件已生成且大小 > 0。

### 5.2 迁移 / 恢复（从 tar 导入）

前置检查：`WSL_INSTALL_DIR` 目录不存在或为空；同名发行版不存在。

```powershell
wsl --import <WSL_DISTRO_NAME> <WSL_INSTALL_DIR> <BACKUP_TAR_PATH> --version 2
```

导入后验证：按第 3 章执行；并可用以下命令指定默认用户（否则默认以 root 登录）：

```powershell
<WSL_DISTRO_NAME>.exe config --default-user <username>
```

> 注意：import 不会保留原发行版的默认用户设置，Agent 应在迁移后主动检查并修复默认用户。

## 6. Agent 执行注意事项

- 所有命令默认在 PowerShell 中执行；启用 Windows 功能（dism）必须管理员权限。
- 涉及重启、交互式输入（如首次设置用户名密码）时，应暂停并请求用户操作，不要自行猜测输入。
- 建议使用 WSL 2 以获得更好的兼容性和性能。
- 若启用功能失败，检查系统版本（Win10 2004+ / Win11）与管理员权限后再重试。
- 每完成一章，向用户汇报当前状态与下一步计划。
