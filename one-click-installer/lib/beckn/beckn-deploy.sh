#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-deploy.sh <envcode> <component> — render and apply ONE Beckn component (cce | openhim | openmrs).
# Run under infisical-run.sh, with the installer config loaded (install-beckn.sh does both). Safe to re-run.
#
# What it does, in the component's namespace:
#   1. Secret onix-config     the Sygnal adapter's config + its two routing files, rendered from k8s/beckn/onix/config/ with
#                             this participant's id, keys, timeouts and the address of its own service. openmrs: also its
#                             Beckn referral pair's two configs + four routing files (k8s/beckn/onix-beckn/config/)
#   2. ConfigMap onix-sygnal-profile  the CCE profile of Sygnal (BECKN_SYGNAL_PROFILE): the Sygnal adapter's only spec
#      ConfigMap onix-sygnal-schema   the Sygnal adapter's schema folders, one key per file, "/" written "__": the version
#                                     folders BECKN_SYGNAL_SCHEMAS names in BECKN_SCHEMA_DIR (CceClinicalEvent v2.0,
#                                     CceCareAlert v1.0)
#      ConfigMap onix-schema          openmrs only, for its Beckn referral pair, unchanged: BECKN_REFERRAL_SCHEMAS
#                                     (CceClinicalEvent v1.0, CceCareAlert v1.0) + the Health* referral pack
#                                     (k8s/beckn/onix-beckn/health-schema). cce / openhim: removed (no referral pair)
#   3. kubectl apply          k8s/beckn/<component> rendered with kustomize, ${VARS} filled with envsubst. cce / openhim: the
#                             Beckn adapter pair of the former setup (onix-bap, onix-bpp) is removed — only OpenMRS keeps
#                             one, for the Spice referrals.
#   4. host aliases           on the adapter pods: the public hosts that live on THIS machine -> Traefik's ClusterIP
#                             (a pod cannot reach the machine's own public address)
#   5. (cce only)             the intelligence service's alert routes to cce-beckn-service
# Nothing rendered is written into the repository: the files hold private keys, so they exist in a temp dir only.
#
# DRY_RUN=1 renders and checks everything, prints the resource list, and applies nothing.
set -euo pipefail
ENVCODE="${1:?usage: beckn-deploy.sh <envcode> <component>}"
COMPONENT="${2:?usage: beckn-deploy.sh <envcode> <component>   (cce | openhim | openmrs)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$(cd "$HERE/.." && pwd)"; REPO="$(cd "$LIB/../.." && pwd)"
. "$HERE/beckn-lib.sh"
export ENVCODE
beckn_defaults
beckn_kubectl
NS="$(beckn_component_ns "$COMPONENT")"
P="$(printf '%s' "$COMPONENT" | tr '[:lower:]' '[:upper:]')"
SRC="$REPO/k8s/beckn/$COMPONENT"
[ -r "$SRC/kustomization.yaml" ] || { echo "ERROR: no $SRC/kustomization.yaml"; exit 1; }
: "${BECKN_SCHEMA_DIR:?BECKN_SCHEMA_DIR not set — install-beckn.sh resolves it (the folder holding CceClinicalEvent/ and CceCareAlert/)}"
: "${BECKN_SYGNAL_PROFILE:=$BECKN_SCHEMA_DIR/$BECKN_SYGNAL_PROFILE_REL}"
[ -r "$BECKN_SYGNAL_PROFILE" ] || { echo "ERROR: no CCE Sygnal profile at $BECKN_SYGNAL_PROFILE"; beckn_profile_hint "$BECKN_SCHEMA_DIR"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
say() { echo "  [$COMPONENT] $*"; }

# ── this participant's adapter settings ──────────────────────────────────────────────────────────────────────────────────
# One identity: BECKN_<P>_ID / BECKN_<P>_KEY_ID (beckn_defaults falls back to the participant's former BAP or BPP record).
# Keys: the most specific one that is set wins — that former role's, the participant's, then the pair shared by every
# participant here.
pick() { local v; for v in "$@"; do if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return 0; fi; done; return 0; }
ROLE="$(beckn_role "$P")"
export "ONIX_SUBSCRIBER_ID=$(pick "BECKN_${P}_ID")" "ONIX_KEY_ID=$(pick "BECKN_${P}_KEY_ID")"
for k in SIGNING_PRIVATE_KEY SIGNING_PUBLIC_KEY ENCR_PRIVATE_KEY ENCR_PUBLIC_KEY; do
  export "ONIX_${k}=$(pick "BECKN_${P}_${ROLE}_${k}" "BECKN_${P}_${k}" "BECKN_${k}")"
done
export ONIX_APP_NAME="onix-$COMPONENT" ONIX_LOG_LEVEL="$BECKN_ONIX_LOG_LEVEL" ONIX_REDIS_ADDR="onix-redis:6379"
# Every answer comes back in the same HTTP call (there are no callbacks), so each hop must wait longer than the hop
# behind it:
#   sygnal/event/report, OpenMRS -> HIE -> CCE
#     cce-beckn-service -> collector                       15 s  (CCE_COLLECTOR_TIMEOUT)
#     CCE onix receiver -> cce-beckn-service               18 s
#     HIE onix caller -> CCE                               20 s  (the HIE adaptor gives its onix 20 s too and gets the
#                                                                 CCE onix's own error first)
#     OpenHIM channel "CCE Beckn feed" -> /inbound         22.5 s (openhim-metadata.json)
#     HIE adaptor -> OpenHIM channel                       25 s  (OPENHIM_EMITTER_BECKN_OPENHIM_CHANNEL_TIMEOUT_MS)
#     HIE onix receiver -> HIE adaptor                     30 s
#     OpenMRS onix caller -> HIE                           40 s
#     OpenMRS emitter -> its adapters                      50 s  (OPENMRS_EMITTER_BECKN_ONIX_TIMEOUT, one setting for every
#                                                                 leg; the referral pair's onix-bap waits 45 s for Spice)
#   sygnal/signal/emit, CCE -> OpenMRS
#     OpenMRS onix receiver -> receiver adaptor             5 s
#     CCE onix caller -> OpenMRS                            6 s
#     cce-beckn-service -> its onix                         7 s  (CCE_BECKN_ONIX_READ_TIMEOUT_MS; the intelligence
#                                                                 service waits 10 s for cce-beckn-service)
# The adapters' own HTTP server timeout (write) is 60 s, above all of them.
# Receiver: the action it accepts and the base URL of the service it passes it to (onix appends the action).
# Caller: the action this participant sends.
case "$COMPONENT" in
  cce)     export ONIX_RECEIVER_TIMEOUT=18s ONIX_CALLER_TIMEOUT=6s
           export ONIX_RECEIVER_ACTION=sygnal/event/report ONIX_RECEIVER_TARGET="http://cce-beckn-service:8075" ONIX_CALLER_ACTION=sygnal/signal/emit;;
  openhim) export ONIX_RECEIVER_TIMEOUT=30s ONIX_CALLER_TIMEOUT=20s
           export ONIX_RECEIVER_ACTION=sygnal/event/report ONIX_RECEIVER_TARGET="http://openhim-cce-emitter-adaptor:8082" ONIX_CALLER_ACTION=sygnal/event/report;;
  openmrs) export ONIX_RECEIVER_TIMEOUT=5s ONIX_CALLER_TIMEOUT=40s
           export ONIX_RECEIVER_ACTION=sygnal/signal/emit ONIX_RECEIVER_TARGET="http://openmrs-cce-receiver-adaptor:8080" ONIX_CALLER_ACTION=sygnal/event/report;;
esac
HOSTVAR="BECKN_${P}_HOST"; export BECKN_HOST="${!HOSTVAR:?$HOSTVAR not set}"

# OpenMRS's Beckn adapter pair for the Spice referrals (standard Beckn, unchanged): its BAP and BPP identities and waits.
# A referral from Spice makes several OpenMRS calls (30 s each at most) before the receiver answers: onix-bpp waits 45 s,
# onix-bap 45 s for Spice (the emitter 50 s). Callbacks are logged and answered at once: 5 s into the receiver, 10 s out.
CONFIG_DIRS=("$REPO/k8s/beckn/onix/config")
if [ "$COMPONENT" = openmrs ]; then
  CONFIG_DIRS+=("$REPO/k8s/beckn/onix-beckn/config")
  for role in BAP BPP; do
    export "ONIX_${role}_SUBSCRIBER_ID=$(pick "BECKN_${P}_${role}_ID")" "ONIX_${role}_KEY_ID=$(pick "BECKN_${P}_${role}_KEY_ID")"
    for k in SIGNING_PRIVATE_KEY SIGNING_PUBLIC_KEY ENCR_PRIVATE_KEY ENCR_PUBLIC_KEY; do
      export "ONIX_${role}_${k}=$(pick "BECKN_${P}_${role}_${k}" "BECKN_${P}_${k}" "BECKN_${k}")"
    done
  done
  export ONIX_HTTP_TIMEOUT=60 ONIX_BAP_RECEIVER_TIMEOUT=5s ONIX_BPP_CALLER_TIMEOUT=10s ONIX_BPP_RECEIVER_TIMEOUT=45s ONIX_BAP_CALLER_TIMEOUT=45s
  export ONIX_BPP_RECEIVER_TARGET="http://openmrs-cce-receiver-adaptor:8080/beckn/bpp-webhook" ONIX_BAP_RECEIVER_TARGET="http://openmrs-cce-receiver-adaptor:8080/beckn/bap-webhook"
fi

# The HIE's subscriber list (beckn.subscribers of the adaptor): every HMIS that may send it sygnal/event/report (checked
# against context.senderId), and the source its events are filed under. OpenMRS always; Spice once configured.
if [ "$COMPONENT" = openhim ]; then
  OPENHIM_ADAPTOR_SPRING_JSON="$(python3 - <<'PY'
import json, os
E = os.environ.get
subs = [{"subscriber-id": E("BECKN_OPENMRS_ID"), "source-system": "openmrs"}]
if E("BECKN_SPICE_CONFIGURED") == "true":
    subs.append({"subscriber-id": E("BECKN_SPICE_ID"), "source-system": "spice"})
print(json.dumps({"beckn": {"subscribers": subs}}, separators=(",", ":")))
PY
)"; export OPENHIM_ADAPTOR_SPRING_JSON
fi
# CCE's alert recipients (hmis.yml of cce-beckn-service): OpenMRS when its id and address are known, Spice once
# configured with its Sygnal address (BECKN_SPICE_URI). An alert goes to an HMIS as sygnal/signal/emit, to its
# subscriber-uri (its https://<host>/sygnal/receiver).
# The HIE is not one: alerts go to an HMIS directly, and the HIE adaptor has no sygnal/signal/emit endpoint.
if [ "$COMPONENT" = cce ]; then
  CCE_BECKN_HMIS_ENTRIES="$(python3 - <<'PY'
import os
E = lambda k: (os.environ.get(k) or "").strip()
entries = []
if E("BECKN_OPENMRS_ID") and E("BECKN_OPENMRS_URI"):
    entries.append((E("BECKN_OPENMRS_ID"), E("BECKN_OPENMRS_URI")))
if E("BECKN_SPICE_CONFIGURED") == "true" and E("BECKN_SPICE_URI"):
    entries.append((E("BECKN_SPICE_ID"), E("BECKN_SPICE_URI")))
pad = " " * 10
lines = []
for sid, uri in entries:
    lines.append(f"{pad}- subscriber-id: {sid}")
    lines.append(f"{pad}  subscriber-uri: {uri}")
print("\n".join(lines) if lines else pad + "[]")
PY
)"; export CCE_BECKN_HMIS_ENTRIES
fi
export BECKN_REFERRALS_OUT_CONTRACT_ID="${BECKN_REFERRALS_OUT_CONTRACT_ID:-}" BECKN_REFERRALS_OUT_TRANSACTION_ID="${BECKN_REFERRALS_OUT_TRANSACTION_ID:-}"

# Every ${VAR} a file references must have a value, or it would render as "" and fail later, far from the cause. The
# few that may be empty are listed.
OPTIONAL=" BECKN_NETWORK_ID BECKN_ALLOWED_NETWORK_IDS BECKN_SYGNAL_ALLOWED_NETWORK_IDS BECKN_OPENHIM_FACILITY_FILTER_IDS BECKN_SPICE_BPP_ID BECKN_SPICE_BPP_URI BECKN_SPICE_FACILITY_CODES BECKN_REFERRALS_OUT_CONTRACT_ID BECKN_REFERRALS_OUT_TRANSACTION_ID BECKN_HEALTH_ID_TYPES BECKN_CONFIG_HASH ONIX_CONFIG_HASH "
check_vars() {   # <file...> -> prints the envsubst variable list; exits if a non-optional one is empty
  local v missing=() list=""
  for v in $(grep -ho '\${[A-Z_0-9]*}' "$@" | tr -d '${}' | sort -u); do
    list="$list \${$v}"
    if [ -z "${!v:-}" ]; then case "$OPTIONAL" in *" $v "*) export "$v=${!v:-}";; *) missing+=("$v");; esac; fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR [$COMPONENT]: no value for: ${missing[*]}" >&2
    echo "       BECKN_* identity keys come from the installer config, private keys and passwords from Infisical /beckn (beckn-seed.sh)." >&2
    exit 1
  fi
  printf '%s' "$list"
}

# ── 1. adapter config -> Secret onix-config ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/onix"
CONFIG_FILES=(); for d in "${CONFIG_DIRS[@]}"; do CONFIG_FILES+=("$d"/*.yaml); done
VARS="$(check_vars "${CONFIG_FILES[@]}")"
for f in "${CONFIG_FILES[@]}"; do envsubst "$VARS" < "$f" > "$TMP/onix/$(basename "$f")"; done
# No network id configured: no membership check — leave the setting out rather than give the adapter an empty list.
[ -n "${BECKN_SYGNAL_ALLOWED_NETWORK_IDS:-}" ] || sed -i '/^ *allowedNetworkIDs:/d' "$TMP"/onix/onix.yaml
if [ "$COMPONENT" = openmrs ] && [ -z "${BECKN_ALLOWED_NETWORK_IDS:-}" ]; then sed -i '/^ *allowedNetworkIDs:/d' "$TMP"/onix/onix-b?p.yaml; fi
export ONIX_CONFIG_HASH; ONIX_CONFIG_HASH="$(cat "$TMP"/onix/*.yaml | sha256sum | cut -c1-16)"

# ── 2. the CCE profile -> ConfigMap onix-sygnal-profile; schema folders -> ConfigMaps onix-sygnal-schema, onix-schema ──────
# The profile is the Sygnal adapter's only spec (schemaValidator type "file"). Schemas are loaded at start
# (extendedSchema_localSchemaPath) from <Type>/<version>/attributes.yaml. onix finds a local schema by its TYPE name and
# ignores the version folder (its key is <Type>/attributes.yaml), so an adapter must hold exactly ONE version of a type —
# and two versions of CceClinicalEvent are in use:
#   onix-sygnal (every participant)   v2.0: the object in sygnal/event/report           -> ConfigMap onix-sygnal-schema
#   onix-bap / onix-bpp (openmrs)     v1.0: the box in performanceAttributes of the      -> ConfigMap onix-schema
#                                     referral legs, unchanged
# So each kind of adapter has its own ConfigMap, and its version folders are named explicitly (BECKN_SYGNAL_SCHEMAS,
# BECKN_REFERRAL_SCHEMAS) — nothing is taken because it happens to be in the schema folder.
schema_args() {   # <root> <file…> -> --from-file arguments, one per file, key = path under <root> with "/" written "__"
  local root="$1" f rel; shift
  for f in "$@"; do rel="${f#"$root"/}"; printf '%s\n' "--from-file=${rel//\//__}=$f"; done
}
one_version_per_type() {   # <what> <--from-file argument…>: stop if a type would be there in two versions
  local what="$1" dup; shift
  dup="$(printf '%s\n' "$@" | sed 's/^--from-file=//; s/=.*//' | awk -F'__' '{print $1 "/" $NF}' | sort | uniq -d | head -1)"
  [ -z "$dup" ] || { echo "ERROR [$COMPONENT]: $what would hold more than one version of schema $dup — an adapter must hold one version per type" >&2; exit 1; }
}
SYGNAL_SCHEMA_LIST="$(beckn_schema_set "$BECKN_SCHEMA_DIR" BECKN_SYGNAL_SCHEMAS "$BECKN_SYGNAL_SCHEMAS")"
mapfile -t SYGNAL_SCHEMA_FILES <<< "$SYGNAL_SCHEMA_LIST"
mapfile -t SYGNAL_SCHEMA_ARGS < <(schema_args "$BECKN_SCHEMA_DIR" "${SYGNAL_SCHEMA_FILES[@]}")
one_version_per_type "ConfigMap onix-sygnal-schema" "${SYGNAL_SCHEMA_ARGS[@]}"
n="${#SYGNAL_SCHEMA_FILES[@]}"
SCHEMA_FILES=("$BECKN_SYGNAL_PROFILE" "${SYGNAL_SCHEMA_FILES[@]}")
# openmrs: what its Beckn pair (onix-bap / onix-bpp) holds, as before — the CCE schemas of the referral legs and the
# Health* referral pack (schema.beckn.io no longer serves it). onix-sygnal does not mount this ConfigMap.
HEALTH_SCHEMA_DIR="$REPO/k8s/beckn/onix-beckn/health-schema"
r=0; h=0; REFERRAL_SCHEMA_ARGS=()
if [ "$COMPONENT" = openmrs ]; then
  REFERRAL_SCHEMA_LIST="$(beckn_schema_set "$BECKN_SCHEMA_DIR" BECKN_REFERRAL_SCHEMAS "$BECKN_REFERRAL_SCHEMAS")"
  mapfile -t REFERRAL_SCHEMA_FILES <<< "$REFERRAL_SCHEMA_LIST"
  mapfile -t HEALTH_SCHEMA_FILES < <(find "$HEALTH_SCHEMA_DIR" -mindepth 3 -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.jsonld' -o -name '*.json' \) | sort)
  mapfile -t REFERRAL_SCHEMA_ARGS < <(schema_args "$BECKN_SCHEMA_DIR" "${REFERRAL_SCHEMA_FILES[@]}"; schema_args "$HEALTH_SCHEMA_DIR" "${HEALTH_SCHEMA_FILES[@]}")
  one_version_per_type "ConfigMap onix-schema ($BECKN_SCHEMA_DIR + $HEALTH_SCHEMA_DIR)" "${REFERRAL_SCHEMA_ARGS[@]}"
  r="${#REFERRAL_SCHEMA_FILES[@]}"; h="${#HEALTH_SCHEMA_FILES[@]}"
  SCHEMA_FILES+=("${REFERRAL_SCHEMA_FILES[@]}" "${HEALTH_SCHEMA_FILES[@]}")
fi
SCHEMA_HASH="$(cat "${SCHEMA_FILES[@]}" | sha256sum | cut -c1-8)"
ONIX_CONFIG_HASH="${ONIX_CONFIG_HASH}-${SCHEMA_HASH}"

# ── 3. the component's manifests ─────────────────────────────────────────────────────────────────────────────────────────
# envsubst BEFORE kustomize, in a throwaway copy (as lib/native/05-k8s-deploy.sh does): kustomize re-writes YAML and drops
# quotes it finds unnecessary, so a value substituted afterwards could change type ("false" -> false, a JSON string -> a map).
# Substituting first keeps every value exactly as the manifest quotes it.
cp -r "$REPO/k8s/beckn" "$TMP/beckn"
BASES=(onix netpol); [ "$COMPONENT" = openmrs ] && BASES+=(onix-beckn)
mapfile -t MANIFESTS < <(cd "$REPO/k8s/beckn" && find "$COMPONENT" "${BASES[@]}" -maxdepth 1 -name '*.yaml' | sort)
VARS="$(cd "$REPO/k8s/beckn" && check_vars "${MANIFESTS[@]}")"
render() { local f; for f in "${MANIFESTS[@]}"; do envsubst "$VARS" < "$REPO/k8s/beckn/$f" > "$TMP/beckn/$f"; done; $KUBECTL kustomize "$TMP/beckn/$COMPONENT"; }
# BECKN_CONFIG_HASH rolls the pods that read their settings once, at start, whenever a value they consume changes:
# it is the hash of the whole render (taken with the hash itself empty).
export BECKN_CONFIG_HASH=""
BECKN_CONFIG_HASH="$(render | sha256sum | cut -c1-16)"
render > "$TMP/render.yaml"
if grep -q '\${[A-Z_0-9]*}' "$TMP/render.yaml"; then
  echo "ERROR [$COMPONENT]: unsubstituted variable(s) left in the render: $(grep -o '\${[A-Z_0-9]*}' "$TMP/render.yaml" | sort -u | tr '\n' ' ')" >&2; exit 1
fi

if [ "$COMPONENT" = openmrs ]; then
  # Site data the frontend mounts from the node. Created empty when there is none, so a plain install starts.
  D="$BECKN_OPENMRS_HOST_DIR"
  if [ -z "${DRY_RUN:-}" ]; then
    ( umask 022; mkdir -p "$D/frontend/custom-esms"; [ -s "$D/config-core_demo.json" ] || echo '{}' > "$D/config-core_demo.json" )
  fi
fi

if [ -n "${DRY_RUN:-}" ]; then
  say "DRY_RUN — namespace $NS, $(grep -c '^kind:' "$TMP/render.yaml") resources, adapter $ONIX_SUBSCRIBER_ID config $ONIX_CONFIG_HASH, profile ${BECKN_SYGNAL_PROFILE#"$BECKN_SCHEMA_DIR"/} + $n Sygnal schema files ($BECKN_SYGNAL_SCHEMAS)$( [ "$COMPONENT" = openmrs ] && echo "; referral pair onix-bap $ONIX_BAP_SUBSCRIBER_ID, onix-bpp $ONIX_BPP_SUBSCRIBER_ID: $r schema files ($BECKN_REFERRAL_SCHEMAS) + $h Health* referral schema files"); nothing applied"
  say "  ConfigMap onix-sygnal-schema: $(printf '%s\n' "${SYGNAL_SCHEMA_ARGS[@]}" | sed 's/^--from-file=//; s/=.*//' | tr '\n' ' ')"
  [ "$COMPONENT" != openmrs ] || say "  ConfigMap onix-schema (referral pair): $(printf '%s\n' "${REFERRAL_SCHEMA_ARGS[@]}" | sed 's/^--from-file=//; s/=.*//' | grep '^Cce' | tr '\n' ' ')+ $h Health* keys"
  grep -E '^kind:|^  name:' "$TMP/render.yaml" | paste - - | sed 's/kind: //; s/ *name: / /' | sort | sed 's/^/      /'
  exit 0
fi

if [ "$COMPONENT" = cce ]; then
  $KUBECTL get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: namespace $NS does not exist — run install.sh for '$ENVCODE' first"; exit 1; }
else
  $KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
fi
$KUBECTL -n "$NS" create secret generic onix-config --from-file="$TMP/onix" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL -n "$NS" create configmap onix-sygnal-profile --from-file="cce-sygnal-apis.yaml=$BECKN_SYGNAL_PROFILE" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL -n "$NS" create configmap onix-sygnal-schema "${SYGNAL_SCHEMA_ARGS[@]}" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
say "namespace $NS: Sygnal adapter config ($ONIX_SUBSCRIBER_ID; network ${BECKN_SYGNAL_ALLOWED_NETWORK_IDS:-not checked}) + CCE profile ${BECKN_SYGNAL_PROFILE#"$BECKN_SCHEMA_DIR"/} + $n Sygnal schema files ($BECKN_SYGNAL_SCHEMAS)"
if [ "$COMPONENT" = openmrs ]; then
  $KUBECTL -n "$NS" create configmap onix-schema "${REFERRAL_SCHEMA_ARGS[@]}" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
  say "namespace $NS: Beckn referral pair config ($ONIX_BAP_SUBSCRIBER_ID, $ONIX_BPP_SUBSCRIBER_ID; network ${BECKN_ALLOWED_NETWORK_IDS:-not checked}) + $r schema files ($BECKN_REFERRAL_SCHEMAS) + $h Health* referral schema files"
fi
$KUBECTL -n "$NS" apply -f "$TMP/render.yaml" | sed "s/^/      /"
# cce / openhim: the Sygnal adapter replaces the Beckn adapter pair of the former setup — remove it (a no-op once gone).
# Their ConfigMap onix-schema goes too: onix-sygnal reads onix-sygnal-schema now, and only a referral pair reads
# onix-schema. A pod that is still running keeps the copy it mounted.
if [ "$COMPONENT" != openmrs ]; then
  $KUBECTL -n "$NS" delete deploy,svc onix-bap onix-bpp --ignore-not-found | sed "s/^/      /"
  $KUBECTL -n "$NS" delete configmap onix-schema --ignore-not-found | sed "s/^/      /"
fi

# ── 4. host aliases + roll the adapter when its config changed ───────────────────────────────────────────────────────────
# The adapter sends to the other participants' PUBLIC addresses (context.receiverUri). Those that live on this machine
# resolve to its own public IP, which a pod cannot reach — so they are pointed at Traefik's ClusterIP instead. The
# certificate still matches: Traefik serves each host's own certificate.
TIP="$($KUBECTL get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')"
ALIASES=""
for c in $BECKN_COMPONENTS; do
  hv="BECKN_$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')_HOST"; [ -n "${!hv:-}" ] && ALIASES="$ALIASES\"${!hv}\","
done
ADAPTERS=(onix-sygnal); [ "$COMPONENT" = openmrs ] && ADAPTERS+=(onix-bap onix-bpp)
for d in "${ADAPTERS[@]}"; do
  $KUBECTL -n "$NS" patch deploy "$d" --type=strategic -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"cce.openphc.org/onix-config-hash\":\"${ONIX_CONFIG_HASH}\"}},\"spec\":{\"hostAliases\":[{\"ip\":\"${TIP}\",\"hostnames\":[${ALIASES%,}]}]}}}}" >/dev/null
done
say "${ADAPTERS[*]}: local hosts -> Traefik $TIP"

# ── 5. CCE: where the intelligence service sends alerts ─────────────────────────────────────────────────────────────────
# One receiver-adaptor record and one destination mapping per alert destination: OPENMRS when OpenMRS's id and address are
# known, SPICE once Spice is configured. Each points at cce-beckn-service's POST /v1/alerts, signed with the shared webhook
# secret, with the destination's subscriber id in X-CCE-Beckn-Subscriber-Id: cce-beckn-service sends the alert to that HMIS
# (its hmis.yml entry) as sygnal/signal/emit.
# A protocol action reaches a destination by its intelligence-destination code (e.g. OPENMRS). Safe to re-run: an existing
# record is updated, not duplicated.
if [ "$COMPONENT" = cce ]; then
  INTEL_IP="$($KUBECTL -n "$NS" get svc cce-intelligence-service -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [ -z "$INTEL_IP" ]; then
    say "intelligence alert routes: cce-intelligence-service not found in $NS — skipped"
  else
    INTEL_URL="http://$INTEL_IP:8085" python3 - <<'PY' | sed 's/^/      /'
import json, os, time, urllib.request, urllib.error
E = lambda k: (os.environ.get(k) or "").strip()
base = E("INTEL_URL")
secret = E("CCE_BECKN_ALERTS_WEBHOOK_SECRET")
dests = []
if E("BECKN_OPENMRS_ID") and E("BECKN_OPENMRS_URI"):
    dests.append(("OPENMRS", E("BECKN_OPENMRS_ID")))
if E("BECKN_SPICE_CONFIGURED") == "true" and E("BECKN_SPICE_URI"):
    dests.append(("SPICE", E("BECKN_SPICE_ID")))

def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"{}")

for attempt in range(30):                 # the service may still be starting
    try:
        call("GET", "/v1/receiver-adaptors"); break
    except Exception:
        time.sleep(5)
else:
    print("intelligence alert routes: cce-intelligence-service did not answer — skipped"); raise SystemExit(0)
if not secret:
    print("intelligence alert routes: CCE_BECKN_ALERTS_WEBHOOK_SECRET is empty — skipped"); raise SystemExit(0)

adaptors = {a["name"]: a for a in call("GET", "/v1/receiver-adaptors").get("data", [])}
# Listing the mappings fails in the intelligence service once one exists (it reads each mapping's adaptor outside a
# transaction). Without the list, a mapping is created, and one that already exists is left as it is: it points at the
# adaptor by id, and an existing adaptor keeps its id (it is updated in place below).
try:
    mappings = {m["destination"]: m for m in call("GET", "/v1/destination-adaptor-mappings").get("data", [])}
except Exception:
    mappings = None

def route(dest, subscriber_id):
    name = "beckn-alerts-" + dest.lower()
    record = {
        "name": name,
        "definition": {
            "resourceType": "Endpoint", "id": name, "status": "active", "name": "CCE alerts to " + subscriber_id + " over Sygnal",
            "connectionType": {"system": "http://terminology.hl7.org/CodeSystem/endpoint-connection-type", "code": "hl7-fhir-rest"},
            "payloadType": [{"coding": [{"system": "http://hl7.org/fhir/resource-types", "code": "CommunicationRequest"}]}],
            "payloadMimeType": ["application/fhir+json"],
            "address": "http://cce-beckn-service:8075/v1/alerts"},
        "config": {"webhookSecret": secret, "customHeaders": {"X-CCE-Beckn-Subscriber-Id": subscriber_id}},
        "status": "ACTIVE"}
    if name in adaptors:
        adaptor = call("PUT", "/v1/receiver-adaptors/" + adaptors[name]["id"], record)["data"]
    else:
        adaptor = call("POST", "/v1/receiver-adaptors", {k: record[k] for k in ("name", "definition", "config")})["data"]
    if mappings is not None and dest in mappings:
        call("PUT", "/v1/destination-adaptor-mappings/" + mappings[dest]["id"],
             {"receiverAdaptorId": adaptor["id"], "status": "ACTIVE"})
    elif mappings is not None:
        call("POST", "/v1/destination-adaptor-mappings", {"destination": dest, "receiverAdaptorId": adaptor["id"]})
    else:
        try:
            call("POST", "/v1/destination-adaptor-mappings", {"destination": dest, "receiverAdaptorId": adaptor["id"]})
        except urllib.error.HTTPError:
            pass                              # the mapping exists already (destination is unique)
    print(f"intelligence alert route: {dest} -> cce-beckn-service /v1/alerts -> {subscriber_id}")

# A failure here is reported, never fatal: the alert routes can be fixed and the deploy re-run.
for dest, subscriber_id in dests:
    try:
        route(dest, subscriber_id)
    except Exception as e:
        print(f"WARNING intelligence alert route {dest}: {e}")
if not dests:
    print("intelligence alert routes: no destination (OpenMRS id or address unknown, Spice not configured)")
PY
  fi
fi
