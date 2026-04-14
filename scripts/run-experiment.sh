#!/usr/bin/env bash
# run-experiment.sh — apply a ChaosEngine and wait for completion
# Usage: ./run-experiment.sh <experiment> <namespace> <target-service>
# Returns: exit 0 on Pass verdict, exit 1 on Fail/timeout

set -euo pipefail

EXPERIMENT="${1:?Usage: $0 <experiment> <namespace> <target-service>}"
NAMESPACE="${2:-default}"
TARGET="${3:-}"

EXPERIMENTS_DIR="$(cd "$(dirname "$0")/../experiments" && pwd)"
POLL_INTERVAL="${POLL_INTERVAL:-15}"   # seconds between status polls
MAX_WAIT="${MAX_WAIT:-600}"            # 10 minutes max wait

log()    { echo "[$(date -u +%H:%M:%S)] $*"; }
pass()   { echo "[$(date -u +%H:%M:%S)] ✓ $*"; }
fail()   { echo "[$(date -u +%H:%M:%S)] ✗ $*" >&2; }

# ── validate inputs ───────────────────────────────────────────────────────────

EXPERIMENT_DIR="${EXPERIMENTS_DIR}/${EXPERIMENT}"
if [[ ! -d "$EXPERIMENT_DIR" ]]; then
  fail "Experiment '$EXPERIMENT' not found at $EXPERIMENT_DIR"
  echo "Available experiments:"
  ls "$EXPERIMENTS_DIR"
  exit 1
fi

CHAOSENGINE_FILE="${EXPERIMENT_DIR}/chaosengine.yaml"
if [[ ! -f "$CHAOSENGINE_FILE" ]]; then
  fail "No chaosengine.yaml found at $CHAOSENGINE_FILE"
  exit 1
fi

# ── derive engine/result names from manifest ─────────────────────────────────

ENGINE_NAME=$(grep "^  name:" "$CHAOSENGINE_FILE" | head -1 | awk '{print $2}')
if [[ -z "$ENGINE_NAME" ]]; then
  fail "Could not determine engine name from $CHAOSENGINE_FILE"
  exit 1
fi

# ChaosResult name follows convention: <engine>-<experiment>
# e.g. pod-delete-engine-pod-delete
CHAOS_EXPERIMENT_NAME=$(grep "^    - name:" "$CHAOSENGINE_FILE" | head -1 | awk '{print $3}')
RESULT_NAME="${ENGINE_NAME}-${CHAOS_EXPERIMENT_NAME}"

# ── pre-flight ────────────────────────────────────────────────────────────────

log "Experiment   : $EXPERIMENT"
log "Engine name  : $ENGINE_NAME"
log "Namespace    : $NAMESPACE"
log "Target svc   : ${TARGET:-<from manifest>}"
log "Result name  : $RESULT_NAME"
log "Max wait     : ${MAX_WAIT}s"

# Check for existing engine and clean up if stopped/completed
EXISTING=$(kubectl get chaosengine "$ENGINE_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.engineStatus}' 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
  log "Found existing ChaosEngine (status=$EXISTING) — deleting before re-run"
  kubectl delete chaosengine "$ENGINE_NAME" -n "$NAMESPACE" --ignore-not-found=true
  # Also delete stale ChaosResult
  kubectl delete chaosresult "$RESULT_NAME" -n "$NAMESPACE" --ignore-not-found=true
  sleep 5
fi

# ── apply manifest ────────────────────────────────────────────────────────────

log "Applying ChaosEngine..."
kubectl apply -f "$CHAOSENGINE_FILE" -n "$NAMESPACE"
pass "ChaosEngine applied"

# ── wait for completion ───────────────────────────────────────────────────────

log "Polling for completion (every ${POLL_INTERVAL}s, max ${MAX_WAIT}s)..."

ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  ENGINE_STATUS=$(kubectl get chaosengine "$ENGINE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.engineStatus}' 2>/dev/null || echo "unknown")

  EXPERIMENT_STATUS=$(kubectl get chaosengine "$ENGINE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.experiments[0].status}' 2>/dev/null || echo "")

  log "  [${ELAPSED}s] engineStatus=$ENGINE_STATUS experimentStatus=${EXPERIMENT_STATUS:-pending}"

  if [[ "$ENGINE_STATUS" == "completed" ]] || [[ "$ENGINE_STATUS" == "stopped" ]]; then
    break
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  fail "Timed out waiting for ChaosEngine to complete after ${MAX_WAIT}s"
  log "Dumping ChaosEngine status:"
  kubectl get chaosengine "$ENGINE_NAME" -n "$NAMESPACE" -o yaml || true
  exit 1
fi

# ── collect result ────────────────────────────────────────────────────────────

log "Fetching ChaosResult..."
RESULT_JSON=$(kubectl get chaosresult "$RESULT_NAME" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")

VERDICT=$(echo "$RESULT_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['status']['experimentStatus']['verdict'])
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

PASS_PCT=$(echo "$RESULT_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['status']['experimentStatus']['probeSuccessPercentage'])
except Exception:
    print('N/A')
" 2>/dev/null || echo "N/A")

FAIL_STEP=$(echo "$RESULT_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    steps = d['status']['history']['passedRuns']
    print(f'passedRuns={steps}')
except Exception:
    print('')
" 2>/dev/null || echo "")

log "═══════════════════════════════════════"
log "  EXPERIMENT RESULT"
log "  Verdict          : $VERDICT"
log "  Probe success    : $PASS_PCT"
[[ -n "$FAIL_STEP" ]] && log "  History          : $FAIL_STEP"
log "═══════════════════════════════════════"

# Full result dump for artifacts
echo ""
echo "=== Full ChaosResult ==="
kubectl get chaosresult "$RESULT_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null || echo "(no result found)"

# ── exit code ─────────────────────────────────────────────────────────────────

case "$VERDICT" in
  Pass)
    pass "Experiment passed"
    exit 0
    ;;
  Fail)
    fail "Experiment FAILED — system did not meet resilience requirements"
    exit 1
    ;;
  *)
    fail "Unknown verdict: $VERDICT"
    exit 1
    ;;
esac
