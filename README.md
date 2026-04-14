# chaos-lab

Chaos Engineering platform for Kubernetes. Validates system resilience by injecting controlled failures and measuring impact against SLOs.

## Philosophy

> "Everything fails, all the time." — Werner Vogels

Chaos Engineering is the practice of experimenting on a system to build confidence in its ability to withstand turbulent conditions. This lab implements the [Chaos Engineering Principles](https://principlesofchaos.org/):

1. **Define steady state** — measure normal behaviour (SLOs)
2. **Hypothesize** — predict the system handles the fault
3. **Inject fault** — run the experiment
4. **Observe** — compare actual vs predicted behaviour
5. **Fix** — if hypothesis fails, you found a real weakness

## Experiments

| Experiment | Fault Type | Target | Blast Radius |
|-----------|-----------|--------|-------------|
| pod-delete | Pod failure | frontend deployment | single pod |
| network-latency | 200ms latency | backend → DB | namespace |
| cpu-stress | CPU hog 80% | backend pods | 2 pods |
| disk-fill | Disk 90% full | stateful workload | single pod |
| node-drain | Node eviction | worker node | all pods on node |

## SLO targets

| Service | Availability SLO | Latency SLO (p99) |
|---------|-----------------|-------------------|
| frontend | 99.9% | < 500ms |
| backend API | 99.5% | < 200ms |
| database | 99.95% | < 50ms |

## Repository structure

```
chaos-lab/
├── experiments/              # LitmusChaos ChaosEngine definitions
│   ├── pod-delete/
│   ├── network-latency/
│   ├── cpu-stress/
│   ├── disk-fill/
│   └── node-drain/
├── litmus/                   # LitmusChaos operator setup
├── monitoring/dashboards/    # Grafana dashboards (JSON)
├── runbooks/                 # Incident response runbooks
├── slo/                      # SLO/SLA definitions (Prometheus rules)
├── scripts/                  # Helper scripts
└── .github/workflows/        # Scheduled + manual chaos CI
```

## Quick start

### Install LitmusChaos

```bash
kubectl apply -f litmus/install.yaml
kubectl apply -f litmus/rbac.yaml
kubectl wait --for=condition=ready pod -l app=chaos-operator -n litmus --timeout=120s
```

### Run an experiment

```bash
# Run pod-delete experiment against frontend
./scripts/run-experiment.sh pod-delete frontend production

# Check steady state before/after
./scripts/check-steady-state.sh frontend
```

### Run via CI

```bash
# Trigger manual chaos run from GitHub Actions
gh workflow run chaos-manual.yml \
  -f experiment=pod-delete \
  -f target_namespace=production \
  -f target_app=frontend
```

## Grafana dashboards

Import dashboards from `monitoring/dashboards/`:

| Dashboard | Purpose |
|-----------|---------|
| chaos-overview | Active experiments, fault injection timeline, recovery time |
| slo-tracking | Error budget consumption, SLO compliance over time |

## Safety controls

- **Blast radius limits**: experiments target max 1 pod by default
- **Steady-state checks**: pre/post experiment health validation
- **Auto-stop**: experiment aborts if error rate exceeds 5%
- **Prod gate**: production experiments require manual approval in CI
- **Rollback**: all experiments include automatic revert on failure

## License

MIT
