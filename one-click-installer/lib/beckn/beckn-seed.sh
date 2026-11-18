#!/usr/bin/env bash
# one-click-installer/lib/beckn/beckn-seed.sh <envcode> [seed-file] — put the Beckn add-on's secrets into Infisical, folder /beckn
# of the environment's project. Run under infisical-run.sh (install-beckn.sh does). Safe to re-run: a value that exists is kept.
#
# Like lib/infisical-seed.sh: a value in the seed file is stored as given; a missing one is generated, defaulted, or left
# blank, by kind. Kinds here:
#   secret    random 32 characters
#   uuid      a random UUID — the contract id and transactionId a sender puts in its messages. Nothing issues them (there is
#             no confirm) and they are not secret, but each must be generated ONCE and then stay the same.
#   default   a fixed value
#   blank     nothing stored until the operator supplies it
#   required  must be in the seed file (or already in Infisical): the adapters' private keys, issued with the registry records
#
#   Contract                 consumer -> provider      keys                       who reads them
#   HIE to CCE               HIE -> CCE                BECKN_HIE_CCE_*            HIE adaptor (sends them); CCE's hmis.yml (alerts)
#   HIE feed, OpenMRS        OpenMRS -> HIE            BECKN_HIE_FEED_OPENMRS_*   OpenMRS emitter (sends them)
#   HIE feed, Spice          Spice -> HIE              —                          nobody here: Spice chooses its own
#   Referrals in             Spice -> OpenMRS          BECKN_REFERRALS_IN_*       OpenMRS emitter, in on_status to Spice (agree with Spice)
#   Referrals out            OpenMRS -> Spice          BECKN_REFERRALS_OUT_*      OpenMRS emitter, in update to Spice (blank until Spice
#                                                                                 supplies them)
# A receiver (CCE, the HIE adaptor, the OpenMRS receiver) accepts any non-blank contract id and echoes it in its on_update;
# what it checks is who sent the message.
set -euo pipefail
ENVCODE="${1:?usage: beckn-seed.sh <envcode> [seed-file]}"
SEED_FILE="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$(cd "$HERE/.." && pwd)"; REPO="$(cd "$LIB/../.." && pwd)"
. "$LIB/infisical-secret-helpers.sh"
. "$HERE/beckn-lib.sh"
beckn_defaults
infisical_resolve_project "$ENVCODE"
infisical_login

declare -A SEED=()
if [ -n "$SEED_FILE" ]; then
  [ -r "$SEED_FILE" ] || { echo "ERROR: cannot read seed file: $SEED_FILE"; exit 1; }
  # Split at the FIRST "=" by hand: `IFS='=' read -r key val` also drops a trailing "=" from the value, which silently
  # corrupts a base64 value (every Ed25519 key ends in one).
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//')"
    case "$val" in
      \"*) val="${val#\"}"; val="${val%%\"*}" ;;
      \'*) val="${val#\'}"; val="${val%%\'*}" ;;
      *)   val="$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//')" ;;
    esac
    SEED["$key"]="$val"
  done < "$SEED_FILE"
fi

F=/beckn
SPEC=(
  # every id a sender here uses, whatever is hosted here (the HIE adaptor and CCE's hmis.yml read the same HIE_CCE pair)
  "BECKN_HIE_CCE_CONTRACT_ID:uuid" "BECKN_HIE_CCE_TRANSACTION_ID:uuid"
  "BECKN_HIE_FEED_OPENMRS_CONTRACT_ID:uuid" "BECKN_HIE_FEED_OPENMRS_TRANSACTION_ID:uuid"
  "BECKN_REFERRALS_IN_CONTRACT_ID:uuid" "BECKN_REFERRALS_IN_TRANSACTION_ID:uuid"
  "BECKN_REFERRALS_OUT_CONTRACT_ID:blank" "BECKN_REFERRALS_OUT_TRANSACTION_ID:blank"
)
# Private keys: one pair per participant (BECKN_<P>_SIGNING_PRIVATE_KEY / BECKN_<P>_ENCR_PRIVATE_KEY), or — when every
# participant on this machine was registered with the same key pair — one shared pair (BECKN_SIGNING_PRIVATE_KEY /
# BECKN_ENCR_PRIVATE_KEY). A role-specific key (BECKN_<P>_BAP_… / BECKN_<P>_BPP_…) wins over both. beckn-deploy.sh resolves them.
KEYS_OK=1
for c in $BECKN_COMPONENTS; do
  p="$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')"
  for kind in SIGNING ENCR; do
    found=""
    for k in "BECKN_${p}_BAP_${kind}_PRIVATE_KEY" "BECKN_${p}_${kind}_PRIVATE_KEY" "BECKN_${kind}_PRIVATE_KEY"; do
      if [ -n "${SEED[$k]:-}" ] || [ -n "$(infisical_get "$F" "$k" "$PROJECT_ID" "$INFISICAL_ENV_SLUG")" ]; then found="$k"; break; fi
    done
    [ -n "$found" ] || { echo "  ✗ no ${kind,,} private key for $c: put BECKN_${p}_${kind}_PRIVATE_KEY (or the shared BECKN_${kind}_PRIVATE_KEY) in the seed file"; KEYS_OK=0; }
  done
done
if beckn_hosted cce; then SPEC+=("CCE_BECKN_ALERTS_WEBHOOK_SECRET:secret"); fi
if beckn_hosted openhim; then
  SPEC+=("OPENHIM_ROOT_USER:default:root@openhim.org" "OPENHIM_ROOT_PASSWORD:secret")
  # one password per OpenHIM client in the metadata file: OPENHIM_CLIENT_PASSWORD_<CLIENTID>
  while read -r cid; do [ -n "$cid" ] && SPEC+=("OPENHIM_CLIENT_PASSWORD_${cid}:secret"); done < <(
    python3 -c 'import json,re,sys
for c in json.load(open(sys.argv[1]))["clients"]: print(re.sub(r"[^A-Z0-9]", "_", c["clientID"].upper()))' "$REPO/k8s/beckn/openhim/openhim-metadata.json")
fi
if beckn_hosted openmrs; then
  # OPENMRS_ADMIN_*: the OpenMRS account the adaptors sign in with. Not created here — it must MATCH the account in the
  # OpenMRS database. "admin" / "Admin123" is what the O3 reference application installs; change the password in OpenMRS,
  # then here, then re-run install-beckn.sh.
  SPEC+=("OPENMRS_DB_PASSWORD:secret" "OPENMRS_DB_ROOT_PASSWORD:secret" "OPENMRS_ADMIN_USER:default:admin" "OPENMRS_ADMIN_PASSWORD:default:Admin123")
fi

FROM_FILE=() GENERATED=() DEFAULTED=() KEPT=() BLANK=()
for entry in "${SPEC[@]}"; do
  IFS=':' read -r key kind extra <<< "$entry"
  if [ -n "${SEED[$key]:-}" ]; then
    infisical_set "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "${SEED[$key]}"; FROM_FILE+=("$key"); continue
  fi
  if [ -n "$(infisical_get "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG")" ]; then KEPT+=("$key"); continue; fi
  case "$kind" in
    secret)  infisical_get_or_generate "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" >/dev/null; GENERATED+=("$key") ;;
    uuid)    infisical_set "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$(cat /proc/sys/kernel/random/uuid)"; GENERATED+=("$key") ;;
    default) infisical_set "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$extra"; DEFAULTED+=("$key") ;;
    blank)   BLANK+=("$key") ;;
  esac
done
# Where the two UIs are, for tools that run without the config file (tools/show-credentials.sh). Not the config key's own name:
# a value stored under that name would be injected over the config on the next run and hide a changed host.
if beckn_hosted openhim; then infisical_set "$F" OPENHIM_PUBLIC_URL "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "https://${BECKN_OPENHIM_HOST}"; fi
if beckn_hosted openmrs; then infisical_set "$F" OPENMRS_PUBLIC_URL "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "https://${BECKN_OPENMRS_HOST}"; fi
# anything else in the seed file that belongs to the add-on (the private keys, a Spice id, …) is stored as given
KNOWN=" $(printf '%s ' "${SPEC[@]}" | sed 's#:[^ ]*# #g') "
for key in "${!SEED[@]}"; do
  case "$KNOWN" in *" $key "*) continue ;; esac
  case "$key" in BECKN_*|OPENHIM_*|OPENMRS_*|CCE_BECKN_*) ;; *) echo "  note: seed key $key is not a Beckn key — ignored (use SEED_ENV_FILE of install.sh for it)"; continue ;; esac
  [ -z "${SEED[$key]}" ] && continue
  infisical_set "$F" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "${SEED[$key]}"; FROM_FILE+=("$key")
done

echo "[beckn-seed $ENVCODE] Infisical folder $F"
echo "  from seed file (${#FROM_FILE[@]}): ${FROM_FILE[*]:-none}"
echo "  generated (${#GENERATED[@]}): ${GENERATED[*]:-none}"
echo "  defaults (${#DEFAULTED[@]}): ${DEFAULTED[*]:-none}"
echo "  kept, already in Infisical (${#KEPT[@]}): ${KEPT[*]:-none}"
[ "${#BLANK[@]}" -eq 0 ] || echo "  left blank until supplied (${#BLANK[@]}): ${BLANK[*]}"
[ "$KEYS_OK" = 1 ] || { echo "ERROR: adapter private keys are missing (above). They come with the registry records; nothing can be generated here."; exit 1; }
