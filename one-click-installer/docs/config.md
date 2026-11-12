# Configuration reference

This page covers every key in the installer config file, the environment-only variables, the seed file and
`config/.gitignore`. For the short version, see [Configuration in the top-level README](../README.md#configuration).

- The template is [`config/example.env`](../config/example.env). Copy it to `config/<envcode>.env` and edit the copy.
- The authoritative list of known keys is `CCE_CONFIG_KEYS` in [`lib/load-config.sh`](../lib/load-config.sh). The
  validation rules are in `cce_validate_config` in the same file.
- The config file holds **no secrets**. Secrets live in Infisical, or are given once in the seed file.

## How the config file is read

[`lib/load-config.sh`](../lib/load-config.sh) (`cce_load_config`) reads the file line by line:

- `#` starts a comment. Everything after the first `#` on a line is dropped, including inside a value. A value cannot
  contain `#`.
- Blank lines are skipped. Lines without `=` are skipped with a warning.
- Leading and trailing spaces are trimmed. One pair of surrounding `"` or `'` quotes is removed from the value.
- Keys must match `^[A-Z_][A-Z0-9_]*$`.
- **The environment wins.** A key that is already set in the environment is not overwritten. So
  `sudo env IS_CLOUD_DEPLOYMENT=true bash install.sh --config …` overrides the file. Use `sudo env VAR=x`, not
  `VAR=x sudo …` and not `sudo -E` (see [sudo-compat.sh](lib-install.md#sudo-compatsh)).
- Every key is exported, so every script that `install.sh` starts sees it.
- A key that is not in `CCE_CONFIG_KEYS` and does not start with `IMAGE_` produces
  `WARNING: unknown config key(s) — typo? …`. It is still exported. So an environment-only variable such as
  `FORCE_K3S_REINSTALL` works from the file, but warns.
- After reading, two defaults are exported if still unset: `USE_LOCAL_INFISICAL=true` and `KAFKA_VERSION=3.9.2`, so
  every later script sees the same values as `example.env`.

(These parsing rules are for the config file. The seed file has its own rules, which keep `#` inside values: see
[The seed file → Format](#format).)

`cce_validate_config` then stops the install if:

| Check | Message starts with |
|---|---|
| `ENVCODE` empty, or not `^[a-z0-9]+$` | `CONFIG: ENVCODE …` |
| `IS_CLOUD_DEPLOYMENT` not exactly `true` or `false` (empty also fails) | `CONFIG: IS_CLOUD_DEPLOYMENT must be true or false` |
| `USE_LOCAL_INFISICAL`, `ENABLE_PG_STAT_STATEMENTS`, `LOG_CONNECTIONS`, `PORTAINER_ENABLED` set to something other than `true`/`false` | `CONFIG: <KEY> must be true or false` |
| `LOCAL_INFISICAL_RUNTIME` not `native`/`docker` | `CONFIG: LOCAL_INFISICAL_RUNTIME …` |
| `EXPORTER_RUNTIME` not `systemd`/`docker` | `CONFIG: EXPORTER_RUNTIME …` |
| `INGRESS_HOST` set but `ACME_EMAIL` empty | `CONFIG: INGRESS_HOST is set (TLS) but ACME_EMAIL is empty` |
| `SEED_ENV_FILE` or `PROTOCOL_FILE` set but not readable | `CONFIG: … not readable` |

`install.sh` also stops before phase 1 if `k8s/base` or `k8s/overlays/<OVERLAY_TEMPLATE>` is missing from the
repository, if `data-pipeline/schema` is missing while `DATA_PIPELINE_REF` is empty (with a ref set, phase 4 fetches
it), if `KEYCLOAK_THEME_DIR` has no `login/theme.properties`, or if `EMITTER_ADAPTOR` names an unknown emitter.

## What "change it later" means

Each key below has a **Change later** line. The answers are:

- **Re-run install.sh** — edit the config file, run the same `install.sh --config …` command again. Every phase is
  re-run. Existing installs are reused.
- **Redeploy** — the value reaches the cluster through Infisical; run [`lib/redeploy.sh`](lib-day2.md#redeploysh).
- **First install only** — the value is used when the component is first installed. Changing it on an existing machine
  has no effect (or is unsafe, as noted).

---

## Environment identity

### `ENVCODE`
- **Meaning:** short code for this environment. Becomes the k3s namespace `cce-<ENVCODE>`, the Infisical project
  `cce-<ENVCODE>`, the machine identity `cce-<ENVCODE>-identity`, and the creds files `<ENVCODE>.creds` / `.meta`.
  It is the first argument of almost every script.
- **Default:** none (required). `example.env` has `dev`.
- **Allowed:** lowercase letters and digits only.
- **Read by:** `install.sh`, and passed as an argument to every lib script.
- **Change later:** do not. A new code is a new environment: new namespace, new Infisical project, new creds.

### `OVERLAY_NAME`
- **Meaning:** directory created under `k8s/overlays/` for this environment.
- **Default:** the value of `ENVCODE`.
- **Allowed:** any directory name, but it must differ from `OVERLAY_TEMPLATE`. So `ENVCODE=prod` needs, for
  example, `OVERLAY_NAME=<country>-prod`.
- **Read by:** `install.sh`, [generate-overlay.sh](lib-install.md#generate-overlaysh),
  [apply-image-pins.sh](lib-install.md#apply-image-pinssh), [overlay-vars-check.sh](lib-install.md#overlay-vars-checksh),
  [dry-render.sh](lib-install.md#dry-rendersh), [05-k8s-deploy.sh](native.md#05-k8s-deploysh),
  [redeploy.sh](lib-day2.md#redeploysh).
- **Change later:** re-run install.sh. A new overlay is generated; the old one stays on disk.
- **Gotcha:** day-2 scripts do not read the config file. If `OVERLAY_NAME` differs from `ENVCODE`, export it when you
  run them by hand: `sudo env OVERLAY_NAME=<name> bash lib/redeploy.sh cce-<env>`.

### `OVERLAY_TEMPLATE`
- **Meaning:** existing overlay that is cloned to make the new one (resource sizing, HPAs, rate limits, patches).
- **Default:** `prod` (the reference production overlay, `k8s/overlays/prod`).
- **Read by:** `install.sh` (asset check), [generate-overlay.sh](lib-install.md#generate-overlaysh).
- **Change later:** only matters when the overlay is generated. To regenerate, delete `k8s/overlays/<OVERLAY_NAME>`
  and re-run install.sh.

## Public access

### `INGRESS_HOST`
- **Meaning:** DNS name that points at this machine.
- **Default:** empty. Empty means plain HTTP on the machine's address, no TLS.
- **Read by:** `install.sh` appends it to the seed (so it is stored in Infisical `/platform`).
  [05-k8s-deploy.sh](native.md#05-k8s-deploysh) reads it from the Infisical-injected environment: when set, it applies
  the Traefik ACME config, keeps the TLS ingress, and adds a `hostAliases` entry to `gateway-service`; when empty, it
  rewrites the ingress to plain HTTP with [plain-http-ingress.py](lib-install.md#plain-http-ingresspy).
- **Change later:** re-run install.sh.
- **Without a name (plain HTTP):** the token issuer is `http://<this host's IP>/auth/realms/cce` (`CCE_PUBLIC_URL`,
  derived at deploy time by [host-ip.sh](lib-infisical.md#host-ipsh)). The gateway accepts only tokens with that issuer,
  so server-to-server calls (the emitter's inbound Basic auth) work as they are, but people must open the Insights UI
  at that same address. On a cloud VM, where users reach a public IP instead, set `CCE_PUBLIC_URL=http://<public IP>`
  in Infisical `/platform`, or use a DNS name. Keycloak decides a token's issuer from the address used to reach it.
- **Gotcha:** going back from a name to empty does not clear it. `install.sh` only appends a non-empty value to the
  seed, and the seed never deletes keys. Delete `INGRESS_HOST` (and `ACME_EMAIL`) from Infisical `/platform` by hand,
  then re-run.

### `ACME_EMAIL`
- **Meaning:** Let's Encrypt contact for the TLS certificate.
- **Default:** empty. **Required** when `INGRESS_HOST` is set (validation fails otherwise).
- **Read by:** same path as `INGRESS_HOST`; substituted into `k8s/base/traefik/traefik-helmchartconfig.yaml`.
- **Change later:** re-run install.sh.

## Hosting / network security

### `IS_CLOUD_DEPLOYMENT`
- **Meaning:** `true` = the machine sits behind a cloud security group or firewall that you manage; the installer does
  not configure a host firewall. `false` = on-prem, bare metal, or a VM directly on the internet; the installer
  configures UFW with [ufw-baseline.sh](lib-install.md#ufw-baselinesh).
- **Default:** none. **Required**; empty fails validation. `example.env` has `false`.
- **Read by:** `install.sh` only (summary and phase 7).
- **Change later:** `false` → `true` does **not** disable UFW; the installer just stops touching it. Run
  `sudo ufw disable` yourself if that is what you want. `true` → `false`: re-run install.sh.
- **Note:** with `true`, the cloud firewall is the only barrier for the services that listen on all interfaces:
  PostgreSQL 5432, Kafka 9092/9094 (no authentication), ClickHouse 8123/9000/9009/9363, the exporters
  9100/9187/9308 and the k3s API 6443. It must allow only 22/80/443. Phase 7 prints this list. Kafka Connect's REST API
  and ClickHouse's password-less `default` user are bound to loopback. See
  [architecture.md](architecture.md#network-exposure).

### `SSH_ALLOWED_CIDR`
- **Meaning:** restrict SSH (port 22) to one network, for example `196.12.0.0/16`.
- **Default:** empty = SSH open to all.
- **Read by:** [ufw-baseline.sh](lib-install.md#ufw-baselinesh) (only runs when `IS_CLOUD_DEPLOYMENT=false`).
- **Change later:** re-run install.sh or `ufw-baseline.sh`. When this is set, the allow-from-anywhere `22/tcp` rule
  from an earlier run is deleted. If no current SSH session comes from inside the range, the 10-minute dead-man timer
  stays armed and UFW turns itself off again (see [ufw-baseline.sh](lib-install.md#ufw-baselinesh)). Going back to
  empty re-adds `22/tcp` from anywhere but does not delete the range rule.

### `UFW_EXTRA_ALLOW`
- **Meaning:** extra public allows, comma separated. An entry that looks like a CIDR (`10.20.0.0/16`) becomes
  `ufw allow from <cidr>` (all ports from that network). Anything else is passed to `ufw allow` as is (`8443/tcp`).
- **Default:** empty.
- **Read by:** [ufw-baseline.sh](lib-install.md#ufw-baselinesh).
- **Change later:** re-run install.sh or `ufw-baseline.sh`. Entries are only added; removing one from the list does not
  delete its rule (`sudo ufw status numbered`, then `sudo ufw delete <n>`).

### `K3S_CLUSTER_CIDR`, `K3S_SERVICE_CIDR` (Advanced section of example.env)
- **Meaning:** the k3s pod and service networks. Change them only if `10.42.0.0/16` / `10.43.0.0/16` clash with the
  site's own network.
- **Default:** unset = `10.42.0.0/16` and `10.43.0.0/16` (k3s defaults).
- **Read by:** [prereqs.sh](lib-install.md#prereqssh) (passes `--cluster-cidr`, `--service-cidr` and `--cluster-dns`
  = the 10th address of the service range to the k3s installer), setup-prod-infra.sh through
  [01](native.md#01-install-postgres-kafkash) (`pg_hba.conf` lines), [ufw-baseline.sh](lib-install.md#ufw-baselinesh)
  (allowed sources) and [portainer.sh](lib-install.md#portainersh) (`IPAddressAllow` in the `cce-portainer` unit).
- **Change later:** first install only, for k3s. An existing cluster keeps its networks; prereqs prints a note when they
  differ. To change them, reinstall k3s on an empty cluster (`FORCE_K3S_REINSTALL=1`). Old `pg_hba.conf` lines are
  not removed.

## Secrets store (Infisical)

### `USE_LOCAL_INFISICAL`
- **Meaning:** `true` = run Infisical on this machine (127.0.0.1:8080) and log in to it automatically. `false` = use
  an existing Infisical at `INFISICAL_DOMAIN`; export `INFISICAL_ADMIN_EMAIL` and `INFISICAL_ADMIN_PASSWORD` (an
  org admin) before running. Never put those in the config file.
- **Default:** `true` (also when the key is missing).
- **Read by:** `install.sh` (phase 2), [prereqs.sh](lib-install.md#prereqssh) (whether docker is needed).
- **Change later:** switching an existing environment between Infisical instances is not automated. The creds files
  point at a project in one instance.

### `INFISICAL_DOMAIN`
- **Meaning:** base URL of the Infisical API.
- **Default:** `http://localhost:8080`.
- **Read by:** `install.sh` (health check `GET /api/status`), [infisical-bootstrap.sh](lib-infisical.md#infisical-bootstrapsh),
  [infisical-run.sh](lib-infisical.md#infisical-runsh), [infisical-secret-helpers.sh](lib-infisical.md#infisical-secret-helperssh).
- **Note:** with a local Infisical, `install.sh` sources `/opt/cce-local-infisical/admin.env` when no admin login is in
  the environment. That file sets `INFISICAL_DOMAIN=http://127.0.0.1:8080` and wins over the config value.
- **Remote instance:** the URL must answer from this machine. If the instance is reached over an SSH tunnel, open the
  tunnel first.

### `LOCAL_INFISICAL_RUNTIME`
- **Meaning:** how the local Infisical runs. `native` = `infisical-core` apt package + Redis + a database in the native
  PostgreSQL ([infisical-native.sh](lib-infisical.md#infisical-nativesh)). `docker` = the older docker compose stack
  ([infisical-local.sh](lib-infisical.md#infisical-localsh)).
- **Default:** `native`.
- **Read by:** `install.sh`, [prereqs.sh](lib-install.md#prereqssh).
- **Change later:** `docker` → `native`: re-run install.sh. It migrates automatically (same keys, database copied,
  containers removed). `native` → `docker` is not supported.

### `INFISICAL_CORE_VERSION`
- **Meaning:** exact `infisical-core` apt package version for the native runtime. The package is put on hold.
- **Default:** `0.162.24-1`.
- **Read by:** [infisical-native.sh](lib-infisical.md#infisical-nativesh).
- **Change later:** re-run install.sh. Never set it older than the version that wrote the existing database: the
  server only migrates forward. The hold is overridden for this install (`--allow-change-held-packages`) and set again.

### `SEED_ENV_FILE`
- **Meaning:** path to a `KEY=value` file of initial values for Infisical. See [The seed file](#the-seed-file) below.
- **Default:** empty. In practice it is needed: the intelligence-service keys it must hold have no defaults, and
  [overlay-vars-check.sh](lib-install.md#overlay-vars-checksh) fails phase 5 without them.
- **Read by:** `install.sh` (phase 3), [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh) (env only).
- **Keep it outside the repository.** It holds passwords.
- **Change later:** re-run install.sh. Values from the file are written to Infisical on every run.

### `CCE_INFISICAL_CREDS_DIR` (Advanced section of example.env)
- **Meaning:** directory holding `<envcode>.creds` (the machine identity's client id and secret) and `<envcode>.meta`
  (project id and environment slug).
- **Default:** `<home of the user who ran sudo>/.cce-infisical`. See [creds-dir.sh](lib-infisical.md#creds-dirsh).
- **Change later:** if you move the files, set this the same way for every later run, including day-2 scripts
  (`sudo env CCE_INFISICAL_CREDS_DIR=… bash …`).

## Portainer

### `PORTAINER_ENABLED`
- **Meaning:** install the native Portainer server (`cce-portainer` systemd service) and its agent in k3s.
- **Default:** `true`.
- **Read by:** `install.sh` (phase 6b).
- **Change later:** `false` stops the installer from touching Portainer. It does not uninstall it.

### `PORTAINER_VERSION`
- **Meaning:** Portainer CE release for both the server binary and the agent image.
- **Default:** `2.39.2`.
- **Read by:** [portainer.sh](lib-install.md#portainersh), `install.sh` (summary).
- **Change later:** re-run install.sh. The new release is installed to `/opt/portainer-<version>`, and `/opt/portainer`
  is re-pointed.

### `PORTAINER_SHA256` (Advanced section of example.env)
- **Meaning:** SHA-256 of `portainer-<version>-linux-amd64.tar.gz`.
- **Default:** pinned for 2.39.2. For any other version, if unset, it is read from the release's own
  `-checksum.txt` on GitHub (same source as the archive, so weaker).
- **Read by:** [portainer.sh](lib-install.md#portainersh).

## Keycloak login theme

### `KEYCLOAK_THEME_DIR`
- **Meaning:** directory (relative to the repository root, or absolute) that holds `login/theme.properties`. It is
  mounted into Keycloak under the theme name `insights-ui-theme`, which the `cce` realm then selects.
- **Default:** `keycloak-themes/cce-insights-theme/dev` (unbranded).
- **Read by:** `install.sh` (checks the file exists), [05-k8s-deploy.sh](native.md#05-k8s-deploysh) (hostPath),
  [06-seed.sh](native.md#06-seedsh) (message only).
- **Change later:** re-run install.sh. 05 rewrites the hostPath. The Keycloak pod may need a restart to see the new
  files (`k3s kubectl -n cce-<env> rollout restart deploy/keycloak`).

## Platform versions

### `K3S_VERSION`
- **Default:** `v1.35.4+k3s1`. Also pins the bundled Traefik.
- **Read by:** [prereqs.sh](lib-install.md#prereqssh).
- **Change later:** first install only. An existing k3s at another version is reported, never replaced. With
  `FORCE_K3S_REINSTALL=1` (environment) **and** no pods outside `kube-system`, prereqs uninstalls k3s and installs the
  pinned version.

### `INFISICAL_CLI_VERSION`
- **Default:** `0.43.93`.
- **Read by:** [prereqs.sh](lib-install.md#prereqssh).
- **Change later:** first install only. An existing CLI at another version is left alone.

### `CLICKHOUSE_VERSION`
- **Meaning:** a series (`26.5` = newest 26.5.x in the repository) or an exact version (`26.5.2.39`).
- **Default:** `26.5`. Stay on 26.5 unless the analytics schema has been made compatible: ClickHouse 26.10 and later
  reject `data-pipeline/schema/03-create-materialized-views.sql`.
- **Read by:** [02-install-clickhouse.sh](native.md#02-install-clickhousesh).
- **Change later:** first install only. When `clickhouse-server` exists, 02 skips the install. The packages are held
  (`apt-mark hold`), so `apt upgrade` does not move them either.

### `POSTGRES_VERSION`
- **Default:** `16`.
- **Read by:** `k8s/infrastructure/setup-prod-infra.sh` (through [01](native.md#01-install-postgres-kafkash)) and
  [infisical-native.sh](lib-infisical.md#infisical-nativesh).
- **Change later:** do not change it on an existing machine. PostgreSQL is installed only when `psql` is absent, and
  setup-prod-infra.sh edits `/etc/postgresql/<version>/main/…`, which would not exist for a new value.

### `KAFKA_VERSION`
- **Meaning:** Kafka and Kafka Connect version (they share `/opt/kafka`).
- **Default:** `3.9.2` (fixes CVE-2025-27817 / -27818 in Connect), also when the key is missing: load-config.sh exports
  it. (setup-prod-infra.sh's own default stays `3.7.0` for callers outside the installer; the installer always passes
  the value.)
- **Read by:** setup-prod-infra.sh (through [01](native.md#01-install-postgres-kafkash)), [prereqs.sh](lib-install.md#prereqssh).
- **Change later:** re-run install.sh. A **newer** value upgrades Kafka in place: the old install is moved to
  `/opt/kafka-<old>` as a rollback copy, `config/`, `.cluster-id` and `connect-plugins/` are carried over, and the
  data directory `/var/lib/kafka/data` is not touched. Kafka and Connect are down for about a minute. An **older** value
  is ignored (no downgrade).
- **Tip:** the download from archive.apache.org can be very slow. Put `kafka_2.13-<version>.tgz` in `/tmp` first; it
  is reused if its SHA-512 matches.

### `DEBEZIUM_VERSION`
- **Default:** `3.0.0.Final`.
- **Read by:** [03-install-kafka-connect.sh](native.md#03-install-kafka-connectsh).
- **Change later:** first install only. 03 downloads the plugin only when `/opt/kafka/connect-plugins/debezium-connector-postgres`
  is absent. To change it, stop `kafka-connect`, remove that directory, and re-run.

### `KAFKA_PORT` (no longer a config key)
- Kafka always listens on 9092, and [host-ip.sh](lib-infisical.md#host-ipsh) derives `KAFKA_BOOTSTRAP_SERVERS` as
  `<host IP>:9092`. Setting `KAFKA_PORT` in the config only produces the "unknown key" warning.

### `EXPORTER_RUNTIME`
- **Meaning:** how postgres_exporter and kafka_exporter run. `systemd` = pinned, checksum-verified release binaries as
  host services `cce-postgres-exporter` / `cce-kafka-exporter`. `docker` = `docker run --network host` containers.
- **Default:** `systemd`.
- **Read by:** [07-monitoring-exporters.sh](native.md#07-monitoring-exporterssh), [prereqs.sh](lib-install.md#prereqssh).
- **Change later:** re-run install.sh. Switching removes the other runtime's exporters.
- **Note:** both runtimes use the same pinned versions (the docker runtime pulls the `v<version>` image tags).

### `POSTGRES_EXPORTER_VERSION`, `POSTGRES_EXPORTER_SHA256`, `KAFKA_EXPORTER_VERSION`, `KAFKA_EXPORTER_SHA256` (Advanced section of example.env)
- **Defaults:** postgres_exporter `0.20.1`, kafka_exporter `1.11.0`, each with a pinned SHA-256 of the
  `linux-amd64.tar.gz` release archive.
- **Read by:** [07-monitoring-exporters.sh](native.md#07-monitoring-exporterssh). The versions apply to both runtimes;
  the `_SHA256` values only to the systemd runtime (release archives).
- **Change later:** re-run install.sh. If you change a version, you must also set its `_SHA256`; otherwise the download
  fails the checksum and the install stops.

### `ENABLE_PG_STAT_STATEMENTS`
- **Meaning:** preload `pg_stat_statements` and create the extension in `ccedb` and `postgres`. The Grafana Postgres
  query dashboards are empty without it.
- **Default:** `true`.
- **Read by:** [01-install-postgres-kafka.sh](native.md#01-install-postgres-kafkash).
- **Change later:** `true` on an existing machine restarts PostgreSQL once. `false` does not remove it.

### `LOG_CONNECTIONS` (Advanced section of example.env)
- **Meaning:** set PostgreSQL `log_connections = on`, so who connected, from where, as which role, is in the log.
- **Default:** `true`.
- **Read by:** [01-install-postgres-kafka.sh](native.md#01-install-postgres-kafkash). The install result line reports it.
- **Change later:** `false` does not turn it off again. Use `ALTER SYSTEM SET log_connections = off` yourself.

## CCE service images

All `IMAGE_*` keys are free-form (no "unknown key" warning). They are applied to the overlay's kustomize `images:`
block by [apply-image-pins.sh](lib-install.md#apply-image-pinssh) on **every** install.sh run (phase 4), then deployed
by [05-k8s-deploy.sh](native.md#05-k8s-deploysh).

| Key | Effect |
|---|---|
| `IMAGE_REGISTRY` | Replaces the registry/owner part of every image name, e.g. `registry.example.org/cce`. Empty = keep the overlay's names. |
| `IMAGE_TAG_DEFAULT` | Tag or digest for every service that has no key of its own. |
| `IMAGE_<NAME>` | Tag (`release-1.2.0`) or digest (`sha256:…`) for one image. `<NAME>` is the image's last path part, upper-cased, with every non-alphanumeric character turned into `_`. For example `cce-collector-service` → `IMAGE_CCE_COLLECTOR_SERVICE`. |
| `IMAGE_CCE_EMITTER_ADAPTOR` | Generic key for whichever `*-cce-emitter-adaptor` image the overlay contains. A system-specific key (e.g. `IMAGE_OPENHIM_CCE_EMITTER_ADAPTOR`) wins over it. If the overlay contains more than one emitter adaptor, the generic key is an error unless each emitter has its own key. The emitter strips clinical data before it reaches CCE: pin a build that includes redaction. |

Keys in `example.env`: `IMAGE_CCE_COLLECTOR_SERVICE`, `IMAGE_CCE_PROTOCOL_SERVICE`, `IMAGE_CCE_MATCHER_SERVICE`,
`IMAGE_CCE_STEP_SLA_SERVICE`, `IMAGE_CCE_INTELLIGENCE_SERVICE`, `IMAGE_CCE_INSIGHTS_SERVICE`, `IMAGE_CCE_INSIGHTS_UI`,
`IMAGE_GATEWAY_SERVICE`, `IMAGE_CCE_EMITTER_ADAPTOR`.

- **A digest is the strongest pin.** What you tested is what runs. A tag can be re-pushed.
- **Change later:** edit the config and re-run install.sh, or run `apply-image-pins.sh <env>` then
  `05-k8s-deploy.sh <env>` (see [the day-2 table](README.md#task--script-to-run-by-hand)).
- **No key = the template's version.** A service with no key of its own (and no `IMAGE_TAG_DEFAULT`) gets the name
  and tag/digest from the template overlay (`k8s/overlays/<OVERLAY_TEMPLATE>/kustomization.yaml`). So clearing a key, or
  clearing `IMAGE_REGISTRY`, reverts to the template. An image the template does not have (for example a non-openhim
  emitter from `k8s/emitters/`) gets no tag at all, i.e. the tag in its own manifest.
- **Mirrors and day-2 scripts.** [redeploy.sh](lib-day2.md#redeploysh) with no deployment names finds deployments by
  the image names in the overlay's `images:` block, whatever the registry, so `IMAGE_REGISTRY` mirrors work.
  [image-changed.sh](lib-day2.md#image-changedsh) can only check ghcr.io; a mirrored deployment named explicitly is
  reported as "not checked".
- The template overlay's own tags are mutable (`latest`, and for the insights images `demo-rw-latest`, a build of the
  first implementation). apply-image-pins.sh prints a `NOTE` while any image still uses a `demo-rw` tag. Pin every
  service for a real deployment.
- **Insights builds.** `example.env` sets `IMAGE_CCE_INSIGHTS_SERVICE` and `IMAGE_CCE_INSIGHTS_UI` to `demo-dev-latest`:
  the unbranded `demo-dev` branch build, with step groups. It reads ClickHouse's `step_group_instances`, which the
  vendored `data-pipeline/` creates (cce-data-pipeline `demo-v2`, step groups), and needs Matcher migration V8. For a
  real deployment pin `demo-dev-v<N>` or a digest. Other lines: `demo-rw-*` (Rwanda), `demo-tiberbu-*`, `latest`/`v<N>`
  (main).
- **Upgrading an existing environment to the step-group pipeline** (a fresh install needs none of this): follow the
  steps at the top of `data-pipeline/schema/10-step-groups-upgrade.sql` — publication + connector (re-run install.sh),
  then `sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env> 10-step-groups-upgrade` followed by a plain
  `redeploy-clickhouse.sh <env>` to create the new tables and views.

## Emitter adaptor selection

Each implementation runs one emitter adaptor: the one for its source system. It receives that system's events, strips
clinical findings, and forwards them to the collector.

### `EMITTER_ADAPTOR`
- **Meaning:** which `<system>-cce-emitter-adaptor` to deploy. `openhim` is built into `k8s/base`; any other is a
  directory `k8s/emitters/<name>/` (a kustomization plus `emitter.conf`). Available today: `openhim`, `tiberbu`.
- **Default:** `openhim`.
- **Read by:** `install.sh` (validates it before anything is installed, and prints it in the summary),
  [apply-emitter.sh](lib-install.md#apply-emittersh) (rewrites the overlay), and
  [infisical-seed.sh](lib-infisical.md#infisical-seedsh) (default names for the inbound client and user). Later steps
  read the choice back from the overlay, not from the config: [05-k8s-deploy.sh](native.md#05-k8s-deploysh)
  (Prometheus job) and [06-seed.sh](native.md#06-seedsh) (permission row, Keycloak).
- **What the source system uses:** `POST https://<INGRESS_HOST>/v1/<name>-emitter-adaptor/inbound` with HTTP Basic
  credentials. The user is `EMITTER_INBOUND_USER` (default `<name>-emitter-inbound`); the password is
  `EMITTER_INBOUND_PASSWORD`, generated into Infisical `/keycloak` unless you put your own in the seed file. Read it with
  `sudo bash one-click-installer/lib/infisical-run.sh <envcode> printenv EMITTER_INBOUND_USER EMITTER_INBOUND_PASSWORD`.
  The install's result section prints the URL and this command.
- **Change later:** edit the config and re-run install.sh. apply-emitter.sh switches the overlay in either direction,
  and the seed step creates the new emitter's Keycloak client and user. The old emitter's Keycloak client and user stay
  (remove them in Keycloak if no longer wanted).
- **Gotchas:**
  - The password is only used when the inbound user is **created**. An existing user's password is never changed, so
    changing `EMITTER_INBOUND_PASSWORD` in Infisical later has no effect on Keycloak; change it in Keycloak too.
  - Pin the emitter image with `IMAGE_CCE_EMITTER_ADAPTOR` (see above). The tiberbu manifest defaults to `:latest`.
  - Adding another emitter: create `k8s/emitters/<name>/` with `kustomization.yaml`, the Deployment + Service
    manifest, and `emitter.conf` (`DEPLOYMENT`, `PORT`, `IMAGE`, `SOURCE`). The Deployment and Service must both be
    named `DEPLOYMENT`; the gateway routes `/v1/<DEPLOYMENT>/**` to `http://<DEPLOYMENT>:<PORT>` and strips the first two
    path segments, so the adaptor must serve `POST /inbound`.

## Data pipeline version

### `DATA_PIPELINE_REF`
- **Meaning:** branch, tag or full commit SHA of `DATA_PIPELINE_REPO` to deploy (ClickHouse schema, CDC publication,
  Debezium connector, Grafana dashboards). It is SQL and config, not an image.
- **Default:** empty = use `data-pipeline/` as it is in this repository.
- **Read by:** [sync-data-pipeline.sh](lib-install.md#sync-data-pipelinesh), `install.sh` (summary).
- **Change later:** re-run install.sh, or run sync-data-pipeline.sh by hand. Then apply the schema with
  [redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh): a re-run of install.sh only creates objects that do not
  exist yet.
- **Gotchas:** syncing replaces `data-pipeline/{schema,cdc,connectors,infra}` including local edits (this repository's
  copy keeps 200 days in ClickHouse; upstream keeps 90). Setting the key back to empty does **not** restore the
  vendored copy; use `git checkout data-pipeline/`. The ref must match the service versions you deploy.

### `DATA_PIPELINE_REPO`
- **Default:** `https://github.com/openphc/cce-data-pipeline.git`.
- **Read by:** [sync-data-pipeline.sh](lib-install.md#sync-data-pipelinesh). Fetched without prompting for a password,
  so a private repository needs credentials already configured for git on the machine.

## Clinical protocol (optional)

### `PROTOCOL_FILE`, `PROTOCOL_LOAD_URL`
- **Meaning:** a FHIR R4 PlanDefinition JSON for this implementation, and the endpoint to post it to. Since 2.0 the
  endpoint is `https://<INGRESS_HOST>/v1/protocol/protocol-definitions`.
- **Default:** empty = skip.
- **Read by:** [06-seed.sh](native.md#06-seedsh). Both must be set; `PROTOCOL_FILE` must be readable (validated).
- **Credential:** `PROTOCOL_AUTH='Bearer <token>'` (a token with `COMPLIANCE_WRITE`) must be in the **environment**,
  never in the file.
- **Change later:** 06 reads the protocol's `url` and `version` from the file and lists what is loaded at
  `PROTOCOL_LOAD_URL`. If that `url|version` is already there it is not posted again, so re-runs are safe. To load a
  new protocol version, change `version` in the file (or point `PROTOCOL_FILE` at the new one) and re-run.

## Automation

### `ASSUME_YES` (Advanced section of example.env)
- Any non-empty value answers both confirmation prompts with yes. Same as `--yes`.

### `SKIP_PREREQS` (Advanced section of example.env)
- Any non-empty value skips phase 1 ([prereqs.sh](lib-install.md#prereqssh)). Use only on a machine you know is ready.

---

## Environment variables that are not config keys

These are read from the environment. Pass them with `sudo env VAR=value bash …`. Put in the config file, they work
but trigger the "unknown key" warning.

| Variable | Read by | Meaning |
|---|---|---|
| `INFISICAL_ADMIN_EMAIL`, `INFISICAL_ADMIN_PASSWORD` | install.sh, [infisical-bootstrap.sh](lib-infisical.md#infisical-bootstrapsh) | Org-admin login for a remote Infisical. Prompted for if absent. Not needed with a local Infisical. |
| `PROTOCOL_AUTH` | [06-seed.sh](native.md#06-seedsh) | `Authorization` header value for the protocol load. |
| `FORCE_K3S_REINSTALL` | [prereqs.sh](lib-install.md#prereqssh) | Reinstall k3s at `K3S_VERSION` if the cluster has no workload pods. |
| `CHECK_ONLY` | [prereqs.sh](lib-install.md#prereqssh) | Report only, install nothing. |
| `NEED_DOCKER` | [prereqs.sh](lib-install.md#prereqssh) | Install docker even with native runtimes. |
| `CCE_LOCAL_INFISICAL_DIR` | install.sh, [infisical-native.sh](lib-infisical.md#infisical-nativesh), [infisical-local.sh](lib-infisical.md#infisical-localsh) | State directory of the local Infisical. Default `/opt/cce-local-infisical`. |
| `INFISICAL_IMAGE` | [infisical-local.sh](lib-infisical.md#infisical-localsh) | Image for the docker Infisical. Default: a pinned digest. |
| `CDC_TABLE_WAIT_SECS` | [04-data-pipeline.sh](native.md#04-data-pipelinesh) | How long to wait for the services to create the CDC tables. Default 1200. |
| `KC_PF_PORT` | [06-seed.sh](native.md#06-seedsh) | Local port for the Keycloak port-forward. Default 18080. |
| `CH_HTTP_PORT`, `CH_TCP_PORT`, `CH_INTERSERVER_PORT`, `CH_METRICS_PORT` | [02](native.md#02-install-clickhousesh), [05](native.md#05-k8s-deploysh) | ClickHouse ports. Defaults 8123, 9000, 9009, 9363. Leave them alone on a dedicated machine. |
| `CONNECT_REST_PORT`, `CONNECT_URL`, `CH_HTTP` | [03](native.md#03-install-kafka-connectsh), [04](native.md#04-data-pipelinesh), [connector-repoint.sh](tools.md#connector-repointsh) | Kafka Connect REST port / URL, ClickHouse HTTP URL. Defaults 8083, `http://localhost:8083`, `http://localhost:8123`. |
| `NODE_EXPORTER_SHIFT_PORT` | [05-k8s-deploy.sh](native.md#05-k8s-deploysh) | Move node-exporter off 9100. Unset on a dedicated machine. |
| `KUBECTL` | most k8s scripts | kubectl command to use. Default `kubectl` if present, else `sudo k3s kubectl` (`k3s kubectl` in portainer.sh / set-admin-passwords.sh). |
| `DRY_RUN`, `REFRESH_ENV`, `CHANGED_ONLY`, `IMAGE_TAG`, `IMAGE_DIGEST`, `ASK_VERSION`, `ROLLOUT_TIMEOUT`, `WAIT_DELETE_TIMEOUT`, `REFRESH_MV`, `DROP_FIRST` | [day-2 scripts](lib-day2.md) | See each script. |

---

## The seed file

`SEED_ENV_FILE` points at a plain `KEY=value` file. It is how you give Infisical values you choose yourself, instead
of generated or default ones. Keep it **outside the repository**; it holds passwords.

### Format

Parsed by [infisical-seed.sh](lib-infisical.md#infisical-seedsh), not by the shell:

- One `KEY=value` per line. Lines starting with `#` are comments.
- Spaces in the key are removed. Leading and trailing spaces in the value are removed.
- A value in quotes (`"…"` or `'…'`) is taken exactly, up to the closing quote, `#` included.
- Unquoted, `#` is part of the value (`s3cret#2027` is kept whole). Only whitespace followed by `#` starts a
  trailing comment: `KEY=value   # note` stores `value`.
- An empty value is the same as not giving the key.

### What happens to each key

`install.sh` copies the file to a temporary file, appends `INGRESS_HOST` and `ACME_EMAIL` from the config if they are
set and not already in it, then runs [infisical-seed.sh](lib-infisical.md#infisical-seedsh). For each key in the
script's `SPEC` table:

| Kind | Key in seed file | Key not in seed file |
|---|---|---|
| `secret` | Stored (overwrites Infisical) | Existing Infisical value kept; if none, a random alphanumeric value (up to 32 characters) is generated and stored |
| `default` | Stored | Existing Infisical value kept; if none, the default is stored |
| `blank` | Stored | Not touched (an absent key behaves like an empty one) |
| `detected` | Stored, and then wins over detection | Not stored; derived from the host IP at deploy time ([host-ip.sh](lib-infisical.md#host-ipsh)) |

Any key in the seed file that is not in `SPEC` is stored under `/platform`, so nothing you supply is dropped.

> **Changing a value later.** Change it in Infisical and redeploy: a re-run of install.sh keeps it (for example
> `CCE_OPSALERT_NOTIFICATIONS_ENABLED=true` once the environment is live). A value in the seed file, however, is written
> on **every** run and overwrites Infisical, so remove a key from the seed file once you manage it in Infisical.
> Corollary: when a new installer version changes a default, existing environments keep their stored value.

### Required in the seed file

These have no default and are not optional in [overlay-vars-check.sh](lib-install.md#overlay-vars-checksh). Without
them phase 5 fails and nothing is installed. The intelligence service will not start without them.

```
CCE_INTELLIGENCE_SMTP_HOST=
CCE_INTELLIGENCE_SMTP_USERNAME=
CCE_INTELLIGENCE_SMTP_PASSWORD=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER1=
CCE_INTELLIGENCE_ALERT_NAME_TIER1=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER2=
CCE_INTELLIGENCE_ALERT_NAME_TIER2=
CCE_INTELLIGENCE_ALERT_EMAIL_TIER3=
CCE_INTELLIGENCE_ALERT_NAME_TIER3=
```

### Commonly supplied

- Emitter / OpenHIM: `OPENHIM_CORE_HOST`, `OPENHIM_USERNAME`, `OPENHIM_PASSWORD`, `FACILITY_FILTER_IDS`, and
  `OPENHIM_CORE_SCHEME` / `OPENHIM_CORE_API_PORT` / `OPENHIM_CORE_AUTH_TYPE` if they differ from the defaults.
- `GATEWAY_ALLOWED_ORIGINS` (CORS).
- Passwords you want to fix in advance: `GRAFANA_ADMIN_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD`,
  `PORTAINER_ADMIN_PASSWORD` (12 characters minimum; it lands in `/platform` and [portainer.sh](lib-install.md#portainersh)
  copies it to `/portainer` on first install).

### The SPEC table

Folder = Infisical folder. `infisical run --recursive` flattens all folders into one environment, so the folder is for
organisation only.

| Key | Folder | Kind | Default |
|---|---|---|---|
| `POSTGRES_HOST` | /postgres | detected | host IP |
| `POSTGRES_PORT` | /postgres | default | `5432` |
| `POSTGRES_DATABASE` | /postgres | default | `ccedb` |
| `POSTGRES_USER` | /postgres | default | `admin` |
| `POSTGRES_PASSWORD` | /postgres | secret | generated |
| `POSTGRES_READ_ONLY_USER` | /postgres | default | `cce_cdc_user` |
| `POSTGRES_READ_ONLY_PASSWORD` | /postgres | secret | generated |
| `CLICKHOUSE_HOST` | /clickhouse | detected | host IP |
| `CLICKHOUSE_PORT` | /clickhouse | default | `8123` |
| `CLICKHOUSE_DB` | /clickhouse | default | `cce_analytics` |
| `CLICKHOUSE_USER` | /clickhouse | default | `cce_pipeline` |
| `CLICKHOUSE_PASSWORD` | /clickhouse | secret | generated |
| `CLICKHOUSE_USE_FINAL` | /clickhouse | default | `true` |
| `KAFKA_BOOTSTRAP_SERVERS` | /kafka | detected | `<host IP>:9092` |
| `CONNECT_URL` | /kafka-connect | default | `http://localhost:8083` |
| `KEYCLOAK_ADMIN_USER` | /keycloak | default | `admin` |
| `KEYCLOAK_ADMIN_PASSWORD` | /keycloak | secret | generated |
| `BASIC_AUTH_ENABLED` | /keycloak | default | `true` |
| `BASIC_AUTH_CLIENT_ID` | /keycloak | default | `<EMITTER_ADAPTOR>-basic` |
| `BASIC_AUTH_CLIENT_SECRET` | /keycloak | secret | generated |
| `EMITTER_INBOUND_USER` | /keycloak | default | `<EMITTER_ADAPTOR>-emitter-inbound` |
| `EMITTER_INBOUND_PASSWORD` | /keycloak | secret | generated |
| `GRAFANA_ADMIN_USER` | /grafana | default | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | /grafana | secret | generated |
| `OPENHIM_CORE_HOST` | /openhim-emitter-adaptor | blank | |
| `OPENHIM_CORE_API_PORT` | /openhim-emitter-adaptor | default | `8080` (must not be empty: the emitter crash-loops on an empty int) |
| `OPENHIM_CORE_SCHEME` | /openhim-emitter-adaptor | default | `https` |
| `OPENHIM_CORE_AUTH_TYPE` | /openhim-emitter-adaptor | default | `basic` |
| `OPENHIM_USERNAME`, `OPENHIM_PASSWORD` | /openhim-emitter-adaptor | blank | |
| `FACILITY_FILTER_IDS` | /openhim-emitter-adaptor | blank | |
| `CCE_COLLECTOR_AUTH_TOKEN` | /platform | secret | generated |
| `INGRESS_HOST`, `ACME_EMAIL`, `GATEWAY_ALLOWED_ORIGINS` | /platform | blank | |
| `CACHE_TTL_ANALYTICS`, `CACHE_TTL_LOOKUPS`, `CACHE_TTL_METRICS` | /platform | default | `30` |
| `IMAGE_PULL_POLICY` | /platform | default | `Always` |
| `CCE_OPSALERT_NOTIFICATIONS_ENABLED` | /platform | default | `false` |
| `CCE_OPSALERT_REPEAT_INTERVAL_MINUTES` | /platform | default | `1440` |
| `CCE_OPSALERT_TIER1_THRESHOLD_MINUTES` | /platform | default | `240` |
| `CCE_OPSALERT_TIER2_THRESHOLD_MINUTES` | /platform | default | `1440` |
| `CCE_OPSALERT_TIER3_THRESHOLD_MINUTES` | /platform | default | `2880` |
| `CCE_OPSALERT_TIER1_CC` … `TIER3_CC` | /platform | blank | |
| `CCE_INTELLIGENCE_SMTP_PORT` | /platform | default | `587` |
| `CCE_INTELLIGENCE_SMTP_HOST`, `_USERNAME`, `_PASSWORD` | /platform | blank | **required in seed** |
| `CCE_INTELLIGENCE_ALERT_EMAIL_TIER1..3`, `CCE_INTELLIGENCE_ALERT_NAME_TIER1..3` | /platform | blank | **required in seed** |
| `VM_HOST_IP`, `VM_HOST_CIDR` | /platform | detected | host IP, `<host IP>/32` |

Other scripts add keys outside this table:

| Key | Folder | Written by |
|---|---|---|
| `POSTGRES_EXPORTER_PASSWORD` | /postgres | [07-monitoring-exporters.sh](native.md#07-monitoring-exporterssh) (generated once) |
| `PORTAINER_ADMIN_PASSWORD` | /portainer | [portainer.sh](lib-install.md#portainersh) (seed value or generated once), [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh) |

Notes:

- `POSTGRES_DATABASE` is used by the services and the Debezium connector template. The native install steps use
  `POSTGRES_DB` (never seeded, so always `ccedb`). Do not change the database name.
- `CLICKHOUSE_PORT`, `POSTGRES_PORT`, `CONNECT_URL` describe the standard ports the native steps use. Changing them in
  Infisical does not move the services.
- The keys the overlay may leave empty (reported as notes, not failures) are: `OPENHIM_CORE_HOST`, `OPENHIM_USERNAME`,
  `OPENHIM_PASSWORD`, `FACILITY_FILTER_IDS`, `INGRESS_HOST`, `ACME_EMAIL`, `GATEWAY_ALLOWED_ORIGINS`,
  `BASIC_AUTH_CLIENT_ID`, `CCE_OPSALERT_TIER1_CC`, `CCE_OPSALERT_TIER2_CC`, `CCE_OPSALERT_TIER3_CC`.

### After the install: changing a value

1. Change it in Infisical (UI over an SSH tunnel to port 8080, or the `infisical` CLI). If the key is also in the seed
   file, change it there too (or remove it there): seed values are written on every install.sh run.
2. `sudo bash one-click-installer/lib/redeploy.sh cce-<env> [deployment…]` re-renders `cce-config` / `cce-secrets`
   and restarts the deployments.
3. Grafana and Portainer admin passwords live in their own databases after first start. Use
   [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh), not Infisical alone.

---

## `config/.gitignore`

[`config/.gitignore`](../config/.gitignore) contains:

```
*.env
!example.env
```

Every `config/*.env` is ignored by git except the documented template. A real config names hosts and networks; it is
kept out of the repository on purpose. Keep a copy of your config somewhere safe: install.sh needs the same file for
every re-run. The seed file should not be in `config/` at all; keep it outside the repository.
