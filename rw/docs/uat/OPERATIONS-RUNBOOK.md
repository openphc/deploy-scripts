# RW CCE UAT — Operations Runbook (102.215.10.21)

For the team running **RW UAT on 102.215.10.21**, the environment set up by `rw/one-click-install.sh`. The CCE services are
built on this machine from the RW-MOH GitLab.

- How the installer works: [`../ONE-CLICK-INSTALL.md`](../ONE-CLICK-INSTALL.md)
- Security, credential rotation and open security items: [`SECURITY.md`](SECURITY.md)
- Recovering from data or machine loss, and testing backups: [`DISASTER-RECOVERY.md`](DISASTER-RECOVERY.md)
- How an event flows, the ports, and every configuration key: [`CONFIG-REFERENCE.md`](CONFIG-REFERENCE.md)
- Every file under `rw/`: [`../../README.md`](../../README.md)

Facts below were checked on the machine on **2026-11-12**.

> The VM's hostname is `cce-prod`, but **102.215.10.21 is UAT**. Always go by IP.

## 1. The environment at a glance

| | |
|---|---|
| Host | `ssh cceadmin@102.215.10.21`, then `cd /home/cceadmin/deploy-scripts`. Every command below runs there, with `sudo`. |
| URLs | `https://cceuat.moh.gov.rw` with the paths `/insights`, `/v1`, `/auth`, `/grafana` and `/kafka-ui` |
| Config | `rw/config/uat.env`: repos and branches, sizing, versions. **It has no secrets.** |
| Protocol | `rw/protocols/emr-service-protocol.json`, the definition loaded on UAT (§12) |
| Secrets | the local Infisical (project `cce-uat`), on 127.0.0.1:8080 |
| k8s | namespace `cce-uat`, overlay `k8s/overlays/rw-uat` (generated; don't edit by hand) |
| Source code | `/opt/cce-src/<repo>` |
| Build state | `/var/lib/cce-rw/uat/`: `pins.env` (deployed tags), `build-manifest.tsv`, `logs/<repo>.log` |
| Backups | `/var/backups/cce-uat/<YYYYMMDD>/`, daily at 02:00, kept 10 days |
| GitLab token | `/root/.cce-gitlab.token` |

What runs where:

| Component | Runs as | Check with |
|---|---|---|
| PostgreSQL 16 (`ccedb`, `keycloak`, `infisical`) | systemd `postgresql@16-main` | `systemctl status postgresql@16-main` |
| Kafka 3.9.2 (KRaft), Kafka Connect + Debezium | systemd `kafka`, `kafka-connect` | `curl -s localhost:8083/connectors` |
| ClickHouse 26.5 | systemd `clickhouse-server` | `systemctl status clickhouse-server` |
| Infisical + Redis | systemd `infisical-runsvdir`, `redis-server` | `sudo infisical-ctl status` |
| postgres_exporter, kafka_exporter | systemd `cce-postgres-exporter`, `cce-kafka-exporter` | `curl -s localhost:9187/metrics \| grep ^pg_up` |
| Portainer | systemd `cce-portainer` (9443, local only) | §2 |
| CCE services, Keycloak 26.5.4, Grafana, Prometheus, kafka-ui | k3s, namespace `cce-uat` (14 pods) | `sudo k3s kubectl -n cce-uat get pods` |

**No docker containers run here.** Docker is installed only to build images, and `sudo docker ps -a` should be empty.

## 2. Access

| What | How |
|---|---|
| Insights UI | `https://cceuat.moh.gov.rw/insights`, with a Keycloak user of realm `cce` |
| Keycloak admin | `https://cceuat.moh.gov.rw/auth/admin` (master realm admin: Infisical `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD`) |
| Grafana | `https://cceuat.moh.gov.rw/grafana` (user `admin`; password in Infisical `/grafana GRAFANA_ADMIN_PASSWORD`) |
| Portainer | `ssh -L 9443:localhost:9443 cceadmin@102.215.10.21`, then `https://localhost:9443` (user `admin`; Infisical `/portainer`) |
| Infisical UI | `ssh -L 8080:localhost:8080 cceadmin@102.215.10.21`, then `http://localhost:8080`. The login is in `/opt/cce-local-infisical/admin.env` (root only). |

**Change the Grafana/Portainer admin password** with `sudo bash one-click-installer/lib/set-admin-passwords.sh uat`, which prompts
for each. Changing Infisical alone does nothing, because both tools keep their password in their own database.

## 3. Health check

```bash
sudo k3s kubectl -n cce-uat get pods                                   # all 1/1 Running
for s in postgresql@16-main kafka kafka-connect clickhouse-server infisical-runsvdir redis-server \
         cce-postgres-exporter cce-kafka-exporter cce-portainer; do printf '%-24s %s\n' $s "$(systemctl is-active $s)"; done
curl -s localhost:8083/connectors/cce-ccedb-source/status | python3 -m json.tool | grep state   # all RUNNING
curl -s -o /dev/null -w '%{http_code}\n' https://cceuat.moh.gov.rw/auth/realms/cce            # 200
sudo docker ps -a                                                      # empty
```

What is deployed (repo, branch, commit, image):

```bash
sudo k3s kubectl -n cce-uat get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
sudo column -t -s$'\t' /var/lib/cce-rw/uat/build-manifest.tsv | tail -15
```

## 4. Logs and restarts

```bash
sudo k3s kubectl -n cce-uat logs deploy/gateway-service -f --tail=100       # any CCE service: deploy/<name>
sudo k3s kubectl -n cce-uat rollout restart deploy/<name>                   # restart one service (image stays: IfNotPresent)
sudo journalctl -u kafka-connect -n 200 --no-pager                          # any systemd service from §1
sudo infisical-ctl tail                                                     # Infisical
```

Restarting `postgresql@16-main` briefly drops CDC, and Debezium reconnects by itself. Restarting `kafka` also restarts `kafka-connect`.

## 5. Get new code, build, deploy

These are the scripts, `--config rw/config/uat.env` is always required:

| I want to… | Command |
|---|---|
| pull the latest commits, build, deploy (the usual) | `sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env [repo...]` |
| only pull and build (deploy later) | `… --build-only [repo...]` |
| only deploy what was built last | `… --deploy-only` |
| apply a changed Infisical value (no new code) | `… --deploy-only --restart [repo...]` |
| check GitLab access and branches, nothing else | `sudo bash rw/one-click-install.sh --config rw/config/uat.env --check-only` |
| fetch a new `cce-data-pipeline` commit (to read it), no deploy | `… --build-only cce-data-pipeline` |
| deploy a `cce-data-pipeline` change, or repair anything | `sudo bash rw/one-click-install.sh --config rw/config/uat.env --yes` |

How it works:
- **Getting and building:** `rw/lib/build-from-source.sh` does both. It fetches each repo's configured branch into
  `/opt/cce-src/<repo>` and builds the image the way the repo's CI does. The image is loaded straight into k3s, tagged
  `cce.local/rw/<repo>:<branch>-<commit>`; there is no registry. A commit that hasn't changed is not rebuilt (`FORCE_REBUILD=1`
  forces it).
- **Deploying:** the deploy step writes the tags into the overlay, refreshes `cce-config`/`cce-secrets` from Infisical and applies
  the overlay. Only services whose image changed restart.
- **Repo names, not deployment names:** pass repo names (`cce-insights-ui`, `openhim-cce-emitter-adaptor`, …). Naming a service
  that compiles against `cce-common-util` pulls common-util in automatically.
- **Don't edit code under `/opt/cce-src`:** the next fetch overwrites it.

### Change a branch, pin a commit, roll back

Edit `SRC_<REPO>_BRANCH` in `rw/config/uat.env`, then run `rw/redeploy-from-source.sh` for that repo. `<REPO>` is the repo name
upper-cased, with `-` replaced by `_`. The value can be:
- a **branch** (`release-2.0.0`)
- a **tag**
- a **full 40-character commit SHA**, to pin one commit, for example the one before a bad change. A previously built commit is
  usually still in k3s, so a rollback deploys at once.

Write a comment above a pin saying why, and when it can be removed.

`cce-common-util` goes into the collector, protocol, matcher and step-sla images, so changing it rebuilds all four.

### A `cce-data-pipeline` change

`rw/redeploy-from-source.sh` refuses this repo. Re-run the installer instead: `sudo bash rw/one-click-install.sh --config rw/config/uat.env --yes`.
It is safe on the live environment, because every phase is idempotent and unchanged images are reused. It takes about 15 minutes.
It does the following:
1. reapplies the ClickHouse schema
2. waits for every CDC table
3. reapplies the Postgres publication
4. updates the Debezium connector

**The schema step only creates missing objects. It never alters an existing table.** When a release changes existing tables, it
ships an upgrade file (`schema/NN-*-upgrade.sql`) that has to be run **once, before the re-run**. Read the header of that file:

```bash
cat > /tmp/ch.sh <<'Q'
clickhouse-client --host 127.0.0.1 -d cce_analytics --multiquery < /opt/cce-src/cce-data-pipeline/schema/<NN-…-upgrade>.sql
Q
sudo env CCE_INFISICAL_CREDS_DIR=/home/cceadmin/.cce-infisical bash one-click-installer/lib/infisical-run.sh uat bash /tmp/ch.sh; rm /tmp/ch.sh
```

To have the new commit in `/opt/cce-src/cce-data-pipeline` before the re-run, fetch it without deploying:
`sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --build-only cce-data-pipeline`. Example: on 2026-11-06,
`10-step-groups-upgrade.sql` (step groups) was applied this way, then the installer was re-run.

For a schema-only change to objects the files already create: `sudo bash one-click-installer/lib/redeploy-clickhouse.sh uat`
(`DRY_RUN=1` to preview).

## 6. Configuration and secrets

| Change | Where | Then |
|---|---|---|
| a service's env value or a password | Infisical (§2), project `cce-uat` | `rw/redeploy-from-source.sh … --deploy-only --restart [repo]`. For a **DB password**, also change it in Postgres (`ALTER ROLE`) first. |
| repo URL or branch | `rw/config/uat.env` `SRC_*` | §5 |
| CPU limit of one service | `uat.env` `CPU_LIMIT_OVERRIDES=<deployment>=<cpu>,…` (now: protocol and step-sla at 800m) | `… --deploy-only` |
| replicas | `uat.env` `HPA_REPLICAS` (now 1 = one pod per service) | `… --deploy-only` |
| insights-ui build settings | `uat.env` `INSIGHTS_UI_VITE_*` | `rw/redeploy-from-source.sh … cce-insights-ui` (they are built into the bundle) |
| anything else in `uat.env` (versions, firewall, ingress) | `uat.env` | re-run `rw/one-click-install.sh` |

**Rotate the GitLab token** (`read_repository`; it is used only for fetching code):

```bash
sudo sh -c 'umask 077; cat > /root/.cce-gitlab.token'     # paste, Enter, Ctrl-D
sudo bash rw/one-click-install.sh --config rw/config/uat.env --check-only
```

Then revoke the old token in GitLab. An expired token stops builds at the pre-flight (`cannot access …`), while the running
services are unaffected.

## 7. Backups

The daily 02:00 cron runs `rw/lib/backup-db.sh uat` and writes to `/var/backups/cce-uat/<date>/`:
- `pg-ccedb-*.sql.gz`, `pg-keycloak-*.sql.gz` (plain SQL with `--clean`)
- `clickhouse-cce_analytics-*.sql.gz`

```bash
sudo crontab -l | grep cce-uat                  # the schedule
sudo tail -20 /var/backups/cce-uat/backup.log   # the last runs
sudo env CCE_INFISICAL_CREDS_DIR=/home/cceadmin/.cce-infisical \
  bash one-click-installer/lib/infisical-run.sh uat bash rw/lib/backup-db.sh uat     # back up now
sudo SCHEDULE="30 1 * * *" RETENTION_DAYS=14 bash rw/lib/install-cron-backups.sh uat  # change the schedule or retention
```

**Restore a Postgres database.** Stop its users first. Replicas set to 0 also pause the HPA.

```bash
sudo k3s kubectl -n cce-uat scale deploy --all --replicas=0          # (for keycloak alone: deploy/keycloak)
gunzip -c /var/backups/cce-uat/<date>/pg-ccedb-<stamp>.sql.gz | sudo -u postgres psql -q -d ccedb
sudo k3s kubectl -n cce-uat scale deploy --all --replicas=1          # back up (HPA_REPLICAS=1); a redeploy does NOT undo a manual scale
```

After a `ccedb` restore, ClickHouse no longer matches it. Rebuild ClickHouse from Postgres (drop `cce_analytics`, then re-run the
installer, which re-snapshots it through CDC).

The backups stay on this machine. Copy them elsewhere if UAT data matters.

## 8. OpenHIM

OpenHIM posts to `https://cceuat.moh.gov.rw/v1/openhim-emitter-adaptor/inbound` with HTTP Basic credentials:
1. The gateway exchanges them with Keycloak (client `openhim-basic`, user `openhim-emitter-inbound`, role
   `gateway-service:EMITTER_INBOUND_WRITE`).
2. The emitter accepts an event only from a known OpenHIM client. Its `X-OpenHIM-ClientID` header must equal
   `EBUZIMA_CLIENT_ID`, which is `ebuzima`. That value is fixed in the deployment (`k8s/base/services/openhim-emitter-adaptor.yaml`),
   not in Infisical. Any other client gets **200 "ignored"** and nothing is stored. Accepted events get **202**.

```bash
sudo k3s kubectl -n cce-uat logs deploy/gateway-service --since=10m | grep -ci authoriz       # requests reaching the gateway
sudo k3s kubectl -n cce-uat logs deploy/openhim-emitter-adaptor --since=10m | grep -iE 'ignored|accepted|client' | tail
```

401/403 at the gateway means the Keycloak side is missing or wrong. Re-create it, which is idempotent and keeps existing users:

```bash
sudo bash one-click-installer/lib/infisical-run.sh uat bash rw/lib/keycloak-openhim-basic.sh uat
```

Tools for the OpenHIM side, in `rw/tools/openhim/` (run from any machine that reaches the OpenHIM Core API; Python 3 standard
library only):

| Tool | Use |
|---|---|
| `register-mediator.sh <host> <api_port> <http\|https> <user> <password> [channel\|--list]` | registers the CCE emitter mediator with OpenHIM Core. With a channel name it also adds the "CCE Emitter Adaptor" route (secondary) to that channel, pointing at `CCE_ENDPOINT_HOST` (set `cceuat.moh.gov.rw` for UAT; the default is PROD's). Adding the route needs `CCE_BASIC_PASS`, the password of `openhim-emitter-inbound`. `--list` lists the channels. |
| `openhim_non2xx_primary.py` | lists a channel's transactions whose primary route answered non-2xx (`OPENHIM_*` settings in the file's header) |

The OpenHIM admin login is not CCE's. Get it from the OpenHIM admins, and never put it in a file in the repo.

## 9. Data pipeline (CDC → ClickHouse)

```bash
sudo -u postgres psql -d ccedb -c "SELECT slot_name, active FROM pg_replication_slots;"                  # active = t
sudo -u postgres psql -d ccedb -tAc "SELECT count(*) FROM pg_publication_tables WHERE pubname='cce_analytics_pub'"   # 16
curl -s localhost:8083/connectors/cce-ccedb-source/status | python3 -m json.tool                        # RUNNING
curl -s -X POST 'localhost:8083/connectors/cce-ccedb-source/restart?includeTasks=true&onlyFailed=true'  # restart failed tasks
```

To count rows in ClickHouse, run `clickhouse-client` the same way as in §5. For example, use `-q "SELECT count() FROM step_instances FINAL"` in place of `--multiquery < file`.

## 10. TLS, DNS and the firewall

- **Certificate:** Traefik gets it from Let's Encrypt for `cceuat.moh.gov.rw`. After a DNS change, or if the browser shows
  "TRAEFIK DEFAULT CERT", run `sudo bash rw/lib/tls-check.sh cceuat.moh.gov.rw`. It restarts Traefik when needed and waits for
  the certificate.
- **Firewall:** UFW is default-deny, with only ports 22, 80 and 443 public. Check it with `sudo ufw status verbose`. Restore the
  baseline with `sudo bash one-click-installer/lib/ufw-baseline.sh`.
- **Docker ports:** `cce-docker-fw` blocks docker-published ports from outside. Check it with `systemctl is-active cce-docker-fw`.
- **IP change:** the IP is detected at every deploy, not stored. After an IP change, run `… --deploy-only --restart`, then
  `tls-check.sh` once DNS follows.

## 11. Troubleshooting

| Symptom | Cause, and what to do |
|---|---|
| A pod restarts every ~105 s; logs end before or just after `Started … in 9x seconds`, exit 137/143 | the CPU limit is too low, so startup outlasts the liveness probe. Raise it in `CPU_LIMIT_OVERRIDES` (§6), then `--deploy-only`. This happened to protocol and step-sla. |
| A restart or rollout hangs with "old replicas pending termination" | `sudo k3s kubectl -n cce-uat scale deploy/<name> --replicas=0`, then `--replicas=1` |
| `ErrImageNeverPull` / `ErrImagePull` for `cce.local/rw/…` | the image isn't in k3s. Check with `sudo k3s ctr -n k8s.io images ls -q \| grep cce.local`, then rebuild (§5) |
| Build failed | the error shows the end of `/var/lib/cce-rw/uat/logs/<repo>.log`. Fix the cause, then re-run; images already built are reused |
| `client version 1.24 is too old` during a build | the docker drop-in `/etc/systemd/system/docker.service.d/min-api-version.conf` is missing. Re-run the installer, which restores it |
| Pre-flight: `repository is EMPTY` / `no branch 'X'` / `cannot access` | not synced to GitLab yet / the branch name is wrong / the token expired (§6) |
| Pre-flight: `cannot reach https://…` | that site is needed and unreachable from .21. Retry. Sites for software already installed are not checked |
| `missing table [...]` at a service's start | a service is ahead of the database schema. Usually a pin mismatch between repos; check `build-manifest.tsv` and the release notes |
| Insights pages empty | check §9 (CDC), then the ClickHouse counts |
| OpenHIM returns 200 but nothing is stored | `X-OpenHIM-ClientID` isn't `ebuzima` (§8) |
| Gateway: 403 on a valid token | the token lacks the role, or `api_permissions` changed (or was empty) when the gateway started. Check the role (§13), then restart the gateway |
| Gateway: 500 "Invalid Authorization header" | the request has no `Authorization: Bearer <token>`, or a malformed one. Not a fault |
| Gateway: 401 | bad token: wrong issuer (must be `https://cceuat.moh.gov.rw/auth/realms/cce`), expired, or wrong signature |
| 429 Too Many Requests | a rate limit (`SECURITY.md` §6). Per client IP and per host; load tests hit it |
| Insights shows zeros for an older period | the ClickHouse 90-day retention removed it (§14). Postgres still has the data |
| Disk filling; `retained` WAL growing | the CDC connector stopped, so the replication slot holds WAL (§14). Restart the connector's tasks (§9) |
| Pod `Pending` | not enough CPU or memory on the node, or the quota is reached (§16): `sudo k3s kubectl -n cce-uat describe pod <pod>` |

## 12. Protocol definition

The protocol on UAT is `rw/protocols/emr-service-protocol.json`: "Rwanda Health Center Patient Journey",
`http://openphc.org/PlanDefinition/emr-service-protocol`, version `1.0.0`, loaded 2026-11-11 (id `a864bcdd-…`, ACTIVE). Its one
step group is "Outpatient Visit", one per visit. `consultation` is a step with child steps, not a group (it has no
`groupingBehavior: logical-group`), so no consultation groups are created.

Protocols are managed through the protocol-service API. Inside the cluster it needs no token, so use a port-forward:

```bash
sudo k3s kubectl -n cce-uat port-forward svc/cce-protocol-service 18091:8080 >/dev/null 2>&1 &
B=http://localhost:18091/v1/protocol/protocol-definitions
curl -s $B | python3 -m json.tool | head -40                         # list
python3 -c 'import json,sys;print(json.dumps({"planDefinitionJson":open(sys.argv[1]).read()}))' \
  rw/protocols/emr-service-protocol.json > /tmp/pd.json
curl -s -X POST $B -H 'Content-Type: application/json' --data-binary @/tmp/pd.json   # load: 201, ACTIVE, trigger index built
curl -s -X POST $B/<id>/retire                                       # retire
curl -s -X POST $B/<id>/rebuild-index                                # rebuild the trigger index
curl -s -X DELETE $B/<id>                                            # delete: 204; 409 while it has protocol instances
kill %1; rm -f /tmp/pd.json
```

**After any protocol change, restart the matcher.** It reads the protocols once at startup:
`sudo k3s kubectl -n cce-uat rollout restart deploy/cce-matcher-service`.

Keep the file in `rw/protocols/` identical to what is loaded, so PROD can be given the same definition.

### Replace the protocol and re-run every event through the matcher

A new protocol applies only to events the matcher sees after it is loaded. To re-evaluate the history, wipe what the matcher
derived and replay `cce.events.inbound` from the start. Done on 2026-11-11 in about 2 minutes: 1,746 events gave 107 protocol
instances, 142 visit groups, 931 steps and 503 deviations, with the same counts in Postgres and ClickHouse. Kept:
`inbound_event_log`, `facility`, `api_permissions`, the Flyway history and the adaptor config tables.

1. **Check the replay source is complete.** The topic must still hold every event, and Kafka keeps them for 7 days only
   (§14, retention). This must print offset 0 for every partition; if not, stop, because the expired events would be missing
   from the replay:
   `/opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic cce.events.inbound --time -2`
2. **Back up:** `sudo -u postgres pg_dump -Fc ccedb | sudo tee /var/backups/cce-uat/pre-replay-<date>.dump >/dev/null`
3. **Stop the consumers:**
   `sudo k3s kubectl -n cce-uat scale deploy cce-matcher-service cce-step-sla-service cce-intelligence-service --replicas=0`
4. **Empty the derived Postgres tables** (`sudo -u postgres psql -d ccedb`):

   ```sql
   TRUNCATE matcher_event_log, protocol_instance, protocol_instance_history, step_group_instance, step_instance,
            step_instance_history, step_sla_state_transition, deviation, intelligence_delivery,
            intelligence_delivery_audit_log, intelligence_event_log;
   ```
5. **Delete the old protocol** with the API (`DELETE`, above). That also deletes its trigger index. Wait about 20 s, so the CDC
   delete reaches ClickHouse.
6. **Purge the derived Kafka topics** to their end, with `/opt/kafka/bin/kafka-delete-records.sh`:
   - `cce.public.` + `deviation`, `matcher_event_log`, `protocol_definition`, `protocol_instance`, `protocol_instance_history`,
     `step_group_instance`, `step_instance`, `step_instance_history`, `step_sla_state_transition`
   - `cce.intelligence.triggers`, `cce.intelligence.triggers.dlq`, `cce.events.inbound.dlq`

   **Keep** `cce.events.inbound` (the replay source), `cce.public.facility`, `cce.public.inbound_event_log` and the `connect-*`
   topics.
7. **Empty ClickHouse.** Debezium skips `TRUNCATE`, so the mirror must be emptied by hand. `TRUNCATE TABLE` every table in
   `cce_analytics` except:
   - `inbound_event_logs`, `facility`, `action_definitions`, `destination_adaptor_mapping`, `receiver_adaptor`
   - the summaries built only from inbound events: `mv_daily_adoption_kpis`, `mv_daily_event_kpis`, `mv_event_volume_hourly`,
     `mv_facility_summary`, `mv_ingestion_quality`, `mv_patient_facility_latest`, `mv_practitioner_summary`

   Then `SYSTEM RELOAD DICTIONARIES`. Run `clickhouse-client` as in §5.
8. **Load the new protocol** with the API (`POST`, above).
9. **Replay:** reset the matcher's offsets, then start the consumers. The matcher skips any event already in
   `matcher_event_log`, which is why step 4 empties it.

   ```bash
   sudo /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group cce-matcher-service \
     --topic cce.events.inbound --reset-offsets --to-earliest --execute
   sudo k3s kubectl -n cce-uat scale deploy cce-matcher-service cce-step-sla-service cce-intelligence-service --replicas=1
   ```
10. **Check:**
    - the group's lag reaches 0: `sudo /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group cce-matcher-service`
    - `matcher_event_log` has as many rows as `inbound_event_log`
    - the matcher and step-sla logs show no errors, and the DLQ topics stay empty
    - the Postgres and ClickHouse row counts match

## 13. Admin tasks

### Add an Insights user

1. Keycloak admin (§2) → realm **`cce`** → **Users** → **Add user**. Fill in the username and e-mail, then **Create**.
2. **Credentials** → **Set password**, with **Temporary** off unless the user should change it at first login.
3. **Role mapping** → **Assign role** → filter by **clients** → `gateway-service` **`INSIGHTS_READ`** → **Assign**.

The user logs in at `https://cceuat.moh.gov.rw/insights`. Give only `INSIGHTS_READ` (`SECURITY.md` §5). On 2026-11-12 the
realm has 5 users: 4 with `INSIGHTS_READ`, and `openhim-emitter-inbound` with `EMITTER_INBOUND_WRITE`.

To remove access, disable the user (**Enabled** off) rather than deleting it, so the audit trail keeps the name.

### Gateway permissions (`api_permissions`)

The gateway decides which client role may call which path from the table `api_permissions` in `ccedb`: a URI pattern and an HTTP
method map to a permission name, which is a `gateway-service` client role in Keycloak. The 15 rows on UAT:

| Path | Method | Role |
|---|---|---|
| `/v1/insights/**` | GET | `INSIGHTS_READ` |
| `/v1/events/**` | POST | `COLLECTOR_EVENTS_WRITE` |
| `/v1/openhim-emitter-adaptor/**` | POST | `EMITTER_INBOUND_WRITE` |
| `/v1/protocol/**` | GET / POST, PUT, DELETE | `COMPLIANCE_READ` / `COMPLIANCE_WRITE` |
| `/v1/compliance/**` | GET / POST, PUT, DELETE | `COMPLIANCE_READ` / `COMPLIANCE_WRITE` (1.x paths; no 2.0 service answers them) |
| `/test/**` | GET / POST, PUT, DELETE | `HTTPBIN_READ` / `HTTPBIN_WRITE` (test route) |

```bash
sudo -u postgres psql -d ccedb -c "SELECT permission_name, http_method, uri_pattern FROM api_permissions ORDER BY 1"
```

**The gateway reads the table once, at startup.** After changing it, restart the gateway:
`sudo k3s kubectl -n cce-uat rollout restart deploy/gateway-service`. A new permission name must also exist as a
`gateway-service` client role in Keycloak, and be assigned to the users or clients that need it.

Rate limits sit in front of the gateway: `SECURITY.md` §6.

## 14. Maintenance

| How often | What |
|---|---|
| Daily | the backup ran (`sudo tail -3 /var/backups/cce-uat/backup.log`); the health check (§3) |
| Weekly | disk (`df -h /`); the replication slot's retained WAL (below); Grafana's host and pipeline dashboards (§15) |
| Monthly | OS updates and a reboot in a window (below); certificate expiry (§10); retention dates (below); copy the recovery kit off the machine (`DISASTER-RECOVERY.md`) |
| Quarterly | credential rotation (`SECURITY.md` §2); a restore test (`DISASTER-RECOVERY.md`); k3s and component versions |

### The CDC replication slot ⚠️

Debezium reads Postgres through the logical replication slot `cce_analytics_slot`. **While the connector is stopped or failing,
Postgres keeps every WAL file the slot hasn't read**, and the disk fills. `max_slot_wal_keep_size` is 10 GB: past that, Postgres
drops the slot's WAL rather than fill the disk, and the slot becomes `lost`.

```bash
sudo -u postgres psql -d ccedb -c "SELECT slot_name, active, wal_status,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained FROM pg_replication_slots"
```

Healthy: `active` = `t`, `wal_status` = `reserved`, `retained` in kB or MB (440 kB on 2026-11-12). If `retained` keeps growing,
fix the connector (§9). If the slot is `lost`, ClickHouse has missed changes: drop `cce_analytics` and re-run the installer,
which recreates the slot and re-snapshots everything.

### Retention: how long each store keeps data

| Store | Kept | Set in |
|---|---|---|
| Postgres `ccedb` | for ever | none |
| ClickHouse `inbound_event_logs`, `matcher_event_logs` | **90 days** after `received_at` | `cce-data-pipeline` `schema/04-create-indexes.sql` |
| ClickHouse `intelligence_event_logs`, `intelligence_deliveries` | 90 days after `created_at` | the same file |
| Kafka topics | 7 days (`log.retention.hours=168`; `cce.events.inbound` `retention.ms` 7 days) | `/opt/kafka/config/kraft/server.properties`, per-topic config |
| Prometheus metrics | 15 days | the prometheus deployment (`--storage.tsdb.retention.time`) |
| Backups | 10 days | `rw/lib/install-cron-backups.sh` (`RETENTION_DAYS`) |

Two consequences:
- **Insights loses older periods.** Insights counts patients and events from `inbound_event_logs`. Events older than 90 days
  drop out, so Insights shows zeros for those periods although Postgres still has them. UAT's first events (2026-11-04) start
  dropping around **2027-02-02**. To keep more, change the TTL in `cce-data-pipeline` (as the old PROD did, to 200 days) and
  apply it with `one-click-installer/lib/redeploy-clickhouse.sh uat`. A `MODIFY TTL` typed by hand is undone by the next schema
  apply.
- **A replay from Kafka covers only what the topic still holds** (§12, step 1). Kafka deletes by whole 1 GB segment, so on
  2026-11-12 `cce.events.inbound` still held every event since 2026-11-04. Once the first segment fills and ages past 7 days,
  older events leave the topic, and a full replay can't be done from Kafka any more.

### Disk and logs

```bash
df -h /
sudo du -sh /var/lib/postgresql /var/lib/clickhouse /var/lib/kafka /var/lib/rancher /var/lib/docker /var/backups/cce-uat /var/log
sudo journalctl --disk-usage            # vacuum if large: sudo journalctl --vacuum-time=30d
```

On 2026-11-12: 68 GB used of 490 GB (15%). The largest: ClickHouse 11 GB, k3s 11 GB (images), docker 5.6 GB (build cache),
`/var/log` 2.9 GB, journald 776 MB. Docker's build cache can be emptied with `sudo docker builder prune -af`. The next build is
then slower.

### OS updates and reboots

The machine runs Ubuntu 22.04.2 LTS. `unattended-upgrades` is on and installs security updates by itself, but never reboots.
On 2026-11-12, 118 updates were pending and **a reboot was required**.

```bash
sudo apt update && sudo apt list --upgradable
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs     # what asks for a reboot
sudo apt upgrade                                                        # in a window
sudo reboot
```

Every service starts by itself after a reboot (systemd units, and k3s restarts the pods). Allow about 5 minutes, then run the
health check (§3). Before any k3s upgrade, copy `/var/lib/rancher/k3s/server/db/` (this single node keeps the cluster state in
SQLite there), and plan for a few minutes without the API.

## 15. Monitoring

**Grafana** (`https://cceuat.moh.gov.rw/grafana`) has three data sources: Prometheus, ClickHouse (`cce_analytics`) and
PostgreSQL (`ccedb`). Its dashboards are provisioned from the configmap `grafana-dashboards`:

| Dashboard | Shows |
|---|---|
| `host-server` | the machine: CPU, memory, disk, network |
| `cce-pipeline-health`, `pipeline-health` | CDC into ClickHouse: lag, ingestion, row counts |
| `postgres-exporter`, `postgres-query-analytics` | PostgreSQL health; its slowest and most frequent queries |
| `kafka-exporter` | topics, consumer lag |
| `clickhouse-query-analytics` | ClickHouse queries, table sizes, merges |
| `cce-collector-service`, `cce-matcher-service`, `cce-step-sla-service`, `cce-intelligence-service`, `openhim-emitter-adaptor` | each service: JVM, HTTP, throughput |
| `caddy`, `tiberbu-emitter-adaptor` | not used here (no Caddy, no Tiberbu emitter) |

**Prometheus** scrapes every 15 s and keeps 15 days. Its 12 targets were all up on 2026-11-12: the 7 CCE services, the
ClickHouse server, postgres_exporter, kafka_exporter, node-exporter and itself. To see them:

```bash
sudo k3s kubectl -n cce-uat port-forward svc/prometheus 9090:9090    # then, with ssh -L 9090:localhost:9090, http://localhost:9090/targets
```

**Alerts.** Two rules are loaded: `ServiceDown` (a target down for 1 minute) and `HighMemoryUsage`. **Nothing sends them
anywhere**: there is no Alertmanager and no Grafana contact point, so they show only in Prometheus and Grafana. The emitter's
redaction alerts are not loaded either. Both are open items in `SECURITY.md` §9. Until alerts are delivered, the daily health
check (§3) is the monitoring.

## 16. Scaling

Resources per pod (request / limit), as deployed on 2026-11-12:

| Service | CPU | Memory |
|---|---|---|
| cce-collector-service, gateway-service, cce-insights-service, cce-intelligence-service | 600m / 3 | 768Mi / 1.5–3Gi |
| cce-matcher-service | 600m / 1200m | 758Mi / 1.5Gi |
| openhim-emitter-adaptor | 300m / 1500m | 768Mi / 2.25Gi |
| cce-protocol-service, cce-step-sla-service | 100m / 800m (`CPU_LIMIT_OVERRIDES`) | 256Mi / 768Mi |
| keycloak | 250m / 1 | 512Mi / 1Gi |
| cce-insights-ui, grafana, prometheus, kafka-ui | 100–200m / 0.5–1 | 256–512Mi / 0.5–1Gi |

- **Replicas:** every HPA is pinned to 1 (`HPA_REPLICAS=1` in `uat.env`); their CPU target is 70%. Empty `HPA_REPLICAS` gives
  PROD's ranges: collector, gateway and emitter 2–3, the rest 1–3.
- **Quota:** `uat-resource-quota` allows requests of 20 CPU / 28Gi and limits of 64 CPU / 80Gi. In use: requests 4.5 CPU /
  7.2Gi. A pod over the quota is refused, and a rollout then stalls (§11).
- **The machine:** 8 CPUs, 22 GB. Pod requests take 59% of the CPU and 31% of the memory. The native services (PostgreSQL,
  ClickHouse, Kafka, Infisical) use the rest, outside k8s.
- **When to grow:** when pods stay Pending for lack of CPU or memory, when `host-server` shows CPU or memory high for long
  periods, or before raising replicas. Add CPU and memory to the VM; nothing needs reconfiguring after a reboot.
- **Changing a service's resources:** `CPU_LIMIT_OVERRIDES` for CPU limits (§6); anything else is in the overlay template
  `k8s/overlays/prod/`, which the generated `rw-uat` overlay is made from.

## 17. Scripts — what to use here

**Use:**

| Script | Purpose |
|---|---|
| `rw/one-click-install.sh` | the whole environment; re-run to repair it or for data-pipeline changes (`--check-only`, `--yes`) |
| `rw/redeploy-from-source.sh` | day 2: pull, build, deploy (`--build-only`, `--deploy-only`, `--restart`) |
| `rw/lib/build-from-source.sh` | gets the code and builds; called by the two above, not run by hand |
| `rw/lib/keycloak-openhim-basic.sh` | OpenHIM's Keycloak client, role and user |
| `rw/lib/backup-db.sh`, `rw/lib/install-cron-backups.sh` | backups |
| `rw/lib/tls-check.sh` | the Let's Encrypt certificate |
| `rw/lib/overlay-tweaks.sh` | applies `HPA_REPLICAS` / `CPU_LIMIT_OVERRIDES`; called by the deploy |
| `one-click-installer/lib/infisical-run.sh uat <cmd>` | runs a command with the `cce-uat` secrets in its environment |
| `one-click-installer/lib/set-admin-passwords.sh uat` | Grafana and Portainer admin passwords |
| `one-click-installer/lib/redeploy-clickhouse.sh uat` | reapplies the ClickHouse schema files |
| `one-click-installer/lib/ufw-baseline.sh` | the firewall baseline |
| `rw/tools/openhim/*` | OpenHIM mediator registration and transaction checks (§8) |

**Do not use** `one-click-installer/lib/redeploy.sh`: it looks for `ghcr.io/openphc/*` images and finds none here. Use
`rw/redeploy-from-source.sh`.

The scripts of the old shared-VM setup on 102.215.10.20 (`rw/prod/*`, `rw/uat/*`, `rw/lib/native/*`, `rw/lib/redeploy.sh`, …)
were removed from `rw/` on 2026-11-12. They don't apply to a one-click machine.
