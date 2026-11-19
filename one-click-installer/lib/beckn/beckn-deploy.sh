#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-deploy.sh <envcode> <component> — render and apply ONE Beckn component (cce | openhim | openmrs).
# Run under infisical-run.sh, with the installer config loaded (install-beckn.sh does both). Safe to re-run.
#
# What it does, in the component's namespace:
#   1. Secret onix-config     the adapter's two configs + four routing files, rendered from k8s/beckn/onix/config/ with this
#                             participant's ids, keys, timeouts and webhook addresses
#   2. ConfigMap onix-schema  the extra schema folders, one key per file, "/" written "__": the CCE schemas (BECKN_SCHEMA_DIR)
#                             and the Health* referral pack in k8s/beckn/onix/health-schema (schema.beckn.io no longer serves it)
#   3. kubectl apply          k8s/beckn/<component> rendered with kustomize, ${VARS} filled with envsubst
#   4. host aliases           on the two onix pods: the public Beckn hosts that live on THIS machine -> Traefik's ClusterIP
#                             (a pod cannot reach the machine's own public address)
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
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
say() { echo "  [$COMPONENT] $*"; }

# ── this participant's adapter settings ──────────────────────────────────────────────────────────────────────────────────
# Keys: the most specific one that is set wins — per role, per participant, then the pair shared by every participant here.
pick() { local v; for v in "$@"; do if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return 0; fi; done; return 0; }
for role in BAP BPP; do
  export "ONIX_${role}_SUBSCRIBER_ID=$(pick "BECKN_${P}_${role}_ID")" "ONIX_${role}_KEY_ID=$(pick "BECKN_${P}_${role}_KEY_ID")"
  for k in SIGNING_PRIVATE_KEY SIGNING_PUBLIC_KEY ENCR_PRIVATE_KEY ENCR_PUBLIC_KEY; do
    export "ONIX_${role}_${k}=$(pick "BECKN_${P}_${role}_${k}" "BECKN_${P}_${k}" "BECKN_${k}")"
  done
done
export ONIX_LOG_LEVEL="$BECKN_ONIX_LOG_LEVEL"
# Every answer on the event route comes back in the same HTTP call, so each hop must wait longer than the hop behind it:
#   CCE: beckn-service waits 15 s for the collector -> CCE's onix-bpp 18 s -> HIE's onix-bap 20 s -> HIE adaptor 25 s ->
#   OpenHIM channel 30 s -> adaptor's Beckn endpoint 35 s -> HIE's onix-bpp 40 s -> OpenMRS's onix-bap 45 s -> emitter 50 s.
# Callbacks (on_update, on_status) are logged on arrival and answered at once: 5 s into the local service.
export ONIX_BAP_RECEIVER_TIMEOUT=5s ONIX_BPP_CALLER_TIMEOUT=10s ONIX_HTTP_TIMEOUT=60
case "$COMPONENT" in
  cce)     # cce-beckn-service gives its own callbacks 7 s (CCE_BECKN_ONIX_READ_TIMEOUT_MS): the adapter must give up first
           export ONIX_BPP_RECEIVER_TIMEOUT=18s ONIX_BAP_CALLER_TIMEOUT=10s ONIX_BPP_CALLER_TIMEOUT=6s
           export ONIX_BPP_RECEIVER_TARGET="http://cce-beckn-service:8075/api/bpp-webhook" ONIX_BAP_RECEIVER_TARGET="http://cce-beckn-service:8075/api/bap-webhook";;
  openhim) export ONIX_BPP_RECEIVER_TIMEOUT=40s ONIX_BAP_CALLER_TIMEOUT=20s
           export ONIX_BPP_RECEIVER_TARGET="http://openhim-cce-emitter-adaptor:8082/beckn/bpp-webhook" ONIX_BAP_RECEIVER_TARGET="http://openhim-cce-emitter-adaptor:8082/beckn/bap-webhook";;
  openmrs) # a referral from Spice makes several OpenMRS calls (30 s each at most) before the receiver answers
           export ONIX_BPP_RECEIVER_TIMEOUT=45s ONIX_BAP_CALLER_TIMEOUT=45s
           export ONIX_BPP_RECEIVER_TARGET="http://openmrs-cce-receiver-adaptor:8080/beckn/bpp-webhook" ONIX_BAP_RECEIVER_TARGET="http://openmrs-cce-receiver-adaptor:8080/beckn/bap-webhook";;
esac
HOSTVAR="BECKN_${P}_HOST"; export BECKN_HOST="${!HOSTVAR:?$HOSTVAR not set}"

# The HIE's subscriber list (beckn.subscribers of the adaptor): every HMIS that may send it events. OpenMRS always; Spice once
# its real id is configured. No contract ids: the adaptor accepts any non-blank contract id from a listed subscriber and
# echoes it in its on_update (openhim-cce-emitter-adaptor PR 43).
if [ "$COMPONENT" = openhim ]; then
  OPENHIM_ADAPTOR_SPRING_JSON="$(python3 - <<'PY'
import json, os
E = os.environ.get
subs = [{"subscriber-id": E("BECKN_OPENMRS_BAP_ID"), "subscriber-uri": E("BECKN_OPENMRS_BAP_URI"), "source-system": "openmrs"}]
if E("BECKN_SPICE_CONFIGURED") == "true":
    subs.append({"subscriber-id": E("BECKN_SPICE_BAP_ID"), "subscriber-uri": E("BECKN_SPICE_BAP_URI"), "source-system": "spice"})
print(json.dumps({"beckn": {"subscribers": subs}}, separators=(",", ":")))
PY
)"; export OPENHIM_ADAPTOR_SPRING_JSON
fi
# CCE's alert recipients (hmis.yml of cce-beckn-service): the HIE, OpenMRS when its id is known, Spice once configured. An
# alert goes to an HMIS as on_status, a transaction of its own; contract-id is optional (the HIE keeps its own).
if [ "$COMPONENT" = cce ]; then
  CCE_BECKN_HMIS_ENTRIES="$(python3 - <<'PY'
import os
E = lambda k: (os.environ.get(k) or "").strip()
entries = [(E("BECKN_OPENHIM_BAP_ID"), E("BECKN_OPENHIM_BAP_URI"), E("BECKN_HIE_CCE_CONTRACT_ID"))]
if E("BECKN_OPENMRS_BAP_ID") and E("BECKN_OPENMRS_BAP_URI"):
    entries.append((E("BECKN_OPENMRS_BAP_ID"), E("BECKN_OPENMRS_BAP_URI"), ""))
if E("BECKN_SPICE_CONFIGURED") == "true":
    entries.append((E("BECKN_SPICE_BAP_ID"), E("BECKN_SPICE_BAP_URI"), ""))
pad = " " * 10
lines = []
for sid, uri, contract in entries:
    if not sid:
        continue
    lines.append(f"{pad}- subscriber-id: {sid}")
    lines.append(f"{pad}  subscriber-uri: {uri}")
    if contract:
        lines.append(f"{pad}  contract-id: {contract}")
print("\n".join(lines))
PY
)"; export CCE_BECKN_HMIS_ENTRIES
fi
export BECKN_REFERRALS_OUT_CONTRACT_ID="${BECKN_REFERRALS_OUT_CONTRACT_ID:-}" BECKN_REFERRALS_OUT_TRANSACTION_ID="${BECKN_REFERRALS_OUT_TRANSACTION_ID:-}"

# Every ${VAR} a file references must have a value, or it would render as "" and fail later, far from the cause. The
# few that may be empty are listed.
OPTIONAL=" BECKN_NETWORK_ID BECKN_ALLOWED_NETWORK_IDS BECKN_OPENHIM_FACILITY_FILTER_IDS BECKN_SPICE_BPP_ID BECKN_SPICE_BPP_URI BECKN_SPICE_FACILITY_CODES BECKN_REFERRALS_OUT_CONTRACT_ID BECKN_REFERRALS_OUT_TRANSACTION_ID BECKN_HEALTH_ID_TYPES BECKN_CONFIG_HASH ONIX_CONFIG_HASH "
check_vars() {   # <file...> -> prints the envsubst variable list; exits if a non-optional one is empty
  local v missing=() list=""
  for v in $(grep -ho '\${[A-Z_0-9]*}' "$@" | tr -d '${}' | sort -u); do
    list="$list \${$v}"
    if [ -z "${!v:-}" ]; then case "$OPTIONAL" in *" $v "*) export "$v=${!v:-}";; *) missing+=("$v");; esac; fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR [$COMPONENT]: no value for: ${missing[*]}" >&2
    echo "       BECKN_* identity keys come from the installer config, keys/passwords/contract ids from Infisical /beckn (beckn-seed.sh)." >&2
    exit 1
  fi
  printf '%s' "$list"
}

# ── 1. adapter config -> Secret onix-config ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/onix"
VARS="$(check_vars "$REPO"/k8s/beckn/onix/config/*.yaml)"
for f in "$REPO"/k8s/beckn/onix/config/*.yaml; do envsubst "$VARS" < "$f" > "$TMP/onix/$(basename "$f")"; done
# No network id configured: no membership check — leave the setting out rather than give the adapter an empty list.
[ -n "${BECKN_ALLOWED_NETWORK_IDS:-}" ] || sed -i '/^ *allowedNetworkIDs:/d' "$TMP"/onix/onix-*.yaml
export ONIX_CONFIG_HASH; ONIX_CONFIG_HASH="$(cat "$TMP"/onix/*.yaml | sha256sum | cut -c1-16)"

# ── 2. schema folders -> ConfigMap onix-schema ───────────────────────────────────────────────────────────────────────────
# The adapters load these at start (extendedSchema_localSchemaPath) and look a schema up as <Schema>/attributes.yaml, so a
# folder name must appear once across both sources.
HEALTH_SCHEMA_DIR="$REPO/k8s/beckn/onix/health-schema"
SCHEMA_ARGS=(); n=0; SCHEMA_FILES=()
for dir in "$BECKN_SCHEMA_DIR" "$HEALTH_SCHEMA_DIR"; do
  while IFS= read -r f; do
    rel="${f#"$dir"/}"; SCHEMA_ARGS+=("--from-file=${rel//\//__}=$f"); SCHEMA_FILES+=("$f"); n=$((n + 1))
  done < <(find "$dir" -mindepth 3 -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.jsonld' -o -name '*.json' \) | sort)
done
[ "$n" -gt 0 ] || { echo "ERROR: no schema files under $BECKN_SCHEMA_DIR (expected <Schema>/<version>/attributes.yaml and context.jsonld)"; exit 1; }
DUP="$(printf '%s\n' "${SCHEMA_ARGS[@]}" | sed 's/^--from-file=//; s/=.*//' | sort | uniq -d | head -1)"
[ -z "$DUP" ] || { echo "ERROR: schema file $DUP is in both $BECKN_SCHEMA_DIR and $HEALTH_SCHEMA_DIR"; exit 1; }
SCHEMA_HASH="$(cat "${SCHEMA_FILES[@]}" | sha256sum | cut -c1-8)"
ONIX_CONFIG_HASH="${ONIX_CONFIG_HASH}-${SCHEMA_HASH}"

# ── 3. the component's manifests ─────────────────────────────────────────────────────────────────────────────────────────
# envsubst BEFORE kustomize, in a throwaway copy (as lib/native/05-k8s-deploy.sh does): kustomize re-writes YAML and drops
# quotes it finds unnecessary, so a value substituted afterwards could change type ("false" -> false, a JSON string -> a map).
# Substituting first keeps every value exactly as the manifest quotes it.
cp -r "$REPO/k8s/beckn" "$TMP/beckn"
mapfile -t MANIFESTS < <(cd "$REPO/k8s/beckn" && find "$COMPONENT" onix netpol -maxdepth 1 -name '*.yaml' | sort)
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
  say "DRY_RUN — namespace $NS, $(grep -c '^kind:' "$TMP/render.yaml") resources, adapter config $ONIX_CONFIG_HASH, $n schema files; nothing applied"
  grep -E '^kind:|^  name:' "$TMP/render.yaml" | paste - - | sed 's/kind: //; s/ *name: / /' | sort | sed 's/^/      /'
  exit 0
fi

if [ "$COMPONENT" = cce ]; then
  $KUBECTL get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: namespace $NS does not exist — run install.sh for '$ENVCODE' first"; exit 1; }
else
  $KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
fi
$KUBECTL -n "$NS" create secret generic onix-config --from-file="$TMP/onix" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
$KUBECTL -n "$NS" create configmap onix-schema "${SCHEMA_ARGS[@]}" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
say "namespace $NS: adapter config ($ONIX_BAP_SUBSCRIBER_ID, $ONIX_BPP_SUBSCRIBER_ID; network ${BECKN_ALLOWED_NETWORK_IDS:-not checked}) + $n schema files"
$KUBECTL -n "$NS" apply -f "$TMP/render.yaml" | sed "s/^/      /"

# ── 4. host aliases + roll the adapter when its config changed ───────────────────────────────────────────────────────────
# The adapter sends to the other participants' PUBLIC addresses (context.bppUri / bapUri). Those that live on this machine
# resolve to its own public IP, which a pod cannot reach — so they are pointed at Traefik's ClusterIP instead. The
# certificate still matches: Traefik serves each host's own certificate.
TIP="$($KUBECTL get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')"
ALIASES=""
for c in $BECKN_COMPONENTS; do
  hv="BECKN_$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')_HOST"; [ -n "${!hv:-}" ] && ALIASES="$ALIASES\"${!hv}\","
done
for d in onix-bap onix-bpp; do
  $KUBECTL -n "$NS" patch deploy "$d" --type=strategic -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"cce.openphc.org/onix-config-hash\":\"${ONIX_CONFIG_HASH}\"}},\"spec\":{\"hostAliases\":[{\"ip\":\"${TIP}\",\"hostnames\":[${ALIASES%,}]}]}}}}" >/dev/null
done
say "onix-bap / onix-bpp: local Beckn hosts -> Traefik $TIP"

# ── 5. CCE: where the intelligence service sends alerts ─────────────────────────────────────────────────────────────────
# One receiver-adaptor record and one destination mapping per alert destination: OPENMRS when OpenMRS's id is known, SPICE
# once Spice is configured. Each points at cce-beckn-service's POST /v1/alerts, signed with the shared webhook secret, with
# the destination's BAP id in X-CCE-Beckn-Subscriber-Id: cce-beckn-service sends the alert to that HMIS as on_status.
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
if E("BECKN_OPENMRS_BAP_ID"):
    dests.append(("OPENMRS", E("BECKN_OPENMRS_BAP_ID")))
if E("BECKN_SPICE_CONFIGURED") == "true" and E("BECKN_SPICE_BAP_ID"):
    dests.append(("SPICE", E("BECKN_SPICE_BAP_ID")))

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

def route(dest, bap_id):
    name = "beckn-alerts-" + dest.lower()
    record = {
        "name": name,
        "definition": {
            "resourceType": "Endpoint", "id": name, "status": "active", "name": "CCE alerts to " + bap_id + " over Beckn",
            "connectionType": {"system": "http://terminology.hl7.org/CodeSystem/endpoint-connection-type", "code": "hl7-fhir-rest"},
            "payloadType": [{"coding": [{"system": "http://hl7.org/fhir/resource-types", "code": "CommunicationRequest"}]}],
            "payloadMimeType": ["application/fhir+json"],
            "address": "http://cce-beckn-service:8075/v1/alerts"},
        "config": {"webhookSecret": secret, "customHeaders": {"X-CCE-Beckn-Subscriber-Id": bap_id}},
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
    print(f"intelligence alert route: {dest} -> cce-beckn-service /v1/alerts -> {bap_id}")

# A failure here is reported, never fatal: the alert routes can be fixed and the deploy re-run.
for dest, bap_id in dests:
    try:
        route(dest, bap_id)
    except Exception as e:
        print(f"WARNING intelligence alert route {dest}: {e}")
if not dests:
    print("intelligence alert routes: no destination (OpenMRS id unknown, Spice not configured)")
PY
  fi
fi
