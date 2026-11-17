# lib/ — day-2 scripts

Scripts you run by hand after the install: roll out new config or images, apply ClickHouse schema changes, update
Grafana dashboards, change admin passwords. For a one-line summary of each task see the
[Day-2 operations table](../README.md#day-2-operations) and [docs/README.md](README.md#task--script-to-run-by-hand).

Every section uses the same labels: **Purpose · Called by / when to run · Usage · Reads · Changes · Safe to re-run? ·
Verify · Notes.**

Rules that apply to all of them:

- Run as root on the machine: `sudo bash one-click-installer/lib/<script> …`. Pass variables with `sudo env VAR=x bash …`.
- They do not read the config file. If `OVERLAY_NAME` differs from the env code, export it.
- Scripts that need secrets re-run themselves under [infisical-run.sh](lib-infisical.md#infisical-runsh).

Contents:
[redeploy.sh](#redeploysh) ·
[rollout-changed.sh](#rollout-changedsh) ·
[image-changed.sh](#image-changedsh) ·
[redeploy-clickhouse.sh](#redeploy-clickhousesh) ·
[grafana-redeploy.sh](#grafana-redeploysh) ·
[set-admin-passwords.sh](#set-admin-passwordssh)

---

## redeploy.sh

[`lib/redeploy.sh`](../lib/redeploy.sh)

**Purpose.** One command to roll out a changed Infisical value and/or a new image for the CCE services. It refreshes
the `cce-config` ConfigMap and `cce-secrets` Secret from Infisical, then restarts the deployments so they read the new
values and pull the current image.

Why a restart is needed: the ConfigMap and Secret have fixed names (`disableNameSuffixHash`), so applying them does not
roll the pods, and environment variables are read only at pod start.

**Called by / when to run.** By hand, after changing a value in Infisical or pushing a new image to a mutable tag.
Also by [native/install-all.sh](native.md#install-allsh) with `--pull-images`.

**Usage.**
```bash
sudo bash one-click-installer/lib/redeploy.sh cce-<env>                              # all CCE deployments
sudo bash one-click-installer/lib/redeploy.sh cce-<env> cce-intelligence-service     # just one (or several)
sudo env DRY_RUN=1 bash one-click-installer/lib/redeploy.sh cce-<env>                # show what would happen
sudo env CHANGED_ONLY=1 bash one-click-installer/lib/redeploy.sh cce-<env>           # only what actually changed
sudo env IMAGE_DIGEST=sha256:… bash one-click-installer/lib/redeploy.sh cce-<env> gateway-service
sudo env ASK_VERSION=1 bash one-click-installer/lib/redeploy.sh cce-<env> a b c      # prompt per deployment
sudo env REFRESH_ENV=0 bash one-click-installer/lib/redeploy.sh cce-<env>            # image only, skip Infisical
```

**Reads.**

| Variable | Default | Meaning |
|---|---|---|
| `DRY_RUN` | empty | Print the plan, change nothing. |
| `REFRESH_ENV` | `1` | `0` skips the Infisical refresh. |
| `CHANGED_ONLY` | empty | Restart only deployments whose consumed `cce-config`/`cce-secrets` keys changed ([rollout-changed.sh](#rollout-changedsh)) or whose tag now points at a newer digest ([image-changed.sh](#image-changedsh)). |
| `IMAGE_TAG` / `IMAGE_DIGEST` | empty | Pin exactly one target deployment to `<its current repo>:<tag>` or `@<digest>` with `kubectl set image`. Digest wins if both are set. |
| `ASK_VERSION` | empty | Prompt for a tag/digest per deployment (blank = plain restart). Needs a terminal. |
| `ROLLOUT_TIMEOUT` | `180s` | Wait per deployment. |
| `WAIT_DELETE_TIMEOUT` | `90s` | Wait for pods to go in the scale-to-0 fallback. |
| `OVERLAY_NAME` | env code | Overlay to render for the refresh, and whose `images:` block selects the targets. |
| `KUBECTL` | `kubectl` or `sudo k3s kubectl` | |

The env code is the namespace without `cce-`. The refresh runs only if `<creds dir>/<env>.meta` exists.

**Changes.**
1. Re-runs itself under `infisical-run.sh <env>` (unless `REFRESH_ENV=0`, no `.meta`, or `VM_HOST_IP` is already set).
2. Refresh: copies `k8s/` into a temporary directory, substitutes the variables into the copy's `kustomization.yaml`,
   renders the copy with `kubectl kustomize`, and applies **only** the `cce-config` ConfigMap and the `cce-secrets`
   Secret. The tracked overlay file is never written, so secrets cannot be left in the repository.
3. Targets: the named deployments; or, with no names, every deployment running an image listed in the overlay's
   `images:` block, matched by image name whatever the registry (so `IMAGE_REGISTRY` mirrors work). If the overlay
   file cannot be read, it falls back to deployments with an image under `ghcr.io/openphc/`.
4. For each target: `rollout restart` (or `set image` when pinning), then `rollout status`. If the rollout does not
   finish in time and the deployment has no HPA, it falls back to scaling to 0, waiting for the pods to go, then
   scaling back to the replica count the deployment had (at least 1).

**Safe to re-run?** Yes. Each run restarts the targets again (a short disruption per service).

**Verify.** `redeploy: done (rc=0).` Then `k3s kubectl -n cce-<env> get pods`. To confirm a value:
`k3s kubectl -n cce-<env> get cm cce-config -o jsonpath='{.data.<KEY>}'`.

**Notes.**
- The refresh does not apply Deployments or other resources. A change to the overlay itself (image pins, patches,
  resources) needs [05-k8s-deploy.sh](native.md#05-k8s-deploysh) or a re-run of install.sh.
- `IMAGE_TAG` / `IMAGE_DIGEST` / `ASK_VERSION` change the live Deployment only. The next 05 run or install.sh run puts
  back the overlay's pin. For a lasting change, set `IMAGE_<NAME>` in the config.
- `set image` assumes the container has the same name as the deployment (true for every CCE service).
- The scale-to-0 fallback causes downtime for that service while it restarts.
- `CHANGED_ONLY=1` detects new images only on ghcr.io ([image-changed.sh](#image-changedsh)); for a mirror, only
  env changes are detected.

---

## rollout-changed.sh

[`lib/rollout-changed.sh`](../lib/rollout-changed.sh)

**Purpose.** Restarts only the deployments whose environment actually changed. It snapshots a hash of every key in
`cce-secrets` and `cce-config` before an apply, compares after, and maps changed keys to the deployments that consume
them (`secretKeyRef`, `configMapKeyRef`, or `envFrom` of either object).

**Called by / when to run.** [native/install-all.sh](native.md#install-allsh) brackets the k8s deploy with
`capture` / `restart`. [redeploy.sh](#redeploysh) uses `capture` / `list` for `CHANGED_ONLY`. Rarely by hand.

**Usage.**
```bash
bash one-click-installer/lib/rollout-changed.sh cce-<env> /tmp/snap capture   # before the apply
# … apply …
bash one-click-installer/lib/rollout-changed.sh cce-<env> /tmp/snap list      # print changed deployment names
bash one-click-installer/lib/rollout-changed.sh cce-<env> /tmp/snap restart   # restart them
```

**Reads.** `KUBECTL`. The two objects and all Deployments in the namespace.

**Changes.** `capture`: writes the snapshot file (`KEY<TAB>sha256`, no values). `restart`: `rollout restart` of each
affected deployment. `list`: nothing.

**Safe to re-run?** Yes.

**Verify.** `restart` prints `rollout-changed: restarting -> …` or `nothing to restart`.

**Notes.** On a fresh install the snapshot is empty and `restart` does nothing (all pods are new). A deployment that
uses `envFrom` on either object is restarted when any key changes.

---

## image-changed.sh

[`lib/image-changed.sh`](../lib/image-changed.sh)

**Purpose.** Prints the deployments whose running image digest differs from what their tag points at in the registry
now, i.e. a newer build was pushed.

**Called by / when to run.** [redeploy.sh](#redeploysh) with `CHANGED_ONLY=1`. By hand to see which services are behind.

**Usage.**
```bash
sudo bash one-click-installer/lib/image-changed.sh cce-<env>                    # all deployments with a ghcr.io/openphc/* image
sudo bash one-click-installer/lib/image-changed.sh cce-<env> gateway-service    # only those named
```

**Reads.** `KUBECTL`. Deployments and pods (label `app=<deployment>`) in the namespace. Public ghcr.io API (anonymous
token, manifest `HEAD`).

**Changes.** Nothing.

**Safe to re-run?** Yes (read-only).

**Verify.** Output is one deployment name per line; empty means all current.

**Notes.** Only images under `ghcr.io/openphc/` can be checked (ghcr's anonymous token API). Without names, other
images are silently ignored; a deployment **named** explicitly whose image is elsewhere (an `IMAGE_REGISTRY` mirror)
is reported on stderr as `image-changed: <name> not checked — <image> is not on ghcr.io`. If the registry cannot be reached, or the image is
private, the deployment is skipped (not reported as changed). An image pinned by digest (`…@sha256:…`) does not
resolve as a tag, so it is also skipped. That is correct: a digest cannot move.

---

## redeploy-clickhouse.sh

[`lib/redeploy-clickhouse.sh`](../lib/redeploy-clickhouse.sh)

**Purpose.** Applies the ClickHouse analytics schema (`data-pipeline/schema/*.sql`) to the running ClickHouse over
HTTP, then forces a refresh of refreshable materialized views. Use after a schema change, for example after
[sync-data-pipeline.sh](lib-install.md#sync-data-pipelinesh).

**Called by / when to run.** By hand only.

**Usage.**
```bash
sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env>                                    # all files, default order
sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env> 08-reference-tables 07-daily-summary-aggregates
sudo env DRY_RUN=1 bash one-click-installer/lib/redeploy-clickhouse.sh <env>                      # preview
sudo env DROP_FIRST="tbl_a mv_b" bash one-click-installer/lib/redeploy-clickhouse.sh <env>       # replace changed objects
sudo env REFRESH_MV=0 bash one-click-installer/lib/redeploy-clickhouse.sh <env>                   # skip the MV refresh
```

**Reads.** From Infisical (it re-runs itself under `infisical-run.sh` when `CLICKHOUSE_PASSWORD` is empty):
`CLICKHOUSE_HOST`, `CLICKHOUSE_PORT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB` (default
`cce_analytics`). It exports `CLICKHOUSE_USER` / `CLICKHOUSE_DB` for apply-schema.py, which reads those names.
`CH_HTTP` overrides the URL. `DRY_RUN`, `DROP_FIRST`, `REFRESH_MV`.

**Changes.** In database `CLICKHOUSE_DB` (`cce_analytics`):
1. `DROP TABLE IF EXISTS` each name in `DROP_FIRST`.
2. Runs `data-pipeline/scripts/apply-schema.py` on the files. Default order: `01`…`06`, then `08-reference-tables`
   **before** `07-daily-summary-aggregates` (07 depends on 08). Missing files are skipped. `09-historical-backfill` is a
   manual backfill and is never applied by default.
3. `SYSTEM REFRESH VIEW` for every view in `system.view_refreshes`.

**Safe to re-run?** Yes without `DROP_FIRST`: `CREATE … IF NOT EXISTS` does not alter existing objects. With
`DROP_FIRST`, **the dropped tables lose their data**; they are recreated empty. This script never reloads data from
PostgreSQL. A full rebuild (drop the database and re-snapshot from PostgreSQL through Debezium) is a separate procedure.

**Verify.** `redeploy-clickhouse: done.` and no failure lines from apply-schema.py. Then check the tables:
`curl -s 'http://localhost:8123/?user=cce_pipeline&password=…' --data-binary 'SHOW TABLES FROM cce_analytics'`
(type the password, do not paste it into shared logs).

**Notes.** Because `CREATE` is additive, a changed column or view definition is not applied unless you drop the object
first. Know what depends on a table before dropping it.

---

## grafana-redeploy.sh

[`lib/grafana-redeploy.sh`](../lib/grafana-redeploy.sh)

**Purpose.** Rebuilds the `grafana-dashboards` ConfigMap from the dashboard JSON files and restarts Grafana so it loads
them.

**Called by / when to run.** By hand after adding or editing a dashboard. [05-k8s-deploy.sh](native.md#05-k8s-deploysh)
builds the same ConfigMap during install (but does not restart Grafana).

**Usage.**
```bash
sudo bash one-click-installer/lib/grafana-redeploy.sh <env>
sudo env DRY_RUN=1 bash one-click-installer/lib/grafana-redeploy.sh <env>    # list dashboards, change nothing
```

**Reads.** `grafana/dashboards/*.json` (repository root) and
`data-pipeline/infra/grafana/provisioning/dashboards/json/pipeline-health.json`. `KUBECTL`, `DRY_RUN`,
`ROLLOUT_TIMEOUT` (default `180s`). No Infisical secrets.

**Changes.** In each repository dashboard, the placeholder `${DS_PROMETHEUS}` is replaced by the datasource uid
`prometheus`. Then a server-side apply of ConfigMap `grafana-dashboards` in `cce-<env>` (server-side because the JSON
exceeds the 256 KB client-side annotation limit), and `rollout restart deploy/grafana`.

**Safe to re-run?** Yes.

**Verify.** `grafana-redeploy: done.` Open `/grafana`, check the dashboard list.

**Notes.**
- A ConfigMap is limited to about 1 MB. The script warns at 1,000,000 bytes.
- Datasources are provisioned separately (ConfigMap `grafana-datasources` in `k8s/base/monitoring/grafana.yaml`).
- To add a dashboard: drop the `.json` into `grafana/dashboards/` and run this script.

---

## set-admin-passwords.sh

[`lib/set-admin-passwords.sh`](../lib/set-admin-passwords.sh)

**Purpose.** Changes the Grafana and Portainer admin passwords. Both apps keep the password in their own database after
first start, so changing Infisical alone does nothing; this script changes all places.

**Called by / when to run.** By hand only. For example, to set the passwords an older environment used.

**Usage.**
```bash
sudo bash one-click-installer/lib/set-admin-passwords.sh <env>
sudo env SEED_ENV_FILE=/secure/path/seed.env bash one-click-installer/lib/set-admin-passwords.sh <env>
```
It prompts for each password (input hidden). Blank keeps the current one.

**Reads.** `SEED_ENV_FILE` (optional). Current values from Infisical (it re-runs itself under `infisical-run.sh`).

**Changes.**
- Grafana (if given): if `SEED_ENV_FILE` is writable, replaces its `GRAFANA_ADMIN_PASSWORD=` line (so install.sh
  re-runs keep it). Sets Infisical `/grafana GRAFANA_ADMIN_PASSWORD`. Runs
  `grafana cli admin reset-admin-password` in the Grafana pod.
- Portainer (if given; minimum 12 characters): logs in to `https://127.0.0.1:9443/api` with the current Infisical
  password, changes it for user id 1 (the `admin` created by [portainer.sh](lib-install.md#portainersh)), then sets
  Infisical `/portainer PORTAINER_ADMIN_PASSWORD`.

**Safe to re-run?** Yes.

**Verify.** `Done.` Log in to Grafana (`/grafana`) and Portainer (SSH tunnel to 9443) with the new passwords.

**Notes.**
- The Grafana value is written to the seed file before anything else is checked. If a later step fails, the seed file
  already has the new value.
- If the Portainer password was changed by hand in the UI, update Infisical `/portainer` first, or the login fails.
- Without `SEED_ENV_FILE`, a later install.sh run with a seed file that still holds the old `GRAFANA_ADMIN_PASSWORD`
  writes the old value back to Infisical (Grafana itself keeps the new one). Keep the seed file in step.
