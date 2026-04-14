# Runbook: Network Degradation / High Latency

**Severity**: P2 (latency SLO breach) → P1 if availability drops  
**Alerts**: `BackendLatencyP99High`, `FrontendLatencyP99High`, `BackendSLOBurnRateFast`

---

## Symptoms

- p99 latency above SLO threshold (frontend >1s, backend >500ms)
- Request timeouts in application logs
- Increased error rate due to downstream timeouts
- `network-latency` chaos experiment in progress (check first)

---

## Immediate triage (< 5 min)

```bash
# 1. Is a chaos experiment active?
kubectl get chaosengine -n default -o wide
# If network-latency-engine is 'active' — this is expected; monitor only

# 2. Check current p99 latency
kubectl exec -n monitoring deploy/prometheus -- \
  promtool query instant \
  'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{app="backend"}[5m])) by (le))'

# 3. Check error rates
kubectl exec -n monitoring deploy/prometheus -- \
  promtool query instant \
  'sum(rate(http_requests_total{app="backend",status=~"5.."}[5m])) / sum(rate(http_requests_total{app="backend"}[5m]))'

# 4. Check network conditions at pod level
kubectl exec -n default <backend-pod> -- ping -c 5 frontend.default.svc.cluster.local
kubectl exec -n default <backend-pod> -- curl -w "@/dev/stdin" -o /dev/null -s http://frontend.default.svc.cluster.local/healthz <<'EOF'
  time_namelookup: %{time_namelookup}s
  time_connect: %{time_connect}s
  time_appconnect: %{time_appconnect}s
  time_total: %{time_total}s
EOF
```

---

## Distinguish chaos vs real degradation

| Indicator | Chaos (expected) | Real incident |
|-----------|-----------------|---------------|
| `kubectl get chaosengine` | `engineStatus=active` | No active engines |
| Latency pattern | Uniform +200ms (jitter ±50ms) | Spiky or one-sided |
| Affected pods | ~50% (`PODS_AFFECTED_PERC=50`) | All pods or specific nodes |
| Start time | Matches scheduled run (Tue/Thu 10:00 UTC) | Unexpected |
| `tc qdisc show` in pod | Shows `netem` rule | No `netem` |

To check tc rules inside a pod:
```bash
kubectl exec -n default <pod-name> -- tc qdisc show dev eth0
# Expected during chaos: qdisc netem ... delay 200ms 50ms
```

---

## Diagnosis by latency type

### High DNS resolution latency
```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50

# Test DNS resolution time
kubectl exec -n default <any-pod> -- time nslookup backend.default.svc.cluster.local
```

### High inter-pod latency (pod→pod)
```bash
# Check node where pods are running
kubectl get pods -n default -o wide

# If pods are on different nodes, check node-to-node latency
# (requires privileged access — use if available)
# ping between node IPs
```

### High upstream latency (external dependency)
```bash
# Check if backend calls external services
kubectl logs -n default deploy/backend --tail=100 | grep -E "timeout|dial|connection"

# Check service mesh / istio sidecar if present
kubectl get pods -n default -o jsonpath='{.items[*].spec.containers[*].name}' | tr ' ' '\n' | sort -u
```

---

## Network policy check

Accidental `NetworkPolicy` changes can cause latency by forcing traffic through unexpected paths:

```bash
kubectl get networkpolicy -n default
kubectl describe networkpolicy -n default
```

Verify ingress/egress rules haven't changed recently:
```bash
kubectl get networkpolicy -n default -o yaml | grep -A 20 "spec:"
```

---

## Mitigation

### Active chaos experiment — no action needed
If `network-latency-engine` is `active`, the degradation is intentional. The experiment ends automatically after `TOTAL_CHAOS_DURATION` (120s). Monitor:

```bash
# Watch until completed
watch -n 10 kubectl get chaosengine network-latency-engine -n default
```

### Stop a chaos experiment early
```bash
# Update engineState to stop
kubectl patch chaosengine network-latency-engine -n default \
  --type merge \
  -p '{"spec":{"engineState":"stop"}}'
```

### Circuit breaker / retry config
If downstream is degraded, check application retry settings. For services using Istio:

```bash
kubectl get virtualservice -n default
kubectl get destinationrule -n default
```

Typical fix: increase timeout or retry budget temporarily:
```yaml
# Example VirtualService timeout patch
kubectl patch virtualservice backend -n default --type merge -p '
  spec:
    http:
    - timeout: 5s
      retries:
        attempts: 3
        perTryTimeout: 2s
'
```

### Node-level network issue
```bash
# Check node conditions
kubectl get nodes
kubectl describe node <node-name> | grep -A 10 "Conditions:"

# Check for NetworkUnavailable condition
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

---

## Chaos experiment calibration

If the `network-latency` chaos experiment is causing p99 to breach SLO (not just approach it), consider adjusting:

```yaml
# experiments/network-latency/chaosengine.yaml
- name: NETWORK_LATENCY
  value: "100"   # reduce from 200ms to 100ms
- name: PODS_AFFECTED_PERC
  value: "25"    # reduce from 50% to 25%
```

Or tighten the SLO probe:
```yaml
promProbe/inputs:
  comparator:
    value: "0.8"  # tighten from 1.0s to 800ms
```

---

## Escalation

| Condition | Action |
|-----------|--------|
| p99 > 2x SLO for > 5 min | Page on-call |
| DNS resolution failing | Escalate to infra team (CoreDNS/CNI) |
| All pods affected (no chaos active) | Declare incident — possible CNI or node network issue |
| Node `NetworkUnavailable=True` | Escalate to cloud provider |

---

## Post-incident

1. Check if chaos probe thresholds were appropriate
2. Update SLO values in `slo/services.yaml` if baseline has shifted
3. If application lacks retry logic, file issue
4. Add new metric/probe to catch this pattern earlier in future experiments

---

*Last reviewed: 2025-01-01 | Owner: platform-team*
