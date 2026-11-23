#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-status.sh <envcode> — read-only check of the Beckn add-on, and the ids to give the
# other participants. Run through run.sh (config + Infisical):
#
#   sudo bash one-click-installer/lib/beckn/run.sh --config one-click-installer/config/<env>.env beckn-status.sh
#
# Per hosted component: pods, the version of the CCE profile its Sygnal adapter holds (OpenMRS's referral pair: the schemas
# it loaded), its subscriber in the network registry (live? same address — https://<host>/sygnal/receiver — and signing
# key as configured here? a member of the network?), and the public
# Sygnal address (an empty, unsigned request must be refused by the ADAPTER — 400 or 401 — which proves DNS, TLS, the
# ingress and the adapter in one call). OpenMRS: the same for its Beckn referral pair (onix-bap / onix-bpp, /bap/receiver,
# /bpp/receiver). Then the ids and addresses to give the other participants, and the referral contract ids.
set -uo pipefail
ENVCODE="${1:?usage: beckn-status.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/beckn-lib.sh"
export ENVCODE
beckn_defaults
beckn_kubectl || exit 1
pick() { local v; for v in "$@"; do if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return 0; fi; done; return 0; }
BAD=0
# registry_check <subscriber id> <key id> <address(es) used here, space-separated> <signing public key> <network id>
# subscribers.beckn.one: the "any registry" name the adapters themselves use for this lookup (onix 1.9.4 dediregistry).
# The record's url is only shown: delivery never uses it (senders put the address in the message: receiverUri for
# Sygnal, bapUri / bppUri for Beckn).
registry_check() {
  curl -s -m 20 "${BECKN_REGISTRY_URL%/}/lookup/$1/subscribers.beckn.one/$2" | ID="$1" URI="$3" PUB="$4" NET="$5" python3 -c '
import json, os, sys
E = os.environ
try: d = json.load(sys.stdin).get("data") or {}
except Exception: d = {}
det = d.get("details") or {}
if not det: print("   registry %-40s NOT FOUND (subscriber id / key id)" % E["ID"]); sys.exit(1)
problems = [n for n, ok in (("state " + str(d.get("state")), d.get("state") == "live"),
                            ("signing key differs", det.get("signing_public_key") == E["PUB"]),
                            ("not a member of " + E["NET"], not E["NET"] or E["NET"] in (d.get("network_memberships") or []))) if not ok]
url = str(det.get("url"))
note = "" if url in E["URI"].split() else "  (record url %s; not used for delivery)" % url
print("   registry %-40s %s%s" % (E["ID"], ("live, signing key matches" + (", member of " + E["NET"] if E["NET"] else "")) if not problems else "MISMATCH: " + "; ".join(problems), note))
sys.exit(1 if problems else 0)'
}
probe() {   # <url>: an empty, unsigned request must be refused by the adapter
  local code note
  code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$1")"
  case "$code" in 400|401) note="the adapter refused the empty, unsigned request (as it must)";; 000) note="NOT REACHABLE (DNS, firewall or certificate)"; BAD=1;;
                  404) note="NOT ROUTED to the adapter (ingress)"; BAD=1;; 5*) note="adapter or ingress error"; BAD=1;; *) note="answered";; esac
  echo "   $1 -> HTTP $code  $note"
}

for c in $BECKN_COMPONENTS; do
  NS="$(beckn_component_ns "$c")"; P="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"; hv="BECKN_${P}_HOST"; HOST="${!hv}"; ROLE="$(beckn_role "$P")"
  echo "== $c   namespace $NS   https://$HOST"
  $KUBECTL -n "$NS" get pods -l "app.kubernetes.io/part-of=${c}-beckn" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); t++; if ($3=="Running" && a[1]==a[2]) r++; else bad=bad"\n     not ready: "$1" "$2" "$3" restarts="$4} END{printf "   pods ready: %d/%d%s\n", r, t, bad; exit (r==t && t>0) ? 0 : 1}' || BAD=1
  # The Sygnal adapter holds the CCE profile and no payload schemas: show the version of the profile it was given.
  # OpenMRS's referral pair loads its schema folders at start: show what it logged.
  pv="$($KUBECTL -n "$NS" get configmap onix-sygnal-profile -o 'jsonpath={.data.cce-sygnal-apis\.yaml}' 2>/dev/null | sed -n 's/^  version: *//p' | head -1)"
  if [ -n "$pv" ]; then echo "   onix-sygnal profile: CCE profile of Sygnal, version $pv (this add-on deploys $BECKN_SYGNAL_PROFILE_REL)"
  else echo "   onix-sygnal profile: NOT FOUND (ConfigMap onix-sygnal-profile) — the adapter cannot start without it"; BAD=1; fi
  if [ -n "$pv" ] && [ -z "$($KUBECTL -n "$NS" get configmap onix-sygnal-profile -o "jsonpath={.data.${BECKN_SYGNAL_EXTENSION_FILE//./\\.}}" 2>/dev/null | head -c 1)" ]; then
    echo "   onix-sygnal profile: $BECKN_SYGNAL_EXTENSION_FILE MISSING from ConfigMap onix-sygnal-profile — the profile refers to it; re-run install-beckn.sh"; BAD=1
  fi
  ADAPTERS=""; [ "$c" = openmrs ] && ADAPTERS="onix-bap onix-bpp"
  for d in $ADAPTERS; do
    line="$($KUBECTL -n "$NS" logs "deploy/$d" --tail=400 2>/dev/null | grep -i -E 'preloaded|no schemas loaded' | tail -1 | sed -E 's/.*"(message|msg)":"([^"]*)".*/\2/' | cut -c1-110)"
    echo "   $d schemas: ${line:-(no schema line in the last 400 log lines)}"
  done
  idv="BECKN_${P}_ID"; kv="BECKN_${P}_KEY_ID"; uv="BECKN_${P}_URI"; urls="${!uv}"
  # OpenMRS's Sygnal id is normally its BAP id: ONE registry record for both adapters (its url stays /bap/receiver).
  SHARED=""; if [ "$c" = openmrs ] && [ "${!idv}" = "${BECKN_OPENMRS_BAP_ID:-}" ]; then SHARED=1; urls="$urls ${BECKN_OPENMRS_BAP_URI:-}"; fi
  registry_check "${!idv}" "${!kv}" "$urls" "$(pick "BECKN_${P}_${ROLE}_SIGNING_PUBLIC_KEY" "BECKN_${P}_SIGNING_PUBLIC_KEY" "BECKN_SIGNING_PUBLIC_KEY")" "$BECKN_SYGNAL_NETWORK_ID" || BAD=1
  case "$c" in openmrs) action=sygnal/signal/emit;; *) action=sygnal/event/report;; esac
  probe "https://$HOST/sygnal/receiver/$action"
  # OpenMRS's Beckn referral pair (Spice referrals, standard Beckn)
  if [ "$c" = openmrs ]; then
    for role in BAP BPP; do
      [ "$role" = BAP ] && [ -n "$SHARED" ] && { echo "   registry ${BECKN_OPENMRS_BAP_ID} (BAP): the record above"; continue; }
      idv="BECKN_OPENMRS_${role}_ID"; kv="BECKN_OPENMRS_${role}_KEY_ID"; uv="BECKN_OPENMRS_${role}_URI"
      registry_check "${!idv}" "${!kv}" "${!uv}" "$(pick "BECKN_OPENMRS_${role}_SIGNING_PUBLIC_KEY" "BECKN_OPENMRS_SIGNING_PUBLIC_KEY" "BECKN_SIGNING_PUBLIC_KEY")" "${BECKN_NETWORK_ID:-}" || BAD=1
    done
    probe "https://$HOST/bap/receiver/on_update"; probe "https://$HOST/bpp/receiver/update"
  fi
done

cat <<IDS

== Sygnal ids and addresses (what the other participants put in context.receiverId / context.receiverUri; every id must
   be a member of the Sygnal network below):
   CCE        ${BECKN_CCE_ID:-(not set)}   ${BECKN_CCE_URI:-(no address)}
   HIE        ${BECKN_OPENHIM_ID:-(not set)}   ${BECKN_OPENHIM_URI:-(no address)}
   OpenMRS    ${BECKN_OPENMRS_ID:-(not set)}   ${BECKN_OPENMRS_URI:-(no address)}
   Spice      $( [ "$BECKN_SPICE_CONFIGURED" = true ] && echo "$BECKN_SPICE_ID   ${BECKN_SPICE_URI:-(no address: no alerts)}" || echo "not configured" )
$(beckn_hosted openmrs && cat <<REF

== Spice <-> OpenMRS referrals (standard Beckn, OpenMRS's onix-bap / onix-bpp; network ${BECKN_NETWORK_ID:-not checked})
   OpenMRS    BAP ${BECKN_OPENMRS_BAP_ID:-?} ${BECKN_OPENMRS_BAP_URI:-}   BPP ${BECKN_OPENMRS_BPP_ID:-?} ${BECKN_OPENMRS_BPP_URI:-}
   Spice      $( [ "$BECKN_SPICE_REFERRALS_CONFIGURED" = true ] && echo "BAP $BECKN_SPICE_BAP_ID   BPP ${BECKN_SPICE_BPP_ID:-?}" || echo "not configured — placeholder ids" ); referral legs $BECKN_REFERRALS_ENABLED
   Referrals in    (OpenMRS emitter, on_status to Spice; agree with Spice)   contract ${BECKN_REFERRALS_IN_CONTRACT_ID:-(not set)}  transaction ${BECKN_REFERRALS_IN_TRANSACTION_ID:-(not set)}
   Referrals out   (OpenMRS emitter, update to Spice; Spice supplies them)    contract ${BECKN_REFERRALS_OUT_CONTRACT_ID:-(not set)}  transaction ${BECKN_REFERRALS_OUT_TRANSACTION_ID:-(not set)}
REF
)
   Sygnal network (context.networkId; the Sygnal adapters accept its members only): $BECKN_SYGNAL_NETWORK_ID
   Schema base URL (the same for every participant): $BECKN_SCHEMA_BASE_URL
   HIE redaction (BECKN_OPENHIM_REDACTION_ENABLED): $( [ "${BECKN_OPENHIM_REDACTION_ENABLED:-false}" = false ] && echo "OFF — full clinical payloads go to CCE" || echo "on")
IDS
[ "$BAD" = 0 ] && echo && echo "OK" || { echo; echo "Problems above."; exit 1; }
