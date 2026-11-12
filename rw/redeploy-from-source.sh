#!/usr/bin/env bash
# rw/redeploy-from-source.sh — day 2 of an environment set up by rw/one-click-install.sh (which must have completed once on this
# machine): pull new commits from GitLab, build the images, deploy them to k3s. One step or all three:
#
#   sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env                         # pull + build + deploy, every service
#   sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env cce-insights-ui         # the same, just these repos
#   sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --build-only [repo...]  # pull + build; nothing deployed
#   sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --deploy-only           # deploy the last built images; no git, no build
#   sudo bash rw/redeploy-from-source.sh --config rw/config/uat.env --deploy-only --restart [repo...]   # + restart (config changes)
#
# Pull + build is rw/lib/build-from-source.sh: it fetches each repo into SOURCE_DIR/<repo> (/opt/cce-src/<repo>), builds it as its CI
# does, imports the image into k3s and records the tag in /var/lib/cce-rw/<env>/pins.env. A repo whose commit has not moved keeps
# its image. Deploy pins those tags in k8s/overlays/<OVERLAY_NAME>, re-renders cce-config/cce-secrets from Infisical and applies
# the overlay: only deployments whose image tag changed roll. --restart also rollout-restarts the services (named, or all CCE ones),
# so a changed Infisical value takes effect without a new image.
# cce-data-pipeline: only fetched (--build-only cce-data-pipeline); deploying it needs the installer's data-pipeline step (re-run
# rw/one-click-install.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"; GLIB="$REPO/one-click-installer/lib"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }

CONFIG=""; ONLY=(); BUILD=1; DEPLOY=1; RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?}"; shift 2;;
    --build-only) DEPLOY=0; shift;;
    --deploy-only) BUILD=0; shift;;
    --restart) RESTART=1; shift;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    -*) echo "unknown option $1"; exit 2;;
    *) ONLY+=("$1"); shift;;
  esac
done
[ -n "$CONFIG" ] || { echo "usage: redeploy-from-source.sh --config <file> [--build-only | --deploy-only [--restart]] [repo...]"; exit 2; }
[ "$BUILD$DEPLOY" = 00 ] && { echo "ERROR: --build-only and --deploy-only together do nothing"; exit 2; }
[ "$RESTART" = 1 ] && [ "$DEPLOY" = 0 ] && { echo "ERROR: --restart needs a deploy (drop --build-only)"; exit 2; }
# cce-data-pipeline can be fetched (--build-only cce-data-pipeline: e.g. to read a new release's upgrade SQL first), but deploying it
# needs the installer's data-pipeline step (schema + CDC).
if [ "$DEPLOY" = 1 ]; then
  for r in "${ONLY[@]}"; do [ "$r" = cce-data-pipeline ] && { echo "ERROR: deploying cce-data-pipeline needs the full installer (schema/CDC): rw/one-click-install.sh — or fetch it only: --build-only cce-data-pipeline"; exit 2; }; done
fi

. "$HERE/lib/source-services.sh"
. "$GLIB/load-config.sh"
CCE_CONFIG_KEYS="$CCE_CONFIG_KEYS$(rw_config_keys)"
cce_load_config "$CONFIG"
export OVERLAY_NAME="${OVERLAY_NAME:-$ENVCODE}" KEYCLOAK_THEME_DIR="${KEYCLOAK_THEME_DIR:-keycloak-themes/insights-ui-theme}"   # RW branded login theme
export STATE_DIR="/var/lib/cce-rw/$ENVCODE" SOURCE_DIR="${SOURCE_DIR:-/opt/cce-src}" LOCAL_IMAGE_REGISTRY="${LOCAL_IMAGE_REGISTRY:-cce.local/rw}"
[ -s "$STATE_DIR/pins.env" ] && [ -d "$REPO/k8s/overlays/$OVERLAY_NAME" ] \
  || { echo "ERROR: $ENVCODE was never installed on this machine — run rw/one-click-install.sh first"; exit 1; }
for r in "${ONLY[@]}"; do
  printf '%s\n' "${RW_SOURCES[@]}" | cut -d'|' -f1 | grep -Fx -- "$r" >/dev/null || { echo "ERROR: unknown repo '$r' (see rw/lib/source-services.sh)"; exit 2; }
done

if [ "$BUILD" = 1 ]; then
  TARGETS=("${ONLY[@]}")
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    for e in "${RW_SOURCES[@]}"; do n="${e%%|*}"; [ "$n" = cce-data-pipeline ] || TARGETS+=("$n"); done
  fi
  echo "████ Pull + build ${TARGETS[*]}  (sources: $SOURCE_DIR)"
  bash "$HERE/lib/build-from-source.sh" "${TARGETS[@]}"
fi
if [ "$DEPLOY" = 0 ]; then
  echo "Built, not deployed (--build-only). Tags: $STATE_DIR/pins.env. Deploy them with:"
  echo "  sudo bash rw/redeploy-from-source.sh --config $CONFIG --deploy-only"
  exit 0
fi

set -a; . "$STATE_DIR/pins.env"; set +a
export IMAGE_REGISTRY="$LOCAL_IMAGE_REGISTRY"
NS="cce-$ENVCODE"
echo "████ Deploy: pin the built tags in k8s/overlays/$OVERLAY_NAME, refresh config from Infisical, apply"
bash "$GLIB/apply-image-pins.sh" "$ENVCODE"
bash "$HERE/lib/overlay-tweaks.sh" "$REPO/k8s/overlays/$OVERLAY_NAME"
bash "$GLIB/infisical-run.sh" "$ENVCODE" bash "$GLIB/native/05-k8s-deploy.sh" "$ENVCODE"

if [ "$RESTART" = 1 ]; then
  # Deployment names differ from repo names (openhim-cce-emitter-adaptor -> openhim-emitter-adaptor), so match on the image.
  mapfile -t DEPS < <(k3s kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
    | awk -F'\t' -v reg="$LOCAL_IMAGE_REGISTRY/" -v only="${ONLY[*]}" '
        index($2, reg) == 1 { r = substr($2, length(reg) + 1); sub(/:.*/, "", r)
                              if (only == "" || index(" " only " ", " " r " ")) print $1 }')
  [ "${#DEPS[@]}" -gt 0 ] || { echo "ERROR: no deployment in $NS runs a $LOCAL_IMAGE_REGISTRY image${ONLY:+ of ${ONLY[*]}}"; exit 1; }
  echo "████ Restart ${DEPS[*]} (picks up the refreshed cce-config / cce-secrets)"
  for d in "${DEPS[@]}"; do k3s kubectl -n "$NS" rollout restart "deploy/$d" >/dev/null; done
  for d in "${DEPS[@]}"; do
    # One CPU-limit-bound namespace can stall a rolling surge; say so instead of hanging silently.
    k3s kubectl -n "$NS" rollout status "deploy/$d" --timeout="${ROLLOUT_TIMEOUT:-300s}" >/dev/null \
      && echo "  ✓ $d" || echo "  ✗ $d did not finish rolling within ${ROLLOUT_TIMEOUT:-300s} — check: k3s kubectl -n $NS get pods"
  done
fi
k3s kubectl -n "$NS" get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' \
  | grep -E "NAME|$LOCAL_IMAGE_REGISTRY"
