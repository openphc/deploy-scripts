# deploy-scripts — `deploy-scripts-rw` branch (Rwanda)

This branch holds only what is needed to install and operate a **Rwanda (RW-MOH) CCE environment** with the CCE services built
from the RW-MOH GitLab (`repository.moh.gov.rw/cce/*`). It is meant to be mirrored to that GitLab and cloned on the servers.
It is in use for RW UAT on 102.215.10.21.

| Path | What |
|---|---|
| `rw/one-click-install.sh` | sets up a whole environment on one machine: native PostgreSQL / Kafka / ClickHouse / Infisical, k3s, the CCE services built from source, CDC, backups, firewall |
| `rw/redeploy-from-source.sh` | day 2: pull new commits from GitLab, build, deploy (`--build-only`, `--deploy-only`, `--restart`) |
| `rw/config/uat.env` | the UAT configuration: which repo and branch each service is built from, sizing, versions. No secrets. |
| `rw/lib/` | the RW steps: building from source, OpenHIM's Keycloak client, backups, TLS check, sizing tweaks |
| `rw/docs/` | `ONE-CLICK-INSTALL.md` (how the installer works), `UAT_OPERATIONS_RUNBOOK.md` (day-to-day operation) and `UAT_SECURITY.md` (security, credential rotation) |
| `one-click-installer/` | the generic installer the RW one wraps (native services, Infisical, k3s deploy, data pipeline, Portainer, firewall) |
| `k8s/` | the Kubernetes manifests: `base/`, `overlays/prod/` (the template each environment's overlay is generated from), the realm/permission seeds, the native Postgres/Kafka setup |
| `grafana/dashboards/`, `keycloak-themes/` | Grafana dashboards; the Keycloak login themes (RW uses `insights-ui-theme`) |

Start with `rw/docs/ONE-CLICK-INSTALL.md`.

**Secrets never go in this repository.** They live in each environment's Infisical, in the root-only GitLab token file
(`/root/.cce-gitlab.token`) and in the seed file (`/root/cce-<env>-seed.env`). `.gitignore` allows only the files listed above
under `rw/`, so credentials and backups that sit in `rw/` on a working copy cannot be committed by accident.

**Keeping it current:** the generic parts (`one-click-installer/`, `k8s/`, `grafana/`, …) come from the main branch of
openphc/deploy-scripts. Merge main into this branch to pick up their changes.
`data-pipeline/` is not kept here: the installer creates it on every run from the `cce-data-pipeline` commit configured in
`rw/config/<env>.env` (fetched from GitLab), and ignores it in git.
The folders removed here (caddy, docker-compose stacks, openhim-console, portainer-deployment, the shared-VM UAT overlay and deploy
scripts, the 1.x upgrade, the GitHub Actions workflows) belong to the older GHCR-based setups and are not used by this installer.
