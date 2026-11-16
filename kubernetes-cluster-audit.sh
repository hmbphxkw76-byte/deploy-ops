#!/usr/bin/env bash
# Kubernetes 集群健康与凭据一致性只读审计
#
# 用法:
#   bash kubernetes-cluster-audit.sh                 # 基础体检（不需要凭据）
#   bash kubernetes-cluster-audit.sh --secrets       # 追加凭据一致性检查（需基准 secret）
#   REGISTRY=10.0.0.1:5000 SECRET_NS=default SECRET_NAME=harbor-creds \
#     bash kubernetes-cluster-audit.sh --secrets
#
# 只读：不修改任何集群资源。
# 退出码: 0=无 FAIL, 1=存在 FAIL。
#
# 背景: 2026-11-16 实测——Harbor admin 密码被轮换后集群内三份 harbor-creds 未同步，
#       导致 ai-weekly 全量 ImagePullBackOff(401) 且 Argo CD 应用 Degraded。
#       本脚本把「节点 / Pod / DaemonSet / Argo CD / 凭据同步」收敛为一条可复用门禁。
set -uo pipefail

REGISTRY="${REGISTRY:-192.168.40.189:30003}"
SECRET_NS="${SECRET_NS:-default}"
SECRET_NAME="${SECRET_NAME:-harbor-creds}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
CHECK_SECRETS=0
[ "${1:-}" = "--secrets" ] && CHECK_SECRETS=1

P=0; F=0; W=0
ok()   { printf 'PASS  %s\n' "$*"; P=$((P+1)); }
bad()  { printf 'FAIL  %s\n' "$*" >&2; F=$((F+1)); }
warn() { printf 'WARN  %s\n' "$*"; W=$((W+1)); }
hdr()  { printf '\n== %s ==\n' "$*"; }

command -v kubectl >/dev/null 2>&1 || { bad "kubectl 未安装或不在 PATH"; exit 1; }

# ---------- 1. apiserver ----------
hdr "1/6 apiserver"
if kubectl get --raw='/readyz' >/dev/null 2>&1; then ok "apiserver /readyz 可达"; else bad "apiserver 不可达（检查 KUBECONFIG）"; fi

# ---------- 2. 节点 ----------
hdr "2/6 节点"
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || { bad "无法读取节点列表"; NODES=0; }
if [ "$NODES" -gt 0 ] && [ "$READY" -eq "$NODES" ]; then
  ok "节点 Ready $READY/$NODES"
else
  bad "节点未全部 Ready: $READY/$NODES"
  kubectl get nodes -o wide 2>/dev/null | sed 's/^/      /'
fi

# ---------- 3. 异常 Pod ----------
hdr "3/6 异常 Pod"
BAD_PODS=$(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded,status.phase!=Completed \
  --no-headers 2>/dev/null)
if [ -z "$BAD_PODS" ]; then
  ok "无非 Running/Succeeded/Completed 的 Pod"
else
  bad "存在异常 Pod:"; printf '%s\n' "$BAD_PODS" | sed 's/^/      /'
fi

# ---------- 4. 关键 DaemonSet 就绪率 ----------
hdr "4/6 关键 DaemonSet"
DS_LIST="kube-system/kube-proxy kube-flannel/kube-flannel-ds metallb-system/speaker monitoring/node-exporter"
for ds in $DS_LIST; do
  ns="${ds%%/*}"; name="${ds##*/}"
  line=$(kubectl -n "$ns" get ds "$name" --no-headers 2>/dev/null) || { warn "$ds 不存在，跳过"; continue; }
  # 列: NAME DESIRED CURRENT READY UP-TO-DATE AVAILABLE NODE SELECTOR AGE
  d=$(awk '{print $2}' <<<"$line"); r=$(awk '{print $4}' <<<"$line")
  if [ -n "$d" ] && [ "$d" = "$r" ]; then ok "$ds ready $r/$d"; else bad "$ds ready $r/$d"; fi
done

# ---------- 5. Argo CD 应用 ----------
hdr "5/6 Argo CD 应用"
if kubectl get applications -n "$ARGOCD_NS" >/dev/null 2>&1; then
  UNHEALTHY=$(kubectl get applications -n "$ARGOCD_NS" --no-headers 2>/dev/null | awk '$3!="Healthy"{print}')
  UNSYNCED=$(kubectl get applications -n "$ARGOCD_NS" --no-headers 2>/dev/null | awk '$2!="Synced"{print}')
  if [ -z "$UNHEALTHY" ] && [ -z "$UNSYNCED" ]; then
    ok "全部应用 Synced + Healthy"
  else
    [ -n "$UNHEALTHY" ] && { bad "存在非 Healthy 应用:"; printf '%s\n' "$UNHEALTHY" | sed 's/^/      /'; }
    [ -n "$UNSYNCED" ] && { bad "存在非 Synced 应用:"; printf '%s\n' "$UNSYNCED" | sed 's/^/      /'; }
  fi
else
  warn "未安装 Argo CD（命名空间 $ARGOCD_NS 无 applications），跳过"
fi

# ---------- 6. 凭据一致性（可选） ----------
if [ "$CHECK_SECRETS" = 1 ]; then
  hdr "6/6 凭据一致性（基准 $SECRET_NS/$SECRET_NAME @ $REGISTRY）"
  command -v curl >/dev/null 2>&1 || { bad "curl 未安装"; }

  # 注意: key 形如 ".dockerconfigjson"（含前导点），jsonpath 不便转义，改用 go-template
  raw=$(kubectl -n "$SECRET_NS" get secret "$SECRET_NAME" -o go-template='{{index .data ".dockerconfigjson"}}' 2>/dev/null)
  if [ -z "$raw" ]; then
    warn "基准 secret $SECRET_NS/$SECRET_NAME 不存在，跳过凭据检查"
  else
    decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
    b_user=$(printf '%s' "$decoded" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
    b_pass=$(printf '%s' "$decoded" | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$b_user" ] || [ -z "$b_pass" ]; then
      bad "基准 secret 无法解析出 username/password"
    else
      ok "基准凭据可读（user=$b_user，pass_len=${#b_pass}）"

      # 6.1 全命名空间同 registry 的 dockerconfigjson 与基准一致
      list=$(kubectl get secrets -A -o go-template='{{range .items}}{{if eq .type "kubernetes.io/dockerconfigjson"}}{{.metadata.namespace}}/{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
      drift=0; total=0
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        s_ns="${s%%/*}"; s_name="${s##*/}"
        s_raw=$(kubectl -n "$s_ns" get secret "$s_name" -o go-template='{{index .data ".dockerconfigjson"}}' 2>/dev/null)
        s_dec=$(printf '%s' "$s_raw" | base64 -d 2>/dev/null)
        # 只比对包含本 registry 的 secret
        if grep -q "\"$REGISTRY\"" <<<"$s_dec"; then
          total=$((total+1))
          s_user=$(printf '%s' "$s_dec" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4)
          s_pass=$(printf '%s' "$s_dec" | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
          if [ "$s_user" = "$b_user" ] && [ "$s_pass" = "$b_pass" ]; then
            printf '      ok   %s\n' "$s"
          else
            printf '      DRIFT %s (user=%s pass_len=%s)\n' "$s" "$s_user" "${#s_pass}"
            drift=$((drift+1))
          fi
        fi
      done <<<"$list"
      [ "$total" -gt 0 ] || warn "未发现指向 $REGISTRY 的 dockerconfigjson secret"
      [ "$drift" = 0 ] && ok "凭据无漂移（比对 $total 份）" || bad "凭据漂移 $drift 份（与基准不一致）"

      # 6.2 用基准凭据实测 registry 认证
      code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$b_user:$b_pass" "https://$REGISTRY/v2/" 2>/dev/null)
      [ "$code" = "200" ] && ok "registry /v2/ 认证通过（HTTP 200）" || bad "registry /v2/ 认证失败（HTTP $code）"

      # 6.3 取一个「确实有仓库」的项目，验证 token 是否带 pull 权限（actions 非空）
      projs=$(curl -sk -u "$b_user:$b_pass" "https://$REGISTRY/api/v2.0/projects?page_size=50" 2>/dev/null \
              | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
      repo=""
      for p in $projs; do
        r=$(curl -sk -u "$b_user:$b_pass" "https://$REGISTRY/api/v2.0/projects/${p}/repositories?page_size=50" 2>/dev/null \
            | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$r" ]; then repo="$r"; break; fi
      done
      if [ -n "$repo" ]; then
        tok=$(curl -sk -u "$b_user:$b_pass" "https://$REGISTRY/service/token?service=harbor-registry&scope=repository:${repo}:pull" 2>/dev/null \
              | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
        payload=$(printf '%s' "$tok" | cut -d. -f2 2>/dev/null | tr '_-' '/+' | base64 -d 2>/dev/null)
        if grep -q '"actions":\["' <<<"$payload"; then
          ok "token 具备 pull 权限（$repo）"
        elif grep -q '"actions":\[\]' <<<"$payload"; then
          bad "token 权限为空（匿名/无权限）：$repo"
        else
          warn "无法解析 token payload（$repo）"
        fi
      else
        warn "未发现任何含仓库的项目，跳过 token 检查"
      fi
    fi
  fi
else
  hdr "6/6 凭据一致性"
  warn "未启用（加 --secrets 开启）"
fi

# ---------- 汇总 ----------
printf '\n=== 结果: %d 通过, %d 失败, %d 警告 ===\n' "$P" "$F" "$W"
[ "$F" -eq 0 ] && exit 0 || exit 1
