# RW CCE UAT — Disaster recovery (102.215.10.21)

How to get RW UAT back after losing a service, data, or the whole machine. Day-to-day operation: [`OPERATIONS-RUNBOOK.md`](OPERATIONS-RUNBOOK.md)
(§ numbers below refer to it). Security and secrets: [`SECURITY.md`](SECURITY.md). Facts checked on 2026-11-12.

## 1. What can be rebuilt, and what can't

| Part | If lost | Comes back from |
|---|---|---|
| CCE code and images | rebuilt | RW-MOH GitLab, by the installer (about an hour) |
| Config (`rw/config/uat.env`, k8s templates) | rebuilt | the `deploy-scripts-rw` branch |
| ClickHouse `cce_analytics` | rebuilt | re-snapshotted from Postgres by CDC (installer re-run) |
| Kafka topics | rebuilt | transient; the services re-create what they need |
| Grafana dashboards, Prometheus config | rebuilt | provisioned by the installer |
| **Postgres `ccedb`** (events, protocol, patients' journeys, permissions) | **lost** | the daily dump only |
| **Postgres `keycloak`** (users, their passwords, client secrets, signing keys) | **lost** | the daily dump only |
| **Infisical** (every secret) | **lost** | **nothing today**: its database isn't in the backup (`SECURITY.md` §9). An export of its values (§3) is the way back. |
| Infisical's keys `/opt/cce-local-infisical/` | **lost** | an off-machine copy only. Without `ENCRYPTION_KEY`, even a database dump of Infisical can't be read. |

## 2. Objectives

| | Today | Why |
|---|---|---|
| Data loss, machine intact (RPO) | up to 24 h | dumps at 02:00 daily, kept 10 days in `/var/backups/cce-uat/` |
| Data loss, **machine lost** | **everything** since the last off-machine copy | the dumps sit on the same disk; nothing copies them off today |
| Time to recover (RTO) | service: minutes · data: under 1 h · machine: about 3 h | installer about 1 h, restore and checks after |

UAT holds test data, so these are acceptable as long as everyone knows them. The off-machine kit (§3) is what moves the second
row from "everything" to "up to a day".

## 3. The recovery kit: keep it off the machine

Copy these somewhere off the machine, encrypted and access-restricted, **monthly and after any change** to them:

| What | Path on .21 | Needed for |
|---|---|---|
| the latest dumps | `/var/backups/cce-uat/<YYYYMMDD>/pg-ccedb-*.sql.gz`, `pg-keycloak-*.sql.gz` | the data |
| an export of every Infisical value | made with the commands below | re-creating the secrets on a new machine |
| the seed file | `/root/cce-uat-seed.env` | the values chosen at install |
| Infisical's keys | `/opt/cce-local-infisical/` (`.env`, `admin.env`) | reading an Infisical database dump, if one is ever made |

Not needed in the kit: the GitLab token (issue a new one) and the machine identity `uat.creds` (a new Infisical issues a new one).

**Export every Infisical value**, folder by folder (`infisical export --recursive` returns nothing on this CLI). As root, into a
root-only file:

```bash
sudo bash -c 'umask 077; set -a; . /home/cceadmin/.cce-infisical/uat.creds; . /home/cceadmin/.cce-infisical/uat.meta; set +a
D=http://localhost:8080
T=$(infisical login --method=universal-auth --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" --plain --silent --domain=$D)
OUT=/root/cce-uat-infisical-export-$(date +%Y%m%d).env; : > $OUT
for f in / /clickhouse /grafana /kafka-connect /keycloak /openhim-emitter-adaptor /platform /portainer /postgres; do
  infisical export --path=$f --projectId=$PROJECT_ID --env=$INFISICAL_ENV_SLUG --domain=$D --token="$T" --format=dotenv >> $OUT
done; grep -c = $OUT; echo $OUT'
```

It should count about 50 keys. The folder list is the one on 2026-11-12; check it with the Infisical UI if it may have changed.
The file holds every password: copy it into the kit, then delete it from the machine.

## 4. Scenarios

### A. A service is down or crash-looping

Not a disaster: `OPERATIONS-RUNBOOK.md` §4 (logs, restart) and §11 (troubleshooting). A deployment that is wrong after a change
can be rolled back by pinning the previous commit (§5, "Change a branch, pin a commit, roll back").

### B. Bad data in Postgres

Examples: a wrong protocol was applied, a script deleted rows.

- **The derived data is wrong** (journeys, steps, deviations) but the events are fine: re-run every event through the matcher
  (`OPERATIONS-RUNBOOK.md` §12). This keeps everything that arrived since the last backup.
- **The events or the config tables are damaged:** restore `ccedb` from the last good dump (§7), then rebuild ClickHouse
  (drop `cce_analytics`, re-run the installer). Everything since that dump is lost.

### C. A native component's data is lost

Examples: ClickHouse's or Kafka's data directory is gone; Postgres is intact.

Re-run the installer: `sudo bash rw/one-click-install.sh --config rw/config/uat.env --yes`. Every phase is idempotent: it
re-installs what is missing, re-creates the ClickHouse schema and the CDC connector, and the connector re-snapshots ClickHouse
from Postgres. If the replication slot shows `lost` (§14), drop `cce_analytics` first so the snapshot starts clean.

### D. The machine is lost

1. **A new machine:** Ubuntu LTS, ideally the same IP. With a new IP, point `cceuat.moh.gov.rw` at it in DNS.
2. **The seed file:** take the Infisical export from the kit and use it as `/root/cce-uat-seed.env` (root, 600). Every value goes
   back into the new Infisical, so the restored databases (Postgres roles, Keycloak's client secrets and admin) match it.
   Remove lines with empty values first; the installer can't store them.
3. **Install:** [`../ONE-CLICK-INSTALL.md`](../ONE-CLICK-INSTALL.md), "Run it", steps 1, 2, 4 and 5 (step 3, the seed file,
   is done above). About an hour.
4. **Restore the data:**

   ```bash
   sudo k3s kubectl -n cce-uat scale deploy --all --replicas=0
   gunzip -c pg-keycloak-<stamp>.sql.gz | sudo -u postgres psql -q -d keycloak
   gunzip -c pg-ccedb-<stamp>.sql.gz   | sudo -u postgres psql -q -d ccedb
   ```

   The Keycloak dump needs the same Keycloak version or newer (26.5.4 on 2026-11-12); Keycloak upgrades its database when it
   starts, never the other way.
5. **Rebuild ClickHouse** from the restored data: drop the database, then re-run the installer, which re-creates the schema
   and re-snapshots:

   ```bash
   clickhouse-client --host 127.0.0.1 -q "DROP DATABASE cce_analytics"     # with CLICKHOUSE_USER/PASSWORD, as in §5
   sudo bash rw/one-click-install.sh --config rw/config/uat.env --yes
   ```

   Then start the services again. The installer doesn't undo a manual scale to 0, and the HPAs leave a deployment at 0 alone:

   ```bash
   sudo k3s kubectl -n cce-uat scale deploy --all --replicas=1
   ```

   The protocol comes back with `ccedb`, so nothing needs reloading; the matcher reads it as it starts.
6. **TLS:** `sudo bash rw/lib/tls-check.sh cceuat.moh.gov.rw` once DNS points at the machine.
7. **OpenHIM:** with the restored Keycloak, OpenHIM's credentials work unchanged. Check that its events arrive (§8).
8. **The checks in §5.**

Without a Keycloak dump, the users must be re-created (§13) and OpenHIM given a new password. Without a `ccedb` dump, UAT
starts empty: load the protocol (§12) and wait for new events.

## 5. Checks after any recovery

- [ ] Every pod 1/1 Running, every systemd service active, `sudo docker ps -a` empty (§3)
- [ ] The CDC connector RUNNING, the replication slot `active` (§9, §14)
- [ ] Row counts match between Postgres and ClickHouse for `inbound_event_log`, `protocol_instance`, `step_instance` (§9)
- [ ] `https://cceuat.moh.gov.rw/insights` loads with a Let's Encrypt certificate, and a user can log in
- [ ] OpenHIM's events arrive: 202 in the emitter's log (§8)
- [ ] The emitter logs `Clinical-data redaction ACTIVE` (`SECURITY.md` §10)
- [ ] The protocol is ACTIVE and the matcher started after it (§12)
- [ ] The next 02:00 backup ran (§7)

## 6. Test the backups

A backup that has never been restored is a hope. Quarterly, restore the latest `ccedb` dump into a scratch database next to the
live one, compare it, and drop it:

```bash
D=/var/backups/cce-uat/$(sudo ls /var/backups/cce-uat | grep -E '^[0-9]{8}$' | tail -1)
sudo -u postgres createdb -O admin ccedb_restore_test
sudo sh -c "gunzip -c $D/pg-ccedb-*.sql.gz" | sudo -u postgres psql -q -d ccedb_restore_test 2>&1 | grep -v 'does not exist' | head
for t in inbound_event_log protocol_instance step_instance deviation; do
  echo "$t live=$(sudo -u postgres psql -d ccedb -tAc "select count(*) from $t") restored=$(sudo -u postgres psql -d ccedb_restore_test -tAc "select count(*) from $t")"
done
sudo -u postgres dropdb ccedb_restore_test
```

The restored counts should be equal to the live ones, or lower by what arrived since 02:00. Write the date and result down.
