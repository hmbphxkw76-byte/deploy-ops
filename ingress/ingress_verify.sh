#!/bin/bash
# ingress-nginx + cert-manager 快速验证（只读）
# 用法: NODE_IP=192.168.40.189 HOST=argocd.lan CA=/root/argocd-deploy/tls/ca.crt bash ingress_verify.sh
# 退出码: 0=全部通过, 1=有失败
set -u
NODE_IP="${NODE_IP:-192.168.40.189}"
HOST="${HOST:-argocd.lan}"
CA="${CA:-/root/argocd-deploy/tls/ca.crt}"
P=0; F=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; P=$((P+1)); else echo "FAIL: $1"; F=$((F+1)); fi; }

chk "ingress-nginx Running"  "test \$(kubectl -n ingress-nginx get pods --no-headers | grep -c Running) -ge 1"
chk "cert-manager Running"  "test \$(kubectl -n cert-manager get pods --no-headers | grep -c Running) -ge 3"
chk "ClusterIssuer Ready"   "kubectl get clusterissuer lab-ca -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
chk "Certificate Ready"     "kubectl -n argocd get certificate argocd-server-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
chk "域名 healthz"          "curl -s --cacert $CA https://${HOST}/healthz | grep -qx ok"
chk "UI 200"                "test \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://${HOST}/) = 200"
chk "HTTP→HTTPS 跳转"       "curl -s -o /dev/null -w '%{http_code}' http://${HOST}:30081/healthz | grep -q 308"

echo "=== 结果: $P 通过, $F 失败 ==="
[ "$F" -eq 0 ] && exit 0 || exit 1
