# RW CCE UAT — Architecture and configuration reference (102.215.10.21)

What runs on RW UAT, how an event flows through it, which ports are open, and every configuration value: where it lives and
which service reads it. Day-to-day operation: [`OPERATIONS-RUNBOOK.md`](OPERATIONS-RUNBOOK.md). Facts checked on 2026-11-12.
No secret values are in this document, only names.

## 1. How an event flows

```
 eBuzima / OpenMRS
        │  FHIR resource
        ▼
 OpenHIM ── HTTPS + Basic auth ──▶ Traefik (443) ──▶ gateway-service ──▶ openhim-emitter-adaptor
                                    rate limits        Keycloak token,      redacts clinical content,
                                                       api_permissions      checks X-OpenHIM-ClientID
                                                                                    │ CloudEvent
                                                                                    ▼
                                                                           cce-collector-service
                                                         Postgres inbound_event_log ◀┤
                                                         Kafka cce.events.inbound   ◀┘
                                                                                    │
                                                                                    ▼
                                                    cce-matcher-service: matches the event to the protocol's triggers
                                                    (protocols from cce-protocol-service's tables) and writes
                                                    protocol_instance, step_group_instance, step_instance, …
                                                                                    │
                          cce-step-sla-service ◀── polls Postgres every 5 s: deadlines → overdue / missed, deviations
                                                                                    │
                          Kafka cce.intelligence.triggers ──▶ cce-intelligence-service ──▶ e-mail (SMTP)

 Postgres ccedb ── logical replication (slot cce_analytics_slot, publication cce_analytics_pub, 16 tables)
        ──▶ Kafka Connect + Debezium ──▶ Kafka cce.public.<table> ──▶ ClickHouse cce_analytics (Kafka engine → tables)
        ──▶ cce-insights-service ──▶ cce-insights-ui (/insights)
```

- **Writes** go through the gateway: OpenHIM's events (`/v1/openhim-emitter-adaptor/inbound`), events from other sources
  (`/v1/events`) and protocol management (`/v1/protocol`).
- **Reads** for Insights go through the gateway to `cce-insights-service` (`/v1/insights`), which reads ClickHouse only.
- The matcher **skips** an event it has already processed (`matcher_event_log`, by CloudEvent id and source). That is what makes
  replays safe (`OPERATIONS-RUNBOOK.md` §12).

## 2. Services in k8s (namespace `cce-uat`)

| Service | Port | Does | Reads / writes |
|---|---|---|---|
| `gateway-service` | 8090 | authenticates (Keycloak JWT, or Basic exchanged for a token), authorizes by `api_permissions`, routes | Postgres (`api_permissions`) |
| `openhim-emitter-adaptor` | 8082 | receives OpenHIM's FHIR, redacts clinical content, forwards a CloudEvent to the collector | collector |
| `cce-collector-service` | 8080 | stores each event and publishes it | Postgres, Kafka `cce.events.inbound` |
| `cce-protocol-service` | 8080 | protocol definitions (PlanDefinitions) and their trigger index | Postgres |
| `cce-matcher-service` | 8080 | matches events to protocol triggers; builds journeys | Kafka in, Postgres, Kafka `cce.intelligence.triggers` out |
| `cce-step-sla-service` | 8092 | judges deadlines (SLA) | Postgres (polling) |
| `cce-intelligence-service` | 8085 | tiered alert e-mails | Kafka `cce.intelligence.triggers`, Postgres, SMTP |
| `cce-insights-service` | 8084 | analytics API | ClickHouse |
| `cce-insights-ui` | 3001 | the Insights web app | the gateway, Keycloak |
| `keycloak` | 8080 | identity; realm `cce` | Postgres (`keycloak`) |
| `grafana` | 3000 | dashboards | Prometheus, ClickHouse, Postgres |
| `prometheus` | 9090 | metrics, alert rules | the services' `/actuator/prometheus`, exporters |
| `kafka-ui` | 8080 | Kafka browser (not reachable from outside) | Kafka |
| `node-exporter` | 9100 | host metrics | |

**Public paths** (Traefik, `https://cceuat.moh.gov.rw`): `/insights` → insights-ui · `/v1` (and `/v1/protocol`, `/v1/events`,
`/v1/insights`) → gateway · `/auth` → Keycloak · `/grafana` → Grafana · `/kafka-ui` → kafka-ui, which answers 404 from outside.
Rate limits are on the `/v1/*` routes (`SECURITY.md` §6).

## 3. Host services and ports

| Port | Listens on | What | Reachable from outside |
|---|---|---|---|
| 22 | all | SSH | **yes** |
| 80, 443 | all | Traefik (k3s) | **yes** |
| 5432 | all | PostgreSQL 16 (`ccedb`, `keycloak`, `infisical`) | no (UFW) |
| 6379 | 127.0.0.1 | Redis (Infisical) | no |
| 6443, 10250 | all | k3s API, kubelet | no (UFW) |
| 8000 | 127.0.0.1 | Portainer edge | no |
| 8080 | 127.0.0.1 | Infisical | no |
| 8083 | all | Kafka Connect REST (no authentication) | no (UFW) |
| 8123, 9000, 9009, 9363 | all | ClickHouse HTTP, native, interserver, metrics | no (UFW) |
| 9092, 9094 | all | Kafka broker, KRaft controller | no (UFW) |
| 9100, 9187, 9308 | all | node, PostgreSQL and Kafka exporters | no (UFW) |
| 9443 | all | Portainer (also limited by a systemd IP filter) | no |

"no (UFW)" means only the firewall stops it: `SECURITY.md` §4.

## 4. Configuration: where each value lives

| Kind | Where | Changed by |
|---|---|---|
| Secrets and service settings | Infisical, project `cce-uat` (§5) | the Infisical UI, then `OPERATIONS-RUNBOOK.md` §6 |
| Repos, branches, versions, sizing, public name | `rw/config/uat.env` (no secrets) | editing it, then §5/§6 of the runbook |
| The host's IP | detected at every deploy, never stored | nothing to change; it follows the machine |
| Fixed values | the k8s manifests in `deploy-scripts` | a change to the repo |
| Insights UI build settings | `INSIGHTS_UI_VITE_*` in `uat.env`, built into the bundle | a rebuild of `cce-insights-ui` |

At deploy time, the Infisical values become the k8s ConfigMap `cce-config` and the Secret `cce-secrets`. Pods read them as
environment variables. A changed value reaches a pod only on the next deploy with restart.

## 5. Infisical keys (project `cce-uat`)

50 keys in 8 folders on 2026-11-12. "Used by" is the k8s deployment that reads the key, or the host component that the
installer configures with it.

**`/postgres`**

| Key | What | Used by |
|---|---|---|
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | the application role (`admin`) | collector, protocol, matcher, step-sla, intelligence, gateway, keycloak, grafana |
| `POSTGRES_DATABASE` | `ccedb` (reaches the pods as `POSTGRES_DB`) | the same services |
| `POSTGRES_PORT` | 5432 | the same services |
| `POSTGRES_READ_ONLY_USER`, `POSTGRES_READ_ONLY_PASSWORD` | the CDC role `cce_cdc_user` | Debezium (Kafka Connect), set by the installer |
| `POSTGRES_EXPORTER_PASSWORD` | the role `postgres_exporter` | postgres_exporter |

**`/clickhouse`**

| Key | What | Used by |
|---|---|---|
| `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB`, `CLICKHOUSE_PORT` | the CCE user, `cce_analytics`, HTTP port | insights-service, grafana; ClickHouse `users.d`, the backups |
| `CLICKHOUSE_USE_FINAL` | `true`: queries read deduplicated rows (`FINAL`) | insights-service |

**`/keycloak`**

| Key | What | Used by |
|---|---|---|
| `KEYCLOAK_ADMIN_USER`, `KEYCLOAK_ADMIN_PASSWORD` | master realm admin | keycloak, gateway, the installer's Keycloak steps |
| `BASIC_AUTH_ENABLED` | `true`: the gateway accepts Basic auth (OpenHIM) | gateway |
| `BASIC_AUTH_CLIENT_ID`, `BASIC_AUTH_CLIENT_SECRET` | the client `openhim-basic` for the Basic → token exchange | gateway, `rw/lib/keycloak-openhim-basic.sh` |

**`/openhim-emitter-adaptor`**

| Key | What | Used by |
|---|---|---|
| `OPENHIM_CORE_HOST`, `OPENHIM_CORE_API_PORT`, `OPENHIM_CORE_SCHEME`, `OPENHIM_CORE_AUTH_TYPE` | OpenHIM Core's API, for the emitter's mediator registration | emitter |
| `OPENHIM_USERNAME`, `OPENHIM_PASSWORD` | the login to OpenHIM Core | emitter |

**`/platform`**

| Key | What | Used by |
|---|---|---|
| `INGRESS_HOST`, `ACME_EMAIL` | the public name and the Let's Encrypt contact | the installer (ingress, TLS); the token issuer the gateway checks |
| `GATEWAY_ALLOWED_ORIGINS` | CORS origins (reaches the gateway as `ALLOWED_ORIGINS`) | gateway |
| `CCE_COLLECTOR_AUTH_TOKEN` | a token for the collector | emitter |
| `CACHE_TTL_ANALYTICS`, `CACHE_TTL_LOOKUPS`, `CACHE_TTL_METRICS` | insights-service cache lifetimes, in **seconds** (30 each). The service's `application.yml` says minutes, but the code applies seconds. | insights-service |
| `CCE_INTELLIGENCE_SMTP_HOST`, `_PORT`, `_USERNAME`, `_PASSWORD` | the mail server for alerts | intelligence |
| `CCE_INTELLIGENCE_ALERT_EMAIL_TIER1..3`, `CCE_INTELLIGENCE_ALERT_NAME_TIER1..3` | who gets each alert tier | intelligence |
| `CCE_OPSALERT_NOTIFICATIONS_ENABLED` | operational alert e-mails on or off (`false` on UAT) | intelligence |
| `CCE_OPSALERT_REPEAT_INTERVAL_MINUTES`, `CCE_OPSALERT_TIER1..3_THRESHOLD_MINUTES` | when operational alerts repeat and escalate | intelligence |
| `IMAGE_PULL_POLICY` | stored, but locally built images always run with `IfNotPresent` | (installer) |

**`/grafana`**: `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` (grafana). **`/portainer`**: `PORTAINER_ADMIN_PASSWORD`
(Portainer). **`/kafka-connect`**: `CONNECT_URL`, the Connect REST address, `http://localhost:8083` (the installer's
data-pipeline step).

Change a Grafana or Portainer password with `one-click-installer/lib/set-admin-passwords.sh uat`, not in Infisical alone.
How to rotate each secret: `SECURITY.md` §2.

**Optional keys, not set on UAT:**
- `FACILITY_FILTER_IDS`: the emitter would forward only these facilities' events. Empty means all.
- `CCE_OPSALERT_TIER1..3_CC`: copy recipients of the operational alerts. They reach `cce-secrets` empty.

### Values that are not in Infisical

| Value | Set by | Used by |
|---|---|---|
| `POSTGRES_HOST`, `KAFKA_BOOTSTRAP_SERVERS`, `CLICKHOUSE_HOST` | the host's IP, detected at every deploy | the services that use those stores |
| `KEYCLOAK_ISSUER`, `KEYCLOAK_HOST`, `GRAFANA_ROOT_URL`, `KAFKA_UI_CLUSTER_NAME` | the overlay template (`k8s/overlays/prod/kustomization.yaml`), adapted by the overlay generator: the issuer is `https://<INGRESS_HOST>/auth/realms/cce` | gateway, keycloak, grafana, kafka-ui |
| `EBUZIMA_CLIENT_ID` = `ebuzima` | fixed in `k8s/base/services/openhim-emitter-adaptor.yaml` | emitter (`X-OpenHIM-ClientID` check) |
| `CCE_COLLECTOR_URL` = `http://cce-collector-service:8080` | fixed in the same manifest | emitter |
| `REDACTION_ENABLED` | the emitter's default, on. **Never set it to `false`** (`SECURITY.md` §10) | emitter |
