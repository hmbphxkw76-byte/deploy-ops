#!/usr/bin/env bash
# deploy-ops 仓库健康校验（本地与 CI 共用）
#
# 校验项:
#   1. Shell 语法（bash -n，覆盖全部已跟踪 .sh）
#   2. 手册内嵌安装脚本与独立 .sh 的一致性（防文档漂移）
#   3. Markdown 内部链接可解析（无死链）
#   4. 孤儿文件检测（根手册未被任何文件引用）
#   5. 敏感信息扫描（私钥 / 明文令牌）
#   6. 临时 / 构建 / 缓存残留扫描（调用 scripts/cleanup.sh --check）
#
# 退出码: 0=全部通过, 1=存在失败项。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
log() { printf '[validate] %s\n' "$*"; }
ok()  { printf '[validate][OK]   %s\n' "$*"; }
bad() { printf '[validate][FAIL] %s\n' "$*" >&2; fail=1; }

check_shell_syntax() {
  local f
  for f in $(git ls-files '*.sh'); do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
  done
}

# 提取 md 中所有 ```bash 代码块，逐一与独立 .sh 比对（忽略 CRLF 差异）
check_embedded() {
  local md="$1" sh="$2" dir b found=0
  if [ ! -f "$md" ] || [ ! -f "$sh" ]; then bad "内嵌校验缺文件: $md / $sh"; return; fi
  dir="$(mktemp -d)"
  awk -v d="$dir" '
    /^```bash/ { inb=1; n++; f=sprintf("%s/block.%02d", d, n); next }
    /^```[[:space:]]*$/ { inb=0; next }
    inb { print > f }
  ' "$md"
  for b in "$dir"/block.*; do
    [ -e "$b" ] || continue
    if diff -q --strip-trailing-cr "$b" "$sh" >/dev/null 2>&1; then found=1; break; fi
  done
  if [ "$found" = 1 ]; then ok "内嵌脚本一致: $md ↔ $sh"; else bad "内嵌脚本与 $sh 不一致或缺失（$md）"; fi
  rm -rf -- "$dir"
}

check_links() {
  local md p target missing=0
  while IFS= read -r md; do
    while IFS= read -r p; do
      case "$p" in http:*|https:*|mailto:*|'#'*) continue ;; esac
      target="${p%%#*}"
      [ -n "$target" ] || continue
      if [ ! -e "$target" ]; then bad "死链 [$md] -> $p"; missing=1; fi
    done < <(grep -oE '\]\([^)]+\)' "$md" | sed -E 's/^\]\(//; s/\)$//')
  done < <(git ls-files '*.md')
  [ "$missing" = 0 ] && ok "内部链接全部可解析"
}

check_orphans() {
  local f base refs orphan=0
  for f in $(git ls-files '*.md'); do
    [ "$f" = "README.md" ] && continue
    base="$(basename "$f")"
    refs="$(git grep -lF "$base" -- '*.md' | grep -vx "$f" || true)"
    if [ -z "$refs" ]; then bad "孤儿文件（无任何引用）: $f"; orphan=1; fi
  done
  [ "$orphan" = 0 ] && ok "无孤儿手册"
}

check_secrets() {
  local hits
  hits="$(git grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' -- . ':!*.crt' || true)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" >&2; bad "发现疑似私钥"; else ok "未发现私钥"; fi
  hits="$(git grep -nE 'sk-[A-Za-z0-9]{24,}|glrt-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}' || true)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" >&2; bad "发现疑似明文令牌"; else ok "未发现明文令牌"; fi
}

log "1/6 Shell 语法";            check_shell_syntax
log "2/6 内嵌脚本一致性";        check_embedded kubernetes-argocd.md kubernetes-argocd-install.sh
                                 check_embedded kubernetes-harbor.md kubernetes-harbor-install.sh
log "3/6 内部链接";              check_links
log "4/6 孤儿文件";              check_orphans
log "5/6 敏感信息";              check_secrets
log "6/6 残留扫描";              if bash scripts/cleanup.sh --check; then ok "残留扫描通过"; else bad "残留扫描未通过"; fi

if [ "$fail" -ne 0 ]; then
  printf '[validate][ERROR] 校验未通过\n' >&2
  exit 1
fi
log "全部校验通过"
