# tools/ — checks and repairs you run by hand

Scripts in [`tools/`](../tools/). None of them is run by `install.sh`; the install's last screen suggests the first
two and [show-credentials.sh](#show-credentialssh). Four are read-only. [connector-repoint.sh](#connector-repointsh) changes the Debezium
connector.

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes**, plus a worked example.

Contents:
[host-ip-check.sh](#host-ip-checksh) ·
[env-fingerprint.sh](#env-fingerprintsh) ·
[env-parity.py](#env-paritypy) ·
[connector-repoint.sh](#connector-repointsh) ·
[show-credentials.sh](#show-credentialssh)

---

## host-ip-check.sh

[`tools/host-ip-check.sh`](../tools/host-ip-check.sh)

**Purpose.** Lists every place the machine's IP address is still written down outside Infisical, and whether it
matches the current address. Use it after the IP changes, or any time as a health check.

**Called by / when to run.** By hand. Suggested at the end of every install.

**Usage.**
```bash
sudo bash one-click-installer/tools/host-ip-check.sh                # every cce-* namespace on this machine
sudo bash one-click-installer/tools/host-ip-check.sh <env>          # only cce-<env>
sudo bash one-click-installer/tools/host-ip-check.sh "env1 env2"    # several (one quoted argument)
```

**Reads.** The routing table (current IP, via [host-ip.sh](lib-infisical.md#host-ipsh)). `/opt/kafka/config/kraft/server.properties`.
In each namespace: NetworkPolicy `/32` ipBlocks, `cce-config` keys `POSTGRES_HOST`, `KAFKA_BOOTSTRAP_SERVERS`,
`CLICKHOUSE_HOST`, and DNS of every ingress host. Kafka Connect on `localhost` ports 8083 (standard) and 8086 (a
shifted port some shared hosts use), connector `cce-ccedb-source`. `KAFKA_ADVERTISED_LISTENERS` of any running docker
container that sets it (only if docker is installed). IP literals in `/etc/clickhouse-server/config.d` and `users.d`.

**Changes.** Nothing.

**Safe to re-run?** Yes (read-only).

**Verify.** Last line `RESULT: no drift — everything agrees with <ip>` (exit 0), or `RESULT: <n> item(s) drifted`
(exit 1). Exit 2 if the IP cannot be detected.

**Notes.**
- Output lines are labelled `native Kafka advertised.listeners`, `Connect :8083 connector …` (and `:8086` if
  something answers there), and `docker <container> KAFKA_ADVERTISED_LISTENERS`.
- The ClickHouse check only reports public-looking addresses. A stale **private** address (10.x, 172.16–31.x,
  192.168.x) in the `cce_kafka` named collection is not reported.

**Worked example — the machine got a new IP.**

```bash
sudo bash one-click-installer/tools/host-ip-check.sh <env>
```
Each `DRIFT` line and its fix:

| DRIFT line | Fix |
|---|---|
| `native Kafka advertised.listeners` (or a `docker … KAFKA_ADVERTISED_LISTENERS` line) | re-run install.sh (step 01 rewrites it), or edit `/opt/kafka/config/kraft/server.properties` and `systemctl restart kafka` |
| `cce-<env> NetworkPolicy host ipBlock`, `cce-config POSTGRES_HOST / KAFKA_BOOTSTRAP_SERVERS / CLICKHOUSE_HOST` | if Infisical stores `VM_HOST_IP` (or any of the five derived keys), delete them there first; then re-run install.sh, or `05-k8s-deploy.sh` followed by `redeploy.sh cce-<env>` |
| `ingress DNS <host>` | update the DNS record at your DNS provider |
| `connector database.hostname` (an IP) | `sudo bash one-click-installer/tools/connector-repoint.sh <env>` |
| `connector state FAILED` | check `curl -s localhost:8083/connectors/cce-ccedb-source/status`; usually fixed by the repoint |
| `stray public IPs in config.d/users.d` | re-run install.sh (step 02 rewrites the ClickHouse config) |

Re-running install.sh with the same config fixes everything in the first, second and last rows at once. Then run the
check again until it reports no drift.

---

## env-fingerprint.sh

[`tools/env-fingerprint.sh`](../tools/env-fingerprint.sh)

**Purpose.** Prints a normalised, diff-able description of an environment's shape, one fact per line:
`<section> | <subject> | <detail>`. Two fingerprints are compared with [env-parity.py](#env-paritypy) to check that a
new environment matches a reference one.

**Called by / when to run.** By hand, on each machine you want to compare. Suggested at the end of every install.

**Usage.**
```bash
sudo bash one-click-installer/tools/env-fingerprint.sh <env> > <env>.fp
sudo env CH_PORT_OVERRIDE=8124 CONNECT_PORT_OVERRIDE=8086 bash one-click-installer/tools/env-fingerprint.sh <env> > <env>.fp
```
Use the overrides on a reference host whose ClickHouse HTTP / Kafka Connect run on non-standard ports.

**Reads.** As root: Kubernetes objects in `cce-<env>`; systemd units `postgresql`, `kafka`, `clickhouse-server`,
`kafka-connect`; PostgreSQL database `ccedb` (as the `postgres` user); Kafka on `localhost:9092`; ClickHouse on
`localhost:<port>` (as its `default` user, no password); Kafka Connect REST; UFW and the `DOCKER-USER` chain.

Sections it prints:

| Section | Content |
|---|---|
| `workload`, `workload-env` | each container: image, replicas, CPU/memory requests and limits, probes; env var **names** |
| `hpa`, `service`, `ingress`, `netpol`, `pdb` | autoscalers, services, ingress paths (TLS y/n), NetworkPolicy egress ports, PDBs |
| `cce-config-key` | key **names** in `cce-config` |
| `pods` | pod kinds and their state |
| `native-unit`, `native-version` | systemd state; PostgreSQL, Kafka, ClickHouse, Connect, k3s and OS versions |
| `pg-setting`, `pg-databases`, `pg-roles`, `pg-extensions`, `pg-publication`, `pg-slot`, `pg-table`, `pg-seed-rows` | PostgreSQL shape and the row counts of `api_permissions` and `protocol_definition` |
| `kafka-prop`, `kafka-topic` | broker settings, topics with partitions and replication |
| `ch-databases`, `ch-table`, `ch-named-collections`, `ch-users`, `ch-dictionaries` | ClickHouse shape, table engines and TTLs |
| `connector`, `connector-table`, `connector-status` | Debezium class, host (IP literal or name), snapshot mode, slot, tables, state |
| `firewall`, `ufw-rule` | UFW status and rules, docker-fw unit and rule count |

**Changes.** Nothing.

**Safe to re-run?** Yes (read-only).

**Verify.** Every line of the output file has the three-part format above. Empty sections mean that service was not
reachable (for example, ClickHouse refused the passwordless `default` user).

**Notes.**
- **No secrets.** Config keys and env vars are printed by name only. Still, the file names hosts, roles and tables;
  treat it as internal.
- Normalisation: `cce-<env>` → `cce-ENV`, every IPv4 → `<IP>`, `//0.0.0.0:` → `//:`. Version strings are exempt (a
  ClickHouse version looks like an IP).
- The database name `ccedb` is fixed in the script.

---

## env-parity.py

[`tools/env-parity.py`](../tools/env-parity.py)

**Purpose.** Compares two fingerprints from [env-fingerprint.sh](#env-fingerprintsh) and reports how closely the
candidate matches the reference.

**Called by / when to run.** By hand, anywhere with Python 3 (it does not need the machines).

**Usage.**
```bash
python3 one-click-installer/tools/env-parity.py <reference.fp> <candidate.fp> [--ignore REGEX]...
```
`--ignore` drops every fact whose `section | subject` matches the regular expression. Repeat it for each pattern.

**Reads.** The two files.

**Changes.** Nothing.

**Safe to re-run?** Yes.

**Verify.** Exit code 0 = identical after ignores; 1 = differences.

**Output.** A header with counts, then three groups, each split by section:
- **DIFFERENT** — same section and subject, different detail (shows `ref:` and `cand:`);
- **MISSING** — in the reference, absent from the candidate (the candidate lacks something);
- **EXTRA** — in the candidate only.

**Worked example — does a new environment match the reference?**

1. On the reference machine (here its env code is `prod`, and it uses shifted ports):
   ```bash
   sudo env CH_PORT_OVERRIDE=8124 CONNECT_PORT_OVERRIDE=8086 \
     bash one-click-installer/tools/env-fingerprint.sh prod > /tmp/ref.fp
   ```
2. On the new machine (env code `trial`, standard ports):
   ```bash
   sudo bash one-click-installer/tools/env-fingerprint.sh trial > /tmp/trial.fp
   ```
3. Copy both files to one place (`scp`), then:
   ```bash
   python3 one-click-installer/tools/env-parity.py ref.fp trial.fp
   ```
4. Read the DIFFERENT and MISSING groups first. Decide which differences are expected — for example image tags you
   pinned on purpose, the OS version, or UFW rules on a cloud machine — and hide them:
   ```bash
   python3 one-click-installer/tools/env-parity.py ref.fp trial.fp \
     --ignore '^native-version \| os$' \
     --ignore '^ufw-rule ' \
     --ignore '^pods '
   ```
   Escape `|` as `\|` in the regex; the matched text is literally `section | subject`.
5. Repeat until what is left is either fixed or understood. Exit code 0 means no unexplained difference remains.

Typical real differences worth acting on: a `pg-setting` (e.g. `shared_preload_libraries` without
`pg_stat_statements`), a missing `pg-extensions` entry, a `connector` with `host=IP-LITERAL`, a `workload` with
different resources, or a missing `ch-table`.

---

## connector-repoint.sh

[`tools/connector-repoint.sh`](../tools/connector-repoint.sh)

**Purpose.** Makes the Debezium connector reach PostgreSQL on `localhost:5432` instead of the machine's IP, so an IP
change does not break CDC. It reads the connector's live config and changes only host, port and password, so the
replicated table list cannot drift.

**Called by / when to run.** By hand, after any tool registered the connector with `POSTGRES_HOST` set to an IP, or
when [host-ip-check.sh](#host-ip-checksh) shows `connector database.hostname` as an IP. The installer's own
[04-data-pipeline.sh](native.md#04-data-pipelinesh) already uses `localhost`.

**Usage.**
```bash
sudo bash one-click-installer/tools/connector-repoint.sh <env>
```
Run it with `sudo`: it re-runs itself under [infisical-run.sh](lib-infisical.md#infisical-runsh) to get the password,
and the creds files are readable only by root. `CDC_DB_HOST=<name>` and `CONNECT_URL=<url>` override the target host
and the Connect REST address for other topologies.

**Reads.** From Infisical: `POSTGRES_READ_ONLY_USER`, `POSTGRES_READ_ONLY_PASSWORD`, `CONNECT_URL` (default
`http://localhost:8083`), `POSTGRES_PORT` (default 5432). `CDC_DB_HOST` (default `localhost`). Connector name is fixed:
`cce-ccedb-source`.

**Changes.** If the connector's `database.hostname` and `database.port` are already `localhost` / `5432`: nothing.
Otherwise it PUTs the connector config with the new host, port and password (Connect's GET hides the password, so it is
re-supplied from Infisical; it is never printed), then polls the status for up to 60 s.

**Safe to re-run?** Yes. A second run finds nothing to do and does not restart the task.

**Verify.** `[<env>] re-pointed -> localhost:5432` followed by status lines ending with all tasks `RUNNING`. Or
`already IP-free — nothing to do`.

**Notes.**
- It refuses (`ABORT: connector user differs from POSTGRES_READ_ONLY_USER`) if the connector uses another database
  user. That protects a connector you did not create.
- If no connector named `cce-ccedb-source` exists, the GET fails and the script stops with a Python error. Run
  [04-data-pipeline.sh](native.md#04-data-pipelinesh) (or re-run install.sh) to register it.

---

## show-credentials.sh

[`tools/show-credentials.sh`](../tools/show-credentials.sh)

**Purpose.** Prints every login of an installed environment in one place: where to log in, the user name, the password
and where it is stored. The installer deliberately writes no plain-text credentials file. Every password is generated
into the environment's Infisical project, and this script reads them from there each time, so the output cannot go stale
and nothing extra is left on disk.

**Called by / when to run.** By hand, after an install: to log in to an admin UI, to hand the source system its inbound
login, or to check which files must be backed up. The install's last screen shows the command.

**Usage.**
```bash
sudo bash one-click-installer/tools/show-credentials.sh <env>            # URLs and user names; passwords masked
sudo bash one-click-installer/tools/show-credentials.sh <env> --reveal   # also print the passwords
```
Run it with `sudo`: it re-runs itself under [infisical-run.sh](lib-infisical.md#infisical-runsh) to get the values,
and the creds files and `admin.env` are readable only by root. `OVERLAY_NAME=<name>` is needed only if the environment
was installed with an overlay name other than `<env>`; it is used to name the emitter adaptor.

**Reads.**
- From Infisical (every folder): `KEYCLOAK_ADMIN_*`, `GRAFANA_ADMIN_*`, `PORTAINER_ADMIN_PASSWORD`, `POSTGRES_*`,
  `CLICKHOUSE_*`, `EMITTER_INBOUND_*`, `BASIC_AUTH_CLIENT_*`, `CCE_COLLECTOR_AUTH_TOKEN`, `CCE_INTELLIGENCE_SMTP_*`,
  `OPENHIM_*`.
- `CCE_PUBLIC_URL` from [host-ip.sh](lib-infisical.md#host-ipsh) (`https://<INGRESS_HOST>`, or `http://<host IP>`).
- `/opt/cce-local-infisical/admin.env` (local Infisical only; `CCE_LOCAL_INFISICAL_DIR` overrides the directory).
- The overlay's `kustomization.yaml`, to find the emitter adaptor and so the inbound URL.
- `systemctl is-active cce-portainer`, to decide whether to list Portainer.

**Changes.** Nothing.

**Safe to re-run?** Yes.

**What it lists.**

| Entry | Where | Stored in |
|---|---|---|
| Infisical (holds everything else) | SSH tunnel to `localhost:8080` | file `/opt/cce-local-infisical/admin.env` |
| Insights UI | `<CCE_PUBLIC_URL>/insights/` | users of the Keycloak realm `cce`; the installer creates none |
| Keycloak admin console | `<CCE_PUBLIC_URL>/auth/admin/` | Infisical `/keycloak` |
| Grafana | `<CCE_PUBLIC_URL>/grafana/` | Infisical `/grafana` |
| Portainer | SSH tunnel to `localhost:9443` | Infisical `/portainer` |
| PostgreSQL owner and CDC read-only user | `localhost:5432`, database `ccedb` | Infisical `/postgres` |
| PostgreSQL superuser | `sudo -u postgres psql` on the host | no password (peer authentication) |
| ClickHouse | `http://localhost:8123`, database `cce_analytics` | Infisical `/clickhouse` |
| ClickHouse `default` user | `clickhouse-client` on the host | no password; loopback only |
| Emitter inbound (give to the source system) | `<CCE_PUBLIC_URL>/v1/<emitter deployment>/inbound`, HTTP Basic | Infisical `/keycloak` |
| Service-to-service secrets | used by the services: gateway Basic-auth client secret, collector token, SMTP, OpenHIM | Infisical `/keycloak`, `/platform`, `/openhim-emitter-adaptor` |

Kafka and Kafka Connect have no login. Connect listens on `127.0.0.1` only; Kafka's 9092 must stay closed to the outside
(UFW, or the cloud security group).

**Back these up off the machine.** All are 0600 and owned by root. Without them Infisical, and so every password above,
cannot be recovered:
- `/opt/cce-local-infisical/admin.env`: the Infisical admin login.
- `/opt/cce-local-infisical/.env`: Infisical's encryption key, auth secret and database password. The encryption key
  is needed to decrypt Infisical's data, including from a database backup.
- `~<sudo user>/.cce-infisical/<env>.creds` and `.meta`: the machine identity and project ID the scripts use. These
  can be re-created from the Infisical UI, the two above cannot.

With a remote Infisical (`USE_LOCAL_INFISICAL=false`) only the `.creds`/`.meta` pair is on the machine; the Infisical
admin login is whatever the operator used at install.

**Verify.** The masked output lists every entry with a user name and `********`. `(not set)` means the key is empty in
Infisical: expected for SMTP and OpenHIM until they are filled in, wrong for anything else.

**Notes.**
- Changing an admin password: Keycloak, Grafana and Portainer keep it in their own database after the first start, so
  editing Infisical alone does nothing. Grafana and Portainer:
  [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh). Keycloak: change it in the admin console, then set
  `KEYCLOAK_ADMIN_PASSWORD` in Infisical to the same value. [06-seed.sh](native.md#06-seedsh) logs in with it on every
  re-run.
- `--reveal` prints passwords to the terminal. Clear the scrollback afterwards if the screen is shared or recorded.
- The `SEED_ENV_FILE` given at install can hold the SMTP password. Delete it after the install, or protect it like the
  files above.

Example (masked, trimmed):
```
== Credentials for environment 'trial'   (passwords masked — add --reveal to show) ==
-- Keycloak admin console
   where:     http://13.235.174.187/auth/admin/
   user:      admin
   password:  ********
   stored in: Infisical /keycloak KEYCLOAK_ADMIN_*
-- Emitter inbound (tiberbu) — give to the source system
   where:     http://13.235.174.187/v1/tiberbu-emitter-adaptor/inbound  (HTTP Basic)
   user:      tiberbu-emitter-inbound
   password:  ********
   stored in: Infisical /keycloak EMITTER_INBOUND_*
```
