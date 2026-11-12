# RW one-click installer: CCE built from the RW-MOH GitLab

`rw/one-click-install.sh` sets up a complete RW CCE environment on **one dedicated Ubuntu machine**. The CCE service images are
**built on that machine from the RW-MOH GitLab** (`repository.moh.gov.rw/cce/*`). This is the stopgap until GitLab CI/CD builds and
publishes the images.

It is in use for **RW UAT on 102.215.10.21** (config `rw/config/uat.env`). **RW PROD on 102.215.10.20** is to be wiped and set
up with it too (config `rw/config/prod.env`, step-by-step guide `prod/INSTALL-GUIDE.md`). Hostnames on these VMs are misleading,
so always go by IP.

Day-to-day operation (get new code, build, deploy, back up, protocols): `uat/OPERATIONS-RUNBOOK.md`. Security:
`uat/SECURITY.md`. The PROD equivalents will follow once PROD is installed.

## The scripts at a glance

| Script | What it does | When |
|---|---|---|
| `rw/one-click-install.sh` | the whole environment, phases below | first install; re-run after a `cce-data-pipeline` change; resumes after a failure |
| `rw/lib/build-from-source.sh` | **gets the code and builds the images**: fetches each repo into `/opt/cce-src/<repo>`, builds it, imports the image into k3s | called by both scripts here; not run by hand |
| `rw/redeploy-from-source.sh` | day 2: pull + build + deploy (or only one of them: `--build-only`, `--deploy-only [--restart]`) | new commits, branch changes, config changes |
| `rw/config/<env>.env` | repo URL + branch per repo, and every other setting | edit, then run one of the above |

Phases of `rw/one-click-install.sh`:

| Phase | What happens | Script |
|---|---|---|
| RW 1/5 Pre-flight | every repo + branch reachable with the token (`--check-only` stops here) | `rw/lib/build-from-source.sh --check-only` |
| RW 2/5 Prerequisites | k3s, Infisical CLI, docker + JDK 21 + buildx (for the builds) | `one-click-installer/lib/prereqs.sh` |
| RW 3/5 Build | clone into `/opt/cce-src`, build every image, import into k3s | `rw/lib/build-from-source.sh` |
| RW 4/5 Install | the generic installer, with the built tags pinned: native Infisical, seed, overlay, native Postgres/Kafka/ClickHouse/Connect, exporters, k3s deploy, CDC, Keycloak seed, Portainer, firewall | `one-click-installer/install.sh` |
| RW 4b Keycloak | OpenHIM Basic-auth client, role and user | `rw/lib/keycloak-openhim-basic.sh` |
| RW 5/5 Backups | daily cron + a first backup | `rw/lib/install-cron-backups.sh`, `rw/lib/backup-db.sh` |
| (end) | TLS certificate check, "no containers" check, versions deployed | `rw/lib/tls-check.sh` |

> Earlier versions of this installer pulled GHCR images. The scripts of the old shared-VM setup on 102.215.10.20 (`rw/prod`,
> `rw/uat`, most of the old `rw/lib`) were removed from `rw/` on 2026-11-12; a copy is kept outside the repository.

## What you get

The same setup as RW PROD:

- PostgreSQL 16, Kafka (KRaft), ClickHouse 26.5, and Kafka Connect + Debezium, installed natively under systemd
- a local Infisical, installed natively, not in a container
- the `cce-<envcode>` k3s namespace, using PROD's resource sizing, HPAs and rate limits (`HPA_REPLICAS` / `CPU_LIMIT_OVERRIDES`
  adjust them per machine)
- CDC into ClickHouse
- the Keycloak `cce` realm with the RW login theme
- UFW default-deny, with only ports 22, 80 and 443 public
- Prometheus exporters and Portainer as host services, and daily backups
- **no docker containers** (docker is installed only to build the images)

One thing differs from PROD: where the images come from.

| Repo | Built as (same recipe as its CI) |
|---|---|
| cce-common-util | library: the 2.0 services compile against it as `../cce-common-util` |
| cce-collector-service, cce-step-sla-service | `./gradlew bootBuildImage`, with cce-common-util next to them |
| cce-protocol-service, cce-matcher-service | `docker build -f <repo>/Dockerfile <workspace>` (that Dockerfile copies cce-common-util too) |
| cce-intelligence-service, gateway-service, openhim-cce-emitter-adaptor | `./gradlew bootBuildImage` |
| cce-insights-service | `./gradlew bootBuildImage -x generateJooq` |
| cce-insights-ui | `docker build` with the `INSIGHTS_UI_VITE_*` build args |
| cce-data-pipeline | not an image: its schema, CDC and connector config replace the vendored `data-pipeline/` |

How the images get to k3s:

- **Name:** `cce.local/rw/<repo>:<branch>-<commit>`. Repos that use cce-common-util add `-u<commit>` (cce-common-util's commit).
  The UI adds `-c<hash of build args>`.
- **No registry:** each image is imported straight into k3s's containerd, and the pods run with `imagePullPolicy: IfNotPresent`.
- **Rebuilds:** a commit that hasn't changed is never rebuilt. A new commit gets a new tag, and only that deployment rolls.

## Run it

1. **Get deploy-scripts onto the machine**, at `/home/cceadmin/deploy-scripts`. Use the branch **`deploy-scripts-rw`**: it holds
   exactly what this installer needs (`one-click-installer/`, `k8s/`, `grafana/`, `keycloak-themes/` and these `rw/` files) and
   nothing secret. `data-pipeline/` is not in it: the installer creates it from the GitLab `cce-data-pipeline` commit on every run. Once it is in the RW-MOH GitLab, clone it with the same token as the CCE repos (step 2 first):

   ```sh
   sudo env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://repository.moh.gov.rw/.extraHeader \
     GIT_CONFIG_VALUE_0="Authorization: Basic $(sudo sh -c 'printf "oauth2:%s" "$(tr -d "[:space:]" < /root/.cce-gitlab.token)"' | base64 -w0)" \
     git clone -b deploy-scripts-rw https://repository.moh.gov.rw/cce/deploy-scripts.git /home/cceadmin/deploy-scripts
   sudo chown -R cceadmin: /home/cceadmin/deploy-scripts
   ```

   (Repository path as expected once mirrored. Until then, copy the branch's files over instead.) Later updates: the same
   `env … git -C /home/cceadmin/deploy-scripts pull`. Never copy `rw/bkp/` onto a server.
2. **Store the GitLab token**, readable by root only. It needs `read_repository`:
   `sudo install -m 600 /dev/null /root/.cce-gitlab.token`, then put the token in that file.
3. **Write the seed file** `/root/cce-<env>-seed.env` (chmod 600; `SEED_ENV_FILE` in the config). Without these keys the intelligence-service won't start:
   - `CCE_INTELLIGENCE_SMTP_HOST`, `CCE_INTELLIGENCE_SMTP_USERNAME`, `CCE_INTELLIGENCE_SMTP_PASSWORD`
   - `CCE_INTELLIGENCE_ALERT_EMAIL_TIER1..3`
   - `CCE_INTELLIGENCE_ALERT_NAME_TIER1..3`

   Optional: `OPENHIM_*`, `FACILITY_FILTER_IDS`, and any password you want instead of a generated one.
4. **Check the repos:** `sudo bash rw/one-click-install.sh --config rw/config/<env>.env --check-only`. This lists every repo and
   branch, and says whether it is reachable, empty or missing that branch. Nothing is installed.
5. **Install:** `sudo bash rw/one-click-install.sh --config rw/config/<env>.env` (add `--yes` to answer the prompts). The first run
   takes about an hour, mostly on Gradle and buildpack downloads. If it stops part-way, re-run the same command and it resumes.

## OpenHIM authentication (Keycloak)

OpenHIM calls `POST https://<INGRESS_HOST>/v1/openhim-emitter-adaptor/inbound` with HTTP Basic credentials. They belong to a user
in the `cce` realm, `openhim-emitter-inbound`. The gateway, with `BASIC_AUTH_ENABLED=true`, exchanges them for a token via the
`openhim-basic` client and a password grant. It then checks that the token's issuer is `https://<INGRESS_HOST>/auth/realms/cce`,
and lets the role `gateway-service:EMITTER_INBOUND_WRITE` through (seeded in `api_permissions`).

`k8s/seeds/cce-realm.json` has neither that client nor that role; on the old RW PROD and UAT they were added by hand. The generic
installer's seed step (`one-click-installer/lib/keycloak-inbound-basic.sh`) creates them, and phase **RW 4b**
(`rw/lib/keycloak-openhim-basic.sh`) checks them again:

- **Role:** `gateway-service:EMITTER_INBOUND_WRITE`
- **Client:** `openhim-basic`, with its secret equal to Infisical's `BASIC_AUTH_CLIENT_SECRET`
- **User:** `EMITTER_INBOUND_USER` (default `openhim-emitter-inbound`) with that role, created with `EMITTER_INBOUND_PASSWORD`.
  Put the password OpenHIM is configured with in the seed file; without one, the installer generates it (read it with
  `sudo bash one-click-installer/tools/show-credentials.sh <env> --reveal` and give it to the OpenHIM admins). A seed file with
  RW's older names `OPENHIM_INBOUND_USER`/`OPENHIM_INBOUND_PASSWORD` still works: the RW installer passes them on.
- An **existing** user's password is never changed. On an environment installed before these keys existed (UAT .21), a re-run
  stores a generated `EMITTER_INBOUND_PASSWORD` in Infisical that is **not** the user's real password; replace it in Infisical
  with the real one if you want `show-credentials.sh` to be right.

RW defaults `BASIC_AUTH_ENABLED=true` and `BASIC_AUTH_CLIENT_ID=openhim-basic`.

**Moving an existing environment to a new machine** (UAT .20 → .21, 2026-11-04): so OpenHIM's credentials keep working
unchanged after the DNS switch, copy the old Keycloak database instead (`pg_dump keycloak` → restore; both run 26.5.4). That brings:

- the users, with their password hashes, so nobody resets anything
- the client secrets and the realm signing keys

Also put the old environment's `BASIC_AUTH_*`, `KEYCLOAK_ADMIN_USER`/`KEYCLOAK_ADMIN_PASSWORD` (the copied master realm's admin)
and `OPENHIM_*` into the seed file, then re-run the installer. Phase 4b then finds everything already present. A rollback copy of
.21's own fresh Keycloak database is in `/var/backups/cce-uat/pre-keycloak-copy/`.

## Firewall

This is part of the install step (4/5), and matches PROD's live UFW on 102.215.10.20.

- **Docker ports:** the `cce-docker-fw` rule always blocks new connections from the public NIC into ports Docker publishes,
  which otherwise bypass UFW.
- **UFW:** with `IS_CLOUD_DEPLOYMENT=false` (RW is on-prem), `one-click-installer/lib/ufw-baseline.sh` sets:
  - default deny incoming, allow outgoing, allow routed (the k3s pods need routed)
  - public ports 22, 80 and 443 only
  - `lo`, `cni0`, `flannel.1`, `docker0`, the pod and service CIDRs, and 172.16.0.0/12 allowed internally
- **Lock-out guard:** a 10-minute timer disables UFW if the install loses SSH while turning it on.
- **Check:** afterwards, `rw/one-click-install.sh` stops with an error if UFW isn't active, and prints the public ports.

To limit SSH to an admin network, set `SSH_ALLOWED_CIDR`. For extra public rules, set `UFW_EXTRA_ALLOW`.

## Infisical (native)

Infisical is **not** a container. Phase 2 of the generic installer (`one-click-installer/lib/infisical-native.sh up`) installs and runs:

| Piece | What it is |
|---|---|
| `infisical-core` | `INFISICAL_CORE_VERSION`, default `0.162.24-1`, held in apt; configured in `/etc/infisical/infisical.rb`, managed with `infisical-ctl`, started at boot by `infisical-runsvdir.service` |
| Redis | Ubuntu's `redis-server`, bound to 127.0.0.1 |
| Database | `infisical` in the native PostgreSQL, owned by its own role `infisical`. On a fresh machine PostgreSQL 16 is installed here from PGDG, and step 01 later configures it for CCE. |

The API is on **127.0.0.1:8080 only**. Its keys (`ENCRYPTION_KEY`, `AUTH_SECRET`) and the database password live in
`/opt/cce-local-infisical/.env`, and the org-admin login in `admin.env`. Both files are 0600.

**From the Docker Infisical of an older install:** run `one-click-installer/lib/infisical-native.sh migrate`. The installer does this by itself
when it finds that Docker Infisical. It keeps the same keys, copies the database into the native PostgreSQL, and starts the native
server; the installer then removes the containers. The Docker data volume and a dump (`/opt/cce-local-infisical/docker-infisical-*.sql.gz`) stay as a
rollback copy. There is no native 0.161.x package, so the copied database moves forward to 0.162.x; it can't go back.

## TLS after a DNS change

Let's Encrypt can only issue the certificate once public DNS points `INGRESS_HOST` at this machine. If Traefik tried earlier,
it gives up retrying and keeps serving its default certificate. The installer's last step, `rw/lib/tls-check.sh`, handles this:

| What it finds | What it does |
|---|---|
| DNS points elsewhere | says so and does nothing |
| DNS points here, Let's Encrypt certificate served | nothing |
| DNS points here, Traefik's default certificate served | restarts Traefik, then waits up to 3 minutes for the certificate |

After a DNS change, run it by hand:

```sh
sudo bash rw/lib/tls-check.sh cceuat.moh.gov.rw
```

## No containers

After an install **no Docker containers exist** (the installer checks this at the end). Every service is a systemd service or runs in k3s:

| Service | Runs as |
|---|---|
| PostgreSQL 16, Kafka, ClickHouse 26.5, Kafka Connect + Debezium | systemd |
| Infisical (`infisical-core`), Redis | systemd (`infisical-runsvdir`, `redis-server`) |
| postgres_exporter 0.20.1, kafka_exporter 1.11.0 | systemd (`cce-postgres-exporter`, `cce-kafka-exporter`), as the user `cce-exporter`, from checksum-verified release binaries (step 07, `EXPORTER_RUNTIME=systemd`, the default) |
| Portainer server | systemd (`cce-portainer`) |
| CCE services, Keycloak, Grafana, Prometheus, kafka-ui, portainer-agent | k3s |

Docker itself stays installed only to **build** the CCE images (Paketo buildpacks and Dockerfiles). The builds leave no containers.

## Portainer

Phase 6b of the generic installer (`one-click-installer/lib/portainer.sh`, `PORTAINER_ENABLED`, default on) sets up Portainer, as RW PROD has it.

| Piece | Details |
|---|---|
| Server | the `portainer-ce` **release binary** (`PORTAINER_VERSION`, default 2.39.2, checksum-verified) as the systemd service `cce-portainer`; data in `/var/lib/portainer`. HTTPS listens on `:9443`, which Portainer's own Kubernetes proxy needs: `127.0.0.1:9443` breaks every namespace view. systemd `IPAddressAllow` lets only loopback and the k3s pod and service networks connect, and UFW blocks it as well. Edge 8000 is on 127.0.0.1, HTTP is off. No container. |
| Agent | in k3s, from `one-click-installer/lib/portainer-agent.yaml`, with a cluster-admin service account. Its Service is **ClusterIP**. On .20 it is a LoadBalancer, which publishes :9001 to the internet. |
| Environments | `<envcode>-k3s`, plus `local` (this host's Docker) where docker is installed, as it is here for the builds. Both are registered automatically. |
| Admin login | user `admin`; the password is in Infisical `/portainer` `PORTAINER_ADMIN_PASSWORD`. It is taken from the seed file if set there, and generated on the first run otherwise. Change it, and Grafana's, with `one-click-installer/lib/set-admin-passwords.sh <envcode>`. |

To use it, open a tunnel with `ssh -L 9443:localhost:9443 cceadmin@<host>`, then browse to `https://localhost:9443`.
Accept the self-signed certificate.

## Backups

The installer's last phase sets up the same daily backup PROD has:

- **When:** 02:00 every day, from root's crontab
- **What:** `rw/lib/backup-db.sh` dumps `ccedb` and `keycloak` with `pg_dump`, and exports the ClickHouse `cce_analytics` base tables
- **Where:** `/var/backups/cce-<envcode>/<YYYYMMDD>/`, kept for 10 days. Logs rotate weekly.

It also runs one backup straight away to prove the setup works. `uat/OPERATIONS-RUNBOOK.md` §7 covers restore; the files are laid out
as on PROD, but with this env's paths. To change the defaults, re-run with your own values:

```sh
sudo SCHEDULE="30 1 * * *" RETENTION_DAYS=14 bash rw/lib/install-cron-backups.sh <envcode>
```

As on PROD, the backups stay on this machine. Copy them somewhere else, or they don't protect against losing the machine.

## Configuration (`rw/config/<env>.env`)

- **`SRC_<REPO>_REPO` / `SRC_<REPO>_BRANCH`:** the URL and branch for each repo. The branch can also be a tag, or a full
  40-character commit SHA to pin an exact commit; that image is tagged `commit-<sha10>`. Write the reason for a pin as a comment
  above it. No repo is pinned as of 2026-11-12. `<REPO>` is the repo name upper-cased, with `-` replaced by `_`. Point one at another URL or branch, then re-run.
- **`GIT_TOKEN_FILE`:** where the token is stored. You can also export `GIT_TOKEN` instead. The token is sent only to the repo's
  host, as a request header, and never appears in process arguments or in `.git/config`.
- **`SOURCE_DIR`** (`/opt/cce-src`) holds the clones, one directory per repo (`/opt/cce-src/<repo>`), each a shallow checkout of
  exactly the configured commit. Don't edit code there: the next fetch resets it. **`LOCAL_IMAGE_REGISTRY`** (`cce.local/rw`) is the prefix for image names.
- **`INSIGHTS_UI_VITE_*`:** the UI's build-time settings. The defaults match the CI build PROD runs, including an empty Keycloak
  URL, which means `<page origin>/auth`.
- **Platform keys** (`ENVCODE`, `OVERLAY_NAME`, `INGRESS_HOST`, `IS_CLOUD_DEPLOYMENT`, the versions, …) work as in
  `one-click-installer/config/example.env`.
- **`OVERLAY_NAME`** must not be `prod` or `uat`. Those are the shared-host overlays of the old 102.215.10.20 setup, and the
  generator would reuse them. UAT uses `rw-uat`, PROD `rw-prod`.
- **`INGRESS_HOST`** + **`ACME_EMAIL`:** the public name: `cceuat.moh.gov.rw` for UAT on .21 (DNS switched to .21 on
  2026-11-04), `cce.moh.gov.rw` for PROD on .20. Empty
  means plain HTTP on the IP. Let's Encrypt can only issue the certificate once DNS points at the machine; see "TLS after a DNS change".
- **`HPA_REPLICAS`** (UAT: `1`, so min = max = 1; PROD: empty, PROD's own HPAs) and **`CPU_LIMIT_OVERRIDES`**
  (`<deployment>=<limit>,…`; both: `cce-protocol-service=800m,cce-step-sla-service=800m`): a machine's deviations from PROD's
  sizing, applied to the overlay on every run.
- **Adding a repo** takes more than a config line: it also needs a row in `rw/lib/source-services.sh` (how to build it), and a
  deployment for it in the k8s overlay.

## Day 2: new commits

```sh
sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env                       # pull + build + deploy, every service
sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env cce-insights-ui       # only these repos
sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --build-only          # pull + build, deploy nothing
sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --deploy-only         # deploy the last builds (no git, no build)
sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --deploy-only --restart [repo...]   # after an Infisical change
```

Pull + build fetches each branch and rebuilds what changed. Deploy pins the new tags in `k8s/overlays/<OVERLAY_NAME>` and
re-applies the overlay, so only changed services roll. Schema and CDC changes in `cce-data-pipeline` need a full
`rw/one-click-install.sh` re-run. Details: `uat/OPERATIONS-RUNBOOK.md` §5.

## Where things are

`/var/lib/cce-rw/<envcode>/` (root only):

| File | What it holds |
|---|---|
| `pins.env` | the tag deployed for each service |
| `build-manifest.tsv` | repo, branch, commit, image and time for every build |
| `logs/<repo>.log` | that repo's build output |
| `install.env` | the effective config passed to `one-click-installer/install.sh` |

Elsewhere:

| Path | What |
|---|---|
| `/opt/cce-src/<repo>` | the source checkouts |
| `/root/.cce-gitlab.token` | the GitLab token (`GIT_TOKEN_FILE`) |
| `/root/cce-<env>-seed.env` | the seed file (`SEED_ENV_FILE`) |
| `/home/cceadmin/.cce-infisical/<env>.{creds,meta}` | the machine identity the scripts use to read Infisical |
| `/opt/cce-local-infisical/` | the local Infisical's keys (`.env`) and admin login (`admin.env`) |
| `/var/backups/cce-<env>/` | daily backups |
| `k8s/overlays/<OVERLAY_NAME>/` | the generated overlay (`rw-uat` on .21, `rw-prod` on .20) |

## Troubleshooting

- **"repository is EMPTY":** the repo hasn't been synced from openphc to GitLab yet.
- **"no branch/tag 'X'":** the branch isn't in GitLab. The error lists the branches that are.
- **`client version 1.24 is too old`:** Spring Boot 3.4's `bootBuildImage` client against Docker 29. The installer adds
  `/etc/systemd/system/docker.service.d/min-api-version.conf` (`DOCKER_MIN_API_VERSION=1.24`) and restarts Docker. If you're
  building by hand, check that drop-in exists.
- **A build failed:** the error shows the last 40 lines of `logs/<repo>.log`. Re-run once it's fixed; images that already built
  are reused.
- **`ErrImageNeverPull` / `ErrImagePull` for `cce.local/rw/...`:** the image isn't in k3s. Check with
  `sudo k3s ctr -n k8s.io images ls -q | grep cce.local`, then re-run the build.
- **Anything after the build** (Infisical, native services, deploy, CDC): see `one-click-installer/README.md`. Those phases are
  the generic installer, unchanged.
