# tools/ — checks and repairs you run by hand

Scripts in [`tools/`](../tools/). None of them is run by `install.sh`; the install's last screen suggests the first
two. Three are read-only. [connector-repoint.sh](#connector-repointsh) changes the Debezium connector.

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes**, plus a worked example.

Contents:
[host-ip-check.sh](#host-ip-checksh) ·
[env-fingerprint.sh](#env-fingerprintsh) ·
[env-parity.py](#env-paritypy) ·
[connector-repoint.sh](#connector-repointsh)

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
