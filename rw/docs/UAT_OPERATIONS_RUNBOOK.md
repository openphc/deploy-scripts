# RW CCE UAT — Operations Runbook (102.215.10.21)

For the team running **RW UAT on 102.215.10.21**, the environment set up by `rw/one-click-install.sh`. The CCE services are
built on this machine from the RW-MOH GitLab. This runbook lists only the scripts that apply to it. The original shared-VM setup on
102.215.10.20 has its own, `OPERATIONS-RUNBOOK.md`. How the installer works: `ONE-CLICK-INSTALL.md`. Security, credential rotation
and open security items: `UAT_SECURITY.md`.

> The VM's hostname is `cce-prod`, but **102.215.10.21 is UAT**. Always go by IP.

## 1. The environment at a glance

| | |
|---|---|
| Host | `ssh cceadmin@102.215.10.21`, then `cd /home/cceadmin/deploy-scripts`. Every command below runs there, with `sudo`. |
| URLs | `https://cceuat.moh.gov.rw` with the paths `/insights`, `/v1`, `/auth`, `/grafana` and `/kafka-ui` |
| Config | `rw/config/uat.env`: repos and branches, sizing, versions. **It has no secrets.** |
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
| Kafka (KRaft), Kafka Connect + Debezium | systemd `kafka`, `kafka-connect` | `curl -s localhost:8083/connectors` |
| ClickHouse 26.5 | systemd `clickhouse-server` | `systemctl status clickhouse-server` |
| Infisical + Redis | systemd `infisical-runsvdir`, `redis-server` | `sudo infisical-ctl status` |
| postgres_exporter, kafka_exporter | systemd `cce-postgres-exporter`, `cce-kafka-exporter` | `curl -s localhost:9187/metrics \| grep ^pg_up` |
| Portainer | systemd `cce-portainer` (9443, local only) | §2 |
| CCE services, Keycloak, Grafana, Prometheus, kafka-ui | k3s, namespace `cce-uat` | `sudo k3s kubectl -n cce-uat get pods` |

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
2. The emitter accepts an event only from a known OpenHIM client. Its `X-OpenHIM-ClientID` header must equal Infisical
   `EBUZIMA_CLIENT_ID` (`ebuzima`). Any other client gets **200 "ignored"** and nothing is stored. Accepted events get **202**.

```bash
sudo k3s kubectl -n cce-uat logs deploy/gateway-service --since=10m | grep -ci authoriz       # requests reaching the gateway
sudo k3s kubectl -n cce-uat logs deploy/openhim-emitter-adaptor --since=10m | grep -iE 'ignored|accepted|client' | tail
```

401/403 at the gateway means the Keycloak side is missing or wrong. Re-create it, which is idempotent and keeps existing users:

```bash
sudo bash one-click-installer/lib/infisical-run.sh uat bash rw/lib/keycloak-openhim-basic.sh uat
```

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

## 12. Scripts — what to use here

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

**Do not use here.** They were written for the shared 102.215.10.20 VM, with GHCR images, shifted ports and docker infrastructure.
They are not in the `deploy-scripts-rw` branch; they matter only if an older full copy of `rw/` is on the machine:
- `rw/prod/*` and `rw/uat/*`, including `redeploy.sh`, `deploy-all.sh`, `install-all.sh` and `health-check.sh`
- `rw/lib/redeploy.sh` and `one-click-installer/lib/redeploy.sh`. They look for `ghcr.io/openphc/*` images and find none here.
- `rw/lib/infisical-run.sh`, `rw/lib/native/*`. Use the `one-click-installer/lib/` versions.
