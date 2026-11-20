#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# one-click-installer/install-beckn.sh — add the Beckn network participants to a machine install.sh has already set up.
#
#   sudo bash one-click-installer/install-beckn.sh --config one-click-installer/config/<envcode>.env [--yes] [--only <component,…>]
#
# The same config file as install.sh, with the BECKN_* keys filled in (config/example.env, "Beckn add-on"; docs/beckn.md).
# Deploys the components in BECKN_COMPONENTS — each a Sygnal participant with its own ONIX adapter and public address:
#   cce      cce-beckn-service + CCE's adapter, into the existing cce-<envcode> namespace
#   openhim  OpenHIM + the Beckn build of the emitter adaptor + the HIE's adapter, in its own namespace
#   openmrs  OpenMRS O3 + the emitter and receiver adaptors (Beckn builds) + OpenMRS's Sygnal adapter and its Beckn adapter pair
#            for the Spice referrals (standard Beckn, unchanged), in its own namespace
#
# Needs: install.sh run for this env code with INGRESS_HOST + ACME_EMAIL set (k3s, Traefik with Let's Encrypt, Infisical), and a
# DNS name per component that points at this machine. Safe to re-run; --only limits a run to some components.
# DRY_RUN=1 renders and checks everything and applies nothing.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$HERE/lib"; BLIB="$LIB/beckn"; REPO="$(cd "$HERE/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root:  sudo bash $0 --config <file>"; exit 1; }
chmod +x "$LIB"/*.sh "$BLIB"/*.sh "$HERE"/*.sh 2>/dev/null || true

CONFIG=""; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a file}"; shift 2;;
    --only)   ONLY="${2:?--only needs a component list}"; shift 2;;
    --yes|-y) export ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,17p' "$0"; exit 0;;
    *) echo "unknown argument: $1  (usage: install-beckn.sh --config <file> [--yes] [--only cce,openhim,openmrs])"; exit 2;;
  esac
done
[ -n "$CONFIG" ] || { echo "ERROR: --config <file> is required"; exit 2; }
. "$LIB/load-config.sh"; cce_load_config "$CONFIG"
[ -n "${ENVCODE:-}" ] || { echo "CONFIG: ENVCODE is required"; exit 1; }
export ENVCODE
. "$BLIB/beckn-lib.sh"; beckn_defaults
beckn_validate || { echo "Fix the config above (config/example.env documents every BECKN_* key) and re-run."; exit 1; }
beckn_kubectl
RUN="${ONLY:-$BECKN_COMPONENTS}"; RUN="$(printf '%s' "$RUN" | tr ',' ' ')"
for c in $RUN; do beckn_hosted "$c" || { echo "ERROR: --only $c: not in BECKN_COMPONENTS ($BECKN_COMPONENTS)"; exit 1; }; done
confirm() { if [ -n "${ASSUME_YES:-}" ]; then echo "$1 [y/N] y  (--yes)"; return 0; fi; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }
phase() { echo; echo "████ $*"; }
# Run a script with the environment's secrets injected; drop the Infisical CLI's chatter. The status is the script's own
# (pipefail), never grep's: a run that prints nothing else must not look like a failure.
INF() {
  local rc=0
  bash "$LIB/infisical-run.sh" "$ENVCODE" "$@" 2>&1 \
    | { grep -vE 'new release of infisical|To update, run|Your logged-in session|Injecting [0-9]+ Infisical|^host-ip:' || true; } || rc=$?
  return "$rc"
}

. "$LIB/creds-dir.sh"
[ -r "$(cce_creds_dir)/${ENVCODE}.meta" ] || { echo "ERROR: environment '$ENVCODE' is not installed on this machine (no Infisical project) — run install.sh first"; exit 1; }
$KUBECTL get helmchartconfig traefik -n kube-system -o jsonpath='{.spec.valuesContent}' 2>/dev/null | grep -q 'certificatesresolvers.le.acme' \
  || { echo "ERROR: Traefik has no Let's Encrypt resolver. Beckn addresses are HTTPS: set INGRESS_HOST + ACME_EMAIL and run install.sh first."; exit 1; }

cat <<SUMMARY

════════════════════════════════════════════════════════════════
 Beckn add-on                       environment: $ENVCODE
 Components here:    $BECKN_COMPONENTS$( [ "$RUN" != "$BECKN_COMPONENTS" ] && echo "   (this run: $RUN)" )
$(for c in $BECKN_ALL_COMPONENTS; do p="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"; i="BECKN_${p}_ID"; u="BECKN_${p}_URI"
    if beckn_hosted "$c"; then printf ' %-8s            %s   ns %s\n                     %s\n' "$c" "${!u}" "$(beckn_component_ns "$c")" "${!i}"
    else printf ' %-8s            elsewhere   %s  %s\n' "$c" "${!i:--}" "${!u:-}"; fi; done)
 Spice (Sygnal):     $( [ "$BECKN_SPICE_CONFIGURED" = true ] && echo "$BECKN_SPICE_ID  ${BECKN_SPICE_URI:-}" || echo "not configured")
$(beckn_hosted openmrs && echo " Referrals (Beckn):  OpenMRS $BECKN_OPENMRS_BAP_ID / $BECKN_OPENMRS_BPP_ID   Spice $( [ "$BECKN_SPICE_REFERRALS_CONFIGURED" = true ] && echo "$BECKN_SPICE_BAP_ID" || echo "not configured (placeholder ids)")   legs: $BECKN_REFERRALS_ENABLED")
 Registry:           $BECKN_REGISTRY_URL   Sygnal network $BECKN_SYGNAL_NETWORK_ID
 Schemas:            ${BECKN_SCHEMA_DIR:-$BECKN_SCHEMA_REPO @ $BECKN_SCHEMA_REF}
 HIE redaction:      $( [ "$BECKN_OPENHIM_REDACTION_ENABLED" = false ] && echo "OFF — full clinical payloads go to CCE" || echo "on")
════════════════════════════════════════════════════════════════
SUMMARY
confirm "Proceed?" || { echo "Aborted."; exit 0; }

phase "1/4 Secrets: Infisical /beckn (keys, passwords, referral contract ids)"
INF bash "$BLIB/beckn-seed.sh" "$ENVCODE" "${BECKN_SEED_ENV_FILE:-}"

phase "2/4 Schemas for the adapters (the CCE Sygnal profile, CceClinicalEvent, CceCareAlert)"
# The adapters check every message against these. A local folder wins; otherwise they are fetched, like the data pipeline.
# The profile is <schema>/sygnal-profile/v1.0/cce-sygnal-apis.yaml unless BECKN_SYGNAL_PROFILE names another file.
if [ -n "${BECKN_SCHEMA_DIR:-}" ]; then
  [ -d "$BECKN_SCHEMA_DIR" ] || { echo "ERROR: BECKN_SCHEMA_DIR=$BECKN_SCHEMA_DIR is not a directory"; exit 1; }
  echo "  using $BECKN_SCHEMA_DIR"
else
  FETCH="$(mktemp -d)"; trap 'rm -rf "$FETCH"' EXIT
  git clone -q --depth 1 -b "$BECKN_SCHEMA_REF" "$BECKN_SCHEMA_REPO" "$FETCH/src" 2>/dev/null || {
    echo "ERROR: cannot fetch $BECKN_SCHEMA_REPO @ $BECKN_SCHEMA_REF (a private repository needs credentials)."
    echo "       Copy its schema/ folder to this machine and set BECKN_SCHEMA_DIR to it."; exit 1; }
  BECKN_SCHEMA_DIR="$FETCH/src/schema"; echo "  fetched $BECKN_SCHEMA_REPO @ $BECKN_SCHEMA_REF ($(git -C "$FETCH/src" rev-parse --short HEAD))"
fi
export BECKN_SCHEMA_DIR
for s in CceClinicalEvent CceCareAlert; do [ -d "$BECKN_SCHEMA_DIR/$s" ] || echo "  WARNING: no $s/ in $BECKN_SCHEMA_DIR — the adapters will refuse messages that use it"; done
export BECKN_SYGNAL_PROFILE="${BECKN_SYGNAL_PROFILE:-$BECKN_SCHEMA_DIR/sygnal-profile/v1.0/cce-sygnal-apis.yaml}"
[ -r "$BECKN_SYGNAL_PROFILE" ] || { echo "ERROR: no CCE Sygnal profile at $BECKN_SYGNAL_PROFILE — the adapters cannot start without it."
  echo "       Use a cce-beckn-service ref that has schema/sygnal-profile/ (BECKN_SCHEMA_REF), or set BECKN_SYGNAL_PROFILE."; exit 1; }
echo "  CCE Sygnal profile: $BECKN_SYGNAL_PROFILE"

phase "3/4 Deploy: $RUN"
for c in $RUN; do INF bash "$BLIB/beckn-deploy.sh" "$ENVCODE" "$c"; done
[ -z "${DRY_RUN:-}" ] || { echo; echo "DRY_RUN: nothing applied."; exit 0; }

phase "4/4 Configure and wait"
wait_for() {   # <ns> <timeout> <deployment…>: report, never abort — a slow first start is not a failed install
  local ns="$1" t="$2" d; shift 2
  for d in "$@"; do
    $KUBECTL -n "$ns" rollout status "deploy/$d" --timeout="$t" >/dev/null 2>&1 && echo "  ✓ $ns/$d" || echo "  … $ns/$d not ready after $t  ($KUBECTL -n $ns describe deploy/$d; logs deploy/$d)"
  done
}
for c in $RUN; do
  NS="$(beckn_component_ns "$c")"
  case "$c" in
    cce)     wait_for "$NS" 300s onix-redis onix-sygnal cce-beckn-service;;
    openhim) wait_for "$NS" 600s openhim-mongo openhim-core onix-redis onix-sygnal
             INF bash "$BLIB/openhim-setup.sh" "$ENVCODE"
             wait_for "$NS" 300s openhim-console openhim-cce-emitter-adaptor;;
    openmrs) wait_for "$NS" 300s openmrs-db onix-redis onix-sygnal onix-bap onix-bpp openmrs-gateway openmrs-frontend
             # the first start on an empty database installs the reference application (10-20 minutes)
             wait_for "$NS" 1500s openmrs-backend
             wait_for "$NS" 300s openmrs-cce-receiver-adaptor openmrs-cce-emitter-adaptor;;
  esac
done

echo; echo "████ Result"
for c in $BECKN_COMPONENTS; do
  NS="$(beckn_component_ns "$c")"; sel="-l app.kubernetes.io/part-of=${c}-beckn"
  $KUBECTL -n "$NS" get pods $sel --no-headers 2>/dev/null | awk -v c="$c" '{split($2,a,"/"); t++; if ($3=="Running" && a[1]==a[2]) r++; else print "   not ready: "$1" "$2" "$3} END{printf "   %-8s pods ready: %d/%d\n", c, r, t}'
done
cat <<DONE

Done.
$(beckn_hosted cce && echo "  CCE Sygnal:  $BECKN_CCE_URI   ($BECKN_CCE_ID)")
$(beckn_hosted openhim && echo "  OpenHIM:     https://$BECKN_OPENHIM_HOST/   (console; Core API under /openhim-api)   Sygnal: $BECKN_OPENHIM_URI ($BECKN_OPENHIM_ID)")
$(beckn_hosted openmrs && echo "  OpenMRS:     https://$BECKN_OPENMRS_HOST/openmrs/spa   Sygnal: $BECKN_OPENMRS_URI ($BECKN_OPENMRS_ID)   Beckn (referrals): /bap/receiver, /bpp/receiver")
  Registry:    every Sygnal id must be a member of $BECKN_SYGNAL_NETWORK_ID — beckn-status.sh checks it
  Logins:      sudo bash $HERE/tools/show-credentials.sh $ENVCODE [--reveal]
  Check:       sudo bash $BLIB/run.sh --config $CONFIG beckn-status.sh
  Docs:        $HERE/docs/beckn.md   (the flow, what to exchange with the other participants, copying an OpenMRS)
DONE
