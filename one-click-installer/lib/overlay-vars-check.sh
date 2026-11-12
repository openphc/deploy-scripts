#!/usr/bin/env bash
# one-click-installer/lib/overlay-vars-check.sh <envcode> — every ${VAR} the k8s overlay consumes must have a VALUE in the (Infisical-injected) env.
#
#   bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/overlay-vars-check.sh <envcode>
#
# WHY: the overlay's ${VARS} are substituted by envsubst, and an UNSET/EMPTY one silently becomes "" in cce-config. That is not a
# deploy error — it is a CRASH-LOOP later (an empty string cannot bind to an int/long: insights-service died on
# `cacheConfig.lookupsTtl: Failed to convert ''`, the emitter on `openhim.core.api-port`). Found the hard way on the first fresh
# one-click install: infisical-seed.sh's hand-kept key list had drifted from the PROD overlay. This turns that drift into an
# immediate, named failure at the installer's dry-render gate. (Run under infisical-run.sh so the env is injected.)
#
# Variables that are legitimately blank until the operator supplies external-system config (OpenHIM, TLS, facility filter) are
# reported as notes, not failures.
set -uo pipefail
ENVCODE="${1:?usage: overlay-vars-check.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
OVERLAY="$REPO/k8s/overlays/${OVERLAY_NAME:-$ENVCODE}/kustomization.yaml"
[ -r "$OVERLAY" ] || { echo "no overlay at $OVERLAY"; exit 2; }
OPTIONAL=" OPENHIM_CORE_HOST OPENHIM_USERNAME OPENHIM_PASSWORD FACILITY_FILTER_IDS INGRESS_HOST ACME_EMAIL GATEWAY_ALLOWED_ORIGINS BASIC_AUTH_CLIENT_ID CCE_OPSALERT_TIER1_CC CCE_OPSALERT_TIER2_CC CCE_OPSALERT_TIER3_CC "
missing=(); notes=()
for v in $(grep -o '\${[A-Z_0-9]*}' "$OVERLAY" | tr -d '${}' | sort -u); do
  if [ -z "${!v:-}" ]; then
    case "$OPTIONAL" in *" $v "*) notes+=("$v");; *) missing+=("$v");; esac
  fi
done
echo "overlay-vars-check [$ENVCODE]: $(grep -o '\${[A-Z_0-9]*}' "$OVERLAY" | sort -u | wc -l) variables referenced"
[ "${#notes[@]}" -gt 0 ] && echo "  note — blank until you supply external config (OK for now): ${notes[*]}"
if [ "${#missing[@]}" -gt 0 ]; then
  echo "  FAIL — referenced by the overlay but EMPTY/UNSET in Infisical: ${missing[*]}"
  echo "         They would render as '' and crash-loop pods whose properties are numeric. Add them to Infisical (and to"
  echo "         one-click-installer/lib/infisical-seed.sh's SPEC so new environments get them) — compare with a working environment: kubectl -n cce-<env> get cm cce-config."
  exit 1
fi
echo "  OK — every non-optional overlay variable has a value"
