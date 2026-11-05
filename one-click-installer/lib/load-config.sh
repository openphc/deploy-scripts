#!/usr/bin/env bash
# one-click-installer/lib/load-config.sh — SOURCE me, then:  cce_load_config <file>
#
# Reads a flat KEY=VALUE config file (see config/example.env) and EXPORTS each key — but never overrides a variable that is
# already set in the environment, so automation can still do `sudo env IS_CLOUD_DEPLOYMENT=true bash install.sh --config …`.
# Unknown keys are reported (a typo like IS_CLOUD_DEPLOYEMENT would otherwise be silently ignored) — IMAGE_* keys are free-form.
CCE_CONFIG_KEYS=" ENVCODE OVERLAY_NAME OVERLAY_TEMPLATE INGRESS_HOST ACME_EMAIL IS_CLOUD_DEPLOYMENT SSH_ALLOWED_CIDR UFW_EXTRA_ALLOW
 K3S_CLUSTER_CIDR K3S_SERVICE_CIDR USE_LOCAL_INFISICAL LOCAL_INFISICAL_RUNTIME INFISICAL_CORE_VERSION INFISICAL_DOMAIN SEED_ENV_FILE CCE_INFISICAL_CREDS_DIR
 K3S_VERSION INFISICAL_CLI_VERSION CLICKHOUSE_VERSION POSTGRES_VERSION KAFKA_VERSION DEBEZIUM_VERSION KAFKA_PORT
 ENABLE_PG_STAT_STATEMENTS EXPORTER_RUNTIME POSTGRES_EXPORTER_VERSION POSTGRES_EXPORTER_SHA256 KAFKA_EXPORTER_VERSION KAFKA_EXPORTER_SHA256 PORTAINER_ENABLED PORTAINER_VERSION PORTAINER_SHA256 KEYCLOAK_THEME_DIR DATA_PIPELINE_REF DATA_PIPELINE_REPO IMAGE_REGISTRY IMAGE_TAG_DEFAULT PROTOCOL_FILE PROTOCOL_LOAD_URL ASSUME_YES SKIP_PREREQS "

cce_load_config() {
  local file="$1" line key val unknown=()
  # The list spans lines: without this, the last key on each line (UFW_EXTRA_ALLOW, …) is followed by a newline, not the space the
  # match below needs, and is reported as unknown.
  local known=" $(printf '%s' "$CCE_CONFIG_KEYS" | tr -s '[:space:]' ' ') "
  [ -r "$file" ] || { echo "ERROR: cannot read config file: $file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                                          # strip comments
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in *=*) ;; *) echo "WARNING: ignoring malformed config line: $line" >&2; continue;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "WARNING: ignoring invalid key '$key'" >&2; continue; }
    case "$known" in *" $key "*) ;; *) [[ "$key" == IMAGE_* ]] || unknown+=("$key");; esac
    if [ -z "${!key+x}" ]; then export "$key=$val"; else export "$key"; fi   # environment wins
  done < "$file"
  [ "${#unknown[@]}" -gt 0 ] && echo "WARNING: unknown config key(s) — typo? ${unknown[*]}" >&2
  return 0
}

# Validation shared by install.sh. Prints problems; returns non-zero if any.
cce_validate_config() {
  local bad=0
  [ -n "${ENVCODE:-}" ] || { echo "CONFIG: ENVCODE is required" >&2; bad=1; }
  [[ "${ENVCODE:-x}" =~ ^[a-z0-9]+$ ]] || { echo "CONFIG: ENVCODE must be lowercase letters/digits (got '${ENVCODE:-}')" >&2; bad=1; }
  case "${IS_CLOUD_DEPLOYMENT:-}" in true|false) ;; *) echo "CONFIG: IS_CLOUD_DEPLOYMENT must be true or false (got '${IS_CLOUD_DEPLOYMENT:-}')" >&2; bad=1;; esac
  case "${USE_LOCAL_INFISICAL:-false}" in true|false) ;; *) echo "CONFIG: USE_LOCAL_INFISICAL must be true or false" >&2; bad=1;; esac
  case "${ENABLE_PG_STAT_STATEMENTS:-true}" in true|false) ;; *) echo "CONFIG: ENABLE_PG_STAT_STATEMENTS must be true or false" >&2; bad=1;; esac
  case "${LOCAL_INFISICAL_RUNTIME:-native}" in native|docker) ;; *) echo "CONFIG: LOCAL_INFISICAL_RUNTIME must be native or docker" >&2; bad=1;; esac
  case "${EXPORTER_RUNTIME:-systemd}" in systemd|docker) ;; *) echo "CONFIG: EXPORTER_RUNTIME must be systemd or docker" >&2; bad=1;; esac
  case "${PORTAINER_ENABLED:-true}" in true|false) ;; *) echo "CONFIG: PORTAINER_ENABLED must be true or false" >&2; bad=1;; esac
  if [ -n "${INGRESS_HOST:-}" ] && [ -z "${ACME_EMAIL:-}" ]; then echo "CONFIG: INGRESS_HOST is set (TLS) but ACME_EMAIL is empty" >&2; bad=1; fi
  if [ -n "${SEED_ENV_FILE:-}" ] && [ ! -r "$SEED_ENV_FILE" ]; then echo "CONFIG: SEED_ENV_FILE not readable: $SEED_ENV_FILE" >&2; bad=1; fi
  if [ -n "${PROTOCOL_FILE:-}" ] && [ ! -r "$PROTOCOL_FILE" ]; then echo "CONFIG: PROTOCOL_FILE not readable: $PROTOCOL_FILE" >&2; bad=1; fi
  return $bad
}
