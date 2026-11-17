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
| `k8s/emitters/` | The emitter adaptors (`openhim`, `tiberbu`): each environment deploys exactly one, chosen with `EMITTER_ADAPTOR` |
| `k8s/seeds/` | Keycloak `cce` realm and gateway `api_permissions` |
| (`data-pipeline/`) | Not in git: the installer fetches ClickHouse schema, CDC SQL and the Debezium connector from `cce-data-pipeline` at `DATA_PIPELINE_REF` (default `demo-v2`: step groups, 200-day retention) on every run |
| `grafana/dashboards/` | Grafana dashboards the installer loads |
| `keycloak-themes/cce-insights-theme/` | The unbranded Insights login theme (default). Point `KEYCLOAK_THEME_DIR` at a branded copy to brand it |

## Images

What this branch deploys by default: the template overlay `k8s/overlays/prod/` pins each image to the tag below. Each
tag is mutable and moves with every CI build of its source branch; every build also gets a fixed `v<N>` tag
(`demo-dev-v<N>` for insights). Set `IMAGE_*` in your config to pin a tested `v<N>` or `sha256:` digest per environment.

| Image (`ghcr.io/openphc/…`) | Source repository | Branch | Tag |
|---|---|---|---|
| `openhim-cce-emitter-adaptor` | [openhim-cce-emitter-adaptor](https://github.com/openphc/openhim-cce-emitter-adaptor) | `release-1.0.0` | `latest` |
| `gateway-service` | [gateway-service](https://github.com/openphc/gateway-service) | `main` | `latest` |
| `cce-collector-service` | [cce-collector-service](https://github.com/openphc/cce-collector-service) | `release-2.0.0` | `latest` |
| `cce-protocol-service` | [cce-protocol-service](https://github.com/openphc/cce-protocol-service) | `release-2.0.0` | `latest` |
| `cce-matcher-service` | [cce-matcher-service](https://github.com/openphc/cce-matcher-service) | `release-2.0.0` | `latest` |
| `cce-step-sla-service` | [cce-step-sla-service](https://github.com/openphc/cce-step-sla-service) | `release-2.0.0` | `latest` |
| `cce-intelligence-service` | [cce-intelligence-service](https://github.com/openphc/cce-intelligence-service) | `demo` | `latest` |
| `cce-insights-service` | [cce-insights-service](https://github.com/openphc/cce-insights-service) | `demo-dev` | `demo-dev-latest` |
| `cce-insights-ui` | [cce-insights-ui](https://github.com/openphc/cce-insights-ui) | `demo-dev` | `demo-dev-latest` |

Not images, but part of the same release:

- [cce-common-util](https://github.com/openphc/cce-common-util) `release-2.0.0` is the shared library compiled into
  collector, protocol, matcher and step-sla. A push to it rebuilds those four services' `latest`.
- [cce-data-pipeline](https://github.com/openphc/cce-data-pipeline) `demo-v2` is fetched by the installer
  (`DATA_PIPELINE_REF`).

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
