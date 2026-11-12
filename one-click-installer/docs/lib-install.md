# lib/ — install-time scripts

Scripts in [`lib/`](../lib/) that `install.sh` runs to prepare the machine, build the Kubernetes overlay, check it,
install Portainer and harden the host. The Infisical scripts are in [lib-infisical.md](lib-infisical.md); the day-2
scripts are in [lib-day2.md](lib-day2.md); the `lib/native/` steps are in [native.md](native.md).

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes.**

All paths in usage lines are relative to the repository root. All scripts that change the machine must run as root.

Contents:
[load-config.sh](#load-configsh) ·
[sudo-compat.sh](#sudo-compatsh) ·
[prereqs.sh](#prereqssh) ·
[generate-overlay.sh](#generate-overlaysh) ·
[apply-emitter.sh](#apply-emittersh) ·
[emitter-lib.sh](#emitter-libsh) ·
[keycloak-inbound-basic.sh](#keycloak-inbound-basicsh) ·
[apply-image-pins.sh](#apply-image-pinssh) ·
[sync-data-pipeline.sh](#sync-data-pipelinesh) ·
[overlay-vars-check.sh](#overlay-vars-checksh) ·
[dry-render.sh](#dry-rendersh) ·
[plain-http-ingress.py](#plain-http-ingresspy) ·
[portainer.sh](#portainersh) ·
[portainer-agent.yaml](#portainer-agentyaml) ·
[install-docker-fw.sh](#install-docker-fwsh) ·
[cce-docker-fw.sh and cce-docker-fw.service](#cce-docker-fwsh-and-cce-docker-fwservice) ·
[ufw-baseline.sh](#ufw-baselinesh)

---

## load-config.sh

[`lib/load-config.sh`](../lib/load-config.sh)

**Purpose.** Reads the config file into the environment and validates it. Defines the list of known keys,
`CCE_CONFIG_KEYS`.

**Called by / when to run.** Sourced by `install.sh` before anything else. Not run by hand.

**Usage.**
```bash
. one-click-installer/lib/load-config.sh
cce_load_config one-click-installer/config/<envcode>.env
cce_validate_config || exit 1
```

**Reads.** The config file. The current environment (a variable already set is not overwritten).

**Changes.** Nothing on disk. Exports every key.

**Safe to re-run?** Yes.

**Verify.** `install.sh` prints a summary box after loading. Warnings start with `WARNING:`; validation errors start
with `CONFIG:`.

**Notes.** Parsing rules, the validation table and the unknown-key warning are described in
[config.md → How the config file is read](config.md#how-the-config-file-is-read). To add a new config key, add it to
`CCE_CONFIG_KEYS`, otherwise users get an "unknown key" warning.

---

## sudo-compat.sh

[`lib/sudo-compat.sh`](../lib/sudo-compat.sh)

**Purpose.** Two helpers that run a command as root and work with both classic `sudo` and `sudo-rs` (the default on
Ubuntu 26.04). `sudo-rs` ignores `sudo -E` and drops every variable, which once caused a pinned k3s version to be
ignored.

- `as_root cmd args…` — if already root, run the command directly (the environment is inherited); otherwise `sudo cmd`.
- `as_root_env VAR=x VAR2=y -- cmd args…` — run as root with those variables, using `env VAR=x cmd`.

**Called by / when to run.** Sourced by [prereqs.sh](#prereqssh), [infisical-local.sh](lib-infisical.md#infisical-localsh)
and [01-install-postgres-kafka.sh](native.md#01-install-postgres-kafkash). Not run by hand.

**Usage.** `. "$HERE/sudo-compat.sh"; as_root_env "INSTALL_K3S_VERSION=$K3S_VERSION" -- sh -s -`

**Reads / Changes.** Nothing.

**Safe to re-run?** Yes.

**Verify.** n/a.

**Notes.** The same rule applies to you when you run scripts by hand: write `sudo env VAR=x bash script.sh`, never
`sudo -E` and never `VAR=x sudo …`.

---

## prereqs.sh

[`lib/prereqs.sh`](../lib/prereqs.sh)

**Purpose.** Checks the machine and installs what the installer assumes is present: basic tools, the Infisical CLI,
k3s, and docker only when a docker runtime is chosen.

**Called by / when to run.** `install.sh` phase 1 (skipped when `SKIP_PREREQS` is set). Run it by hand on a new
machine to see if it is ready, with `CHECK_ONLY=1`.

**Usage.**
```bash
sudo bash one-click-installer/lib/prereqs.sh                      # check and install what is missing
sudo env CHECK_ONLY=1 bash one-click-installer/lib/prereqs.sh     # report only, change nothing
```
Run it standalone and it uses the code defaults for versions. To check against your config, export the config values
(`sudo env K3S_VERSION=… KAFKA_VERSION=… bash …`) or run it through install.sh.

**Reads.** `K3S_VERSION` (default `v1.35.4+k3s1`), `INFISICAL_CLI_VERSION` (default `0.43.93`), `KAFKA_VERSION`
(default `3.9.2`, used only to decide whether archive.apache.org must be reachable), `POSTGRES_VERSION`,
`K3S_CLUSTER_CIDR`, `K3S_SERVICE_CIDR`, `EXPORTER_RUNTIME`, `USE_LOCAL_INFISICAL`, `LOCAL_INFISICAL_RUNTIME`,
`NEED_DOCKER`, `FORCE_K3S_REINSTALL`, `CHECK_ONLY`.

**Changes.** In order:

1. **Machine** (check only): Ubuntu with apt and systemd; systemd is PID 1; reports the sudo flavour; CPU ≥ 8, RAM ≥ 24
   GiB, free disk on `/` ≥ 40 GB. Below these it warns (WARN), it does not fail.
2. **Outbound access** (check only): curl to github.com, ghcr.io, quay.io, Docker Hub and registry.k8s.io. Also the
   Ubuntu mirror(s) apt is actually configured with (read from `/etc/apt/sources.list*`; archive.ubuntu.com if none is
   found). A mirror counts as reachable if **any** of its IPv4 addresses answers, as apt itself moves on to the next
   address. Each of these is checked only when the thing it supplies is not installed yet:

   | Host | Needed for | Skipped when |
   |---|---|---|
   | get.k3s.io | k3s | k3s installed (and no `FORCE_K3S_REINSTALL`) |
   | archive.apache.org | Kafka | `/opt/kafka` already at `KAFKA_VERSION` |
   | packages.clickhouse.com, keyserver.ubuntu.com | ClickHouse and its signing key | `clickhouse-server` installed |
   | apt.postgresql.org, www.postgresql.org | PostgreSQL (PGDG) and its key | `postgresql-<POSTGRES_VERSION>` installed |
   | repo1.maven.org | Debezium plugin | `/opt/kafka/connect-plugins/debezium-connector-postgres` exists |
   | artifacts-cli.infisical.com | Infisical CLI | CLI at `INFISICAL_CLI_VERSION` |
   | artifacts-infisical-core.infisical.com | native local Infisical | `infisical-core` installed, or not a native local Infisical |

   HTTP 2xx, 3xx, 401, 403, 404 count as reachable.
3. **Tools:** installs any missing `gettext-base` (envsubst), `curl`, `python3`, `gnupg`, `git` with apt.
4. **Docker:** installs `docker.io` and enables it only if `EXPORTER_RUNTIME=docker`, or a local Infisical with
   `LOCAL_INFISICAL_RUNTIME=docker`, or `NEED_DOCKER` is set. Otherwise prints "not needed".
5. **Infisical CLI:** if absent, adds the Infisical apt repository (`setup.deb.sh` from artifacts-cli.infisical.com) and
   installs `infisical=<version>` (falls back to the newest if that version is not available). An existing CLI at
   another version is left alone (WARN).
6. **k3s:** if absent, runs the get.k3s.io installer with `INSTALL_K3S_VERSION` pinned (log in `/tmp/k3s-install.log`).
   If `K3S_CLUSTER_CIDR` / `K3S_SERVICE_CIDR` are set, it passes `--cluster-cidr`, `--service-cidr` and
   `--cluster-dns` (the 10th address of the service range, like k3s's default `10.43.0.10`). On an existing cluster
   created without them it only prints a note: a cluster keeps its networks. An existing k3s at another version is left alone (WARN), unless `FORCE_K3S_REINSTALL` is set and no pod runs
   outside `kube-system`: then it runs `/usr/local/bin/k3s-uninstall.sh` and installs the pin. Then waits up to 5
   minutes for the node and Traefik to be Ready.

**Safe to re-run?** Yes. It only installs what is missing.

**Verify.** Last line `prereqs: OK (<n> warning(s))`. Exit code 0. `k3s --version`, `infisical --version`,
`k3s kubectl get nodes`.

**Notes.**
- It fails (exit 1) on any FAIL line: wrong OS, no systemd, an unreachable site, a failed apt install, or a k3s
  version that differs from the pin right after installing (`k3s pin IGNORED`).
- GitHub release downloads (exporters, Portainer) are covered only by the github.com check; on a network with an
  allow-list, also allow GitHub's release-asset host.

---

## generate-overlay.sh

[`lib/generate-overlay.sh`](../lib/generate-overlay.sh)

**Purpose.** Creates `k8s/overlays/<OVERLAY_NAME>/` by copying the template overlay (default `k8s/overlays/prod`) and
changing only names and the shared-host workarounds. Sizing, HPAs, rate limits and other patches are copied as is.

**Called by / when to run.** `install.sh` phase 4, only when the overlay directory does not exist. Run by hand only to
regenerate after deleting the directory.

**Usage.**
```bash
sudo env OVERLAY_NAME=<name> OVERLAY_TEMPLATE=prod bash one-click-installer/lib/generate-overlay.sh <envcode>
```

**Reads.** `<envcode>` (argument), `OVERLAY_TEMPLATE` (default `prod`), `OVERLAY_NAME` (default `<envcode>`).

**Changes.** Writes the new directory under `k8s/overlays/`. In every copied `*.yaml`:
- `cce-<template>` → `cce-<envcode>` (namespace, Kafka UI cluster name, rate-limit middleware references);
- `<template>-resource-quota` / `<template>-limit-range` → `<envcode>-…`;
- `environment: <template>` → `environment: <envcode>`;
- `CLICKHOUSE_PORT=8124` → `CLICKHOUSE_PORT=8123` (the reference used a shifted port; a dedicated machine uses the
  standard one), and the comment above it is rewritten.

In `kustomization.yaml` it also:
- removes the two node-exporter patch blocks that moved node-exporter to port 9101 (back to the base's 9100);
- rewrites `KEYCLOAK_ISSUER` and `GRAFANA_ROOT_URL` from `https://${INGRESS_HOST}/…` to `${CCE_PUBLIC_URL}/…`.
  `CCE_PUBLIC_URL` is filled at deploy time by [host-ip.sh](lib-infisical.md#host-ipsh) (`https://<INGRESS_HOST>`,
  or `http://<host IP>` without a domain), so the issuer is correct on a plain-HTTP install too. A `WARNING` is printed
  if the template has no such literal;
- adds a `startupProbe` (`/actuator/health`, every 10 s, up to 30 failures = 5 minutes) to the collector, protocol,
  step-sla, intelligence, insights and gateway Deployments. Liveness checks start only after the first success, so a
  slow first start on a busy fresh machine is not killed (protocol-service at 500m CPU never got past the ~105 s its
  liveness probe allows). Nothing changes once a service is up.
- adds a patch to `cce-collector-service` setting `SPRING_FLYWAY_BASELINE_ON_MIGRATE=true` and
  `SPRING_FLYWAY_BASELINE_VERSION=0`. On a fresh database, all 2.0 services migrate the same `public` schema; without
  this the collector crash-loops with *"Found non-empty schema(s) "public" but no schema history table"* if another
  service migrates first.

Deletes a stray `kustomization.yaml.bak` copied from the template.

**Safe to re-run?** No — it refuses if the directory exists, or if `OVERLAY_NAME` equals the template.
`install.sh` handles this by skipping the step when the directory exists.

**Verify.** It prints the commands to review:
```bash
diff -u k8s/overlays/prod/kustomization.yaml k8s/overlays/<name>/kustomization.yaml
```
Any `WARNING:` line (the node-exporter block, the issuer literal or the `patches:` key not found) means the template changed shape; check
the file by hand.

**Notes.** `k8s/overlays/` is tracked in git. Commit the new overlay after reviewing it. The substitutions use the
literal template name, so they are only correct for a template that follows the `prod` overlay's naming.

---

## apply-emitter.sh

[`lib/apply-emitter.sh`](../lib/apply-emitter.sh)

**Purpose.** Makes the environment's overlay deploy the emitter adaptor chosen with `EMITTER_ADAPTOR`, instead of the
`openhim-emitter-adaptor` that `k8s/base` contains.

**Called by / when to run.** `install.sh` phase 4, on every run, before apply-image-pins.sh. By hand only to switch
emitters without a full re-run (then deploy with [05-k8s-deploy.sh](native.md#05-k8s-deploysh) and run
[06-seed.sh](native.md#06-seedsh) for the permission and Keycloak user).

**Usage.**
```bash
sudo env EMITTER_ADAPTOR=tiberbu bash one-click-installer/lib/apply-emitter.sh <envcode>
```

**Reads.** `EMITTER_ADAPTOR` (default `openhim`), `OVERLAY_NAME`, and `k8s/emitters/*/emitter.conf` via
[emitter-lib.sh](#emitter-libsh).

**Changes.** In `k8s/overlays/<OVERLAY_NAME>/`, for an emitter other than openhim:
- adds `../../emitters/<name>` to `resources:`;
- writes `emitter-delete-openhim-deployment.yaml` and `emitter-delete-openhim-service.yaml` (`$patch: delete`) and
  references them, so the base openhim Deployment and Service are not deployed. They are separate files because the
  installer runs `envsubst` over `kustomization.yaml`, which would turn an inline `$patch` into `: delete`;
- adds a patch pointing gateway route 3 at the emitter (`/v1/<deployment>/**` → `http://<deployment>:<port>`);
- renames the emitter in the existing sizing/pull-policy patch, the HPA in `cce-hpas.yaml`, and the `images:` entry.

Its patches sit between `# >>> emitter` and `# <<< emitter` in `kustomization.yaml`. Do not edit them by hand: they are
rewritten on every run. For `openhim` it removes the block and the two files and restores the openhim names.

**Safe to re-run?** Yes. Running it twice gives the same files, and switching tiberbu → openhim restores the overlay
byte for byte.

**Verify.** It prints `emitter adaptor: <name> — Deployment/Service <deployment>:<port>, image <image>, inbound
/v1/<deployment>/inbound`. After deploying: `sudo k3s kubectl -n cce-<env> get deploy,svc | grep emitter`.

**Notes.**
- An unknown name stops the script (and install.sh, before anything is installed) with the list of known emitters.
- Prometheus, the gateway permission and the Keycloak inbound user are not in the overlay; the deploy and seed steps
  derive them from it.

---

## emitter-lib.sh

[`lib/emitter-lib.sh`](../lib/emitter-lib.sh)

**Purpose.** Sourced helper: resolves an emitter name to its Deployment/Service name, port, image and source, so every
script agrees on them.

**Called by / when to run.** Sourced by install.sh, [apply-emitter.sh](#apply-emittersh),
[05-k8s-deploy.sh](native.md#05-k8s-deploysh) and [06-seed.sh](native.md#06-seedsh). Not run on its own.

**Usage.**
```bash
. one-click-installer/lib/emitter-lib.sh
cce_emitter_conf tiberbu                      # sets EMITTER_NAME EMITTER_DEPLOYMENT EMITTER_PORT EMITTER_IMAGE EMITTER_SOURCE
cce_emitter_from_overlay k8s/overlays/<name>  # the same, for the emitter that overlay deploys
cce_emitter_known                             # names that can be chosen
```

**Reads.** `k8s/emitters/<name>/emitter.conf`. openhim's values (`openhim-emitter-adaptor`, port 8082) are built in.

**Changes.** Nothing; it only sets shell variables.

**Notes.** `cce_emitter_from_overlay` looks for `- ../../emitters/<name>` in the overlay's `resources:`. With none, the
emitter is openhim. This is why day-2 runs of the deploy and seed steps need no config file to know the emitter.

---

## keycloak-inbound-basic.sh

[`lib/keycloak-inbound-basic.sh`](../lib/keycloak-inbound-basic.sh)

**Purpose.** Sets up the Keycloak side of the emitter's inbound HTTP Basic authentication. The source system sends
`Authorization: Basic <user:password>`; the gateway exchanges it for a token with a password grant through a dedicated
client, then checks the `EMITTER_INBOUND_WRITE` permission. `k8s/seeds/cce-realm.json` contains none of this.

**Called by / when to run.** [06-seed.sh](native.md#06-seedsh), after the realm import, on every run. By hand after
changing `BASIC_AUTH_CLIENT_SECRET`.

**Usage.** `sudo bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/keycloak-inbound-basic.sh <env>`

**Reads.** `BASIC_AUTH_ENABLED` (does nothing unless `true`), `BASIC_AUTH_CLIENT_ID`, `BASIC_AUTH_CLIENT_SECRET`,
`EMITTER_INBOUND_USER`, `EMITTER_INBOUND_PASSWORD`, `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD`,
`KC_INBOUND_PF_PORT` (18082). All come from Infisical ([config.md → seed file](config.md)).

**Changes.** In realm `cce`, creating whatever is missing:
- client role `gateway-service:EMITTER_INBOUND_WRITE`;
- client `BASIC_AUTH_CLIENT_ID`: confidential, password grant only. Its secret is set to Infisical's
  `BASIC_AUTH_CLIENT_SECRET` (the gateway is the only user of that secret, so Keycloak follows Infisical);
- user `EMITTER_INBOUND_USER` with password `EMITTER_INBOUND_PASSWORD`, holding the role. It is created with first
  name, last name and e-mail (`<user>@cce.invalid`, verified) because Keycloak 26's default user profile requires them;
  without them the password grant fails with "Account is not fully set up". An **existing** user missing any of these,
  or with pending required actions, has its profile completed and the required actions cleared. Its password is not
  touched.

**Safe to re-run?** Yes. Existing objects are kept; the client secret is re-aligned to Infisical if it differs.

**Verify.** Lines like `client <id>: present, secret matches Infisical` and `user <name>: has EMITTER_INBOUND_WRITE`.
End to end, from the source system's side: `curl -u <user>:<password> -X POST https://<host>/v1/<emitter>-emitter-adaptor/inbound`
returns the adaptor's response, not 401 or 403.

**Notes.**
- An **existing** user's password is never changed: it is the source system's credential. To rotate it, change it in
  Keycloak and give the new one to the source system; updating Infisical alone does nothing.
- The permission row (`EMITTER_INBOUND_WRITE` on `POST /v1/<deployment>/**`) is added by 06-seed.sh, not here.

---

## apply-image-pins.sh

[`lib/apply-image-pins.sh`](../lib/apply-image-pins.sh)

**Purpose.** Sets the image versions in the overlay's kustomize `images:` block from the `IMAGE_*` config keys, so the
config file is the one place versions are decided and the git-tracked overlay records them.

**Called by / when to run.** `install.sh` phase 4, on every run. By hand when you change image versions without a full
re-run (then deploy with [05-k8s-deploy.sh](native.md#05-k8s-deploysh)).

**Usage.**
```bash
sudo env IMAGE_CCE_COLLECTOR_SERVICE=sha256:… bash one-click-installer/lib/apply-image-pins.sh <envcode>
```
Easiest is to source your config first so all `IMAGE_*` keys are set:
```bash
sudo bash -c 'set -a; . one-click-installer/config/<envcode>.env; set +a; bash one-click-installer/lib/apply-image-pins.sh <envcode>'
```

**Reads.** `IMAGE_REGISTRY`, `IMAGE_TAG_DEFAULT`, every `IMAGE_<NAME>`, `IMAGE_CCE_EMITTER_ADAPTOR`, `OVERLAY_NAME`,
`OVERLAY_TEMPLATE`, and the template overlay's `images:` block (`k8s/overlays/<OVERLAY_TEMPLATE>/kustomization.yaml`).
Rules: [config.md → CCE service images](config.md#cce-service-images).

**Changes.** Rewrites the `images:` block of `k8s/overlays/<OVERLAY_NAME>/kustomization.yaml`. Each entry gets
`newName` plus either `newTag` or `digest` (a value starting with `sha256:` is a digest). Per image, in order: its own
key (or the generic emitter key), else `IMAGE_TAG_DEFAULT`, else the template overlay's name and tag/digest, else (an
image the template does not have, such as a non-openhim emitter) no tag at all, so the manifest's own tag applies.

**Safe to re-run?** Yes. Same input gives the same file.

**Verify.** It prints one line per image: `<image> <newName>:<tag>|@<digest> (<source>)`. Source is the key used,
`IMAGE_TAG_DEFAULT`, `template`, or `manifest's own tag (not in the template)`. Then
`git diff k8s/overlays/<name>/kustomization.yaml`.

**Notes.**
- `template` means the template overlay's value. Clearing a key, or `IMAGE_REGISTRY`, reverts to it.
- It prints `NOTE: … still use the template's Rwanda build (demo-rw-…)` while any image uses a `demo-rw` tag (the
  template's insights images do). Pin those services to your own builds.
- With more than one `*-cce-emitter-adaptor` image in the overlay, `IMAGE_CCE_EMITTER_ADAPTOR` stops the script with
  an error unless every emitter has its own key.
- The overlay must have a top-level `images:` block, or the script exits with an error.

---

## sync-data-pipeline.sh

[`lib/sync-data-pipeline.sh`](../lib/sync-data-pipeline.sh)

**Purpose.** Chooses which version of the data pipeline (ClickHouse schema, CDC SQL, Debezium connector, Grafana
dashboards) the environment gets.

**Called by / when to run.** `install.sh` phase 4, every run. By hand when you change the data-pipeline version.

**Usage.**
```bash
sudo bash one-click-installer/lib/sync-data-pipeline.sh                                  # vendored copy: does nothing
sudo env DATA_PIPELINE_REF=<branch|tag|sha> bash one-click-installer/lib/sync-data-pipeline.sh
```

**Reads.** `DATA_PIPELINE_REF`, `DATA_PIPELINE_REPO` (default `https://github.com/openphc/cce-data-pipeline.git`).

**Changes.**
- `DATA_PIPELINE_REF` empty: nothing. Prints `data pipeline: vendored copy`.
- Set: shallow-fetches that ref into a temp directory, checks it contains `schema/01-create-tables.sql`,
  `cdc/01-configure-replication.sql` and `connectors/debezium-postgres-source.json`, then **replaces**
  `data-pipeline/schema`, `cdc`, `connectors` and `infra` with the fetched ones. `data-pipeline/scripts` is copied only
  if it does not exist yet. Writes `data-pipeline/.deployed-ref` (`<repo> <ref> <short sha>`).

**Safe to re-run?** Yes. A re-run with the same ref produces the same files. It overwrites local edits in those four
directories each time.

**Verify.** `cat data-pipeline/.deployed-ref`; `git status data-pipeline/`.

**Notes.**
- It only changes files. Applying a schema change to a running ClickHouse is done by
  [redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh).
- Setting the ref back to empty does not restore the vendored copy. Use `git checkout data-pipeline/`.
- The vendored copy keeps 200 days of ClickHouse data hot; upstream keeps 90. Syncing a ref takes the upstream value.
- Commit `data-pipeline/` after a sync, like the overlay.

---

## overlay-vars-check.sh

[`lib/overlay-vars-check.sh`](../lib/overlay-vars-check.sh)

**Purpose.** Pre-flight check: every `${VAR}` used in the overlay's `kustomization.yaml` must have a non-empty value in
the Infisical-injected environment. An empty value would render as `""` in `cce-config` and crash-loop a service that
expects a number.

**Called by / when to run.** `install.sh` phase 5. By hand after you add a variable to the overlay or remove a key from
Infisical.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/overlay-vars-check.sh <envcode>
```

**Reads.** `k8s/overlays/<OVERLAY_NAME>/kustomization.yaml`, the environment.

**Changes.** Nothing.

**Safe to re-run?** Yes (read-only).

**Verify.** `OK — every non-optional overlay variable has a value`. On failure: `FAIL — referenced by the overlay but
EMPTY/UNSET in Infisical: …` and exit 1. Exit 2 if the overlay file is missing.

**Notes.**
- Optional variables (reported as `note`, not failures): `OPENHIM_CORE_HOST`, `OPENHIM_USERNAME`, `OPENHIM_PASSWORD`,
  `FACILITY_FILTER_IDS`, `INGRESS_HOST`, `ACME_EMAIL`, `GATEWAY_ALLOWED_ORIGINS`, `BASIC_AUTH_CLIENT_ID`,
  `CCE_OPSALERT_TIER1_CC`, `CCE_OPSALERT_TIER2_CC`, `CCE_OPSALERT_TIER3_CC`.
- The usual failure on a new install is the intelligence-service SMTP and alert keys. Add them to the seed file
  ([config.md → Required in the seed file](config.md#required-in-the-seed-file)) and re-run install.sh.
- It checks only `kustomization.yaml`, not base manifests.

---

## dry-render.sh

[`lib/dry-render.sh`](../lib/dry-render.sh)

**Purpose.** Renders the overlay exactly as the deploy will, without applying anything and without touching the real
overlay. Catches kustomize errors before anything is installed.

**Called by / when to run.** `install.sh` phase 5. By hand after editing the overlay.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/dry-render.sh <envcode>
```

**Reads.** `OVERLAY_NAME`, `VM_HOST_IP` / `VM_HOST_CIDR`, all Infisical values (for `envsubst`).

**Changes.** Nothing outside a temp directory (copies `k8s/` there, substitutes, renders, deletes it).

**Safe to re-run?** Yes.

**Verify.** `render OK: <n> resources`. On failure `!! render FAILED:` with kustomize's error, exit 1.

**Notes.** Leftover `${…}` text in the render is not treated as an error: Grafana provisioning and some container
commands resolve those inside the pod on purpose.

---

## plain-http-ingress.py

[`lib/plain-http-ingress.py`](../lib/plain-http-ingress.py)

**Purpose.** Rewrites the rendered manifests so the CCE ingress serves plain HTTP. Used when there is no DNS name
(`INGRESS_HOST` empty), so Let's Encrypt cannot issue a certificate.

**Called by / when to run.** [05-k8s-deploy.sh](native.md#05-k8s-deploysh) step 2, when `INGRESS_HOST` is empty. Not
run by hand.

**Usage.** `python3 one-click-installer/lib/plain-http-ingress.py < render.yaml > render.http.yaml`

**Reads.** A multi-document YAML stream on stdin.

**Changes.** Output only. In documents with `kind: Ingress`: the `router.entrypoints` annotation becomes `web`, the
`router.tls*` annotations are dropped, and the `spec.tls` block is removed. Other documents pass through unchanged.

**Safe to re-run?** Yes (pure filter).

**Verify.** `k3s kubectl -n cce-<env> get ingress -o yaml` shows no `tls:` and `router.entrypoints: web`.
`curl http://<host-ip>/insights/` answers.

**Notes.** It is a line-based rewrite, not a YAML parser. It assumes kustomize's output layout. An empty `host: ""`
is left as is; Kubernetes treats it as "any host".

---

## portainer.sh

[`lib/portainer.sh`](../lib/portainer.sh)

**Purpose.** Installs Portainer CE natively: the release binary as the systemd service `cce-portainer`, plus the
Portainer agent in k3s. Initialises the admin user and registers the environments.

**Called by / when to run.** `install.sh` phase 6b when `PORTAINER_ENABLED=true`. By hand to repair or upgrade
Portainer.

**Usage.**
```bash
sudo bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/portainer.sh <envcode>
```
It must run under `infisical-run.sh` (it needs the machine-identity login).

**Reads.** `PORTAINER_VERSION` (default `2.39.2`), `PORTAINER_SHA256`, `K3S_CLUSTER_CIDR`, `K3S_SERVICE_CIDR`,
`PORTAINER_ADMIN_PASSWORD` (environment, from the seed's `/platform`), Infisical `/portainer PORTAINER_ADMIN_PASSWORD`,
`KUBECTL`.

**Changes.**
1. **Admin password:** if Infisical `/portainer` has none and the seed provided one, copies it there. Otherwise
   generates a random one (up to 32 characters) and stores it in `/portainer`. Stops if it is shorter than 12 characters.
2. **Agent in k3s:** applies [portainer-agent.yaml](#portainer-agentyaml) with the version substituted (namespace
   `portainer`, a cluster-admin service account, a ClusterIP service on 9001). Waits up to 180 s for the rollout.
3. **Server:** if `/opt/portainer-<version>/portainer` is missing, downloads the release archive from GitHub, checks
   its SHA-256 and unpacks it. Points `/opt/portainer` at it. Data in `/var/lib/portainer` (0700).
4. **Migration:** if a docker container named `portainer` exists, stops it, copies the `portainer_data` volume into
   `/var/lib/portainer` (only if that is empty), and removes the container. The volume is kept as a rollback copy.
5. Writes `/etc/systemd/system/cce-portainer.service`, enables and restarts it. HTTPS on `:9443`, HTTP disabled, Edge
   tunnel on `127.0.0.1:8000`. `IPAddressDeny=any` + `IPAddressAllow=localhost <pod CIDR> <service CIDR>`: the kernel
   drops every other client, whatever UFW does. Runs as root.
6. Through the API on `https://127.0.0.1:9443/api`: initialises user `admin` (or notes it already is), logs in, and
   adds the environment `<envcode>-k3s` (agent at `tcp://<agent ClusterIP>:9001`) and, if `/var/run/docker.sock`
   exists, `local` (docker). Existing environments are left alone.

**Safe to re-run?** Yes. The binary is not downloaded again, the password is reused, environments are not duplicated.

**Verify.**
```bash
systemctl status cce-portainer
k3s kubectl -n portainer get pods
ssh -L 9443:localhost:9443 <user>@<host>      # then open https://localhost:9443, log in as admin
```

**Notes.**
- Access is by SSH tunnel only. Port 9443 is not reachable from the network by design.
- Portainer locks itself if not initialised within minutes of first start; the script initialises it straight away.
- If the server was initialised by hand with another password, login fails with
  `cannot log in as admin with PORTAINER_ADMIN_PASSWORD`. Put the real password in Infisical `/portainer`.
- To change the password later use [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh).
- `--bind-https` must stay `:9443`; `127.0.0.1:9443` breaks Portainer's internal Kubernetes proxy URL.

---

## portainer-agent.yaml

[`lib/portainer-agent.yaml`](../lib/portainer-agent.yaml)

**Purpose.** Kubernetes manifest for the Portainer agent: namespace `portainer`, service account
`portainer-sa-clusteradmin` bound to `cluster-admin`, Service `portainer-agent` (ClusterIP, port 9001), headless Service
`portainer-agent-headless`, and a one-replica Deployment of `portainer/agent:${PORTAINER_VERSION}` (requests 50m / 64Mi,
limits 500m / 256Mi).

**Called by / when to run.** Applied by [portainer.sh](#portainersh), which substitutes `${PORTAINER_VERSION}`. Not
applied by hand.

**Reads / Changes.** Creates the objects above.

**Safe to re-run?** Yes (`kubectl apply`).

**Verify.** `k3s kubectl -n portainer get deploy,svc`.

**Notes.** The Service is ClusterIP on purpose. The upstream manifest uses LoadBalancer/NodePort; on k3s that publishes
an agent with cluster-admin rights on the host's public address and bypasses UFW. Do not change the type.

---

## install-docker-fw.sh

[`lib/install-docker-fw.sh`](../lib/install-docker-fw.sh)

**Purpose.** Installs the rule that blocks the public network interface from reaching ports published by docker.
Docker-published ports bypass UFW (Docker's NAT and forward rules run first), so `ufw default deny` does not protect
them.

**Called by / when to run.** `install.sh` phase 7, always (it does nothing without docker). By hand on any host that
runs docker, and after a full host rebuild.

**Usage.** `sudo bash one-click-installer/lib/install-docker-fw.sh`

**Reads.** Nothing.

**Changes.** If docker is not installed, prints "nothing to protect, skipping" and exits 0. Otherwise installs
[cce-docker-fw.sh](#cce-docker-fwsh-and-cce-docker-fwservice) to `/usr/local/sbin/cce-docker-fw.sh` (0755) and the unit
to `/etc/systemd/system/cce-docker-fw.service`, enables it and restarts it (which inserts the iptables rules).

**Safe to re-run?** Yes.

**Verify.** It prints `installed: unit enabled/active, DOCKER-USER rules: 2`. From **outside** the network:
`nmap -Pn <public-ip>` — only 22, 80, 443 should be open.

**Notes.** With the default runtimes docker is not installed, so this step does nothing.

---

## cce-docker-fw.sh and cce-docker-fw.service

[`lib/cce-docker-fw.sh`](../lib/cce-docker-fw.sh), [`lib/cce-docker-fw.service`](../lib/cce-docker-fw.service)

**Purpose.** The script inserts two rules at the top of the iptables `DOCKER-USER` chain: drop NEW connections that
come in on the default-route interface and go out to `docker0` or any `br-*` bridge. The rules carry the comment
`cce-block-public-to-docker`. It is port-independent, so a newly published port is closed by default.

The unit is a `Type=oneshot`, `RemainAfterExit=yes` service, ordered after `docker.service` and `PartOf=docker.service`,
so it re-runs when docker restarts (docker recreates its chains).

**Called by / when to run.** Installed and started by [install-docker-fw.sh](#install-docker-fwsh). Runs at boot and
whenever docker restarts. Do not run it from the repository; run the installed copy if needed:
`sudo systemctl restart cce-docker-fw`.

**Reads.** The default route (`ip -4 route show default`). Waits up to 30 s for the `DOCKER-USER` chain.

**Changes.** iptables `DOCKER-USER` chain only.

**Safe to re-run?** Yes. It checks each rule with `iptables -C` before inserting.

**Verify.** `sudo iptables -S DOCKER-USER | grep cce-block` shows two rules.

**Notes.** Not affected: traffic between containers, pods and the host (they use `cni0`, `flannel.1`, `br-*`, `lo`),
replies to connections containers opened, and k3s's 80/443 (forwarded to the CNI, not a docker bridge). To remove a
rule: `sudo iptables -D DOCKER-USER <rule>`. If the default-route interface changes, restart the service.

---

## ufw-baseline.sh

[`lib/ufw-baseline.sh`](../lib/ufw-baseline.sh)

**Purpose.** Host firewall for a machine with no cloud firewall in front of it. Default deny inbound; only SSH and
HTTP/HTTPS public; databases, broker, k3s API and exporters reachable only from the node's own pod, service and docker
networks.

**Called by / when to run.** `install.sh` phase 7 when `IS_CLOUD_DEPLOYMENT=false`. By hand after changing
`SSH_ALLOWED_CIDR` or `UFW_EXTRA_ALLOW`. Safe on a cloud VM too.

**Usage.**
```bash
sudo env SSH_ALLOWED_CIDR=196.12.0.0/16 UFW_EXTRA_ALLOW="8443/tcp" bash one-click-installer/lib/ufw-baseline.sh
```

**Reads.** `SSH_ALLOWED_CIDR`, `UFW_EXTRA_ALLOW`, `K3S_CLUSTER_CIDR` (default `10.42.0.0/16`), `K3S_SERVICE_CIDR`
(default `10.43.0.0/16`).

**Changes.**
1. Installs `ufw` if missing.
2. **Dead-man switch:** starts a transient systemd timer `cce-ufw-deadman` that runs `ufw --force disable` in 10
   minutes, in case the rules lock you out.
3. Defaults: deny incoming, allow outgoing, **allow routed** (required: k3s pod traffic is forwarded; deny routed
   breaks the cluster). Every `ufw` call below is retried up to three times after a `ufw reload`: ufw rewrites all its
   chains on each change, and a collision with k3s rewriting its own rules can leave ufw's ip6tables chains missing
   (then every ufw command fails). The reload rebuilds them.
4. Allows everything in on `lo`, `cni0`, `flannel.1`, `docker0`; and from the pod CIDR, service CIDR and `172.16.0.0/12`
   (docker bridges).
5. SSH: without `SSH_ALLOWED_CIDR`, allows 22/tcp from anywhere. With it, allows 22/tcp from that range and
   **deletes** an existing allow-from-anywhere `22/tcp` rule (left by an earlier run). Then 80/tcp, 443/tcp, and each
   `UFW_EXTRA_ALLOW` entry.
6. Enables UFW, then decides about the dead-man timer. It is stopped (disarmed) when a port-22 ALLOW rule exists and
   either `SSH_ALLOWED_CIDR` is empty, or there is no SSH session at all (console or automation), or at least one current
   SSH session comes from inside the range. Otherwise it prints a WARNING with the current SSH peers, and the timer
   **stays armed**: UFW is disabled again after 10 minutes unless you fix the range and re-run (or stop
   `cce-ufw-deadman.timer` yourself).

**Safe to re-run?** Yes. UFW ignores duplicate rules. Apart from the SSH case above, rules are only added: removing an
entry from `UFW_EXTRA_ALLOW`, or clearing `SSH_ALLOWED_CIDR`, does not delete the old rule
(`sudo ufw status numbered`, `sudo ufw delete <n>`).

**Verify.** The last line summarises the policy. `sudo ufw status verbose`. From outside the network:
`nmap -Pn <public-ip>` — only 22/80/443 (plus your extras).

**Notes.**
- UFW does not see docker-published ports; [install-docker-fw.sh](#install-docker-fwsh) covers those.
- The dead-man check looks at the source addresses of current SSH sessions; it cannot prove a new connection will
  work. Keep a second session open while you change SSH rules, and check `systemctl list-timers cce-ufw-deadman.timer`
  afterwards.
- Switching `IS_CLOUD_DEPLOYMENT` to `true` later does not disable UFW.
