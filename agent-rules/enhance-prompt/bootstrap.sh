#!/usr/bin/env bash
# 交互规则跨机部署脚本（Linux / Kali Linux 版，幂等）
# 从私有仓库 clone/pull 唯一规范源，生成各 IDE 引用文件（引用而非复制正文），
# 并在 WorkBuddy 用户级记忆与项目级记忆中维护受管段落。
# 受管段落以 BEGIN/END 标记包裹；重复执行先移除旧段落再写入，保证幂等。
set -euo pipefail

REPO_URL='https://github.com/hmbphxkw76-byte/agent-rules.git'
HOME_DIR="${HOME}"
RULES_DIR="${HOME_DIR}/.agent-rules"
SPEC_FILE="${RULES_DIR}/global-interaction-rule.md"
SPEC_REF="@${SPEC_FILE}"

BEGIN_MARK='<!-- BEGIN agent-rules managed -->'
END_MARK='<!-- END agent-rules managed -->'

USER_DIR=''
PROJECT_ROOT="$(pwd)"

usage() {
  echo "用法: bootstrap.sh [-u WORKBUDDY_USER_DIR] [-p PROJECT_ROOT]"
  echo "  -u  仅更新指定的 WorkBuddy user-* 目录；默认扫描全部"
  echo "  -p  项目根目录（刷新项目级指针）；默认当前目录"
}

while getopts ":u:p:h" opt; do
  case "$opt" in
    u) USER_DIR="$OPTARG" ;;
    p) PROJECT_ROOT="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "未知选项: -$OPTARG" >&2; usage >&2; exit 1 ;;
    :) echo "选项 -$OPTARG 缺少参数" >&2; exit 1 ;;
  esac
done

set_managed_block() {
  local path="$1"
  local block="$2"
  local parent
  parent="$(dirname "$path")"
  mkdir -p "$parent"

  local old=''
  if [ -f "$path" ]; then
    old="$(cat "$path")"
  fi

  # 移除旧的受管段落（含其前后空行），保留其余内容
  local cleaned
  cleaned="$(printf '%s\n' "$old" | sed -e "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

  local new_content
  if [ -n "$cleaned" ]; then
    new_content="${cleaned}

${block}"
  else
    new_content="${block}"
  fi
  printf '%s\n' "$new_content" > "$path"
}

# 1. clone 或 pull 规范源
echo '[1/4] 规范源同步'
if [ -d "${RULES_DIR}/.git" ]; then
  git -C "$RULES_DIR" pull --ff-only
  echo "  pulled: ${SPEC_FILE}"
elif [ -f "$SPEC_FILE" ]; then
  echo '  目录已存在且含规范源、未初始化 git：跳过 clone（本机初始化场景）'
else
  git clone "$REPO_URL" "$RULES_DIR"
  echo "  cloned: ${RULES_DIR}"
fi
if [ ! -f "$SPEC_FILE" ]; then
  echo "规范源缺失: ${SPEC_FILE}" >&2
  exit 1
fi

# 2. 生成各 IDE 引用文件（引用而非复制正文）
echo '[2/4] 生成 IDE 引用文件'
ide_block="${BEGIN_MARK}
${SPEC_REF}
${END_MARK}"
set_managed_block "${HOME_DIR}/.claude/CLAUDE.md" "$ide_block"
set_managed_block "${HOME_DIR}/.gemini/GEMINI.md" "$ide_block"
set_managed_block "${HOME_DIR}/.cursor/rules/agent-rules.mdc" "$ide_block"
set_managed_block "${HOME_DIR}/.windsurf/rules/agent-rules.md" "$ide_block"

# 3. WorkBuddy 用户级记忆与项目级指针
echo '[3/4] 刷新 WorkBuddy 记忆指针'
wb_block="${BEGIN_MARK}
- **交互流程**：遵循唯一规范源 ${SPEC_REF}；仅任务型输入走润色—展示—确认—执行，纯提问 / 确认 / 补充直接处理。
${END_MARK}"

if [ -n "$USER_DIR" ]; then
  user_dirs="$USER_DIR"
else
  user_dirs=''
  if [ -d "${HOME_DIR}/.workbuddy" ]; then
    user_dirs="$(find "${HOME_DIR}/.workbuddy" -maxdepth 1 -type d -name 'user-*' 2>/dev/null || true)"
  fi
fi

if [ -n "$user_dirs" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    mem="${d}/MEMORY.md"
    if [ -f "$mem" ]; then
      set_managed_block "$mem" "$wb_block"
      echo "  updated: ${mem}"
    fi
  done <<< "$user_dirs"
fi

if [ -d "${PROJECT_ROOT}/.workbuddy" ]; then
  proj_mem="${PROJECT_ROOT}/.workbuddy/memory/MEMORY.md"
  set_managed_block "$proj_mem" "$wb_block"
  echo "  updated: ${proj_mem}"
fi

# 4. 完成
echo '[4/4] 完成'
echo "  规范源: ${SPEC_FILE}"
echo '  新电脑部署: git clone <repo> ~/.agent-rules && bash ~/.agent-rules/bootstrap.sh'
