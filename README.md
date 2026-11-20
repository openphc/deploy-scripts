# CCE 2.0 deployment (release-2.0.0-beckn)

This branch holds only what the **one-click installer** needs to stand up a complete CCE 2.0 environment on one Ubuntu
machine: native PostgreSQL, Kafka, Kafka Connect/Debezium and ClickHouse, the CCE services on k3s, Keycloak, Infisical,
Prometheus/Grafana and Portainer.

This is `release-2.0.0` plus the **Beckn add-on**: `install-beckn.sh` puts CCE, OpenHIM and OpenMRS on a network, each
behind its own ONIX adapter, so that clinical events travel OpenMRS → HIE → CCE and care alerts CCE → OpenMRS as signed
Sygnal messages (the CCE profile). The Spice ↔ OpenMRS health referrals stay on standard Beckn. Start with
[beckn-demo-setup.md](one-click-installer/docs/beckn-demo-setup.md) (architecture and demo) and
[beckn.md](one-click-installer/docs/beckn.md) (reference).

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
| `k8s/beckn/` | The Beckn add-on: `onix/` (the Sygnal ONIX adapter and its config templates, shared), `onix-beckn/` (OpenMRS's Beckn adapter pair for the Spice referrals, with the Health* schemas), `cce/` (cce-beckn-service), `openhim/` (OpenHIM + the Beckn build of its adaptor), `openmrs/` (OpenMRS O3 + its two adaptors), `netpol/` |
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

The Beckn add-on (`install-beckn.sh`) deploys these as well; it does not go through the overlay, so its versions are set
with their own `IMAGE_*` keys:

| Image | Source repository | Branch | Tag |
|---|---|---|---|
| `ghcr.io/openphc/cce-beckn-service` | [cce-beckn-service](https://github.com/openphc/cce-beckn-service) | `demo` | `latest` |
| `ghcr.io/openphc/openhim-cce-emitter-adaptor` | [openhim-cce-emitter-adaptor](https://github.com/openphc/openhim-cce-emitter-adaptor) | `demo-beckn` | `demo-beckn-latest` |
| `ghcr.io/openphc/openmrs-cce-emitter-adaptor` | [openmrs-cce-emitter-adaptor](https://github.com/openphc/openmrs-cce-emitter-adaptor) | `demo-beckn` | `demo-beckn-latest` |
| `ghcr.io/openphc/openmrs-cce-receiver-adaptor` | [openmrs-cce-receiver-adaptor](https://github.com/openphc/openmrs-cce-receiver-adaptor) | `demo-beckn` | `demo-beckn-latest` |
| `fidedocker/onix-adapter` | beckn-onix | — | `1.9.4` (Sygnal adapters); `1.6.1` (OpenMRS's Beckn referral pair) |
| `jembi/openhim-core`, `jembi/openhim-console`, `mongo` | OpenHIM | — | `v8.5.1`, `v1.18.2`, `7.0` |
| `openmrs/openmrs-reference-application-3-{backend,frontend,gateway}`, `mariadb` | OpenMRS O3 | — | `3.6.0`, `10.11.7` |

Not images, but part of the same release:

- [cce-common-util](https://github.com/openphc/cce-common-util) `release-2.0.0` is the shared library compiled into
  collector, protocol, matcher and step-sla. A push to it rebuilds those four services' `latest`.
- [cce-data-pipeline](https://github.com/openphc/cce-data-pipeline) `demo-v2` is fetched by the installer
  (`DATA_PIPELINE_REF`).

## Install or update an environment

```bash
git clone -b release-2.0.0-beckn https://github.com/openphc/deploy-scripts.git
cd deploy-scripts
cp one-click-installer/config/example.env one-click-installer/config/<env>.env   # edit: ENVCODE, EMITTER_ADAPTOR, image tags, …
sudo bash one-click-installer/install.sh --config one-click-installer/config/<env>.env
```

To update an installed environment: `git pull`, then run the same `install.sh` command again. Re-runs are safe and
keep existing data and secrets.

To add the Beckn participants afterwards (the config needs `INGRESS_HOST`, `ACME_EMAIL` and the `BECKN_*` keys):

```bash
sudo bash one-click-installer/install-beckn.sh --config one-click-installer/config/<env>.env
```

Every login (Infisical, Keycloak, Grafana, Portainer, databases, emitter inbound) is printed by
`sudo bash one-click-installer/tools/show-credentials.sh <env> [--reveal]`.

Read [one-click-installer/README.md](one-click-installer/README.md) before the first install: requirements, every
configuration key, the phases, day-2 operations and troubleshooting.
