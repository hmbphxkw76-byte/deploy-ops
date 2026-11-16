#!/usr/bin/env bash
# deploy-ops 标准化清理工具（本地与 CI 共用，幂等）
#
# 用法:
#   bash scripts/cleanup.sh --check   只读扫描；发现残留退出码 1（CI 门禁）
#   bash scripts/cleanup.sh --pre     流水线前置清理：临时文件 / 构建产物 / 缓存
#   bash scripts/cleanup.sh --post    流水线收尾清理：清理 + 全局缓存 + 校验无残留
#   bash scripts/cleanup.sh --all     = --pre + --post
#   bash scripts/cleanup.sh --cache   仅清理全局工具缓存（opt-in）
#
# 设计约束:
#   - 只清理可再生的临时 / 构建 / 缓存产物；已被 git 跟踪的文件一律跳过。
#   - 被 .gitignore 忽略的残留用 `git clean -Xdf` 统一清理，避免误删未跟踪的工作文件。
#   - 退出码: 0=干净或清理成功, 1=存在残留 / 清理失败。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:---check}"
VERBOSE="${VERBOSE:-0}"
if [ "$#" -gt 1 ]; then
  printf '[cleanup][ERROR] 用法: bash scripts/cleanup.sh --check|--pre|--post|--all|--cache\n' >&2
  exit 2
fi

log()  { printf '[cleanup] %s\n' "$*"; }
warn() { printf '[cleanup][WARN] %s\n' "$*" >&2; }
die()  { printf '[cleanup][ERROR] %s\n' "$*" >&2; exit 1; }

# —— 清理目标（均为可再生产物）——
JUNK_FILES=( '*.log' '*.tmp' '*.temp' '*.bak' '*.orig' '*.rej' '*.old' '*.save'
             '*.swp' '*.swo' '*~' '.DS_Store' 'Thumbs.db' 'desktop.ini' '*.pyc' '*.pyo' )
JUNK_DIRS=( '__pycache__' '.pytest_cache' '.mypy_cache' '.ruff_cache' '.tox' '.eggs'
            'node_modules' '.venv' 'venv' 'dist' 'build' 'out' 'target' 'coverage'
            'htmlcov' '.cache' '.npm' '.yarn' '.pnpm-store' '.gradle' '.terraform' )

# 本地保留（被 .gitignore 忽略但需长期保留，不参与残留清理，如本机 kubeconfig）
KEEP_IGNORED=( '.kube' )

# 全局工具缓存（仅 --post / --cache 清理；逐项确认存在才删）
GLOBAL_CACHE=( "$HOME/.cache/helm" "$HOME/.cache/pip" "$HOME/.npm" "$HOME/.local/share/helm"
               "$HOME/.kube/cache" "$HOME/.cache/ms-playwright" "$HOME/.cache/puppeteer" )

is_tracked()  { git ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }
dir_tracked() { [ -n "$(git ls-files -- "$1")" ]; }

find_junk_files() {
  local -a expr=() p
  for p in "${JUNK_FILES[@]}"; do expr+=( -o -name "$p" ); done
  [ "${#expr[@]}" -gt 0 ] || return 0
  find . -path ./.git -prune -o -type f \( ${expr[@]:1} \) -print 2>/dev/null
}

find_junk_dirs() {
  local -a expr=() p
  for p in "${JUNK_DIRS[@]}"; do expr+=( -o -name "$p" ); done
  [ "${#expr[@]}" -gt 0 ] || return 0
  find . -path ./.git -prune -o -type d \( ${expr[@]:1} \) -print 2>/dev/null
}

clean_files() {
  local n=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_tracked "$f"; then warn "跳过已跟踪文件: $f"; continue; fi
    [ "$VERBOSE" = 1 ] && log "删除文件: $f"
    rm -f -- "$f" && n=$((n + 1))
  done < <(find_junk_files)
  [ "$n" -gt 0 ] && log "已删除 $n 个垃圾文件"
  return 0
}

clean_dirs() {
  local n=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if dir_tracked "$d"; then warn "跳过含已跟踪文件的目录: $d"; continue; fi
    [ "$VERBOSE" = 1 ] && log "删除目录: $d"
    rm -rf -- "$d" && n=$((n + 1))
  done < <(find_junk_dirs)
  [ "$n" -gt 0 ] && log "已删除 $n 个垃圾目录"
  return 0
}

clean_ignored() {
  local out; out="$(git clean -Xdn)"
  [ -n "$out" ] || { [ "$VERBOSE" = 1 ] && log "无被忽略的残留"; return 0; }
  log "清理被忽略的临时/缓存残留"
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$out"
  printf '%s\n' "$out" | sed 's/^Would remove //' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    local keep=0 k
    for k in "${KEEP_IGNORED[@]}"; do
      if [ "$p" = "$k" ] || [ "$p" = "$k/" ]; then keep=1; fi
    done
    if [ "$keep" = 1 ]; then
      [ "$VERBOSE" = 1 ] && log "保留本地目录: $p"
      continue
    fi
    [ "$VERBOSE" = 1 ] && log "删除: $p"
    rm -rf -- "$p"
  done
}

clean_global_cache() {
  local p n=0
  for p in "${GLOBAL_CACHE[@]}"; do
    if [ -e "$p" ]; then
      log "清理全局缓存: $p"
      rm -rf -- "$p" && n=$((n + 1))
    fi
  done
  [ "$n" -gt 0 ] || log "无全局缓存可清理"
}

residue() {
  local out="" p k keep
  out+="$(find_junk_files)"$'\n'
  out+="$(find_junk_dirs)"$'\n'
  out+="$(git clean -Xdn)"
  printf '%s\n' "$out" | sed '/^$/d' | while IFS= read -r p; do
    keep=0
    for k in "${KEEP_IGNORED[@]}"; do
      case "$p" in "$k"|"$k/"|"Would remove $k"|"Would remove $k/") keep=1;; esac
    done
    if [ "$keep" = 1 ]; then continue; fi
    printf '%s\n' "$p"
  done
}

check() {
  local out; out="$(residue)"
  if [ -n "$out" ]; then
    warn "发现残留："
    printf '%s\n' "$out" >&2
    die "存在残留（请先运行 --pre / --post 清理）"
  fi
  log "扫描通过：无临时 / 构建 / 缓存残留"
}

case "$MODE" in
  --check) check ;;
  --pre)   clean_files; clean_dirs; clean_ignored; check ;;
  --post)  clean_files; clean_dirs; clean_ignored; clean_global_cache; check ;;
  --all)   clean_files; clean_dirs; clean_ignored; clean_global_cache; check ;;
  --cache) clean_global_cache ;;
  *)       die "未知模式: $MODE（--check | --pre | --post | --all | --cache）" ;;
esac
