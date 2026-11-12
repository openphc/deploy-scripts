# RW CCE UAT — Security (102.215.10.21)

How RW UAT on **102.215.10.21** is secured. This is the environment set up by `rw/one-click-install.sh`, with the CCE services built
from the RW-MOH GitLab. Operations: [`OPERATIONS-RUNBOOK.md`](OPERATIONS-RUNBOOK.md). Facts below were checked on the machine on
**2026-11-12** unless dated otherwise.

> The VM's hostname is `cce-prod`, but 102.215.10.21 is **UAT**. Always go by IP.

## 1. Secrets management — Infisical is the single source of truth

- **A local Infisical on this machine** holds every application secret, in project **`cce-uat`**. It is a native install (no
  container): the `infisical-core` package, Redis and a database `infisical` in the native PostgreSQL. It listens on
  **127.0.0.1:8080 only**, and Redis on 127.0.0.1:6379. It is not reachable from the network; use an SSH tunnel for the UI.
- **No `.env` files in the deploy paths.** Every install and deploy runs under `one-click-installer/lib/infisical-run.sh uat <cmd>`.
  That logs in with the environment's machine identity and puts the secrets in the command's environment. The effective config
  `/var/lib/cce-rw/uat/install.env` holds no secrets (verified).
- **Secret zero:** the machine identity's login, in `/home/cceadmin/.cce-infisical/uat.{creds,meta}` (root, 600). It only grants
  access to `cce-uat` in this Infisical.
- **Infisical's own keys:** `ENCRYPTION_KEY` and `AUTH_SECRET` are in `/opt/cce-local-infisical/.env` and
  `/etc/infisical/infisical.rb`, and the org-admin login is in `/opt/cce-local-infisical/admin.env` (all root, 600).
  **Without `ENCRYPTION_KEY` the stored secrets cannot be decrypted, even from a database backup.** Keep an encrypted offsite
  copy of `/opt/cce-local-infisical/` and never change the key in place.
- **How secrets reach the pods.** k8s `cce-config` (ConfigMap) and `cce-secrets` (Secret) are rendered from the injected
  environment at deploy time. There is no runtime sync (no Infisical operator or CSI): changing a value in Infisical reaches
  pods only on the next deploy with restart (`rw/redeploy-from-source.sh … --deploy-only --restart`). The native services
  (PostgreSQL roles, ClickHouse `users.d`, Kafka Connect) get theirs when the installer runs.
- **Folders.** Secrets sit in per-component folders (`/platform`, `/postgres`, `/clickhouse`, `/keycloak`, `/grafana`,
  `/portainer`, …), each key in one folder. `infisical run --recursive` flattens them; 76 variables reach a deploy. Values from
  the seed file (`/root/cce-uat-seed.env`, root 600) land in Infisical on install. The seed file is kept so re-runs keep chosen
  values, and so it is a copy of those secrets.
- **Break-glass export.** `infisical export --recursive` is broken on this CLI (0.43.93): export folder by folder, under
  `infisical-run`, and store the result encrypted offsite.
- **Other secrets on disk** (all root-only):

  | File | What |
  |---|---|
  | `/root/.cce-gitlab.token` | GitLab token, `read_repository` (600) |
  | `/etc/cce-exporters/cce-postgres-exporter.env` | postgres_exporter's connection string, password included (640, group `cce-exporter`) |
  | `/var/backups/cce-uat/` | the daily dumps. `keycloak` includes password hashes and client secrets; `ccedb` holds the events (700). |

  `/etc/clickhouse-server/users.d/cce-uat-users.xml` holds the ClickHouse password as a SHA-256 hash (not plaintext). It is
  640, `root:clickhouse`, so only root and the ClickHouse server can read it. The installer (step 02) sets this every run.

## 2. Credential rotation

Rotate quarterly, and at once if exposed. Always **change the value in Infisical (`cce-uat`) first**, then where it is used, in
this order. `R` below = `sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --deploy-only --restart`.

| Credential (Infisical key) | Rotate by |
|---|---|
| `POSTGRES_PASSWORD` (role `admin`, used by the CCE services and Grafana) | `sudo -u postgres psql -c "ALTER ROLE admin PASSWORD '…'"` → update Infisical → `R` → `sudo k3s kubectl -n cce-uat rollout restart deploy/grafana` |
| `POSTGRES_READ_ONLY_PASSWORD` (role `cce_cdc_user`, Debezium) | update Infisical → re-run `rw/one-click-install.sh --yes`. Its data-pipeline step runs `ALTER ROLE` with the Infisical value and updates the connector. |
| `POSTGRES_EXPORTER_PASSWORD` (role `postgres_exporter`) | update Infisical `/postgres` → `sudo bash one-click-installer/lib/infisical-run.sh uat bash one-click-installer/lib/native/07-monitoring-exporters.sh uat` (sets the role and the exporter's file) |
| `CLICKHOUSE_PASSWORD` | update Infisical → re-run `rw/one-click-install.sh --yes` (step 02 rewrites `users.d/cce-uat-users.xml`) → `R` |
| `KEYCLOAK_ADMIN_PASSWORD` (master realm admin) | change it in the Keycloak admin console, **and** in Infisical: the installer and `keycloak-openhim-basic.sh` log in with it |
| `GRAFANA_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD` | `sudo bash one-click-installer/lib/set-admin-passwords.sh uat` (updates Infisical and the app; changing Infisical alone does nothing) |
| `BASIC_AUTH_CLIENT_SECRET` (Keycloak client `openhim-basic`) | update Infisical → `sudo bash one-click-installer/lib/infisical-run.sh uat bash rw/lib/keycloak-openhim-basic.sh uat` (Keycloak follows Infisical) → `R gateway-service` |
| OpenHIM inbound user `openhim-emitter-inbound` | set a new password in Keycloak (realm `cce` → Users), then give it to the OpenHIM admins for the channel's Basic auth. Requests fail with 401 in between. |
| `OPENHIM_PASSWORD`, `CCE_INTELLIGENCE_SMTP_PASSWORD`, `CCE_COLLECTOR_AUTH_TOKEN` | change at the other system first, then Infisical → `R` |
| Infisical machine identity (`uat.creds`) | Infisical UI → the `cce-uat` machine identity → Universal Auth → create a client secret → write it to `uat.creds` → check with the health check → revoke the old secret |
| Infisical org admin (`admin.env`) | change in the Infisical UI, then update `/opt/cce-local-infisical/admin.env` |
| GitLab token | `OPERATIONS-RUNBOOK.md` §6 |

After any rotation, run the health check (runbook §3) and confirm OpenHIM calls are still authorized (runbook §8).

## 3. Transport security

- All external traffic is **HTTPS**: Traefik with a Let's Encrypt certificate for `cceuat.moh.gov.rw` (issuer YR1, valid to
  2027-02-02, renewed automatically). Plain HTTP answers **301 → HTTPS**.
- If the certificate stops renewing (e.g. after a DNS change): `sudo bash rw/lib/tls-check.sh cceuat.moh.gov.rw`.
- Service-to-service traffic stays in the cluster (ClusterIP). Pods reach the host's data services over the host network,
  limited by NetworkPolicy (§4). Portainer uses its own self-signed certificate, reached only through an SSH tunnel.

## 4. Host firewall (UFW) — ACTIVE

The VM has a public IP and no upstream firewall, so the host firewall is the perimeter. The installer configures it
(`one-click-installer/lib/ufw-baseline.sh`, on because `IS_CLOUD_DEPLOYMENT=false`) and checks it is on at the end.

```
default deny incoming · allow outgoing · allow routed         # routed is required for k3s pods
allow in on: lo cni0 flannel.1 docker0                         # k8s + docker bridges
allow from:  10.42.0.0/16 (pods)  10.43.0.0/16 (services)  172.16.0.0/12 (docker)
allow:       22/tcp  80/tcp  443/tcp                           # SSH, app (+ ACME)
```

**Verified from outside on 2026-11-06:** only **22, 80, 443** answer. Closed: 5432 (PostgreSQL), 6379 (Redis), 6443 (k3s API),
8080 (Infisical), 8083 (Kafka Connect), 8123 / 9000 / 9363 (ClickHouse), 9092 / 9093 (Kafka), 9001 (Portainer agent),
9100 / 9187 / 9308 (exporters), 9443 (Portainer), 10250 (kubelet). Re-check after any change, from off the network:
`nmap -Pn 102.215.10.21`. Don't trust `ufw status` alone.

Two more listen on all interfaces (seen on the machine on 2026-11-12, not part of that scan), so they too rely on UFW: 9009
(ClickHouse interserver) and 9094 (the Kafka KRaft controller). Nothing listens on 9093. Include them in the next scan.

What the closed ports rely on:
- **UFW only:** PostgreSQL (`*`), ClickHouse (`0.0.0.0`), Kafka Connect (`0.0.0.0:8083`, no authentication) and Kafka listen on
  all interfaces. They are reachable from the internet the moment UFW is off. Use `ufw disable` only as a short emergency
  measure.
- **Kafka and Kafka Connect 3.9.2** (upgraded from 3.7.0 on 2026-11-06), which fixes CVE-2025-27817 / -27818, the Connect
  vulnerabilities behind the 2026-10-24 exploit on the old UAT. `KAFKA_VERSION` in `rw/config/uat.env` sets it. A newer value
  upgrades Kafka in place on the next installer run: the data and cluster ID are kept, and the old install stays as
  `/opt/kafka-<old version>` for rollback. `metadata.version` is left at 3.7 so rollback stays possible. Finalize it once 3.9.2 has
  run for a while: `sudo /opt/kafka/bin/kafka-features.sh --bootstrap-server localhost:9092 upgrade --release-version 3.9`.
- **Kafka Connect is also hardened.** Its REST API has no authentication and every pod can reach it, so it refuses what that
  exploit used, independent of the version:
  - `connector.client.config.override.policy=None` in `/opt/kafka/config/connect-uat.properties`. A connector may not set any
    `producer.`/`consumer.`/`admin.override.*` client setting; the CCE connector uses none.
  - the JNDI and LDAP JAAS login modules blocked for the whole process (`KAFKA_OPTS=-Dorg.apache.kafka.disallowed.login.modules=…`
    in the `kafka-connect` unit)

  Both are written by the installer (`one-click-installer/lib/native/03-install-kafka-connect.sh`), so a re-run keeps them.
  Check with:

  ```bash
  sudo grep override.policy /opt/kafka/config/connect-uat.properties
  curl -s -X PUT -H 'Content-Type: application/json' localhost:8083/connector-plugins/PostgresConnector/config/validate \
    -d '{"connector.class":"io.debezium.connector.postgresql.PostgresConnector","name":"probe","producer.override.sasl.jaas.config":"x"}' \
    | grep -o "The 'None' policy does not allow[^\"]*"      # must print the refusal; validate creates nothing
  ```
- **Bound to loopback:** Infisical and Redis listen on 127.0.0.1 only.
- **Kernel filter:** Portainer (9443) has a systemd IP filter, `IPAddressAllow=localhost 10.42.0.0/16 10.43.0.0/16`, deny
  everything else. That holds even with UFW off. The Portainer agent is a ClusterIP Service, not a LoadBalancer as on .20.
- **Docker-published ports:** the `cce-docker-fw` rule (`systemctl is-active cce-docker-fw` → active) drops new connections from
  the public NIC to any of them. No containers run here; docker is only used to build images, so this is a safeguard.

**Changing rules:**

```bash
sudo ufw status verbose
sudo ufw allow from <cidr> to any port <p> proto tcp      # prefer source-limited rules
sudo ufw status numbered; sudo ufw delete <n>
```

When changing rules over SSH, arm a dead-man first:

```bash
sudo systemd-run --on-active=600 --unit=ufw-deadman /usr/sbin/ufw --force disable
```

Cancel it with `sudo systemctl stop ufw-deadman.timer` once you're still connected. The installer does the same on its own.

**Other network controls:**
- **NetworkPolicy `deny-cross-namespace`** in `cce-uat`. Pods may talk only to their own namespace, kube-system (Traefik) and
  the host's data services on their ports.
- **PostgreSQL `pg_hba`:** local socket by `peer`; 127.0.0.1 and ::1 by `scram-sha-256`; the pod and service networks
  (10.42/16, 10.43/16) by `md5`; nothing else. `password_encryption = scram-sha-256`.
- **PostgreSQL connection logging is on** (`log_connections = on`, since 2026-11-06; set by the installer's step 01,
  `LOG_CONNECTIONS=false` to skip). Every new connection is logged with source address, role and database, including failed
  logins, in `/var/log/postgresql/postgresql-16-main.log`. Example:
  `connection received: host=127.0.0.1 …` / `password authentication failed for user "…"`. To see who connected from where:
  `sudo grep -E 'connection (received|authorized)|authentication failed' /var/log/postgresql/postgresql-16-main.log | tail`.
- **ClickHouse:** the CCE user is password-protected (`password_sha256_hex`).

## 5. Authentication & authorization

- **Keycloak**, realm `cce`, is the identity provider. Clients:

  | Client | Type |
  |---|---|
  | `cce-insights-ui` | public, browser login |
  | `gateway-service` | confidential |
  | `openhim-emitter-adaptor` | confidential, service account |
  | `openhim-basic` | confidential, direct-access grant only, for the Basic → token exchange |

  The realm (users, password hashes, client secrets and signing keys) was **copied from the old UAT on .20** on 2026-11-04, so
  OpenHIM's credentials kept working after the DNS switch. The `cce` realm has 5 users (2026-11-12).
- **Gateway:** it validates JWTs (issuer `https://cceuat.moh.gov.rw/auth/realms/cce`, keys fetched in-cluster) and authorizes
  each route from the `api_permissions` table (15 rows) against the token's `gateway-service` client roles. Every external API
  path goes through the gateway.
- **OpenHIM inbound (Basic auth):** OpenHIM can only send HTTP Basic, so the gateway (`BASIC_AUTH_ENABLED=true`) exchanges the
  credentials for a token through `openhim-basic`, then applies the normal checks. The user is `openhim-emitter-inbound`, with
  client role `gateway-service:EMITTER_INBOUND_WRITE`. `rw/lib/keycloak-openhim-basic.sh` makes sure the client, role and user
  exist.
- **Emitter source check:** after authentication, the emitter accepts events only from the OpenHIM client ID
  `EBUZIMA_CLIENT_ID` (`ebuzima`, fixed in `k8s/base/services/openhim-emitter-adaptor.yaml`, not in Infisical), sent as
  `X-OpenHIM-ClientID`. Others get 200 "ignored" and nothing is stored.
- **Least privilege:** Insights UI users get only `INSIGHTS_READ`, the OpenHIM user only `EMITTER_INBOUND_WRITE`. Grant the
  minimum client roles needed.

## 6. API rate limiting (Traefik)

The same limits as PROD, enforced at the ingress before authentication. Each API has a per-client-IP bucket and a per-host
"global" bucket, and a request must pass both, else it gets **HTTP 429**. Checked live in `cce-uat`:

| Path | Per client IP (burst) | Global (burst) |
|---|---|---|
| `/v1/compliance` | 50/h (10) | 1000/h (50) |
| `/v1/events` | 50/h (10) | 1000/h (50) |
| `/v1/insights` | 2000/h (200) | 100000/h (5000) |

- **Where they're defined:** `k8s/overlays/prod/ratelimit.yaml`, the template the generated overlay `k8s/overlays/rw-uat` is made from.
- **To change them:** edit `k8s/overlays/rw-uat/ratelimit.yaml`, then `--deploy-only`. Or patch live:
  `sudo k3s kubectl -n cce-uat patch middleware ratelimit-compliance-perip --type=merge -p '{"spec":{"rateLimit":{"average":100}}}'`
- **Load testing:** these limits apply to UAT load tests too. Raise them for the test, then put them back.

## 7. Access to the server

- **SSH** is open on 22 to the whole internet: `cceadmin@102.215.10.21`, directly, no jump host. The SSH server allows
  **password login** (`passwordauthentication yes`), and root only by key (`permitrootlogin without-password`). Recommended:
  - move the team to SSH keys and turn off password login
  - restrict the source: `ufw allow from <admin cidr> to any port 22 proto tcp`, then delete the open rule
  - rotate `cceadmin`'s password after handover
- **Admin consoles:**

  | Console | Reach |
  |---|---|
  | Portainer, Infisical | SSH tunnel only (§4) |
  | Grafana `/grafana` | public, login required |
  | Keycloak admin `/auth/admin` | public, login required |
  | kafka-ui `/kafka-ui` | not reachable from outside (404) |

  The Keycloak admin console being public is the main remaining exposure. Consider limiting `/auth/admin` to admin networks
  at Traefik, and keep the master-realm admin password strong (§2).

## 8. Sensitive files — handling

- **Secrets live in Infisical.** The files on disk are the ones listed in §1, all root-only.
- **None of them is in git.** The `deploy-scripts-rw` branch allow-lists the `rw/` files it tracks, so credentials
  (`rw/bkp/`, which holds the access-credentials notes, Infisical exports and database dumps) cannot be committed by accident.
  `rw/bkp/` is not present on this machine.
- **No credentials in `rw/tools/`.** The OpenHIM tools take the OpenHIM login and the inbound user's password as arguments or
  environment variables only.
- **Keep copies of these offsite, encrypted:** `/opt/cce-local-infisical/` (the Infisical keys), `uat.creds`/`uat.meta`, the seed
  file, and the backups. Treat the `keycloak` and `ccedb` dumps as confidential. The full list, and how to export Infisical's
  values: [`DISASTER-RECOVERY.md`](DISASTER-RECOVERY.md) §3.
- **Send credentials separately** from the docs, over a secure channel.

## 9. Open items

1. **The Infisical database is not backed up.** The daily backup (`rw/lib/backup-db.sh`) dumps `ccedb` and `keycloak` only.
   Losing the VM loses every UAT secret. Fix: add `infisical` to the backup, and keep `/opt/cce-local-infisical/` (the
   encryption key) offsite. A dump is useless without that key.
2. **SSH password login is on, and 22 is open to all** (§7).
3. **No alerting:** Prometheus has no notifier, and the emitter's redaction alerts (`CceEmitterRedactionNotApplied`,
   `CceEmitterRedactionPathMatchesNothing`) are **not loaded** (checked: not in `prometheus-config`). Redaction stopping, or a
   service going down, pages nobody.

## 10. Clinical-data minimisation (emitter redaction)

CCE needs to know *that* a clinical step happened, when, for whom and where, not *what was found*. The
`openhim-cce-emitter-adaptor` therefore strips clinical content **before** forwarding. Nothing downstream ever receives it:
`inbound_event_log`, Kafka, the ClickHouse mirror, the backups. The rules are in the emitter's `application.yml`
(`cce.emitter.redaction`): one rule for every resource, plus additions per resource type. Full spec:
`openhim-cce-emitter-adaptor/docs/data-dictionary.md` §3.6.

- **Removed:**
  - `value[x]`, `note`/`text`/`comment`, `interpretation`, `bodySite`, and dosage, reason and medication fields
  - per-type findings (`Condition.code`, `AllergyIntolerance.code`, `ServiceRequest.code`, …)
  - the patient name (`subject.display` / `patient.display`)
  - Encounter's whole `extension` array, where eBuzima carries the diagnosis, vitals, ANC detail (including HIV status) and the
    patient's name, date of birth and village-level address
- **Kept on purpose:**
  - the patient UPID (`subject.reference`)
  - `Observation.code` (the trigger key)
  - facility attribution
  - statuses and clinical times
- **On this machine:** the emitter is built from GitLab `openhim-cce-emitter-adaptor` `release-1.0.0` (commit `3b02face0b`), and
  redaction is **ACTIVE**. The log says `Clinical-data redaction ACTIVE — 39 entr(ies) applied to all resources`. The image is
  built from source here, not pinned to the .20 GHCR digest, so check redaction after every rebuild of the emitter:

  ```bash
  sudo k3s kubectl -n cce-uat logs deploy/openhim-emitter-adaptor --all-pods=true | grep "redaction ACTIVE"
  ```

  The line is logged once, at startup, so search the whole log (no `--tail`). No line, or a `DISABLED` warning, means clinical
  payloads are being stored. `REDACTION_ENABLED=false` is the kill-switch;
  never leave it set.
- **Spot-check** stored events:

  ```sql
  SELECT count(*) FROM inbound_event_log
  WHERE raw_payload->'data' ?| array['valueString','valueCodeableConcept'] AND received_at > '<deploy time>';
  ```

  It must return 0.
- **Unlike the old PROD,** this environment started empty (2026-11-04) and has only received redacted events (1,821 in
  `inbound_event_log` on 2026-11-12), so it holds no pre-redaction clinical data. The Keycloak data copied from .20 carries no
  clinical content.
