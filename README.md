# CCE 2.0 deployment (release-2.0.0)

This branch holds only what the **one-click installer** needs to stand up a complete CCE 2.0 environment on one Ubuntu
machine: native PostgreSQL, Kafka, Kafka Connect/Debezium and ClickHouse, the CCE services on k3s, Keycloak, Infisical,
Prometheus/Grafana and Portainer.

Deploy from this branch. The older docker-compose, Caddy, UAT and per-environment scripts are not here; they remain in
the history of `main`.

## What is on this branch

| Path | What it is |
|---|---|
| [`one-click-installer/`](one-click-installer/) | The installer: `install.sh`, its `lib/` and `tools/` scripts, `config/example.env` and the detailed [docs](one-click-installer/docs/README.md) |
| `k8s/base/` | Kubernetes manifests of every CCE service, Keycloak and monitoring |
| `k8s/overlays/prod/` | The template the installer copies into `k8s/overlays/<env>/` for a new environment |
| `k8s/emitters/` | Emitter adaptors other than the built-in OpenHIM one (e.g. `tiberbu`), chosen with `EMITTER_ADAPTOR` |
| `k8s/seeds/` | Keycloak `cce` realm and gateway `api_permissions` |
| `k8s/infrastructure/setup-prod-infra.sh` | Native PostgreSQL + Kafka install, run by the installer |
| `data-pipeline/` | ClickHouse schema, CDC SQL and the Debezium connector, from `cce-data-pipeline` `demo-v2` (step groups) with a 200-day hot TTL. `DATA_PIPELINE_REF` deploys another version instead |
| `grafana/dashboards/` | Grafana dashboards the installer loads |
| `keycloak-themes/cce-insights-theme/` | The unbranded Insights login theme (default). Point `KEYCLOAK_THEME_DIR` at a branded copy to brand it |

## Install or update an environment

```bash
git clone -b release-2.0.0 https://github.com/openphc/deploy-scripts.git
cd deploy-scripts
cp one-click-installer/config/example.env one-click-installer/config/<env>.env   # edit: ENVCODE, EMITTER_ADAPTOR, image tags, …
sudo bash one-click-installer/install.sh --config one-click-installer/config/<env>.env
```

To update an installed environment: `git pull`, then run the same `install.sh` command again. Re-runs are safe and
keep existing data and secrets.

Every login (Infisical, Keycloak, Grafana, Portainer, databases, emitter inbound) is printed by
`sudo bash one-click-installer/tools/show-credentials.sh <env> [--reveal]`.

Read [one-click-installer/README.md](one-click-installer/README.md) before the first install: requirements, every
configuration key, the phases, day-2 operations and troubleshooting.
