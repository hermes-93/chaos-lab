#!/usr/bin/env bash
# check-steady-state.sh — validate that target services are healthy before / after chaos
# Usage: ./check-steady-state.sh <service1> [service2 ...]
# Returns: exit 0 if all services are healthy, exit 1 on any failure

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
MIN_AVAILABLE_RATIO="${MIN_AVAILABLE_RATIO:-0.8}"  # 80% of desired replicas must be ready
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"           # 1% error rate threshold
PROMETHEUS="${PROMETHEUS:-http://prometheus.monitoring.svc.cluster.local:9090}"

SERVICES=("$@")
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "Usage: $0 <service1> [service2 ...]" >&2
  exit 1
fi

FAILED=0

log()    { echo "[$(date -u +%H:%M:%S)] $*"; }
pass()   { echo "[$(date -u +%H:%M:%S)] ✓ $*"; }
fail()   { echo "[$(date -u +%H:%M:%S)] ✗ $*" >&2; FAILED=1; }

# ── helpers ──────────────────────────────────────────────────────────────────

check_deployment_replicas() {
  local svc="$1"
  local desired available ratio

  desired=$(kubectl get deployment "$svc" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  available=$(kubectl get deployment "$svc" -n "$NAMESPACE" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")

  if [[ "$desired" -eq 0 ]]; then
    fail "$svc: deployment not found or has 0 desired replicas"
    return
  fi

  # Use awk for float comparison (bash doesn't do floats)
  ratio=$(awk "BEGIN { printf \"%.2f\", $available / $desired }")
  ok=$(awk "BEGIN { print ($ratio >= $MIN_AVAILABLE_RATIO) ? 1 : 0 }")

  if [[ "$ok" -eq 1 ]]; then
    pass "$svc replicas: $available/$desired available (ratio=$ratio)"
  else
    fail "$svc replicas: only $available/$desired available (ratio=$ratio, need >=$MIN_AVAILABLE_RATIO)"
  fi
}

check_pod_restarts() {
  local svc="$1"
  local high_restart_pods

  high_restart_pods=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=$svc" \
    -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' \
    2>/dev/null | awk -F': ' '$2 > 5 {print $0}')

  if [[ -n "$high_restart_pods" ]]; then
    fail "$svc: pods with high restart count (>5):"$'\n'"$high_restart_pods"
  else
    pass "$svc: no pods with excessive restarts"
  fi
}

check_http_health() {
  local svc="$1"
  local url="http://${svc}.${NAMESPACE}.svc.cluster.local/healthz"
  local http_code

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "$HTTP_TIMEOUT" "$url" 2>/dev/null || echo "000")

  if [[ "$http_code" =~ ^2 ]]; then
    pass "$svc /healthz: HTTP $http_code"
  else
    fail "$svc /healthz: HTTP $http_code (expected 2xx)"
  fi
}

check_error_rate() {
  local svc="$1"
  local query result ok

  query="sum(rate(http_requests_total{app=\"${svc}\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{app=\"${svc}\"}[5m]))"
  result=$(curl -sf --max-time "$HTTP_TIMEOUT" \
    "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=${query}" \
    2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d['data']['result']
    print(v[0]['value'][1] if v else '0')
except Exception:
    print('0')
" 2>/dev/null || echo "0")

  # Handle NaN from Prometheus (no data)
  if [[ "$result" == "NaN" ]] || [[ "$result" == "0" ]]; then
    pass "$svc error rate: no data or 0% (OK)"
    return
  fi

  ok=$(awk "BEGIN { print ($result <= $MAX_ERROR_RATE) ? 1 : 0 }")
  pct=$(awk "BEGIN { printf \"%.3f%%\", $result * 100 }")

  if [[ "$ok" -eq 1 ]]; then
    pass "$svc error rate: $pct (below ${MAX_ERROR_RATE} threshold)"
  else
    fail "$svc error rate: $pct exceeds threshold of $(awk "BEGIN { printf \"%.1f%%\", $MAX_ERROR_RATE * 100 }")"
  fi
}

check_no_crashloop() {
  local svc="$1"
  local crashloop_pods

  crashloop_pods=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=$svc" \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null | grep -i "CrashLoopBackOff" || true)

  if [[ -n "$crashloop_pods" ]]; then
    fail "$svc: pods in CrashLoopBackOff:"$'\n'"$crashloop_pods"
  else
    pass "$svc: no CrashLoopBackOff pods"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

log "Checking steady state for: ${SERVICES[*]}"
log "Namespace: $NAMESPACE"
log "───────────────────────────────────────"

for svc in "${SERVICES[@]}"; do
  log "Checking service: $svc"
  check_deployment_replicas "$svc"
  check_no_crashloop "$svc"
  check_pod_restarts "$svc"
  check_http_health "$svc"
  check_error_rate "$svc"
  log "───────────────────────────────────────"
done

if [[ "$FAILED" -eq 1 ]]; then
  log "RESULT: ✗ Steady state check FAILED"
  exit 1
else
  log "RESULT: ✓ All services healthy — steady state confirmed"
  exit 0
fi
