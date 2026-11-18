#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-status.sh <envcode> — read-only check of the Beckn add-on, and the ids to give the
# other participants. Run through run.sh (config + Infisical):
#
#   sudo bash one-click-installer/lib/beckn/run.sh --config one-click-installer/config/<env>.env beckn-status.sh
#
# Per hosted component: pods, the adapter's loaded schemas, its two subscribers in the network registry (live? same address and
# signing key as configured here? a member of the network?), and the public Beckn address (an empty, unsigned request must be
# refused by the ADAPTER — 400 or 401 — which proves DNS, TLS, the ingress and the adapter in one call). Then the contract ids
# the senders here put in their messages.
set -uo pipefail
ENVCODE="${1:?usage: beckn-status.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/beckn-lib.sh"
export ENVCODE
beckn_defaults
beckn_kubectl || exit 1
pick() { local v; for v in "$@"; do if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return 0; fi; done; return 0; }
BAD=0

for c in $BECKN_COMPONENTS; do
  NS="$(beckn_component_ns "$c")"; P="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"; hv="BECKN_${P}_HOST"; HOST="${!hv}"
  echo "== $c   namespace $NS   https://$HOST"
  $KUBECTL -n "$NS" get pods -l "app.kubernetes.io/part-of=${c}-beckn" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); t++; if ($3=="Running" && a[1]==a[2]) r++; else bad=bad"\n     not ready: "$1" "$2" "$3" restarts="$4} END{printf "   pods ready: %d/%d%s\n", r, t, bad; exit (r==t && t>0) ? 0 : 1}' || BAD=1
  for d in onix-bap onix-bpp; do
    line="$($KUBECTL -n "$NS" logs "deploy/$d" --tail=400 2>/dev/null | grep -i -E 'preloaded|no schemas loaded' | tail -1 | sed -E 's/.*"(message|msg)":"([^"]*)".*/\2/' | cut -c1-110)"
    echo "   $d schemas: ${line:-(no schema line in the last 400 log lines)}"
  done
  for role in BAP BPP; do
    idv="BECKN_${P}_${role}_ID"; kv="BECKN_${P}_${role}_KEY_ID"; uv="BECKN_${P}_${role}_URI"
    pub="$(pick "BECKN_${P}_${role}_SIGNING_PUBLIC_KEY" "BECKN_${P}_SIGNING_PUBLIC_KEY" "BECKN_SIGNING_PUBLIC_KEY")"
    curl -s -m 20 "${BECKN_REGISTRY_URL%/}/lookup/${!idv}/${BECKN_REGISTRY_NAME}/${!kv}" | ID="${!idv}" URI="${!uv}" PUB="$pub" NET="$BECKN_NETWORK_ID" python3 -c '
import json, os, sys
E = os.environ
try: d = json.load(sys.stdin).get("data") or {}
except Exception: d = {}
det = d.get("details") or {}
if not det: print("   registry %-40s NOT FOUND (subscriber id / key id / registry name)" % E["ID"]); sys.exit(1)
problems = [n for n, ok in (("state " + str(d.get("state")), d.get("state") == "live"), ("url " + str(det.get("url")), det.get("url") == E["URI"]),
                            ("signing key differs", det.get("signing_public_key") == E["PUB"]),
                            ("not a member of " + E["NET"], not E["NET"] or E["NET"] in (d.get("network_memberships") or []))) if not ok]
print("   registry %-40s %s" % (E["ID"], ("live, address and signing key match" + (", network member" if E["NET"] else "")) if not problems else "MISMATCH: " + "; ".join(problems)))
sys.exit(1 if problems else 0)' || BAD=1
  done
  for path in bap/receiver/on_update bpp/receiver/update; do
    code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "https://$HOST/$path")"
    case "$code" in 400|401) note="the adapter refused the empty, unsigned request (as it must)";; 000) note="NOT REACHABLE (DNS, firewall or certificate)"; BAD=1;;
                    404) note="NOT ROUTED to the adapter (ingress)"; BAD=1;; 5*) note="adapter or ingress error"; BAD=1;; *) note="answered";; esac
    echo "   https://$HOST/$path -> HTTP $code  $note"
  done
done

cat <<IDS

== Contract ids (Infisical /beckn): what each SENDER here puts in its messages. Nothing issues them; a receiver accepts any
   non-blank contract id from a sender it knows and echoes it.
   HIE -> CCE            sent by the HIE adaptor (and in CCE's hmis.yml)   contract ${BECKN_HIE_CCE_CONTRACT_ID:-(not set)}
                                                                           transaction ${BECKN_HIE_CCE_TRANSACTION_ID:-(not set)}
   OpenMRS -> HIE feed   sent by the OpenMRS emitter                       contract ${BECKN_HIE_FEED_OPENMRS_CONTRACT_ID:-(not set)}
                                                                           transaction ${BECKN_HIE_FEED_OPENMRS_TRANSACTION_ID:-(not set)}
   Spice -> HIE feed     Spice chooses its own                             —
   Referrals in          sent by the OpenMRS emitter in on_status to       contract ${BECKN_REFERRALS_IN_CONTRACT_ID:-(not set)}
                         Spice (agree with Spice)                          transaction ${BECKN_REFERRALS_IN_TRANSACTION_ID:-(not set)}
   Referrals out         sent by the OpenMRS emitter in update to Spice    contract ${BECKN_REFERRALS_OUT_CONTRACT_ID:-(not set — Spice supplies it)}
                         (Spice supplies them)                             transaction ${BECKN_REFERRALS_OUT_TRANSACTION_ID:-(not set — Spice supplies it)}
   Spice: $( [ "$BECKN_SPICE_CONFIGURED" = true ] && echo "$BECKN_SPICE_BAP_ID / ${BECKN_SPICE_BPP_ID:-?}" || echo "not configured — placeholder ids; referral legs $BECKN_REFERRALS_ENABLED" )
   Network id (context.networkId; the adapters accept its members only): ${BECKN_NETWORK_ID:-(not set)}
   Schema base URL (the same for every participant): $BECKN_SCHEMA_BASE_URL
IDS
[ "$BAD" = 0 ] && echo && echo "OK" || { echo; echo "Problems above."; exit 1; }
