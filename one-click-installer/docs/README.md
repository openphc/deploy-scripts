# One-click installer — detailed documentation

These pages go one level below the [top-level README](../README.md). Read that first: it has the quick start, the
requirements, the phase table, the day-2 table and the troubleshooting list. The pages here describe every script and
config key in detail: what it does, when it runs, what it reads, what it changes, whether it is safe to re-run, and
how to check it worked.

## Documents

- [architecture.md](architecture.md) — what ends up on the machine: native services vs the k3s namespace, data flow,
  secrets flow, network exposure, important paths.
- [config.md](config.md) — every config key, the environment-only variables, the seed file (`SEED_ENV_FILE`) and
  `config/.gitignore`.
- [lib-install.md](lib-install.md) — install-time scripts: config loading, prerequisites, overlay generation, image
  pins, data-pipeline version, pre-flight checks, Portainer, host firewall.
- [lib-infisical.md](lib-infisical.md) — the secrets store: local Infisical, project bootstrap, seeding, the
  `infisical-run.sh` wrapper, and host-IP detection.
- [native.md](native.md) — `lib/native/install-all.sh` and its steps 01–07, in the order they run.
- [lib-day2.md](lib-day2.md) — day-2 scripts: redeploy, ClickHouse schema, Grafana dashboards, admin passwords.
- [tools.md](tools.md) — `tools/`: IP drift check, environment fingerprint and parity, connector repoint.

## Phase → scripts it runs

`install.sh --config <file>` runs these in order. Each phase is safe to re-run; an interrupted install resumes.

| Phase | Scripts | Notes |
|---|---|---|
| (start) | [load-config.sh](lib-install.md#load-configsh), [creds-dir.sh](lib-infisical.md#creds-dirsh) | load + validate the config; check repo assets and the Keycloak theme; confirm |
| 1 Prerequisites | [prereqs.sh](lib-install.md#prereqssh) → [sudo-compat.sh](lib-install.md#sudo-compatsh) | skipped with `SKIP_PREREQS` |
| 2 Secrets store | [infisical-native.sh](lib-infisical.md#infisical-nativesh) `up` / `migrate`, or [infisical-local.sh](lib-infisical.md#infisical-localsh) `up` (only with `USE_LOCAL_INFISICAL=true`); then [infisical-bootstrap.sh](lib-infisical.md#infisical-bootstrapsh) if no creds, else a login test through [infisical-run.sh](lib-infisical.md#infisical-runsh) | |
| 3 Seed | [infisical-run.sh](lib-infisical.md#infisical-runsh) → [infisical-seed.sh](lib-infisical.md#infisical-seedsh) → [infisical-secret-helpers.sh](lib-infisical.md#infisical-secret-helperssh) | runs every time |
| 4 Overlay + versions | [generate-overlay.sh](lib-install.md#generate-overlaysh) (only if the overlay is missing), [apply-emitter.sh](lib-install.md#apply-emittersh), [apply-image-pins.sh](lib-install.md#apply-image-pinssh), [sync-data-pipeline.sh](lib-install.md#sync-data-pipelinesh) | |
| 5 Pre-flight | [overlay-vars-check.sh](lib-install.md#overlay-vars-checksh), [dry-render.sh](lib-install.md#dry-rendersh) (both under infisical-run.sh) | nothing is installed if this fails; second confirmation |
| 6 Install | [native/install-all.sh](native.md#install-allsh) → [01](native.md#01-install-postgres-kafkash), [02](native.md#02-install-clickhousesh), [03](native.md#03-install-kafka-connectsh), [07](native.md#07-monitoring-exporterssh), [rollout-changed.sh](lib-day2.md#rollout-changedsh) + [05](native.md#05-k8s-deploysh) (+ [plain-http-ingress.py](lib-install.md#plain-http-ingresspy)), [04](native.md#04-data-pipelinesh), [06](native.md#06-seedsh) | restarts the data services on a re-run |
| 6b Portainer | [portainer.sh](lib-install.md#portainersh) + [portainer-agent.yaml](lib-install.md#portainer-agentyaml) | only with `PORTAINER_ENABLED=true` |
| 7 Hardening | [install-docker-fw.sh](lib-install.md#install-docker-fwsh) (+ [cce-docker-fw.sh / .service](lib-install.md#cce-docker-fwsh-and-cce-docker-fwservice)); [ufw-baseline.sh](lib-install.md#ufw-baselinesh) when `IS_CLOUD_DEPLOYMENT=false` | docker-fw does nothing without docker |
| Result | — | pod readiness, docker containers left, security settings (each probe is report-only and cannot abort the run, e.g. on a host without docker); application URL, emitter inbound URL and the command that prints every login |

Every lib script that needs secrets runs through [infisical-run.sh](lib-infisical.md#infisical-runsh), which wraps the
command in [host-ip-exec.sh](lib-infisical.md#host-ip-execsh) / [host-ip.sh](lib-infisical.md#host-ipsh).

## Task → script to run by hand

All commands run on the machine, from the repository root, as root.

| Task | Command | Details |
|---|---|---|
| Is the machine ready? | `sudo env CHECK_ONLY=1 bash one-click-installer/lib/prereqs.sh` | [prereqs.sh](lib-install.md#prereqssh) |
| Change a value in Infisical and apply it | change it in Infisical, then `sudo bash one-click-installer/lib/redeploy.sh cce-<env> [deployment…]` | [redeploy.sh](lib-day2.md#redeploysh), [config.md → changing a value](config.md#after-the-install-changing-a-value) |
| Roll a new build of a mutable tag | `sudo bash one-click-installer/lib/redeploy.sh cce-<env> [deployment…]` (or `CHANGED_ONLY=1`) | [redeploy.sh](lib-day2.md#redeploysh) |
| Pin one service to a digest right now | `sudo env IMAGE_DIGEST=sha256:… bash one-click-installer/lib/redeploy.sh cce-<env> <deployment>` (temporary; set `IMAGE_*` in the config to keep it) | [redeploy.sh](lib-day2.md#redeploysh) |
| Switch the emitter adaptor (source system) | set `EMITTER_ADAPTOR` in the config and re-run install.sh | [apply-emitter.sh](lib-install.md#apply-emittersh), [config.md](config.md#emitter-adaptor-selection) |
| See every login (Infisical, Keycloak, Grafana, Portainer, databases, emitter inbound) | `sudo bash one-click-installer/tools/show-credentials.sh <env> [--reveal]` | [show-credentials.sh](tools.md#show-credentialssh) |
| Give the source system its inbound credentials | `sudo bash one-click-installer/tools/show-credentials.sh <env> --reveal` (the "Emitter inbound" entry) | [show-credentials.sh](tools.md#show-credentialssh), [keycloak-inbound-basic.sh](lib-install.md#keycloak-inbound-basicsh) |
| Change pinned image versions | edit `IMAGE_*` in the config and re-run install.sh; or `apply-image-pins.sh <env>` then `05-k8s-deploy.sh <env>` | [apply-image-pins.sh](lib-install.md#apply-image-pinssh), [05](native.md#05-k8s-deploysh) |
| Change the data-pipeline version | `sudo env DATA_PIPELINE_REF=<ref> bash one-click-installer/lib/sync-data-pipeline.sh`, then the next row | [sync-data-pipeline.sh](lib-install.md#sync-data-pipelinesh) |
| Apply a ClickHouse schema change | `sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env>` (`DROP_FIRST="…"` to replace objects — loses their data) | [redeploy-clickhouse.sh](lib-day2.md#redeploy-clickhousesh) |
| Ship new / edited Grafana dashboards | `sudo bash one-click-installer/lib/grafana-redeploy.sh <env>` | [grafana-redeploy.sh](lib-day2.md#grafana-redeploysh) |
| Change Grafana / Portainer admin password | `sudo bash one-click-installer/lib/set-admin-passwords.sh <env>` | [set-admin-passwords.sh](lib-day2.md#set-admin-passwordssh) |
| Machine IP changed | `sudo bash one-click-installer/tools/host-ip-check.sh <env>`, then fix each DRIFT line | [host-ip-check.sh](tools.md#host-ip-checksh) |
| CDC connector points at an IP | `sudo bash one-click-installer/tools/connector-repoint.sh <env>` | [connector-repoint.sh](tools.md#connector-repointsh) |
| Compare with a reference environment | `env-fingerprint.sh` on each host, then `env-parity.py ref.fp new.fp` | [tools.md](tools.md#env-paritypy) |
| Re-apply the host firewall after changing SSH / extra rules | `sudo env SSH_ALLOWED_CIDR=… bash one-click-installer/lib/ufw-baseline.sh` (narrowing SSH removes the old open-to-all 22 rule; other rules are only added) | [ufw-baseline.sh](lib-install.md#ufw-baselinesh) |
| Run one install step alone | `sudo bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/native/<step>.sh <env>` (load the config first) | [native.md](native.md#execution-order) |
| Check the local Infisical | `sudo bash one-click-installer/lib/infisical-native.sh status` | [infisical-native.sh](lib-infisical.md#infisical-nativesh) |
| Test the environment's Infisical login | `sudo bash one-click-installer/lib/infisical-run.sh <env> true` | [infisical-run.sh](lib-infisical.md#infisical-runsh) |
| Re-check that every overlay variable has a value | `sudo bash one-click-installer/lib/infisical-run.sh <env> bash one-click-installer/lib/overlay-vars-check.sh <env>` | [overlay-vars-check.sh](lib-install.md#overlay-vars-checksh) |

When in doubt, re-running `install.sh` with the same config is the supported way to bring the machine back to the
configured state. Note that it restarts the data services (a short interruption), and writes every key in the seed
file to Infisical again, overwriting changes made there ([config.md](config.md#what-happens-to-each-key)). Values you
changed only in Infisical, and an already-loaded protocol, are left alone.

Problems already handled by the scripts (with the symptom you would see) are listed in the
[top-level troubleshooting table](../README.md#troubleshooting--problems-this-installer-already-handles).

## Conventions in these pages

- `<env>` is the `ENVCODE`. The namespace is `cce-<env>`.
- Run as root with `sudo`. Pass variables as `sudo env VAR=value bash …` (`sudo -E` does not work on Ubuntu 26.04's
  `sudo-rs`).
- Day-2 scripts do not read the config file. Export `OVERLAY_NAME` if it differs from the env code.
- `k3s kubectl` is used in examples; plain `kubectl` works if it is configured for the k3s cluster.
