# Runbook: Pod Failure / CrashLoopBackOff

**Severity**: P2 (degraded service) → P1 if availability SLO breached  
**Alerts**: `FrontendSLOBurnRateFast`, `BackendSLOBurnRateFast`, `ChaosExperimentFailed`

---

## Symptoms

- Pods in `CrashLoopBackOff` or `OOMKilled` state
- Deployment `available` replicas below `minAvailable` PDB threshold
- Frontend/backend error rate spike on the Chaos Overview dashboard
- `kubectl get pods` shows repeated restarts in `RESTARTS` column

---

## Immediate triage (< 5 min)

```bash
# 1. Which pods are unhealthy?
kubectl get pods -n default --field-selector='status.phase!=Running'

# 2. Check restart counts
kubectl get pods -n default -o wide

# 3. Recent events — look for OOMKill, liveness probe failures
kubectl get events -n default --sort-by='.lastTimestamp' | tail -30

# 4. Tail logs of a crashing pod (last 100 lines before crash)
kubectl logs <pod-name> -n default --previous --tail=100
```

---

## Diagnosis decision tree

### Crash immediately on start
```bash
kubectl describe pod <pod-name> -n default
# Look for: Exit Code, OOMKilled, image pull errors
```

- **Exit code 1** — application error; check logs for stack trace
- **Exit code 137 (OOMKilled)** — container exceeded memory limit → see [Memory pressure](#memory-pressure)
- **Exit code 126/127** — entrypoint not found; check image tag and CMD
- **ImagePullBackOff** — registry credentials or missing image tag

### Crash after startup (liveness probe failure)
```bash
kubectl describe pod <pod-name> -n default | grep -A 10 "Liveness"
# Check probe path, port, initialDelaySeconds
```

Common causes:
- App not ready within `initialDelaySeconds` — increase temporarily to diagnose
- Health endpoint returning non-2xx under load
- Dependency (DB, cache) not reachable

### Multiple pods down (PDB triggered)
```bash
# Check PDB status
kubectl get pdb -n default
kubectl describe pdb <name> -n default

# Check if a chaos experiment is in progress
kubectl get chaosengine -n default
kubectl get chaosresult -n default
```

If a chaos experiment caused this — check `ChaosResult`:
```bash
kubectl get chaosresult -n default -o yaml
```

---

## Memory pressure

```bash
# Check current memory usage vs limits
kubectl top pods -n default

# Describe to see limits
kubectl get pod <pod-name> -n default -o jsonpath='{.spec.containers[*].resources}'

# Check node memory
kubectl top nodes
```

**Mitigation**:
1. Temporarily increase memory limit via `kubectl patch` (not a permanent fix)
2. If systematic, update Helm values and roll out properly
3. Check for memory leaks: heap dumps, profiling

---

## During an active chaos experiment

If a scheduled chaos experiment is running when this alert fires, **do not assume it's unrelated**. Check:

```bash
# Is a chaos experiment running right now?
kubectl get chaosengine -n default -o jsonpath='{range .items[*]}{.metadata.name}: {.status.engineStatus}{"\n"}{end}'

# Was the pod-delete experiment the cause?
kubectl get chaosresult pod-delete-engine-pod-delete -n default -o yaml 2>/dev/null
```

If `engineStatus=active` and the fault was intentional: **monitor for self-healing**. The system should recover within `TOTAL_CHAOS_DURATION` + rollout time. Do not intervene unless SLO breach is confirmed.

---

## Recovery actions

### Force rollout restart (no image change)
```bash
kubectl rollout restart deployment/frontend -n default
kubectl rollout restart deployment/backend -n default
kubectl rollout status deployment/frontend -n default --timeout=5m
```

### Roll back to previous version
```bash
kubectl rollout history deployment/frontend -n default
kubectl rollout undo deployment/frontend -n default  # or --to-revision=N
```

### Scale out manually (temporary)
```bash
kubectl scale deployment/frontend --replicas=5 -n default
# NOTE: HPA will override this; patch HPA minReplicas if needed
```

### Check HPA is not blocking scale-out
```bash
kubectl get hpa -n default
kubectl describe hpa backend -n default  # look for "ScalingActive=False"
```

---

## Escalation

| Condition | Action |
|-----------|--------|
| SLO breach (error rate > 0.5% for 10+ min) | Page on-call SRE |
| PDB prevents rollout for > 15 min | Override PDB temporarily (approval required) |
| Multiple deployments affected | Declare incident, use incident channel |
| Node failure suspected | Check node drain runbook |

---

## Post-incident

1. Update `ChaosResult` verdict in experiment notes
2. If chaos experiment caused unexpected impact: review `stopOnFailure` probe config
3. If recurring: file issue with label `reliability` and link to chaos result
4. Consider adding a new probe to catch this failure mode earlier

---

*Last reviewed: 2025-01-01 | Owner: platform-team*
