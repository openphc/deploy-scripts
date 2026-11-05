#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# one-click-installer/install.sh — stand up a complete CCE environment on ONE dedicated Ubuntu machine.
#
#   sudo bash one-click-installer/install.sh --config one-click-installer/config/<envcode>.env [--yes]
#
# Produces the reference production topology: native PostgreSQL / Kafka (KRaft) / ClickHouse / Kafka Connect + Debezium, and
# the cce-<envcode> k3s namespace (same sizing, HPAs and patches as the reference production overlay), secrets in Infisical,
# CDC pipeline into ClickHouse, Keycloak realm + gateway permissions seeded, host hardened. For any country / implementation:
# everything deployment-specific comes from the config file (config/example.env documents every key) and Infisical.
#
# Safe to re-run: every phase is idempotent and an interrupted install RESUMES (existing Infisical project, overlay and native
# services are reused). See README.md for phases, day-2 operations and troubleshooting.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$HERE/lib"; REPO="$(cd "$HERE/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root:  sudo bash $0 --config <file>"; exit 1; }
chmod +x "$LIB"/*.sh "$LIB"/native/*.sh "$HERE"/tools/*.sh "$HERE"/*.sh 2>/dev/null || true   # zipped/rsynced trees lose exec bits

CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a file}"; shift 2;;
    --yes|-y) export ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "unknown argument: $1  (usage: install.sh --config <file> [--yes])"; exit 2;;
  esac
done
[ -n "$CONFIG" ] || { echo "ERROR: --config <file> is required (start from $HERE/config/example.env)"; exit 2; }
. "$LIB/load-config.sh"
cce_load_config "$CONFIG"
cce_validate_config || { echo "Fix the config above and re-run."; exit 1; }
export OVERLAY_NAME="${OVERLAY_NAME:-$ENVCODE}" OVERLAY_TEMPLATE="${OVERLAY_TEMPLATE:-prod}"
NS="cce-${ENVCODE}"; OVERLAY="$REPO/k8s/overlays/$OVERLAY_NAME"
. "$LIB/creds-dir.sh"; CREDS_DIR="$(cce_creds_dir)"

confirm() { if [ -n "${ASSUME_YES:-}" ]; then echo "$1 [y/N] y  (--yes)"; return 0; fi; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }
phase() { echo; echo "████ $*"; }

# repo assets the deploy needs (a partial copy of the repo was a real failure mode: keycloak-themes/ missing -> no IdP)
for d in k8s/base "k8s/overlays/$OVERLAY_TEMPLATE" data-pipeline/schema; do
  [ -e "$REPO/$d" ] || { echo "ERROR: $REPO/$d is missing — copy the whole repository (see README: 'Getting the code onto the machine')"; exit 1; }
done
export KEYCLOAK_THEME_DIR="${KEYCLOAK_THEME_DIR:-keycloak-themes/cce-insights-theme/dev}"
THEME_PATH="$KEYCLOAK_THEME_DIR"; [ "${THEME_PATH#/}" = "$THEME_PATH" ] && THEME_PATH="$REPO/$THEME_PATH"
[ -r "$THEME_PATH/login/theme.properties" ] || { echo "ERROR: KEYCLOAK_THEME_DIR=$KEYCLOAK_THEME_DIR has no login/theme.properties — keycloak would have no login page"; exit 1; }

cat <<SUMMARY

════════════════════════════════════════════════════════════════
 CCE one-click install
 Environment:        $ENVCODE   (namespace $NS, Infisical project cce-$ENVCODE)
 Overlay:            k8s/overlays/$OVERLAY_NAME  (from template: $OVERLAY_TEMPLATE)
 Ingress:            ${INGRESS_HOST:-<none — plain HTTP>}
 Hosting:            $( [ "$IS_CLOUD_DEPLOYMENT" = true ] && echo "cloud (provider firewall is the perimeter; UFW not configured)" || echo "on-prem / direct (UFW host firewall WILL be configured)")
 Infisical:          $( [ "${USE_LOCAL_INFISICAL:-false}" = true ] && echo "local on this machine, ${LOCAL_INFISICAL_RUNTIME:-native} (127.0.0.1:8080)" || echo "${INFISICAL_DOMAIN:-http://localhost:8080}")
 Exporters:          ${EXPORTER_RUNTIME:-systemd}   Portainer: $( [ "${PORTAINER_ENABLED:-true}" = true ] && echo "native ${PORTAINER_VERSION:-2.39.2} (127.0.0.1:9443, SSH tunnel)" || echo "not installed")
 Login theme:        $KEYCLOAK_THEME_DIR
 Data pipeline:      $( [ -n "${DATA_PIPELINE_REF:-}" ] && echo "${DATA_PIPELINE_REPO:-https://github.com/openphc/cce-data-pipeline.git} @ $DATA_PIPELINE_REF" || echo "vendored data-pipeline/ in this repo")
 Versions:           k3s ${K3S_VERSION:-default}  ClickHouse ${CLICKHOUSE_VERSION:-26.5}  Postgres ${POSTGRES_VERSION:-16}  Kafka ${KAFKA_VERSION:-3.7.0}
 Creds dir:          $CREDS_DIR
════════════════════════════════════════════════════════════════
SUMMARY
confirm "Proceed?" || { echo "Aborted."; exit 0; }

phase "1/7 Prerequisites (k3s, Infisical CLI, tools; docker only if a docker runtime is chosen)"
if [ -n "${SKIP_PREREQS:-}" ]; then echo "  SKIP_PREREQS set — skipping"
else bash "$LIB/prereqs.sh" || { echo "ERROR: prerequisites failed (FAIL lines above)"; exit 1; }; fi

phase "2/7 Secrets store: Infisical project + machine identity"
# A local Infisical runs NATIVELY by default (infisical-native.sh: infisical-core + Redis + a database in the native PostgreSQL);
# LOCAL_INFISICAL_RUNTIME=docker keeps the older docker-compose one. An existing docker Infisical is moved to native once (same keys,
# database copied, verified, containers removed — its volume and a dump are kept as a rollback copy).
if [ "${USE_LOCAL_INFISICAL:-false}" = true ]; then
  if [ "${LOCAL_INFISICAL_RUNTIME:-native}" = docker ]; then
    bash "$LIB/infisical-local.sh" up
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -Fx cce-local-infisical-db-1 >/dev/null; then
    bash "$LIB/infisical-native.sh" migrate
    docker compose --project-name cce-local-infisical --project-directory "${CCE_LOCAL_INFISICAL_DIR:-/opt/cce-local-infisical}" down >/dev/null 2>&1 || true
  else
    bash "$LIB/infisical-native.sh" up
  fi
fi
LOCAL_ADMIN="${CCE_LOCAL_INFISICAL_DIR:-/opt/cce-local-infisical}/admin.env"
if [ -z "${INFISICAL_ADMIN_EMAIL:-}" ] && [ -z "${INFISICAL_ADMIN_PASSWORD:-}" ] && [ -r "$LOCAL_ADMIN" ]; then
  echo "  using the local Infisical's admin login ($LOCAL_ADMIN)"; set -a; . "$LOCAL_ADMIN"; set +a
fi
curl -sf --max-time 5 "${INFISICAL_DOMAIN:-http://localhost:8080}/api/status" >/dev/null 2>&1 || {
  echo "ERROR: no Infisical answering at ${INFISICAL_DOMAIN:-http://localhost:8080}."
  echo "       Remote instance: open the tunnel first. No instance at all: set USE_LOCAL_INFISICAL=true in the config."; exit 1; }
if [ -r "$CREDS_DIR/${ENVCODE}.creds" ] && [ -r "$CREDS_DIR/${ENVCODE}.meta" ]; then
  echo "  creds for '$ENVCODE' exist — verifying (resume)…"
  bash "$LIB/infisical-run.sh" "$ENVCODE" true >/dev/null 2>&1 && echo "  OK — reusing the existing project + identity" \
    || { echo "ERROR: existing creds no longer log in. Remove $CREDS_DIR/${ENVCODE}.{creds,meta} to bootstrap afresh."; exit 1; }
else
  bash "$LIB/infisical-bootstrap.sh" "$ENVCODE"
fi

phase "3/7 Seed configuration into Infisical"
SEED_TMP="$(mktemp)"; trap 'rm -f "$SEED_TMP"' EXIT
[ -n "${SEED_ENV_FILE:-}" ] && cp "$SEED_ENV_FILE" "$SEED_TMP"
[ -n "${INGRESS_HOST:-}" ] && ! grep -q '^INGRESS_HOST=' "$SEED_TMP" && echo "INGRESS_HOST=${INGRESS_HOST}" >> "$SEED_TMP"
[ -n "${ACME_EMAIL:-}" ]   && ! grep -q '^ACME_EMAIL=' "$SEED_TMP"   && echo "ACME_EMAIL=${ACME_EMAIL}"     >> "$SEED_TMP"
bash "$LIB/infisical-run.sh" "$ENVCODE" bash "$LIB/infisical-seed.sh" "$ENVCODE" "$SEED_TMP"

phase "4/7 Kubernetes overlay k8s/overlays/$OVERLAY_NAME + image versions + data pipeline version"
if [ -d "$OVERLAY" ]; then echo "  exists — reusing (delete it to regenerate from '$OVERLAY_TEMPLATE')"
else bash "$LIB/generate-overlay.sh" "$ENVCODE"; fi
echo "  image versions (from the config):"
bash "$LIB/apply-image-pins.sh" "$ENVCODE"
bash "$LIB/sync-data-pipeline.sh"

phase "5/7 Pre-flight: every overlay variable has a value + dry render (nothing applied yet)"
bash "$LIB/infisical-run.sh" "$ENVCODE" bash "$LIB/overlay-vars-check.sh" "$ENVCODE" \
  || { echo "ERROR: the overlay needs variables Infisical doesn't have (above). Nothing installed yet."; exit 1; }
bash "$LIB/infisical-run.sh" "$ENVCODE" bash "$LIB/dry-render.sh" "$ENVCODE" 2>&1 | grep -v -i -E "new release|To update|Injecting|Warning: Your" \
  || { echo "ERROR: dry render failed — nothing installed yet."; exit 1; }
confirm "Render OK — install native services and deploy to k3s?" || { echo "Stopped before install; re-run to resume."; exit 0; }

phase "6/7 Install: native PostgreSQL/Kafka/ClickHouse/Connect, k3s deploy, CDC pipeline, seed"
bash "$LIB/native/install-all.sh" "$ENVCODE"

if [ "${PORTAINER_ENABLED:-true}" = true ]; then
  phase "6b/7 Portainer (native server on 127.0.0.1:9443 — SSH tunnel; agent in k3s)"
  bash "$LIB/infisical-run.sh" "$ENVCODE" bash "$LIB/portainer.sh" "$ENVCODE" 2>&1 \
    | grep -vE 'new release of infisical|To update, run|Your logged-in session|Injecting [0-9]+ Infisical|^host-ip:|^$'
fi

phase "7/7 Host hardening"
bash "$LIB/install-docker-fw.sh"                       # docker-published ports: blocked from the public NIC (always)
if [ "$IS_CLOUD_DEPLOYMENT" = true ]; then
  echo "  IS_CLOUD_DEPLOYMENT=true — UFW not configured: make sure the cloud firewall/security group allows ONLY 22/80/443 inbound."
else
  bash "$LIB/ufw-baseline.sh"
fi

echo; echo "████ Result"
KUBECTL="k3s kubectl"
$KUBECTL -n "$NS" get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); t++; if ($3=="Running" && a[1]==a[2]) r++; else print "   not ready: "$1" "$2" "$3} END{printf "   pods ready: %d/%d\n", r, t}'
# With the default runtimes nothing runs in docker: every service is systemd-managed or in k3s.
LEFT="$(docker ps -a --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
if [ -n "${LEFT// /}" ]; then echo "   docker containers present: $LEFT (expected none unless a docker runtime was chosen)"; else echo "   docker containers: none"; fi
cat <<DONE

Done: namespace $NS · Infisical project cce-$ENVCODE · creds $CREDS_DIR/${ENVCODE}.{creds,meta}
  URL:        ${INGRESS_HOST:+https://$INGRESS_HOST/insights/}${INGRESS_HOST:-http://<this-host>/insights/}
  Verify:     sudo bash $HERE/tools/host-ip-check.sh $ENVCODE      (nothing still holds a stale IP)
              sudo bash $HERE/tools/env-fingerprint.sh $ENVCODE > $ENVCODE.fp; python3 $HERE/tools/env-parity.py <reference.fp> $ENVCODE.fp
              nmap -Pn <public-ip> from OUTSIDE the network — only 22/80/443 should be open
  Next:       commit k8s/overlays/$OVERLAY_NAME (tracked); fill blank external settings (OpenHIM, facility filter) in Infisical,
              then: sudo bash $LIB/redeploy.sh $NS
DONE
