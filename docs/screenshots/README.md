# Screenshots

Referenced from the main README:

| File | Shows |
|---|---|
| `ci-pr-checks.png` | PR with all four CI checks green |
| `ci-trivy-blocked.png` | Trivy gate failing on CVE-2026-31789 (CRITICAL) |
| `cd-pipeline-success.png` | CD run: CI gate → build & push → staging → production, all green |
| `cd-auto-rollback.png` | CD #7: staging failed + rolled back, production skipped |
| `grafana-application.png` | Application dashboard during the error spike (logs panel next to error rate) |
| `grafana-host.png` | Host dashboard |
| `grafana-containers.png` | Containers dashboard (memory vs limit) |
| `grafana-alert-firing.png` | Alerting → AppHighErrorRate firing |
| `health-script.png` | system_health.sh runs: OK, WARNING, bad option, rotation |
