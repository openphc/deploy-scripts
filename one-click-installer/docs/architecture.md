# What ends up on the machine

A short picture of a finished install with the default config. For the phase list see the
[top-level README](../README.md#phases); for each script see [docs/README.md](README.md).

## Two halves

```
┌──────────────────────────── one Ubuntu machine ─────────────────────────────┐
│                                                                             │
│  Native (systemd)                         k3s, namespace cce-<env>          │
│  ─────────────────                        ─────────────────────────         │
│  postgresql        :5432                  gateway-service                   │
│  kafka (KRaft)     :9092, :9094 ctrl      cce-collector-service             │
│  clickhouse-server :8123 :9000 :9009      cce-protocol-service              │
│                    :9363 (metrics)        cce-matcher-service               │
│  kafka-connect     127.0.0.1:8083         cce-step-sla-service              │
│  cce-postgres-exporter :9187              cce-intelligence-service          │
│  cce-kafka-exporter    :9308              cce-insights-service / -ui        │
│  infisical-core    127.0.0.1:8080         <system>-cce-emitter-adaptor      │
│  redis-server      127.0.0.1:6379         keycloak, grafana, prometheus,    │
│  cce-portainer     :9443 (kernel-limited)  kafka-ui, node-exporter :9100    │
│                                                                             │
│  k3s itself: API :6443, Traefik ingress on :80/:443  (kube-system)          │
│  Portainer agent (namespace portainer, ClusterIP :9001)                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Native:** the data stores and anything that must reach them on `localhost`. Installed by
  [lib/native/01–03, 07](native.md), [infisical-native.sh](lib-infisical.md#infisical-nativesh) and
  [portainer.sh](lib-install.md#portainersh).
- **k3s:** the CCE application services, Keycloak and the monitoring UI. Defined by the overlay
  `k8s/overlays/<OVERLAY_NAME>` (a copy of the reference production overlay), deployed by
  [05-k8s-deploy.sh](native.md#05-k8s-deploysh).
- With the defaults, **docker is not installed** and nothing runs in a container outside k3s.

Pods reach the native services on the machine's IP (`VM_HOST_IP`, detected at deploy time). The NetworkPolicy
allows pod egress to that address only on the data and metrics ports.

## Data flow

```
 source system ──► emitter adaptor ──► gateway ──► collector ──┐
                                                               ▼
               protocol / matcher / step-sla / intelligence ◄─► PostgreSQL ccedb
                                                               │  (logical replication,
                                                               │   publication on the CDC tables)
                                                               ▼
                                             Kafka Connect + Debezium  (reads localhost:5432
                                                               │         as cce_cdc_user)
                                                               ▼
                                                     Kafka topics (:9092)
                                                               │  (named collection cce_kafka)
                                                               ▼
                                     ClickHouse cce_analytics: Kafka engine tables
                                       → materialized views → tables, rollups, dictionary
                                                               │
                                                               ▼
                                       cce-insights-service / insights UI, Grafana
```

- The CCE services also use Kafka directly (`KAFKA_BOOTSTRAP_SERVERS` in `cce-config`).
- The ClickHouse schema and the CDC setup come from `data-pipeline/` ([04-data-pipeline.sh](native.md#04-data-pipelinesh)).
- Prometheus (in k3s) scrapes the services, node-exporter, ClickHouse `:9363`, and the two host exporters.

## Configuration and secrets flow

```
config/<env>.env ──► install.sh (exports keys) ──► lib scripts
seed file ─────────► infisical-seed.sh ──► Infisical project cce-<env> (env slug "prod", folders)
                                                │
             infisical-run.sh <env> <cmd>  ◄────┘  (machine identity from <creds dir>/<env>.creds)
                    │  + host-ip-exec.sh fills VM_HOST_IP, POSTGRES_HOST, KAFKA_BOOTSTRAP_SERVERS, CLICKHOUSE_HOST
                    ▼
       envsubst into the overlay ──► ConfigMap cce-config + Secret cce-secrets ──► pod environment
```

Infisical is the source of truth for runtime values. Changing a value means: change it in Infisical, then
[redeploy.sh](lib-day2.md#redeploysh). The machine's IP is never stored; it is detected each time.

## Network exposure

Layers, outermost first:

1. **Cloud firewall / security group** (when `IS_CLOUD_DEPLOYMENT=true`) — yours to configure: allow only 22, 80, 443.
2. **UFW** (when `IS_CLOUD_DEPLOYMENT=false`) — [ufw-baseline.sh](lib-install.md#ufw-baselinesh): default deny inbound;
   22/80/443 public; everything from the pod, service and docker networks allowed.
3. **DOCKER-USER block** — [cce-docker-fw.sh](lib-install.md#cce-docker-fwsh-and-cce-docker-fwservice), only when docker
   is installed: the public interface cannot open new connections into docker bridges.
4. **Per-service binding** — Infisical, Redis and the Kafka Connect REST API listen on 127.0.0.1 only; ClickHouse's
   password-less `default` user is restricted to loopback; Portainer is limited by systemd `IPAddressAllow` to
   localhost and the k3s networks; the Portainer agent is a ClusterIP.
5. **Kubernetes NetworkPolicy** — limits pod egress to the host's data and metrics ports.

What listens on **all interfaces** and therefore depends on layer 1 or 2: PostgreSQL 5432 (password auth, pg_hba
allows the k3s networks), Kafka 9092/9094 (no authentication), ClickHouse 8123/9000/9009/9363 (pipeline user with a
password), postgres_exporter 9187, kafka_exporter 9308, node-exporter 9100, k3s API 6443. With
`IS_CLOUD_DEPLOYMENT=true`, install.sh prints this list in phase 7 as a reminder. After every install, check from
**outside** the network:

```bash
nmap -Pn <public-ip>      # only 22, 80, 443 should be open
```

## Files and directories worth knowing

| Path | What |
|---|---|
| `k8s/overlays/<OVERLAY_NAME>/` | the environment's overlay (git-tracked; commit it) |
| `data-pipeline/.deployed-ref` | which data-pipeline ref was synced, if any |
| `<home>/.cce-infisical/<env>.creds`, `.meta` | machine-identity login and project id (root, 0600) |
| `/opt/cce-local-infisical/.env`, `admin.env` | local Infisical keys and org-admin login (0600) — **back up** |
| `/etc/infisical/infisical.rb` | native Infisical config (contains keys, 0600) |
| `/opt/kafka/`, `/var/lib/kafka/data` | Kafka install and data |
| `/opt/kafka/config/kraft/server.properties`, `connect-<env>.properties` | Kafka broker and Connect config |
| `/etc/clickhouse-server/config.d/cce-<env>.xml`, `users.d/cce-<env>-users.xml` | ClickHouse config and pipeline user |
| `/etc/cce-exporters/` | exporter environment files (DB password) |
| `/opt/portainer-<version>/`, `/var/lib/portainer` | Portainer binary and data |
| systemd units | `postgresql`, `kafka`, `kafka-connect`, `clickhouse-server`, `redis-server`, `infisical-core` (via `infisical-ctl`), `cce-postgres-exporter`, `cce-kafka-exporter`, `cce-portainer`, `k3s`; `cce-docker-fw` only with docker |
