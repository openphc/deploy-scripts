# RW: Rwanda MoH deployment of CCE

Everything here sets up and runs CCE for the Rwanda Ministry of Health with the **one-click installer**: one dedicated Ubuntu
machine per environment, CCE services built on that machine from the RW-MOH GitLab (`repository.moh.gov.rw/cce/*`).

| Environment | Machine | Public name | Config | Status |
|---|---|---|---|---|
| UAT | 102.215.10.21 | `cceuat.moh.gov.rw` | `config/uat.env` | installed 2026-11-04, in use |
| PROD | 102.215.10.20 | `cce.moh.gov.rw` | `config/prod.env` | old 1.x system to be removed, then installed with `docs/prod/INSTALL-GUIDE.md` |

The machines' hostnames are misleading (.21 is called `cce-prod`). Always go by IP.

## Where to start

| I want to… | Read |
|---|---|
| understand how the installer works | [`docs/ONE-CLICK-INSTALL.md`](docs/ONE-CLICK-INSTALL.md) |
| operate UAT: deploy new code, back up, change config, load a protocol | [`docs/uat/OPERATIONS-RUNBOOK.md`](docs/uat/OPERATIONS-RUNBOOK.md) |
| know how UAT is secured, rotate a credential | [`docs/uat/SECURITY.md`](docs/uat/SECURITY.md) |
| recover UAT from data or machine loss, test the backups | [`docs/uat/DISASTER-RECOVERY.md`](docs/uat/DISASTER-RECOVERY.md) |
| see how an event flows, which ports are open, what each config key does | [`docs/uat/CONFIG-REFERENCE.md`](docs/uat/CONFIG-REFERENCE.md) |
| install PROD (step by step, for a less-technical operator) | [`docs/prod/INSTALL-GUIDE.md`](docs/prod/INSTALL-GUIDE.md) |

PROD's own versions of the four UAT docs will be written once PROD is installed. Until then, PROD is run the way UAT is, with
`config/prod.env` and namespace `cce-prod`.

## What is here

| Path | What |
|---|---|
| `one-click-install.sh` | installs or repairs a whole environment (`--config config/<env>.env`, `--check-only`, `--yes`) |
| `redeploy-from-source.sh` | day 2: pull, build and deploy (`--build-only`, `--deploy-only`, `--restart`) |
| `config/uat.env`, `config/prod.env` | per environment: repos and branches, versions, sizing, public name. No secrets. |
| `lib/` | helpers the two scripts above call: build (`build-from-source.sh`, `source-services.sh`), overlay sizing (`overlay-tweaks.sh`), OpenHIM's Keycloak client (`keycloak-openhim-basic.sh`), backups (`backup-db.sh`, `install-cron-backups.sh`), TLS (`tls-check.sh`) |
| `protocols/emr-service-protocol.json` | the clinical protocol (PlanDefinition), "Rwanda Health Center Patient Journey": loaded on UAT, and the one PROD gets (confirmed 2026-11-12) |
| `tools/openhim/` | OpenHIM side: register the CCE mediator and route (`register-mediator.sh`), list failed transactions (`openhim_non2xx_primary.py`) |
| `docs/` | the documents above |

The generic installer these scripts drive is `../one-click-installer/`, shared with the other countries.

## Not in the repository

- **`bkp/`** (local only, never committed or copied to a server): Infisical exports, database dumps, the access-credentials
  notes, and `rw-legacy-1.x-2026-11-12.tar.gz`. That archive holds everything removed from `rw/` on 2026-11-12:
  - the scripts of the old shared-VM setup on 102.215.10.20 (`prod/`, `uat/`, `lib/native/`, the old `lib/` helpers)
  - its docs (architecture, backup/restore, DR, monitoring, runbook, security, troubleshooting, …), which describe CCE 1.x
  - the 1.x Postman collection, the old protocol definitions (`clinical-wf-pd.json` "Facility service journey",
    `anc-clinical-wf-pd.json`)
- **Secrets:** each environment's local Infisical, and the seed file `/root/cce-<env>-seed.env` on its machine.
- **Generated on the machine:** `k8s/overlays/rw-<env>/` and `data-pipeline/`, rewritten by every installer run.
