# lib/ — Infisical and host-IP scripts

How the installer creates and uses the secrets store, and how the machine's IP address is filled in at deploy time.
Other lib scripts: [lib-install.md](lib-install.md), [lib-day2.md](lib-day2.md), [native.md](native.md).

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes.**

## How the pieces fit

```
phase 2   infisical-native.sh up        (or infisical-local.sh up, or nothing for a remote Infisical)
            -> Infisical on 127.0.0.1:8080 + /opt/cce-local-infisical/admin.env (org-admin login)
          infisical-bootstrap.sh <env>  (only if <env>.creds/.meta do not exist yet)
            -> project cce-<env>, machine identity cce-<env>-identity
            -> <creds dir>/<env>.creds   INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET
               <creds dir>/<env>.meta    PROJECT_ID / INFISICAL_ENV_SLUG=prod
phase 3   infisical-run.sh <env> infisical-seed.sh <env> <seed>
            -> secrets and defaults written into the project folders
phase 5+  infisical-run.sh <env> <command>
            -> logs in as the machine identity, `infisical run --recursive` injects every secret as an
               environment variable, host-ip-exec.sh fills the IP variables, then runs <command>
```

The creds files are the only "secret zero" on disk. Everything else is fetched from Infisical each time.

Contents:
[creds-dir.sh](#creds-dirsh) ·
[infisical-native.sh](#infisical-nativesh) ·
[infisical-local.sh](#infisical-localsh) ·
[infisical-bootstrap.sh](#infisical-bootstrapsh) ·
[infisical-seed.sh](#infisical-seedsh) ·
[infisical-secret-helpers.sh](#infisical-secret-helperssh) ·
[infisical-run.sh](#infisical-runsh) ·
[host-ip.sh](#host-ipsh) ·
[host-ip-exec.sh](#host-ip-execsh)

---

## creds-dir.sh

[`lib/creds-dir.sh`](../lib/creds-dir.sh)

**Purpose.** Defines `cce_creds_dir`, which prints the directory that holds `<env>.creds` and `<env>.meta`.

**Called by / when to run.** Sourced by `install.sh`, [infisical-bootstrap.sh](#infisical-bootstrapsh),
[infisical-run.sh](#infisical-runsh), [infisical-secret-helpers.sh](#infisical-secret-helperssh),
[redeploy.sh](lib-day2.md#redeploysh). Not run by hand.

**Usage.** `. lib/creds-dir.sh; dir="$(cce_creds_dir)"`

**Reads.** `CCE_INFISICAL_CREDS_DIR`, `SUDO_USER`, `logname`, `HOME`.

**Changes.** Nothing.

**Safe to re-run?** Yes.

**Verify.** `install.sh` shows it as `Creds dir:` in the summary.

**Notes.** Resolution order:
1. `CCE_INFISICAL_CREDS_DIR` if set.
2. Otherwise `<home>/.cce-infisical`, where `<home>` is the home of `SUDO_USER` (the user who ran `sudo`), else of
   `logname`, else `$HOME`, else `/root`.

So `sudo bash install.sh` run by user `alice` writes to `/home/alice/.cce-infisical/`. The files are created by root
with mode 0600, so later scripts that read them must also run with `sudo`. If a different user runs a day-2 script,
the directory resolves differently; set `CCE_INFISICAL_CREDS_DIR` explicitly in that case.

---

## infisical-native.sh

[`lib/infisical-native.sh`](../lib/infisical-native.sh)

**Purpose.** Runs a local Infisical without containers: the `infisical-core` apt package, Ubuntu's Redis, and a
database in the native PostgreSQL. Can also move an existing docker Infisical to native.

**Called by / when to run.** `install.sh` phase 2 when `USE_LOCAL_INFISICAL=true` and `LOCAL_INFISICAL_RUNTIME=native`
(the default): `migrate` if a docker container `cce-local-infisical-db-1` exists, else `up`. By hand: `status`.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-native.sh up        # install and start (fresh machine, or re-run)
sudo bash one-click-installer/lib/infisical-native.sh migrate   # move the docker Infisical to native
sudo bash one-click-installer/lib/infisical-native.sh status    # health and version
```

**Reads.** `CCE_LOCAL_INFISICAL_DIR` (default `/opt/cce-local-infisical`), `INFISICAL_CORE_VERSION` (default
`0.162.24-1`), `POSTGRES_VERSION` (default 16).

**Changes** (`up`):
1. `<state>/.env` (mode 0600, directory 0700): `ENCRYPTION_KEY`, `AUTH_SECRET`, `PG_PASSWORD`, generated once. **Back
   this file up.** Without `ENCRYPTION_KEY` the stored secrets cannot be decrypted. (The restrictive umask applies only
   to this file; files created later, such as apt keyrings, keep normal modes.)
2. Redis: installs `redis-server` if missing, sets `bind 127.0.0.1` and `protected-mode yes` in
   `/etc/redis/redis.conf`, enables and restarts it.
3. PostgreSQL: if `psql` is missing, installs `postgresql-<version>` from the PGDG apt repository (keyring
   `/etc/apt/trusted.gpg.d/postgresql.gpg`, mode 644 so apt's `_apt` user can read it). Creates or updates
   the role `infisical` (password `PG_PASSWORD`) and the database `infisical`.
4. Adds the `infisical-core` apt repository (if `/etc/apt/sources.list.d/infisical-core.list` is absent), installs
   `infisical-core=<version>` when the installed version differs (with `--allow-downgrades
   --allow-change-held-packages`, so a version change works on a held package), and holds the package again.
5. Writes `/etc/infisical/infisical.rb` (mode 0600; contains the keys and the database URL) with `HOST=127.0.0.1`,
   `PORT=8080`, `SITE_URL=http://localhost:8080`, telemetry off. Runs `infisical-ctl reconfigure` (log:
   `/tmp/infisical-reconfigure.log`). Waits up to 3 minutes for `GET /api/status`. **Fails if Infisical listens on
   anything other than 127.0.0.1.**
6. First org admin: if `<state>/admin.env` does not exist, signs up `admin@cce.local` with a random password and
   writes `INFISICAL_ADMIN_EMAIL`, `INFISICAL_ADMIN_PASSWORD`, `INFISICAL_DOMAIN` to `<state>/admin.env` (0600).

`migrate` does steps 1–4 (reusing the docker install's `.env`, so the same keys decrypt the data), stops the docker
backend, dumps the docker database to `<state>/docker-infisical-<timestamp>.sql.gz` (0600), drops and recreates the
native `infisical` database, restores the dump as role `infisical`, then step 5. `install.sh` then runs
`docker compose … down` (the data volume is kept).

**Safe to re-run?** `up`: yes. Secrets, role, database and admin are reused; the config is rewritten and the service
reconfigured each time. `migrate`: run once; on a second run the native database is dropped and restored again from
the docker copy.

**Verify.**
```bash
sudo bash one-click-installer/lib/infisical-native.sh status     # native Infisical: UP at http://127.0.0.1:8080 (<version>)
ss -tlnp | grep 8080                                             # 127.0.0.1:8080 only
```
UI: `ssh -L 8080:localhost:8080 <user>@<host>`, open `http://localhost:8080`, log in with the values in
`/opt/cce-local-infisical/admin.env`.

**Notes.**
- If `admin.env` is lost, `up` tries to sign up again, the server refuses (an admin exists), and the script stops.
  Restore `admin.env` from backup.
- Never lower `INFISICAL_CORE_VERSION` below the version that wrote the database.
- The package is held with `apt-mark hold`, so a routine `apt upgrade` does not move it. Changing
  `INFISICAL_CORE_VERSION` and re-running install.sh overrides the hold for that one install.
- Logs: `infisical-ctl tail`.

---

## infisical-local.sh

[`lib/infisical-local.sh`](../lib/infisical-local.sh)

**Purpose.** The older docker compose variant of the local Infisical: PostgreSQL 14, Redis 7 and the Infisical image,
API published on `127.0.0.1:8080` only.

**Called by / when to run.** `install.sh` phase 2 when `USE_LOCAL_INFISICAL=true` and `LOCAL_INFISICAL_RUNTIME=docker`.
By hand: `status`, `down`, `reset`.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-local.sh up       # start, create the first org admin, write admin.env
sudo bash one-click-installer/lib/infisical-local.sh status
sudo bash one-click-installer/lib/infisical-local.sh down     # stop, data kept
sudo bash one-click-installer/lib/infisical-local.sh reset    # stop and DELETE all its data
```

**Reads.** `CCE_LOCAL_INFISICAL_DIR` (default `/opt/cce-local-infisical`), `INFISICAL_IMAGE` (default: a pinned
`infisical/infisical@sha256:…` digest).

**Changes.** Installs `docker.io` and `docker-compose-v2` if missing. Writes `<state>/.env` (once, 0600) and
`<state>/docker-compose.yml` (every `up`). Starts compose project `cce-local-infisical` with volume `pgdata`. Signs up
`admin@cce-local.invalid` and writes `<state>/admin.env` (0600) if it does not exist.

**Safe to re-run?** `up`, `status`, `down`: yes. `reset`: destroys every secret in this Infisical, including every
project's values. Only use it on a trial machine.

**Verify.** `sudo bash one-click-installer/lib/infisical-local.sh status` → `local Infisical: UP at http://127.0.0.1:8080`.

**Notes.** With `LOCAL_INFISICAL_RUNTIME=native` (the default), the next `install.sh` run migrates this docker
Infisical to native with [infisical-native.sh migrate](#infisical-nativesh).

---

## infisical-bootstrap.sh

[`lib/infisical-bootstrap.sh`](../lib/infisical-bootstrap.sh)

**Purpose.** Creates the Infisical project `cce-<env>` and a Universal Auth machine identity `cce-<env>-identity` with
admin access to that project, then writes the creds files that every other script uses.

**Called by / when to run.** `install.sh` phase 2, only when `<env>.creds` and `<env>.meta` do not both exist.
By hand: `--manual` when the automated path cannot work (for example, the admin belongs to several organisations).

**Usage.**
```bash
sudo env INFISICAL_ADMIN_EMAIL=… INFISICAL_ADMIN_PASSWORD=… bash one-click-installer/lib/infisical-bootstrap.sh <env>
sudo bash one-click-installer/lib/infisical-bootstrap.sh <env> --manual
```

**Reads.** `INFISICAL_DOMAIN` (default `http://localhost:8080`), `INFISICAL_ADMIN_EMAIL`, `INFISICAL_ADMIN_PASSWORD`
(prompted for if empty), `CCE_INFISICAL_CREDS_DIR`.

**Changes.** In Infisical (automated path):
1. Logs in with `POST /api/v3/auth/login` (no organisation) and lists the admin's organisations. Needs **exactly one**;
   otherwise falls back to manual. The request body is built by Python from the environment and sent on stdin, so the
   password is never in any process's arguments, and quotes or backslashes in it are escaped correctly.
2. Exchanges that token for an organisation-scoped one with `POST /api/v3/auth/select-organization` (the same exchange
   `infisical login --organization-id` performs, without putting the password on a command line).
3. Creates project `cce-<env>`. New projects get environments `dev`, `staging`, `prod`; the installer uses slug `prod`.
4. Creates identity `cce-<env>-identity` with organisation role `no-access`, adds Universal Auth, creates a client
   secret, and grants the identity role `admin` on the project.
5. Logs in as the new identity to prove it works.

On disk: `<creds dir>/<env>.creds` (`INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`) and `<creds dir>/<env>.meta`
(`PROJECT_ID`, `INFISICAL_ENV_SLUG=prod`), both 0600.

Manual path: prints step-by-step UI instructions, asks for project id, client id and client secret, writes the same two
files, and verifies the login (deletes the files if it fails).

**Safe to re-run?** No. It stops if `<env>.creds` exists. A failure part-way leaves a project and/or identity behind;
the script prints their ids. Delete them in the Infisical UI (deletes have been seen to fail once and succeed on retry).

**Verify.** `[infisical-bootstrap <env>] SUCCESS — project=… identity=…`. Then
`sudo bash one-click-installer/lib/infisical-run.sh <env> true` exits 0.

**Notes.**
- The admin login must be a real user with organisation-admin rights. A project-scoped identity cannot create a project.
- If `install.sh` says `existing creds no longer log in`, remove `<creds dir>/<env>.{creds,meta}` and re-run to
  bootstrap afresh. This creates a **new** project; the old project's values are not copied.
- If only one of the two files exists, `install.sh` calls bootstrap, which stops because `.creds` exists. Remove the
  leftover file.

---

## infisical-seed.sh

[`lib/infisical-seed.sh`](../lib/infisical-seed.sh)

**Purpose.** Fills the environment's Infisical project: values from the seed file as given; missing secrets generated;
missing non-secrets set to a safe default or left blank for you to fill in later.

**Called by / when to run.** `install.sh` phase 3, every run, under [infisical-run.sh](#infisical-runsh). By hand after
editing the seed file, if you do not want a full re-run.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/infisical-seed.sh <env> /path/to/seed.env
```
The seed path is required. Give an empty file if you have nothing to seed.

**Reads.** The seed file. The machine-identity login from the environment (`INFISICAL_CLIENT_ID` /
`INFISICAL_CLIENT_SECRET`, injected by `infisical-run.sh`). The `.meta` file.

**Changes.** Infisical secrets in project `cce-<env>`, environment `prod`, in folders `/postgres`, `/clickhouse`,
`/kafka-connect`, `/keycloak`, `/grafana`, `/openhim-emitter-adaptor`, `/platform` (created if missing). The full key
table and the rules per kind are in [config.md → The seed file](config.md#the-seed-file).

**Safe to re-run?** Yes. Generated secrets are never rotated, and a `default` key that already has a value in
Infisical is kept (not reset to the default), so changes made in Infisical survive. The one exception: every key in
the seed file is written on every run and overwrites the Infisical value. Once you manage a key in Infisical, remove
it from the seed file (or change it in both).

**Verify.** The summary lists keys `from seed file`, `generated secrets`, `fixed defaults` (stored now because
Infisical had none), `kept (already in Infisical, default not re-applied)`, `NOT STORED — detected`, and `LEFT BLANK`.
Check the blank list: those features stay off until you fill them in.

**Notes.**
- `#` inside a value is kept. Only whitespace followed by `#` starts a trailing comment; a quoted value is taken
  verbatim up to its closing quote ([config.md → Format](config.md#format)).
- Two `default` keys depend on `EMITTER_ADAPTOR`: `BASIC_AUTH_CLIENT_ID` (`<emitter>-basic`) and `EMITTER_INBOUND_USER`
  (`<emitter>-emitter-inbound`). Because existing values are kept, switching emitters later keeps the old names unless
  you change them in Infisical.
- An empty value is never stored (the Infisical CLI rejects empty values). An absent key and an empty one behave the
  same for the deploy.
- Keys the script does not know are stored under `/platform`.

---

## infisical-secret-helpers.sh

[`lib/infisical-secret-helpers.sh`](../lib/infisical-secret-helpers.sh)

**Purpose.** Shared shell functions for reading and writing single Infisical secrets.

| Function | Does |
|---|---|
| `infisical_resolve_project <env> [creds_dir]` | Sources `<creds dir>/<env>.meta`; exports `PROJECT_ID`, `INFISICAL_ENV_SLUG`. |
| `infisical_login` | Universal Auth login with `INFISICAL_CLIENT_ID` / `_SECRET`; exports `INFISICAL_TOKEN`. |
| `infisical_get <path> <key> <project> <slug>` | Prints the value, or nothing if unset. |
| `infisical_set <path> <key> <project> <slug> <value>` | Creates the folder if needed, then sets the secret. |
| `infisical_get_or_generate <path> <key> <project> <slug> [generator…]` | Prints the existing value; if none, generates one (default: random alphanumeric, up to 32 characters), stores it and prints it. Never rotates. |

**Called by / when to run.** Sourced by [infisical-seed.sh](#infisical-seedsh), [portainer.sh](lib-install.md#portainersh),
[set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh), [07-monitoring-exporters.sh](native.md#07-monitoring-exporterssh).

**Usage.** Under `infisical-run.sh`:
```bash
. one-click-installer/lib/infisical-secret-helpers.sh
infisical_resolve_project <env>; infisical_login
infisical_get /grafana GRAFANA_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG"
```

**Reads.** `INFISICAL_DOMAIN` (default `http://localhost:8080`), `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`.

**Changes.** Only what `infisical_set` / `infisical_get_or_generate` write.

**Safe to re-run?** Yes.

**Verify.** n/a.

**Notes.** Folders are not created automatically by Infisical: setting `--path=/foo` on a new project fails until
`/foo` exists. `infisical_set` creates it first (once per run).

---

## infisical-run.sh

[`lib/infisical-run.sh`](../lib/infisical-run.sh)

**Purpose.** Runs any command with all of the environment's Infisical secrets as environment variables. This is how
every script gets its configuration.

**Called by / when to run.** `install.sh` (phases 2, 3, 5, 6b). Re-exec wrapper of
[native/install-all.sh](native.md#install-allsh), [redeploy.sh](lib-day2.md#redeploysh),
[redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh), [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh),
[connector-repoint.sh](tools.md#connector-repointsh). By hand whenever you need the values, for example to run a step
on its own.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-run.sh <env> <command> [args…]
sudo bash one-click-installer/lib/infisical-run.sh <env> true                         # test the login only
sudo bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/native/05-k8s-deploy.sh <env>
```

**Reads.** `<creds dir>/<env>.meta`, `<creds dir>/<env>.creds`, `INFISICAL_DOMAIN` (default `http://localhost:8080`).

**Changes.** Nothing. Logs in as the machine identity, then runs
`infisical run --recursive --path=/ --projectId=… --env=prod -- bash host-ip-exec.sh <env> <command>`. `--recursive`
merges every folder into one set of variables.

**Safe to re-run?** Yes.

**Verify.** `sudo bash one-click-installer/lib/infisical-run.sh <env> true; echo $?` → `0`. Errors:
`unknown env '<env>' — no …/<env>.meta`, `missing/unreadable Infisical creds`, `Universal-Auth login failed`.

**Notes.**
- Needs `sudo`: the creds files are root-owned, mode 0600.
- Do not print the environment inside it (`env`, `set`) in a shared terminal; it holds every secret.
- For a dotenv export of all values, `infisical export --recursive` does not work on this CLI version; export folder by
  folder.

---

## host-ip.sh

[`lib/host-ip.sh`](../lib/host-ip.sh)

**Purpose.** Detects the machine's IP address at deploy time, so it never has to be stored in Infisical (where it would
go stale when the IP changes). Defines `cce_detect_host_ip` and `cce_fill_host_defaults <env>`.

**Called by / when to run.** Sourced by [host-ip-exec.sh](#host-ip-execsh) (so by every `infisical-run.sh` command) and
by [tools/host-ip-check.sh](tools.md#host-ip-checksh). Not run by hand.

**Usage.** `. lib/host-ip.sh; cce_fill_host_defaults <env>`

**Reads.** The routing table (`ip -4 route get 1.1.1.1`, source address). `INGRESS_HOST`. The current
values of the variables below.

**Changes.** Exports, **only if empty**:

| Variable | Value |
|---|---|
| `VM_HOST_IP` | detected address |
| `VM_HOST_CIDR` | `<VM_HOST_IP>/32` |
| `POSTGRES_HOST` | `VM_HOST_IP` |
| `KAFKA_BOOTSTRAP_SERVERS` | `<VM_HOST_IP>:9092` (Kafka's port is fixed) |
| `CLICKHOUSE_HOST` | `VM_HOST_IP` |
| `CCE_PUBLIC_URL` | `https://<INGRESS_HOST>` when set, else `http://<VM_HOST_IP>` — Keycloak's token issuer and Grafana's root URL are built from it |

**Safe to re-run?** Yes.

**Verify.** stderr line `host-ip: [<env>] derived from this host (<ip>): VM_HOST_IP …`.

**Notes.**
- A value set in Infisical wins. If `VM_HOST_IP` from Infisical differs from the detected address it prints a
  `STALE` warning. The fix is to delete those keys from Infisical.
- The detected address is the one used to reach the internet, which is also the address k3s reports as the node's
  InternalIP. On a machine with several interfaces, check it is the one pods should use.
- `GATEWAY_ALLOWED_ORIGINS` is not derived (it is a CORS policy, not topology).
- `CCE_PUBLIC_URL` can be overridden by setting it in Infisical `/platform`, for example `http://<public IP>` on a
  cloud VM without a DNS name, where users reach the machine at a different address than the detected one (see
  [config.md → INGRESS_HOST](config.md#ingress_host)).

---

## host-ip-exec.sh

[`lib/host-ip-exec.sh`](../lib/host-ip-exec.sh)

**Purpose.** Tiny wrapper: source [host-ip.sh](#host-ipsh), fill the IP defaults, then `exec` the command.

**Called by / when to run.** By [infisical-run.sh](#infisical-runsh), inside `infisical run`, so Infisical's values are
already set and win. Not run by hand.

**Usage.** `bash lib/host-ip-exec.sh <env> <command…>`

**Reads / Changes.** As [host-ip.sh](#host-ipsh).

**Safe to re-run?** Yes.

**Verify.** n/a.

**Notes.** None.
