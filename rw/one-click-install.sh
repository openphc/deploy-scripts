#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# rw/one-click-install.sh — stand up an RW CCE environment on ONE dedicated machine, with the CCE services BUILT FROM SOURCE
# (the RW-MOH GitLab), until GitLab CI/CD builds the images.
#
#   sudo bash rw/one-click-install.sh --config rw/config/uat.env [--yes] [--check-only]
#
# Same topology as RW PROD: native PostgreSQL / Kafka (KRaft) / ClickHouse / Kafka Connect + Debezium under systemd, a local
# Infisical, the cce-<envcode> k3s namespace with PROD's sizing/HPAs/patches, CDC into ClickHouse, Keycloak realm + RW login
# theme, UFW default-deny. The only difference from PROD is where the images come from:
#   1. pre-flight   every SRC_* repo + branch in the config is reachable with the GitLab token (nothing installed if not)
#   2. prereqs      k3s, Infisical CLI (one-click-installer/lib/prereqs.sh) + docker, JDK 21 and docker-buildx — for the builds only
#   3. build        rw/lib/build-from-source.sh: clone each repo into SOURCE_DIR, build it the way its CI does, import the image
#                   into k3s (no registry). cce-data-pipeline is deployed from its clone instead of the vendored data-pipeline/.
#   4. install      one-click-installer/install.sh with the built tags pinned in the overlay and imagePullPolicy IfNotPresent —
#                   incl. native Infisical (phase 2), native exporters (07, EXPORTER_RUNTIME=systemd) and native Portainer (6b).
#                   Its last phase is the firewall: the cce-docker-fw rule always, and with IS_CLOUD_DEPLOYMENT=false (RW: on-prem,
#                   like PROD) UFW default-deny with only 22/80/443 public (one-click-installer/lib/ufw-baseline.sh). Checked below.
#   5. backups      daily 02:00 cron (rw/lib/install-cron-backups.sh -> rw/lib/backup-db.sh), same dumps/retention as PROD's
#
# Re-running resumes: unchanged commits are not rebuilt, and every install phase is idempotent. To roll out new commits of some
# services without the full install:  sudo bash rw/redeploy-from-source.sh --config <file> [repo...]
#
# --check-only   run only the pre-flight (repos reachable?) and stop.
# State (versions built, logs, effective config): /var/lib/cce-rw/<envcode>/ (root-only).
# The previous RW installer (pulled GHCR images; 1.x era) is kept at rw/bkp/one-click-install.sh.pre-gitlab-build-2026-11-04.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
GENERIC="$REPO/one-click-installer"; GLIB="$GENERIC/lib"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root:  sudo bash $0 --config <file>"; exit 1; }
chmod +x "$HERE"/lib/*.sh "$HERE"/*.sh 2>/dev/null || true

CONFIG=""; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a file}"; shift 2;;
    --yes|-y) export ASSUME_YES=1; shift;;
    --check-only) CHECK_ONLY=1; shift;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "unknown argument: $1  (usage: one-click-install.sh --config <file> [--yes] [--check-only])"; exit 2;;
  esac
done
[ -n "$CONFIG" ] || { echo "ERROR: --config <file> is required (start from $HERE/config/uat.env)"; exit 2; }
[ -d "$GLIB" ] || { echo "ERROR: $GENERIC is missing — copy the whole deploy-scripts repository, not just rw/"; exit 1; }

. "$HERE/lib/source-services.sh"
. "$GLIB/load-config.sh"
CCE_CONFIG_KEYS="$CCE_CONFIG_KEYS$(rw_config_keys)"
cce_load_config "$CONFIG"
# --check-only needs only the SRC_* keys, so it works before the seed file exists.
[ "$CHECK_ONLY" = 1 ] || cce_validate_config || { echo "Fix the config above and re-run."; exit 1; }
# k8s/overlays/prod and /uat are the shared-host overlays of 102.215.10.20; generate-overlay.sh would silently REUSE them.
export OVERLAY_NAME="${OVERLAY_NAME:-$ENVCODE}" OVERLAY_TEMPLATE="${OVERLAY_TEMPLATE:-prod}"
case "$OVERLAY_NAME" in prod|uat)
  echo "ERROR: OVERLAY_NAME=$OVERLAY_NAME is the existing shared-host overlay — set OVERLAY_NAME=rw-$ENVCODE in the config"; exit 1;;
esac
if [ -z "${GIT_TOKEN:-}" ] && [ -n "${GIT_TOKEN_FILE:-}" ] && [ ! -r "$GIT_TOKEN_FILE" ]; then
  echo "ERROR: GIT_TOKEN_FILE=$GIT_TOKEN_FILE not readable. Create it:  install -m 600 /dev/null $GIT_TOKEN_FILE && <editor> $GIT_TOKEN_FILE"
  exit 1
fi
export STATE_DIR="/var/lib/cce-rw/$ENVCODE"; mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
export SOURCE_DIR="${SOURCE_DIR:-/opt/cce-src}" LOCAL_IMAGE_REGISTRY="${LOCAL_IMAGE_REGISTRY:-cce.local/rw}"

echo
echo "════════════════════════════════════════════════════════════════"
echo " RW one-click install — CCE built from source"
echo " Environment:   $ENVCODE  (namespace cce-$ENVCODE, overlay k8s/overlays/$OVERLAY_NAME)"
echo " Ingress:       ${INGRESS_HOST:-<none — plain HTTP>}"
echo " Firewall:      $( [ "${IS_CLOUD_DEPLOYMENT:-}" = true ] && echo "cloud — UFW NOT configured (provider firewall must allow only 22/80/443)" || echo "UFW default-deny, public 22${SSH_ALLOWED_CIDR:+ (from $SSH_ALLOWED_CIDR)}/80/443${UFW_EXTRA_ALLOW:+ + $UFW_EXTRA_ALLOW} + docker-port block (as PROD)")"
echo " Sources:       $SOURCE_DIR   images: $LOCAL_IMAGE_REGISTRY/<repo>:<branch>-<commit>"
for e in "${RW_SOURCES[@]}"; do
  n="${e%%|*}"; k="$(rw_src_key "$n")"; rv="SRC_${k}_REPO"; bv="SRC_${k}_BRANCH"
  printf '   %-28s %-14s %s\n' "$n" "${!bv:-?}" "${!rv:-<not set>}"
done
echo "════════════════════════════════════════════════════════════════"

command -v git >/dev/null || { echo "installing git…"; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }
echo; echo "████ RW 1/5 Pre-flight: source repositories"
bash "$HERE/lib/build-from-source.sh" --check-only
[ "$CHECK_ONLY" = 1 ] && { echo "Pre-flight OK (--check-only: stopping here)."; exit 0; }
if [ -n "${ASSUME_YES:-}" ]; then echo "Build and install? [y/N] y  (--yes)"
else read -r -p "Build and install? [y/N] " a; [ "$a" = y ] || [ "$a" = Y ] || { echo "Aborted."; exit 0; }; fi

echo; echo "████ RW 2/5 Prerequisites (k3s, docker, Infisical CLI) + build tools (JDK 21, docker-buildx)"
if [ -n "${SKIP_PREREQS:-}" ]; then echo "  SKIP_PREREQS set — skipping"
else NEED_DOCKER=1 bash "$GLIB/prereqs.sh" || { echo "ERROR: prerequisites failed (FAIL lines above)"; exit 1; }; fi   # docker: for the image builds only
need=()
command -v javac >/dev/null || need+=(openjdk-21-jdk-headless)
docker buildx version >/dev/null 2>&1 || need+=(docker-buildx)
if [ "${#need[@]}" -gt 0 ]; then
  echo "  installing ${need[*]}…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
fi
# Docker 29 refuses API versions below 1.44, but Spring Boot 3.4's bootBuildImage client speaks /v1.24/ ("client version 1.24 is
# too old"), so every buildpack build fails. The daemon may lower its floor; it still serves the current API to everything else.
DROPIN=/etc/systemd/system/docker.service.d/min-api-version.conf
if ! grep -qs 'DOCKER_MIN_API_VERSION=1.24' "$DROPIN"; then
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\n# rw/one-click-install.sh: Spring Boot bootBuildImage speaks Docker API v1.24\nEnvironment=DOCKER_MIN_API_VERSION=1.24\n' > "$DROPIN"
  systemctl daemon-reload; systemctl restart docker
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
echo "  JDK: $(javac -version 2>&1)   buildx: $(docker buildx version 2>/dev/null | awk '{print $2}')   docker min API: $(docker version --format '{{.Server.MinAPIVersion}}')"

echo; echo "████ RW 3/5 Build the CCE images from source"
bash "$HERE/lib/build-from-source.sh"
# Every CCE image in the overlay must now be a local build — an unpinned one would point at $LOCAL_IMAGE_REGISTRY/…:latest,
# which exists nowhere.
for e in "${RW_SOURCES[@]}"; do
  IFS='|' read -r n r _ <<< "$e"; case "$r" in lib|pipeline) continue;; esac
  grep -q "^IMAGE_$(rw_src_key "$n")=" "$STATE_DIR/pins.env" || { echo "ERROR: no built image for $n (see $STATE_DIR/logs/)"; exit 1; }
done
set -a; . "$STATE_DIR/pins.env"; set +a
export IMAGE_REGISTRY="$LOCAL_IMAGE_REGISTRY"

# Images exist only in k3s's containerd, so pods must never try to pull them. The seed rewrites defaults on every run, so the
# policy goes in through the seed file (which wins) rather than once into Infisical.
SEED_MERGED="$(mktemp)"; chmod 600 "$SEED_MERGED"; trap 'rm -f "$SEED_MERGED"' EXIT
[ -n "${SEED_ENV_FILE:-}" ] && grep -v '^[[:space:]]*IMAGE_PULL_POLICY=' "$SEED_ENV_FILE" > "$SEED_MERGED" || true
echo "IMAGE_PULL_POLICY=IfNotPresent" >> "$SEED_MERGED"
# RW's OpenHIM authenticates with HTTP Basic (rw/lib/keycloak-openhim-basic.sh). The generic seed defaults it off; RW defaults it
# on, unless the seed file says otherwise.
grep -q '^BASIC_AUTH_ENABLED=' "$SEED_MERGED" || echo "BASIC_AUTH_ENABLED=true" >> "$SEED_MERGED"
grep -q '^BASIC_AUTH_CLIENT_ID=' "$SEED_MERGED" || echo "BASIC_AUTH_CLIENT_ID=openhim-basic" >> "$SEED_MERGED"
# The generic seed now creates the inbound user itself (one-click-installer/lib/keycloak-inbound-basic.sh, before RW 4b), from
# EMITTER_INBOUND_USER/EMITTER_INBOUND_PASSWORD, and generates the password when none is given. A seed file written with RW's
# older names (OPENHIM_INBOUND_*) is passed on under the new ones, so the user gets the password OpenHIM is configured with.
for k in USER PASSWORD; do
  grep -q "^EMITTER_INBOUND_$k=" "$SEED_MERGED" && continue
  l="$(sed -n "s/^OPENHIM_INBOUND_$k=/EMITTER_INBOUND_$k=/p" "$SEED_MERGED" | tail -1)"
  [ -n "$l" ] && printf '%s\n' "$l" >> "$SEED_MERGED"
done
export SEED_ENV_FILE="$SEED_MERGED"

# The generic installer reads its config from a file; give it the effective values (the environment wins over the file anyway).
INSTALL_CFG="$STATE_DIR/install.env"
for k in $CCE_CONFIG_KEYS; do
  case "$k" in SEED_ENV_FILE|ASSUME_YES|SKIP_PREREQS) continue;; esac
  case " $(rw_config_keys) " in *" $k "*) continue;; esac
  [ -n "${!k+x}" ] && printf '%s=%s\n' "$k" "${!k}"
done > "$INSTALL_CFG"
grep '^IMAGE_' "$STATE_DIR/pins.env" >> "$INSTALL_CFG"
chmod 600 "$INSTALL_CFG"

# Generate the overlay here (the generic installer reuses an existing one) so this machine's deviations from PROD's sizing are in
# it before the first deploy. Re-applied every run, so they track the config.
OVERLAY_DIR="$REPO/k8s/overlays/$OVERLAY_NAME"
[ -d "$OVERLAY_DIR" ] || bash "$GLIB/generate-overlay.sh" "$ENVCODE"
bash "$HERE/lib/overlay-tweaks.sh" "$OVERLAY_DIR"

echo; echo "████ RW 4/5 Install (native services, Infisical, k3s deploy, data pipeline, hardening)"
SKIP_PREREQS=1 bash "$GENERIC/install.sh" --config "$INSTALL_CFG" ${ASSUME_YES:+--yes}
# The generic installer's hardening phase did the firewall; fail loudly here if it is not actually on.
if [ "${IS_CLOUD_DEPLOYMENT:-}" != true ]; then
  ufw status | grep -q '^Status: active' || { echo "ERROR: UFW is not active after install — run: sudo bash $GLIB/ufw-baseline.sh"; exit 1; }
  echo "  firewall: UFW active — public: $(ufw status | awk '$2=="ALLOW" && $3=="Anywhere" && $1 ~ /^[0-9]+(\/tcp)?$/ {sub("/tcp","",$1); print $1}' | sort -un | tr '\n' ' ')"
fi
systemctl is-active --quiet cce-docker-fw 2>/dev/null && echo "  docker-port block (cce-docker-fw): active" \
  || echo "  WARNING: cce-docker-fw is not active — docker-published ports bypass UFW (sudo bash $GLIB/install-docker-fw.sh)"

echo; echo "████ RW 4b Keycloak: OpenHIM Basic-auth client, role and inbound user (as on RW PROD/UAT)"
bash "$GLIB/infisical-run.sh" "$ENVCODE" bash "$HERE/lib/keycloak-openhim-basic.sh" "$ENVCODE" 2>&1 \
  | grep -vE 'new release of infisical|To update, run|Your logged-in session|Injecting [0-9]+ Infisical|^host-ip:|^$'

echo; echo "████ RW 5/5 Daily DB backups (like PROD: 02:00, ccedb + keycloak + ClickHouse, ${RETENTION_DAYS:-10} days)"
bash "$HERE/lib/install-cron-backups.sh" "$ENVCODE"
echo "  first backup now (proves the cron's command works):"
CCE_INFISICAL_CREDS_DIR="$(. "$GLIB/creds-dir.sh"; cce_creds_dir)" \
  bash "$GLIB/infisical-run.sh" "$ENVCODE" bash "$HERE/lib/backup-db.sh" "$ENVCODE" 2>&1 | grep -E '^20[0-9]{2}-' \
  || echo "  WARNING: the first backup reported errors — see /var/backups/cce-$ENVCODE/backup.log"

# TLS: if the DNS already points here but Traefik gave up on Let's Encrypt while it did not, kick it (rw/lib/tls-check.sh).
if [ -n "${INGRESS_HOST:-}" ]; then bash "$HERE/lib/tls-check.sh" "$INGRESS_HOST" || true; fi

# This machine runs NO containers: every service is native (systemd) or in k3s. Docker stays installed only to BUILD the CCE images.
LEFT="$(docker ps -a --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
if [ -n "${LEFT// /}" ]; then echo "  WARNING: docker containers exist, expected none: $LEFT"; else echo "  docker containers: none (as intended)"; fi

echo
echo "Source versions deployed ($STATE_DIR/build-manifest.tsv, latest per repo):"
awk -F'\t' 'NR>1{last[$1]=$2"\t"substr($3,1,10)"\t"$4} END{for (r in last) printf "   %-28s %s\n", r, last[r]}' "$STATE_DIR/build-manifest.tsv" | sort
echo "New commits on a branch later:  sudo bash rw/redeploy-from-source.sh --config $CONFIG [repo...]"
