#!/usr/bin/env bash
# one-click-installer/lib/infisical-seed.sh <envcode> <path-to-seed.env>
# Populate a (freshly bootstrapped) Infisical project with config for <envcode>: values from the
# operator's seed .env file are used as-is; secret-shaped values missing from it are generated;
# non-secret values missing from it get a fixed default where one is safe, or are left BLANK for
# the operator to fill in later (external-system config this installer can't know, e.g. OpenHIM).
#
# The KEY_FOLDER table below mirrors the actual folder layout of the live PROD Infisical project
# as of 2026-07-13 (verified via `infisical secrets folders get` / `infisical secrets --path=...`
# against the real instance, not assumed) — but note `infisical run --recursive` flattens every
# folder under / into the environment regardless of which folder a key lives in, so the folder
# choice here is organizational only, not functionally load-bearing.
#
# RUN:  sudo -A bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/infisical-seed.sh <envcode> <path-to-seed.env>
# (Requires infisical-run.sh's env already resolvable — i.e. run AFTER one-click-installer/lib/infisical-bootstrap.sh
# has written the creds/.meta files for a brand-new envcode.)
set -euo pipefail

ENVCODE="${1:?usage: infisical-seed.sh <envcode> <path-to-seed.env>}"
SEED_FILE="${2:?usage: infisical-seed.sh <envcode> <path-to-seed.env>}"
[ -r "$SEED_FILE" ] || { echo "ERROR: cannot read seed file: $SEED_FILE"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./infisical-secret-helpers.sh
. "$REPO/one-click-installer/lib/infisical-secret-helpers.sh"

infisical_resolve_project "$ENVCODE"
infisical_login

# --- 1) parse the seed file into an associative array -----------------------------------------
declare -A SEED=()   # "=()": a never-assigned array is UNBOUND under set -u (an empty/absent seed file crashed here)
while IFS='=' read -r key val; do
  key="$(echo "$key" | tr -d '[:space:]')"
  [ -z "$key" ] && continue
  case "$key" in \#*) continue ;; esac
  # strip surrounding quotes and inline comments the same way `set -a; . file` would tolerate
  val="${val%%#*}"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  val="$(echo "$val" | sed 's/[[:space:]]*$//')"
  SEED["$key"]="$val"
done < "$SEED_FILE"
echo "[seed $ENVCODE] parsed ${#SEED[@]} key(s) from $SEED_FILE"

# --- 2) key classification: folder + how to fill it if the seed file didn't supply it ----------
# format per entry: "KEY:folder:kind[:default-or-generator]"
#   kind=secret    -> infisical_get_or_generate (random 32-char value)
#   kind=default   -> fixed value if not supplied (safe to share across every env)
#   kind=detected  -> NOT stored. The VM's address is a fact about the machine, not config: one-click-installer/lib/host-ip.sh derives it at
#                     deploy time (via infisical-run.sh), so a stored copy could only go stale (it did, 2026-10). If the
#                     operator supplies the key in the seed file anyway, that explicit override IS stored and wins.
#   kind=blank     -> left empty if not supplied ("null now, fill in later")
SPEC=(
  "POSTGRES_HOST:/postgres:detected"
  "POSTGRES_PORT:/postgres:default:5432"
  "POSTGRES_DATABASE:/postgres:default:ccedb"
  "POSTGRES_USER:/postgres:default:admin"
  "POSTGRES_PASSWORD:/postgres:secret"
  "POSTGRES_READ_ONLY_USER:/postgres:default:cce_cdc_user"
  "POSTGRES_READ_ONLY_PASSWORD:/postgres:secret"
  "CLICKHOUSE_HOST:/clickhouse:detected"
  "CLICKHOUSE_PORT:/clickhouse:default:8123"
  "CLICKHOUSE_DB:/clickhouse:default:cce_analytics"
  "CLICKHOUSE_USER:/clickhouse:default:cce_pipeline"
  "CLICKHOUSE_PASSWORD:/clickhouse:secret"
  "KAFKA_BOOTSTRAP_SERVERS:/kafka:detected"
  "CONNECT_URL:/kafka-connect:default:http://localhost:8083"
  "KEYCLOAK_ADMIN_USER:/keycloak:default:admin"
  "KEYCLOAK_ADMIN_PASSWORD:/keycloak:secret"
  "BASIC_AUTH_ENABLED:/keycloak:default:false"
  "BASIC_AUTH_CLIENT_ID:/keycloak:blank"
  "BASIC_AUTH_CLIENT_SECRET:/keycloak:secret"
  "GRAFANA_ADMIN_USER:/grafana:default:admin"
  "GRAFANA_ADMIN_PASSWORD:/grafana:secret"
  "OPENHIM_CORE_HOST:/openhim-emitter-adaptor:blank"
  "OPENHIM_CORE_API_PORT:/openhim-emitter-adaptor:default:8080"   # NOT blank: an empty-string env var cannot bind to the emitter's int property (crash-loop); 8080 = its own default
  "OPENHIM_CORE_SCHEME:/openhim-emitter-adaptor:default:https"
  "OPENHIM_CORE_AUTH_TYPE:/openhim-emitter-adaptor:default:basic"
  "OPENHIM_USERNAME:/openhim-emitter-adaptor:blank"
  "OPENHIM_PASSWORD:/openhim-emitter-adaptor:blank"
  "FACILITY_FILTER_IDS:/openhim-emitter-adaptor:blank"
  "CCE_COLLECTOR_AUTH_TOKEN:/platform:secret"
  "INGRESS_HOST:/platform:blank"
  "ACME_EMAIL:/platform:blank"
  "GATEWAY_ALLOWED_ORIGINS:/platform:blank"
  # The PROD overlay references these but the seed never listed them (added to PROD after this file was written), so every new env got
  # EMPTY values and insights-service crash-looped ("Failed to convert '' to long" on cacheConfig.lookupsTtl). Values = what the reference production environment uses.
  "CACHE_TTL_ANALYTICS:/platform:default:30"
  "CACHE_TTL_LOOKUPS:/platform:default:30"
  "CACHE_TTL_METRICS:/platform:default:30"
  "CLICKHOUSE_USE_FINAL:/clickhouse:default:true"
  "IMAGE_PULL_POLICY:/platform:default:Always"
  # 2.0 intelligence-service ops alerts (ingestion-gap escalation e-mails). Thresholds = the service's own .env.example;
  # repeat = its app default. Notifications start OFF: a fresh env has no traffic yet, so tier 1 would fire after 4h — turn
  # on once the env is live. Recipients + SMTP are REQUIRED by the service and country-specific: supply them in SEED_ENV_FILE
  # (overlay-vars-check names any that are missing). The tier Cc's are genuinely optional.
  "CCE_OPSALERT_NOTIFICATIONS_ENABLED:/platform:default:false"
  "CCE_OPSALERT_REPEAT_INTERVAL_MINUTES:/platform:default:1440"
  "CCE_OPSALERT_TIER1_THRESHOLD_MINUTES:/platform:default:240"
  "CCE_OPSALERT_TIER2_THRESHOLD_MINUTES:/platform:default:1440"
  "CCE_OPSALERT_TIER3_THRESHOLD_MINUTES:/platform:default:2880"
  "CCE_OPSALERT_TIER1_CC:/platform:blank"
  "CCE_OPSALERT_TIER2_CC:/platform:blank"
  "CCE_OPSALERT_TIER3_CC:/platform:blank"
  "CCE_INTELLIGENCE_SMTP_PORT:/platform:default:587"
  "CCE_INTELLIGENCE_SMTP_HOST:/platform:blank"
  "CCE_INTELLIGENCE_SMTP_USERNAME:/platform:blank"
  "CCE_INTELLIGENCE_SMTP_PASSWORD:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_EMAIL_TIER1:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_NAME_TIER1:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_EMAIL_TIER2:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_NAME_TIER2:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_EMAIL_TIER3:/platform:blank"
  "CCE_INTELLIGENCE_ALERT_NAME_TIER3:/platform:blank"
  "VM_HOST_IP:/platform:detected"
  "VM_HOST_CIDR:/platform:detected"
)

# --- 3) (removed) VM_HOST_IP resolution -------------------------------------------------------
# The host IP is no longer seeded, so there is nothing to resolve here and no way for seeding to fail
# because detection did. See one-click-installer/lib/host-ip.sh.

# --- 4) fill every key, tracking outcome for the summary ----------------------------------------
FROM_FILE=() GENERATED=() DEFAULTED=() BLANK=() DETECTED=()
for entry in "${SPEC[@]}"; do
  IFS=':' read -r key folder kind extra <<< "$entry"
  if [ -n "${SEED[$key]+x}" ] && [ -n "${SEED[$key]}" ]; then
    value="${SEED[$key]}"
    FROM_FILE+=("$key")
  else
    case "$kind" in
      secret)  value=$(infisical_get_or_generate "$folder" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG"); GENERATED+=("$key") ;;
      default) value="$extra"; DEFAULTED+=("$key") ;;
      detected) DETECTED+=("$key"); continue ;;   # derived from the host at deploy time (one-click-installer/lib/host-ip.sh) — never stored
      blank)
        # The CLI rejects `secrets set KEY=` with a truly empty value ("ensure that each secret
        # has a none empty key and value"). Skip setting it entirely instead — an absent key and
        # an empty-string key behave identically to envsubst/`infisical run` consumers, so this
        # is functionally equivalent to "null now, fill in later" without fighting the CLI.
        BLANK+=("$key")
        continue
        ;;
    esac
  fi
  infisical_set "$folder" "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$value"
done

# Any seed-file key NOT in SPEC still gets stored — under /platform as a catch-all — so nothing
# the operator explicitly supplied is silently dropped, even if this script doesn't recognize it.
KNOWN_KEYS=" $(printf '%s ' "${SPEC[@]}" | sed 's#:[^ ]*# #g') "
for key in "${!SEED[@]}"; do
  case "$KNOWN_KEYS" in *" $key "*) continue ;; esac
  [ -z "${SEED[$key]}" ] && continue   # same empty-value CLI limitation as the "blank" kind above
  infisical_set /platform "$key" "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "${SEED[$key]}"
  FROM_FILE+=("$key (unrecognized key, stored under /platform)")
done

echo ""
echo "[seed $ENVCODE] done."
echo "  from seed file (${#FROM_FILE[@]}): ${FROM_FILE[*]:-none}"
echo "  generated secrets (${#GENERATED[@]}): ${GENERATED[*]:-none}"
echo "  fixed defaults (${#DEFAULTED[@]}): ${DEFAULTED[*]:-none}"
if [ "${#DETECTED[@]}" -gt 0 ]; then
  echo "  NOT STORED — detected from the host at deploy time (${#DETECTED[@]}): ${DETECTED[*]}"
fi
if [ "${#BLANK[@]}" -gt 0 ]; then
  echo "  LEFT BLANK — fill in before relying on these features (${#BLANK[@]}): ${BLANK[*]}"
fi
