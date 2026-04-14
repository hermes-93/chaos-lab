# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-15

### Added
- LitmusChaos operator install manifest (v3.7.0, non-root UID 2000)
- RBAC: ClusterRole for operator, per-namespace Role for chaos-runner
- Experiments with SLO-gated probes:
  - `pod-delete` — frontend resilience, httpProbe + error-rate promProbe
  - `network-latency` — 200ms+50ms jitter on backend, p99 ≤ 1s SLO
  - `cpu-stress` — 80% CPU load, HPA scale-out k8sProbe, p95 ≤ 500ms
  - `disk-fill` — 90% fill on stateful backend, crashloop detection
  - `node-drain` — non-master drain, PDB ≥ 2 replicas, frontend availability
- GitHub Actions workflows:
  - `chaos-scheduled.yml` — Tue/Thu 10:00 UTC, sequential experiments with staging gate
  - `chaos-manual.yml` — workflow_dispatch with dry-run, per-experiment selection
  - `validate.yml` — YAML lint, ShellCheck, kubeconform, Checkov, Trivy
- SLO PrometheusRules with multi-window burn-rate alerting (frontend 99.5%, backend 99.9%)
- Grafana dashboards: chaos-overview and SLO tracking with error budget gauges
- Runbooks: pod-failure and network-degradation
- Helper scripts: `check-steady-state.sh`, `run-experiment.sh`

### Security
- All manifests scanned with Checkov on every push (SARIF → GitHub Security tab)
- GitHub Actions workflows scanned with Trivy for misconfigs and secrets
- ShellCheck enforces safe shell scripting in automation scripts

[Unreleased]: https://github.com/hermes-93/chaos-lab/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/hermes-93/chaos-lab/releases/tag/v1.0.0
