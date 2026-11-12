# lib/native/ — the install steps (phase 6)

Phase 6 of `install.sh` runs [`lib/native/install-all.sh`](../lib/native/install-all.sh). It installs the data
services natively (systemd), deploys the `cce-<env>` namespace in k3s, wires the CDC pipeline and seeds Keycloak and
the gateway.

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes.**

## Execution order

The step files are numbered by history, not by run order. `install-all.sh` runs them in this order:

| # | Script | What |
|---|---|---|
| 1 | [01-install-postgres-kafka.sh](#01-install-postgres-kafkash) | PostgreSQL + Kafka (KRaft) |
| 2 | [02-install-clickhouse.sh](#02-install-clickhousesh) | ClickHouse |
| 3 | [03-install-kafka-connect.sh](#03-install-kafka-connectsh) | Kafka Connect + Debezium plugin |
| 3b | [07-monitoring-exporters.sh](#07-monitoring-exporterssh) | postgres_exporter, kafka_exporter |
| 4 | [rollout-changed.sh](lib-day2.md#rollout-changedsh) `capture`, [05-k8s-deploy.sh](#05-k8s-deploysh), then `rollout-changed.sh restart` | k3s namespace |
| 4c | [redeploy.sh](lib-day2.md#redeploysh) (only with `--pull-images`) | force image pulls |
| 6 | [04-data-pipeline.sh](#04-data-pipelinesh) | ClickHouse schema, CDC, Debezium connector |
| 7 | [06-seed.sh](#06-seedsh) (skipped with `--skip-seed`) | gateway permissions, Keycloak realm, optional protocol |

(Step 5 in the script's output is only a message: the `ccedb` tables are created by the CCE services themselves when
they first start. Step 6 waits for them.)

**Re-running phase 6 restarts data services.** Every run restarts PostgreSQL (setup-prod-infra.sh), Kafka (01),
ClickHouse (02), Kafka Connect (03) and the exporters (07). On a live environment, a re-run of install.sh means a short
interruption. Plan it.

**Running a step on its own.** Every step needs the Infisical values, so run it through
[infisical-run.sh](lib-infisical.md#infisical-runsh). Steps also read config keys (`OVERLAY_NAME`,
`KEYCLOAK_THEME_DIR`, `KAFKA_VERSION`, `EXPORTER_RUNTIME`, …), which are not in Infisical. Load the config first, or
the code defaults apply:

```bash
sudo bash -c 'set -a; . one-click-installer/config/<env>.env; set +a;
  bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/native/05-k8s-deploy.sh <env>'
```

Contents:
[install-all.sh](#install-allsh) ·
[01-install-postgres-kafka.sh](#01-install-postgres-kafkash) ·
[02-install-clickhouse.sh](#02-install-clickhousesh) ·
[03-install-kafka-connect.sh](#03-install-kafka-connectsh) ·
[07-monitoring-exporters.sh](#07-monitoring-exporterssh) ·
[05-k8s-deploy.sh](#05-k8s-deploysh) ·
[04-data-pipeline.sh](#04-data-pipelinesh) ·
[06-seed.sh](#06-seedsh)

---

## install-all.sh

[`lib/native/install-all.sh`](../lib/native/install-all.sh)

**Purpose.** Runs all steps in order for one environment.

**Called by / when to run.** `install.sh` phase 6 (no flags). By hand, prefer re-running install.sh; running this
alone skips phases 1–5 (no seed, no image pins, no pre-flight).

**Usage.**
```bash
sudo bash one-click-installer/lib/native/install-all.sh <env> [--pull-images] [--skip-seed]
```
- `--pull-images` also runs `redeploy.sh cce-<env>` after the deploy, restarting every CCE service so mutable tags are
  pulled again.
- `--skip-seed` skips step 7 (`06-seed.sh`).

**Reads.** Everything the steps read. Sets `CCE_INFISICAL_WRAPPED=1` and re-runs itself under `infisical-run.sh <env>`.

**Changes.** What each step changes.

**Safe to re-run?** Yes, with the restarts noted above.

**Verify.** Ends with `Done. Verify: … get pods -n cce-<env>`. Each step stops the run on error (`set -e`).

**Notes.** `install.sh` prints a result block after phase 7 with the pod count and the security settings these steps
apply (Kafka version, Connect override policy, PostgreSQL `log_connections`, ClickHouse users-file mode).

---

## 01-install-postgres-kafka.sh

[`lib/native/01-install-postgres-kafka.sh`](../lib/native/01-install-postgres-kafka.sh)

**Purpose.** Installs PostgreSQL and Kafka (KRaft, no ZooKeeper) as systemd services by running
[`k8s/infrastructure/setup-prod-infra.sh`](../../k8s/infrastructure/setup-prod-infra.sh), then adapts them for this
machine.

**Called by / when to run.** Step 1 of [install-all.sh](#install-allsh).

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/01-install-postgres-kafka.sh <env>`

**Reads.** `POSTGRES_PASSWORD` (or `POSTGRES_PROD_PASSWORD`), `VM_HOST_IP` (required). `POSTGRES_USER` (default
`admin`), `POSTGRES_DB` (default `ccedb`), `KAFKA_VERSION`, `POSTGRES_VERSION`, `K3S_CLUSTER_CIDR`,
`K3S_SERVICE_CIDR`, `ENABLE_PG_STAT_STATEMENTS` (default true), `LOG_CONNECTIONS` (default true). All of these are
passed to setup-prod-infra.sh with `env VAR=…` (never `sudo -E`).

**Changes.**

By setup-prod-infra.sh:
- If `psql` is absent: adds the PGDG apt repository (keyring made readable, mode 644) and installs
  `postgresql-<version>`.
- `postgresql.conf`: `listen_addresses = '*'`. `pg_hba.conf`: appends `host all all <cidr> md5` for the k3s pod and
  service networks (`K3S_CLUSTER_CIDR` / `K3S_SERVICE_CIDR`, default `10.42.0.0/16` / `10.43.0.0/16`), each only if
  that line is not there yet. Restarts and enables `postgresql`.
- Creates role `admin` (`CREATEDB`) and database `ccedb` if they do not exist. On **every** run, re-applies the role's
  password from `POSTGRES_PASSWORD` (sent to psql as a variable on stdin, not on the command line), so PostgreSQL
  follows Infisical.
- Installs `openjdk-17-jre-headless` if no `java`; creates system user `kafka`.
- Kafka: if `/opt/kafka` is absent, gets `kafka_2.13-<version>.tgz`: a matching file already in `/tmp` is reused,
  otherwise it is downloaded (archive.apache.org first, then downloads.apache.org and dlcdn); the SHA-512 is checked
  either way. Unpacks to `/opt/kafka`. If the installed version is **older** than
  `KAFKA_VERSION`, upgrades in place (old install kept as `/opt/kafka-<old>`; config, `.cluster-id` and
  `connect-plugins/` carried over; data untouched). Never downgrades.
- Writes `/opt/kafka/config/kraft/server.properties` (every run): node id 1, broker+controller, listeners
  `0.0.0.0:9092` and controller `0.0.0.0:9094`, 3 partitions per topic, auto-create topics, 7-day retention. Formats
  `/var/lib/kafka/data` once. Writes `/etc/systemd/system/kafka.service` (1 GB heap), enables and starts it.

Then this script:
- Sets `advertised.listeners=PLAINTEXT://<VM_HOST_IP>:9092` (so pods can reach the broker) and restarts `kafka`.
- Creates database `keycloak` (owner `POSTGRES_USER`) if missing.
- `pg_stat_statements`: adds it to `shared_preload_libraries` (restarting PostgreSQL once, only if it was not there)
  and runs `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` in `ccedb` and `postgres`.
- `log_connections = on` with `ALTER SYSTEM` and a reload.

**Safe to re-run?** Yes. PostgreSQL and Kafka restart each time.

**Verify.**
```bash
systemctl status postgresql kafka
sudo -u postgres psql -c 'SHOW log_connections' -c 'SHOW shared_preload_libraries'
grep ^advertised.listeners /opt/kafka/config/kraft/server.properties
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

**Notes.**
- To rotate the `admin` password: change `POSTGRES_PASSWORD` in Infisical, re-run this step (or install.sh), then
  [redeploy.sh](lib-day2.md#redeploysh) so the services get the new value.
- Existing `pg_hba.conf` lines are never removed; changing the k3s networks later leaves the old lines in place.
- Kafka is unauthenticated plaintext on 9092 and listens on all interfaces. It must not be reachable from outside
  (UFW, or your cloud firewall).
- After the machine's IP changes, `advertised.listeners` is stale until this step runs again
  ([host-ip-check.sh](tools.md#host-ip-checksh) reports it).
- Slow Kafka download: put a matching `kafka_2.13-<version>.tgz` in `/tmp` beforehand; it is reused if the SHA-512
  matches.

---

## 02-install-clickhouse.sh

[`lib/native/02-install-clickhouse.sh`](../lib/native/02-install-clickhouse.sh)

**Purpose.** Installs ClickHouse server and client natively from the ClickHouse apt repository, pinned and held, and
adds this environment's config and pipeline user.

**Called by / when to run.** Step 2 of [install-all.sh](#install-allsh).

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/02-install-clickhouse.sh <env>`

**Reads.** `CLICKHOUSE_PASSWORD`, `KAFKA_BOOTSTRAP_SERVERS` (required). `CLICKHOUSE_USER` (default `cce_pipeline`),
`CLICKHOUSE_VERSION` (default `26.5`), `CH_HTTP_PORT` (8123), `CH_TCP_PORT` (9000), `CH_INTERSERVER_PORT` (9009),
`CH_METRICS_PORT` (9363).

**Changes.**
1. If `clickhouse-server` is absent: adds the signing key (from keyserver.ubuntu.com) to
   `/usr/share/keyrings/clickhouse-keyring.gpg` (mode 644, so apt's `_apt` user can read it) and the repository to `/etc/apt/sources.list.d/clickhouse.list`,
   pre-answers the default-user password question with an empty value, installs the newest version matching
   `CLICKHOUSE_VERSION` of `clickhouse-common-static`, `clickhouse-server` and `clickhouse-client`, and holds them.
2. Writes `/etc/clickhouse-server/config.d/cce-<env>.xml`: listen on `0.0.0.0`, the four ports, MySQL and PostgreSQL
   wire ports removed, Prometheus endpoint `/metrics` on 9363, and a named collection `cce_kafka` with
   `kafka_broker_list = KAFKA_BOOTSTRAP_SERVERS` (used by the Kafka engine tables).
3. Writes `/etc/clickhouse-server/users.d/cce-<env>-users.xml` (root:clickhouse, 0640): user `CLICKHOUSE_USER` with
   the SHA-256 of the password, any network, access management and named-collection control.
4. Writes `/etc/clickhouse-server/users.d/zz-cce-default-user-localhost.xml` (root:clickhouse, 0640): restricts the
   packaged `default` user (empty password) to `127.0.0.1` and `::1`. CCE never uses it remotely; host-side tools use
   it over localhost.
5. Enables and restarts `clickhouse-server`; waits up to 60 s for `/ping`.

**Safe to re-run?** Yes. The package is not reinstalled; the three XML files are rewritten; the server restarts.

**Verify.**
```bash
systemctl status clickhouse-server
curl -s localhost:8123/ping                         # Ok.
curl -s localhost:9363/metrics | head
stat -c %a /etc/clickhouse-server/users.d/cce-<env>-users.xml     # 640
```

**Notes.**
- ClickHouse 26.10 and later reject the analytics schema. Keep the 26.5 series and the hold.
- `CLICKHOUSE_VERSION` matters only on first install.
- ClickHouse listens on all interfaces, and the pipeline user (password-protected) accepts connections from any
  address. The password-less `default` user works from the machine itself only. Keep ports 8123/9000/9009/9363 closed
  to the outside.
- If the IP changes, the named collection keeps the old broker address until this step runs again.

---

## 03-install-kafka-connect.sh

[`lib/native/03-install-kafka-connect.sh`](../lib/native/03-install-kafka-connect.sh)

**Purpose.** Runs Kafka Connect (distributed mode) natively from the same `/opt/kafka`, with the Debezium PostgreSQL
connector plugin, hardened against the Connect REST exploits.

**Called by / when to run.** Step 3 of [install-all.sh](#install-allsh).

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/03-install-kafka-connect.sh <env>`

**Reads.** `DEBEZIUM_VERSION` (default `3.0.0.Final`), `CONNECT_REST_PORT` (8083), `KAFKA_HOME` (`/opt/kafka`),
`KAFKA_USER` (`kafka`), `KAFKA_CONNECT_BOOTSTRAP` (`localhost:9092`).

**Changes.**
1. If `/opt/kafka/connect-plugins/debezium-connector-postgres` is absent, downloads the plugin from repo1.maven.org and
   unpacks it there. Chowns the plugin directory to `kafka`.
2. Writes `/opt/kafka/config/connect-<env>.properties`: bootstrap `localhost:9092`, group `cce-connect`, JSON converters
   without schemas, internal topics `connect-offsets` / `connect-configs` / `connect-status` (replication 1), REST on
   `HTTP://127.0.0.1:8083` (loopback only; `rest.advertised.host.name=127.0.0.1`), and
   `connector.client.config.override.policy=None`.
3. Writes `/etc/systemd/system/kafka-connect.service`: user `kafka`, 1 GB heap, requires `kafka.service`, and
   `KAFKA_OPTS` that forbids the JNDI and LDAP JAAS login modules. Enables and restarts it; waits up to 2 minutes for
   the REST API.

**Safe to re-run?** Yes. The plugin is not downloaded again; Connect restarts. Registered connectors survive (they are
stored in Kafka).

**Verify.**
```bash
systemctl status kafka-connect
curl -s localhost:8083/connector-plugins | grep -i postgres
grep override.policy /opt/kafka/config/connect-<env>.properties     # =None
```

**Notes.**
- The override policy `None` and the login-module ban mitigate CVE-2025-27817 / -27818 (and CVE-2023-25194). The
  lasting fix is Kafka ≥ 3.9.1, which is why `example.env` sets `KAFKA_VERSION=3.9.2`.
- The REST API has no authentication, so it listens on loopback only. Nothing outside the machine needs it: the
  installer's scripts and tools call `localhost`, and no k3s workload uses Connect. Use an SSH tunnel to reach it
  remotely.
- `DEBEZIUM_VERSION` matters only when the plugin directory is absent.

---

## 07-monitoring-exporters.sh

[`lib/native/07-monitoring-exporters.sh`](../lib/native/07-monitoring-exporters.sh)

**Purpose.** Prometheus exporters for the two native services k3s cannot see: postgres_exporter (port 9187) and
kafka_exporter (port 9308). ClickHouse serves its own metrics (9363).

**Called by / when to run.** Step 3b of [install-all.sh](#install-allsh) (it runs before the k8s deploy, despite its
number).

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/07-monitoring-exporters.sh <env>`

**Reads.** `EXPORTER_RUNTIME` (default `systemd`), `POSTGRES_EXPORTER_VERSION` / `_SHA256`, `KAFKA_EXPORTER_VERSION` /
`_SHA256`, `POSTGRES_DB`. Infisical `/postgres POSTGRES_EXPORTER_PASSWORD`.

**Changes.**
1. Gets `POSTGRES_EXPORTER_PASSWORD` from Infisical, or generates and stores it (never rotated).
2. PostgreSQL: creates or updates role `postgres_exporter` (LOGIN, that password) and grants `pg_monitor`. No superuser.
3. `systemd` runtime:
   - system user `cce-exporter`; directory `/etc/cce-exporters` (root:cce-exporter, 0750);
   - downloads each release archive from GitHub, checks the pinned SHA-256, installs `/usr/local/bin/postgres_exporter`
     and `/usr/local/bin/kafka_exporter` (skipped when that version is already there);
   - `/etc/cce-exporters/cce-postgres-exporter.env` (0640) with the connection string (contains the password),
     written through a root-only temp file (Ubuntu 26.04's `install` fails reading `/dev/stdin` over an existing file);
   - units `cce-postgres-exporter.service` (`:9187`) and `cce-kafka-exporter.service` (`--kafka.server=localhost:9092`,
     `:9308`), sandboxed (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`); enabled and
     restarted;
   - removes docker containers `postgres-exporter` / `kafka-exporter` if docker exists.
4. `docker` runtime: disables the systemd units; (re)creates containers `postgres-exporter`
   (`quay.io/prometheuscommunity/postgres-exporter:v<POSTGRES_EXPORTER_VERSION>`) and `kafka-exporter`
   (`danielqsj/kafka-exporter:v<KAFKA_EXPORTER_VERSION>`), the same versions as the systemd runtime, with `--network host`, `--restart unless-stopped`, logs capped at 3 × 10 MB.
5. Waits for `pg_up 1` on 9187 (fails the install if absent after ~20 s) and for `kafka_brokers` on 9308 (warns only,
   after ~3 minutes; the first Kafka scrape is slow on a fresh machine).

**Safe to re-run?** Yes. Password reused; binaries not re-downloaded; services restarted.

**Verify.**
```bash
systemctl status cce-postgres-exporter cce-kafka-exporter
curl -s localhost:9187/metrics | grep '^pg_up'
curl -s localhost:9308/metrics | grep '^kafka_brokers'
```

**Notes.**
- Changing an exporter version needs the matching `_SHA256`, or the checksum fails and the install stops.
- The exporters listen on all interfaces. Keep 9187 and 9308 closed to the outside.
- Prometheus scrape jobs for them are added by [05-k8s-deploy.sh](#05-k8s-deploysh).

---

## 05-k8s-deploy.sh

[`lib/native/05-k8s-deploy.sh`](../lib/native/05-k8s-deploy.sh)

**Purpose.** Deploys the `cce-<env>` namespace: renders the overlay with the Infisical values, adjusts it for this
machine, and applies it.

**Called by / when to run.** Step 4 of [install-all.sh](#install-allsh). By hand after changing the overlay (for
example after [apply-image-pins.sh](lib-install.md#apply-image-pinssh)).

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/05-k8s-deploy.sh <env>` (with the config loaded
for `OVERLAY_NAME` and `KEYCLOAK_THEME_DIR`; see [Running a step on its own](#execution-order)).

**Reads.** All Infisical values (for `envsubst`, including `CCE_PUBLIC_URL` from [host-ip.sh](lib-infisical.md#host-ipsh)).
`VM_HOST_IP` (required), `VM_HOST_CIDR`, `OVERLAY_NAME`, `INGRESS_HOST`, `ACME_EMAIL`, `KEYCLOAK_THEME_DIR`,
`CH_METRICS_PORT` (9363), `NODE_EXPORTER_SHIFT_PORT` (unset), `KUBECTL`. The emitter, read from the overlay
([emitter-lib.sh](lib-install.md#emitter-libsh)).

**Changes.**
1. **Render.** Copies `k8s/` into a temporary directory, substitutes the variables into the copy's
   `kustomization.yaml`, and runs `kubectl kustomize` on the copy. The tracked `kustomization.yaml` is never written,
   so the secrets never land in the repository, even if the run is killed. The temp directory is deleted on exit. In
   the rendered output it then:
   - replaces the base Prometheus target `172.18.0.1:9363` with `<VM_HOST_IP>:9363` (ClickHouse metrics);
   - adds Prometheus jobs `postgres-exporter` (`<ip>:9187`) and `kafka-exporter` (`<ip>:9308`) if absent;
   - if the overlay runs an emitter other than openhim, renames the base `openhim-emitter-adaptor` scrape job and
     target to that emitter's deployment and port;
   - replaces the literal `${VM_HOST_CIDR}` left in the base NetworkPolicy;
   - points the Keycloak theme hostPath (any `/home/cceadmin/deploy-scripts/keycloak-themes/…` path in the base) at
     `KEYCLOAK_THEME_DIR` in this checkout, and any other `/home/cceadmin/deploy-scripts` path at this repository.
2. **Apply.** With `INGRESS_HOST`: applies `k8s/base/traefik/traefik-helmchartconfig.yaml` (Let's Encrypt resolvers,
   cluster-wide) and the render as is (TLS ingress). Without: rewrites the ingress to plain HTTP with
   [plain-http-ingress.py](lib-install.md#plain-http-ingresspy) and applies that.
3. **NetworkPolicy.** Applies `k8s/base/network-policy.yaml` with variables substituted, adding ports 9100 (or
   `NODE_EXPORTER_SHIFT_PORT`), 9187 and 9308 to the host egress rule so Prometheus can reach the exporters.
4. **node-exporter.** Only if `NODE_EXPORTER_SHIFT_PORT` is set: patches the DaemonSet and Service to that port.
5. **Gateway hostAlias.** With `INGRESS_HOST`: patches `gateway-service` so `INGRESS_HOST` resolves to the Traefik
   ClusterIP inside the pod. The gateway fetches Keycloak's keys from the public URL, and pods cannot reach the node's
   public address from inside.
6. **Dashboards.** Builds ConfigMap `grafana-dashboards` from `grafana/dashboards/*.json` (with `${DS_PROMETHEUS}` →
   `prometheus`) and `pipeline-health.json`, server-side apply.

**Safe to re-run?** Yes (`kubectl apply`). Deployments whose spec changed (for example a new image pin) roll out.
Pods are not restarted for ConfigMap/Secret changes alone; `install-all.sh` handles that with
[rollout-changed.sh](lib-day2.md#rollout-changedsh), or use [redeploy.sh](lib-day2.md#redeploysh).

**Verify.**
```bash
k3s kubectl -n cce-<env> get pods
k3s kubectl -n cce-<env> get ingress
k3s kubectl -n cce-<env> get networkpolicy -o yaml | grep -A1 ipBlock
```
`Applied. Watch: …` is the last line. Any `WARNING:` line means a patch did not find its anchor in the base files.

**Notes.**
- It does not restart Grafana; dashboards load on Grafana's next start (or use
  [grafana-redeploy.sh](lib-day2.md#grafana-redeploysh)).

---

## 04-data-pipeline.sh

[`lib/native/04-data-pipeline.sh`](../lib/native/04-data-pipeline.sh)

**Purpose.** Builds the analytics pipeline: ClickHouse schema, PostgreSQL logical replication, and the Debezium
connector that streams `ccedb` changes into Kafka (and from there into ClickHouse).

**Called by / when to run.** Step 6 of [install-all.sh](#install-allsh), after the k8s deploy.

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/04-data-pipeline.sh <env>`

**Reads.** `CLICKHOUSE_PASSWORD`, `POSTGRES_PASSWORD`, `POSTGRES_READ_ONLY_PASSWORD` (required). `CLICKHOUSE_USER`
(`cce_pipeline`), `CH_HTTP` (`http://localhost:8123`), `POSTGRES_USER` (`admin`), `POSTGRES_DB` (`ccedb`),
`POSTGRES_READ_ONLY_USER` (`cce_cdc_user`), `POSTGRES_PORT` (5432), `CONNECT_URL` (`http://localhost:8083`),
`CDC_TABLE_WAIT_SECS` (1200). Files under `data-pipeline/`.

**Changes.**
1. **ClickHouse.** `CREATE DATABASE IF NOT EXISTS cce_analytics`, then every statement of `data-pipeline/schema/`
   files `01`…`06`, `08`, `07` (in that order), posted one by one over HTTP. Comments are stripped; `USE` statements
   are skipped. A file from this list that the data-pipeline version does not have is skipped with
   `<file>: not in this data-pipeline version — skipped`. Any other `.sql` file in `schema/` (except
   `09-historical-backfill`) is listed in a `NOTE: not applied` line, not applied. Exits 1 if any statement failed.
2. **Wait for tables.** Reads the table list from the `ALTER TABLE … REPLICA IDENTITY` lines of
   `data-pipeline/cdc/01-configure-replication.sql` and waits (up to `CDC_TABLE_WAIT_SECS`) until every table exists
   in `ccedb`. The CCE services create them on first start.
3. **Replication.** As the `postgres` superuser, runs `01-configure-replication.sql` (fed on stdin): sets
   `wal_level=logical`, replication slot/sender limits, `max_slot_wal_keep_size`, the publication and
   `REPLICA IDENTITY FULL` on the CDC tables. Sets `POSTGRES_READ_ONLY_USER` to LOGIN REPLICATION with its password.
   Grants `pg_read_all_stats` to `POSTGRES_USER` (so Grafana's query panels show query text).
4. Restarts PostgreSQL if `wal_level` is not yet `logical`; otherwise reloads.
5. **Connector.** Renders `data-pipeline/connectors/debezium-postgres-source.json` with `POSTGRES_HOST=localhost` (not
   the IP). If the connector exists, PUTs the new config and restarts failed tasks; otherwise creates it.

**Safe to re-run?** Yes. The SQL uses `IF NOT EXISTS`; the connector is updated, not duplicated; a FAILED task from
an earlier run is restarted.

**Verify.**
```bash
curl -s localhost:8083/connectors/cce-ccedb-source/status        # connector and tasks RUNNING
sudo -u postgres psql -d ccedb -c 'SHOW wal_level' -c 'SELECT * FROM pg_publication'
curl -s 'http://localhost:8123/?user=cce_pipeline&password=…' --data-binary 'SHOW TABLES FROM cce_analytics'
```

**Notes.**
- Timeout message `after 1200s these tables still do not exist: …` means some CCE services are not up yet. Check
  `k3s kubectl -n cce-<env> get pods`, fix, re-run install.sh.
- The file list is fixed. New files from a newer data-pipeline version are reported, not applied; apply them with
  [redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh) if needed. `09-historical-backfill.sql` is never applied
  here: it refills rollups after a ClickHouse rebuild, not at install.
- The connector reaches PostgreSQL on `localhost`, so it survives IP changes. If something re-registers it with an IP,
  [connector-repoint.sh](tools.md#connector-repointsh) fixes it.
- Schema changes on an existing environment: [redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh).

---

## 06-seed.sh

[`lib/native/06-seed.sh`](../lib/native/06-seed.sh)

**Purpose.** Seeds what a new environment needs before anyone can log in: gateway API permissions, the Keycloak `cce`
realm, its login theme, the emitter's inbound Basic authentication, and optionally the clinical protocol.

**Called by / when to run.** Step 7 of [install-all.sh](#install-allsh), unless `--skip-seed`.

**Usage.** `infisical-run.sh <env> bash one-click-installer/lib/native/06-seed.sh <env>`

**Reads.** `POSTGRES_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD` (required). `POSTGRES_USER`, `POSTGRES_DB`,
`KEYCLOAK_ADMIN_USER` (`admin`), `KC_PF_PORT` (18080), `PROTOCOL_FILE`, `PROTOCOL_LOAD_URL`, `PROTOCOL_AUTH`,
`KEYCLOAK_THEME_DIR` (message only), the `BASIC_AUTH_*` and `EMITTER_INBOUND_*` keys (passed to
[keycloak-inbound-basic.sh](lib-install.md#keycloak-inbound-basicsh)). Files `k8s/seeds/api_permissions.sql` and
`k8s/seeds/cce-realm.json`. The emitter is read from the overlay ([emitter-lib.sh](lib-install.md#emitter-libsh)).

**Changes.**
1. Runs `k8s/seeds/api_permissions.sql` against `ccedb` (over `localhost:5432` as `POSTGRES_USER`), then adds
   `EMITTER_INBOUND_WRITE` on `POST /v1/<emitter deployment>/**` for the overlay's emitter if that row is missing (the
   SQL file only has the openhim path). Restarts
   `gateway-service`, which reads the permissions only at start-up (otherwise every route returns 403
   "No permission mappings configured").
2. Waits up to 10 minutes for the `keycloak` rollout. Port-forwards `svc/keycloak` to `localhost:18080` (log
   `/tmp/kc-pf-<env>.log`), gets an admin token, imports `cce-realm.json` if realm `cce` does not exist (the file sets
   `loginTheme: insights-ui-theme`), then sets the realm's `loginTheme` to `insights-ui-theme` again (this covers a realm
   imported before the file had it), and runs [keycloak-inbound-basic.sh](lib-install.md#keycloak-inbound-basicsh).
3. If `PROTOCOL_FILE` and `PROTOCOL_LOAD_URL` are both set: reads the PlanDefinition's `url` and `version`, lists the
   loaded protocols (`GET <PROTOCOL_LOAD_URL>?size=500`). If that `url|version` is already loaded, prints
   `already loaded (<status>) — not posted again`. Otherwise wraps the file as
   `{"planDefinitionJson": "<file as a string>"}` and POSTs it with `Authorization: $PROTOCOL_AUTH`, printing the HTTP
   code.

**Safe to re-run?** Yes. The permissions SQL and the emitter row are idempotent. The realm is imported only once (an
existing realm is not updated from the file). Keycloak inbound objects are created only if missing. The protocol is not
posted again when the same `url|version` is loaded. If the list cannot be read (for example the token lacks read
rights), the script posts and the service rejects the duplicate.

**Verify.** `realm import HTTP=201` on first run, `cce realm already exists — skipping` after. `login theme … HTTP=204`.
Open `http(s)://<host>/insights/` — the login page shows the CCE theme. Protocol: `HTTP=2xx`.

**Notes.**
- `✗ keycloak did not become ready` usually means an image pull is still running or the theme hostPath is wrong:
  `k3s kubectl -n cce-<env> describe pod -l app=keycloak`.
- A protocol load failure does not stop the install; check the printed HTTP code.
- Changes made to the realm in the Keycloak UI are not overwritten by later runs (except `loginTheme`).
