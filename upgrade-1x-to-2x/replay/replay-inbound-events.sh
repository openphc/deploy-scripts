#!/usr/bin/env bash
# =================================================================================================
# replay-inbound-events.sh — rebuild CCE state by replaying events from inbound_event_log
# =================================================================================================
# The collector keeps every event it ever accepted in Postgres (inbound_event_log). Kafka keeps only
# 7 days. This script re-publishes accepted events from that table onto cce.events.inbound, exactly
# as the collector published them, so the services that process events rebuild what they derive from
# them, from scratch (mode "rebuild") or for events never processed (mode "fill-gaps").
#
# It is tied neither to a CCE release nor to how CCE is deployed. replay.env next to this script (--config <file>
# uses another) says how each part is reached: the services on Docker Compose, Docker or Kubernetes;
# Postgres, Kafka and Kafka Connect through a command prefix (docker exec, kubectl exec, sudo, or none);
# ClickHouse over HTTP. It also says which services take part (SERVICES), which tables those services
# create and the rebuild drops (DROP_TABLES), and which of those get their data back afterwards
# (RESTORE_TABLES). Each step is its own command — see REPLAY-RUNBOOK.md.
#
#   replay-inbound-events.sh check
#   replay-inbound-events.sh status
#   replay-inbound-events.sh plan     --mode rebuild|fill-gaps [--from T] [--to T]
#   replay-inbound-events.sh backup
#   replay-inbound-events.sh prepare  --mode rebuild|fill-gaps --yes
#   replay-inbound-events.sh publish  [--from T] [--to T]
#   replay-inbound-events.sh wait
#   replay-inbound-events.sh finish   --yes
#   replay-inbound-events.sh rebuild-clickhouse --yes
#   replay-inbound-events.sh backfill-clickhouse     (also run by rebuild-clickhouse)
#   replay-inbound-events.sh verify
#   replay-inbound-events.sh report                  (before/after counts and reasons, as markdown)
#   replay-inbound-events.sh drop-old-tables --yes   (once a rebuild is verified and its report read)
#   replay-inbound-events.sh revert   --yes          (undo: old tables back, ClickHouse rebuilt)
#   replay-inbound-events.sh revert   --yes --no-start   (going back from an upgrade: tables only)
#   replay-inbound-events.sh restore  --file <backup.dump> --yes
#   replay-inbound-events.sh restore-database --file <backup.dump> --yes   (the whole database back; after A11 of an upgrade)
#   replay-inbound-events.sh logs <service>
#   replay-inbound-events.sh service stop|start|state <service>
#
#   (every command also takes --config <file> to use a settings file other than replay.env next to this script)
#
# T is a timestamp Postgres understands, in UTC, e.g. 2026-09-01 or '2026-09-01 06:00'. --from is
# inclusive, --to exclusive, both on inbound_event_log.received_at (when CCE received the event).
# =================================================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- output ---------------------------------------------------------------------------------------
log()  { printf '[replay %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31mSTOP\033[0m %s\n\n' "$*" >&2; exit 1; }
usage() { awk 'NR == 1 {next} /^[^#]/ {exit} {print}' "$0"; }
# Any unexpected failure stops with a message instead of silently (printed once, by the main shell).
on_unexpected_error() {
  [ "$BASHPID" = "$$" ] || return 0
  printf '\n  \033[31mSTOP\033[0m The %s step failed unexpectedly (line %s, exit code %s). The error is shown above.\n' "${COMMAND:-?}" "$1" "$2" >&2
  printf '       inbound_event_log is never changed, so nothing is lost.\n' >&2
  if [ "${COMMAND:-}" = prepare ]; then
    printf '       Undo what prepare did with: revert --yes (going back from an upgrade: revert --yes --no-start),\n' >&2
    printf '       fix the cause, then start again from backup (REPLAY-RUNBOOK.md, "Revert").\n\n' >&2
  else
    printf '       Fix the cause and run the SAME step again, or undo the replay with: revert --yes\n' >&2
    printf '       (REPLAY-RUNBOOK.md, "Revert").\n\n' >&2
  fi
  exit 1
}
trap 'on_unexpected_error $LINENO $?' ERR

# ---- arguments ------------------------------------------------------------------------------------
ORIGINAL_ARGS=("$@")
CONFIG_FILE="$SCRIPT_DIR/replay.env"; COMMAND=""; ARG1=""; ARG2=""; MODE=""; FROM=""; TO=""; YES=""; RESTORE_FILE=""; NO_START=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2;;
    --mode) MODE="${2:-}"; shift 2;;
    --from) FROM="${2:-}"; shift 2;;
    --to)   TO="${2:-}"; shift 2;;
    --file) RESTORE_FILE="${2:-}"; shift 2;;
    --yes)  YES=1; shift;;
    --no-start) NO_START=1; shift;;
    -*) die "Unknown option: $1";;
    *) if [ -z "$COMMAND" ]; then COMMAND="$1"; elif [ -z "$ARG1" ]; then ARG1="$1"; else ARG2="$1"; fi; shift;;
  esac
done
[ -n "$COMMAND" ] || { usage; exit 1; }

# ---- settings: the deployment's file, then defaults -----------------------------------------------
[ -f "$CONFIG_FILE" ] || die "No settings file at $CONFIG_FILE. Describe this deployment in upgrade-1x-to-2x/replay/replay.env first (see REPLAY-RUNBOOK.md)."
# shellcheck disable=SC1090
. "$CONFIG_FILE"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:?Set DEPLOYMENT_NAME in $CONFIG_FILE (a short name for this CCE deployment, e.g. dev)}"

# Secrets from Infisical. The usual way on the RW servers is to run this script under
# rw/lib/infisical-run.sh, like every other rw script (replay-uat.sh, deploy-all.sh): the secrets are
# then already in the environment and nothing here runs. Alternatively, when the settings file names
# a k8s/.infisical.<env> credentials file, the script runs itself again inside `infisical run`.
# Either way --recursive is needed: the secrets sit in per-component folders (clickhouse,
# kafka-connect, postgres, ...), and without it only the root folder's are injected.
INFISICAL_CREDENTIALS="${INFISICAL_CREDENTIALS:-}"
if [ -n "$INFISICAL_CREDENTIALS" ] && [ -z "${REPLAY_INFISICAL_LOADED:-}" ]; then
  [ -f "$INFISICAL_CREDENTIALS" ] || die "Infisical credentials file $INFISICAL_CREDENTIALS not found (named in $CONFIG_FILE). Copy k8s/.infisical.example there and fill it in."
  command -v infisical >/dev/null || die "The infisical CLI is not installed on this host."
  # shellcheck disable=SC1090
  . "$INFISICAL_CREDENTIALS"
  : "${INFISICAL_API_URL:?}" "${INFISICAL_PROJECT_ID:?}" "${INFISICAL_ENV:?}" "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"
  INFISICAL_TOKEN="$(infisical login --method=universal-auth --client-id="$INFISICAL_CLIENT_ID" \
      --client-secret="$INFISICAL_CLIENT_SECRET" --domain="$INFISICAL_API_URL" --silent --plain)" \
    || die "Infisical login failed (credentials in $INFISICAL_CREDENTIALS)."
  export INFISICAL_TOKEN REPLAY_INFISICAL_LOADED=1
  exec infisical run --silent --recursive --path=/ --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" \
    --domain="$INFISICAL_API_URL" -- bash "$0" "${ORIGINAL_ARGS[@]}"
fi

# ---- how the deployment is reached ----------------------------------------------------------------
# Services: PLATFORM says how they are stopped, started and observed.
PLATFORM="${PLATFORM:?PLATFORM must be compose, docker or kubernetes in $CONFIG_FILE}"
case "$PLATFORM" in compose|docker|kubernetes) ;; *) die "PLATFORM must be compose, docker or kubernetes (in $CONFIG_FILE), not '$PLATFORM'.";; esac
COMPOSE_DIR="${COMPOSE_DIR:-/opt/deployment}"; COMPOSE_OPTS="${COMPOSE_OPTS:-}"  # PLATFORM=compose (COMPOSE_OPTS e.g. "-p name -f file")
KUBECTL="${KUBECTL:-kubectl}"; K8S_NAMESPACE="${K8S_NAMESPACE:-}"               # PLATFORM=kubernetes
SERVICE_START_TIMEOUT="${SERVICE_START_TIMEOUT:-300}"   # seconds a service may take to start
SERVICE_STOP_TIMEOUT="${SERVICE_STOP_TIMEOUT:-300}"     # seconds its process may take to exit once stopped

# Postgres, Kafka and Kafka Connect: each is reached through a command prefix that runs a program
# where its tools are — "docker exec -i <container>", "kubectl -n <ns> exec -i <pod> --",
# "sudo -u postgres", or empty for this host. The prefix must pass stdin through (-i for docker and
# kubectl). The older PG_ACCESS / KAFKA_ACCESS / CONNECT_ACCESS settings still work: they are turned
# into a prefix here.
if [ -z "${PG_EXEC+set}" ]; then
  case "${PG_ACCESS:-docker}" in
    docker) PG_EXEC="docker exec -i ${PG_CONTAINER:-cce-postgres}"; PG_PORT="";;
    local)  PG_EXEC="${PG_LOCAL_PREFIX-sudo -u postgres}"; PG_PORT="${PG_PORT:-5432}";;
    *) die "PG_ACCESS must be docker or local in $CONFIG_FILE (or set PG_EXEC).";;
  esac
fi
PG_DB="${PG_DB:-ccedb}"
PG_USER="${PG_USER:-}"; PG_HOST="${PG_HOST:-}"; PG_PORT="${PG_PORT:-}"   # empty: psql's defaults where it runs

if [ -z "${KAFKA_EXEC+set}" ]; then
  case "${KAFKA_ACCESS:-docker}" in
    docker) KAFKA_EXEC="docker exec -i ${KAFKA_CONTAINER:-kafka}"; KAFKA_TOOLS_DIR="${KAFKA_TOOLS_DIR-${KAFKA_CONTAINER_BIN:-}}";;
    local)  KAFKA_EXEC=""; KAFKA_TOOLS_DIR="${KAFKA_TOOLS_DIR-${KAFKA_BIN:-/opt/kafka/bin}}";;
    *) die "KAFKA_ACCESS must be docker or local in $CONFIG_FILE (or set KAFKA_EXEC).";;
  esac
fi
KAFKA_TOOLS_DIR="${KAFKA_TOOLS_DIR:-}"       # folder of the Kafka tools where they run ('' = on the PATH)
KAFKA_TOOL_SUFFIX="${KAFKA_TOOL_SUFFIX:-}"   # "" for Confluent images (kafka-topics), ".sh" for Apache Kafka
KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka:9092}"   # as seen from where the tools run
KAFKA_CLIENT_CONFIG="${KAFKA_CLIENT_CONFIG:-}"     # client properties file (SASL/TLS), where the tools run

if [ -z "${CONNECT_EXEC+set}" ]; then
  case "${CONNECT_ACCESS:-docker}" in
    docker) CONNECT_EXEC="docker exec -i ${CONNECT_CONTAINER:-cce-kafka-connect}";;
    local)  CONNECT_EXEC="";;
    *) die "CONNECT_ACCESS must be docker or local in $CONFIG_FILE (or set CONNECT_EXEC).";;
  esac
fi
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"   # as seen from where CONNECT_EXEC runs curl
CONNECTOR="${CONNECTOR:-cce-ccedb-source}"
CDC_SLOT="${CDC_SLOT:-cce_analytics_slot}"
CDC_PUBLICATION="${CDC_PUBLICATION:-cce_analytics_pub}"

DATA_PIPELINE_DIR="${DATA_PIPELINE_DIR:-$SCRIPT_DIR/../../data-pipeline}"
SECRETS_FILE="${SECRETS_FILE:-}"          # optional file with ClickHouse/CDC credentials (else env)
if [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
  # Take only credentials from it: such files also carry URLs and ports that must not override the
  # settings file (e.g. the data-pipeline .env's own CONNECT_URL).
  eval "$( set -a; . "$SECRETS_FILE" >/dev/null 2>&1; set +a
           for v in CH_USER CH_PASSWORD CLICKHOUSE_USER CLICKHOUSE_PASSWORD CDC_PG_HOST CDC_PG_PORT \
                    CDC_PG_DATABASE CDC_USER CDC_PASSWORD POSTGRES_READ_ONLY_USER POSTGRES_READ_ONLY_PASSWORD \
                    POSTGRES_HOST POSTGRES_PORT POSTGRES_DATABASE; do
             [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
           done )"
fi
CH_USER="${CH_USER:-${CLICKHOUSE_USER:-cce_pipeline}}"
CH_PASSWORD="${CH_PASSWORD:-${CLICKHOUSE_PASSWORD:-}}"
CH_HTTP="${CH_HTTP:-http://${CLICKHOUSE_HOST:-localhost}:${CLICKHOUSE_PORT:-8123}}"   # as seen from this host
CH_DB="${CH_DB:-${CLICKHOUSE_DB:-cce_analytics}}"
CH_NAMED_COLLECTION="${CH_NAMED_COLLECTION:-cce_kafka}"
CH_SCHEMA_FILES="${CH_SCHEMA_FILES:-01-create-tables 02-kafka-ingestion 03-create-materialized-views
  04-create-indexes 05-create-dictionary 06-current-state-rollups 08-reference-tables 07-daily-summary-aggregates}"

# Backups and replay progress. Every step must see the same folder: set STATE_DIR in the settings
# file when steps may be run both with and without sudo (each would otherwise use its own $HOME).
STATE_DIR="${STATE_DIR:-$HOME/cce-replay/$DEPLOYMENT_NAME}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-6}"

# ---- what the replay touches ----------------------------------------------------------------------
# SERVICES: stopped before the replay and started again after, in this order. The first one reads
# cce.events.inbound: it is started as soon as the events are published; the others once it has
# caught up (so deadlines and alerts are only judged on complete data).
SERVICES="${SERVICES:-}"
# DROP_TABLES: the tables those services create. A rebuild drops them (with the services' migration
# records) and the services create them again when they start. A table before those pointing at it.
DROP_TABLES="${DROP_TABLES:-}"
# RESTORE_TABLES: of DROP_TABLES, the ones whose data is put back from before the rebuild.
RESTORE_TABLES="${RESTORE_TABLES:-}"
# SCHEMA_ORDER: the order the services are started in to create their tables (default: SERVICES).
# It differs from SERVICES when a service's migrations need another's tables, e.g. Matcher's need
# Protocol's, so Protocol must build first even though Matcher is the one reading the inbound topic.
SCHEMA_ORDER="${SCHEMA_ORDER:-$SERVICES}"
# Only CCE's own topics and consumer groups are emptied / reset: the Kafka broker is shared with other
# applications on some servers, and their topics and groups must never be touched by a replay.
# The collector: stopped by 'restore-database' while the database is replaced, then started again.
COLLECTOR_SERVICE="${COLLECTOR_SERVICE:-cce-collector-service}"
TOPIC_PATTERN="${TOPIC_PATTERN:-^cce\.}"
GROUP_PATTERN="${GROUP_PATTERN:-^cce-}"
# INSIGHTS_SERVICES: read ClickHouse, so 'rebuild-clickhouse' stops them while the database is dropped
# and copied again, and starts them once the copy has settled (else the dashboard shows errors, then
# partial numbers). Set it empty for a deployment without Insights. CH_SETTLE_MINUTES: how long it
# waits for that before leaving them stopped.
INSIGHTS_SERVICES="${INSIGHTS_SERVICES-cce-insights-service cce-insights-ui}"
CH_SETTLE_MINUTES="${CH_SETTLE_MINUTES:-30}"

# Fixed: the replay's source topic and its dead-letter topic; the tables that are never touched
# whatever is listed (the replay source, the collector's migration record, Keycloak's); the schema
# dropped tables wait in until 'drop-old-tables'.
INBOUND_TOPIC="${INBOUND_TOPIC:-cce.events.inbound}"
DLQ_TOPIC="$INBOUND_TOPIC.dlq"
NEVER_TOUCHED="inbound_event_log flyway_schema_history flyway_schema_history_collector databasechangelog databasechangeloglock"
OLD_SCHEMA="replay_old"

# ---- component access: the only place that knows HOW Postgres, Kafka and Connect are reached ---------
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # quote one argument for sh

pg_cmd() {   # $1 = psql | pg_dump | pg_restore, rest = its arguments: prints a sh command that runs it
  # Credentials are those of wherever PG_EXEC runs it: PG_USER if set, else the database image's
  # POSTGRES_USER there, else the OS user; a password from PGPASSWORD there, else POSTGRES_PASSWORD.
  local s a
  s='[ -n "${PGPASSWORD:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ] || export PGPASSWORD="$POSTGRES_PASSWORD"; '
  s="$s"'export PGOPTIONS="-c client_min_messages=warning"; exec '"$1"   # NOTICEs are noise here
  shift
  if [ -n "$PG_USER" ]; then s="$s -U $(shq "$PG_USER")"; else s="$s"' ${POSTGRES_USER:+-U "$POSTGRES_USER"}'; fi
  [ -z "$PG_HOST" ] || s="$s -h $(shq "$PG_HOST")"
  [ -z "$PG_PORT" ] || s="$s -p $(shq "$PG_PORT")"
  for a in "$@"; do s="$s $(shq "$a")"; done
  printf '%s' "$s"
}
psql_raw()  { $PG_EXEC sh -c "$(pg_cmd psql -d "$PG_DB" "$@")"; }   # psql against the database; SQL on stdin
psql_q()    { psql_raw -v ON_ERROR_STOP=1 -X -q -At -F '|'; }
sql_value() { printf '%s\n' "$1" | psql_q; }
pg_dump_to() { $PG_EXEC sh -c "$(pg_cmd pg_dump -d "$PG_DB" -Fc)" < /dev/null > "$1"; }   # $1 = output file
pg_table_data_sql() {   # $1 = dump file, $2 = table: prints that table's rows from the dump as SQL
  $PG_EXEC sh -c "$(pg_cmd pg_restore --data-only -t "$2" -f -)" < "$1"
}

kafka_run() {   # $1 = tool without suffix (kafka-topics, kafka-get-offsets, ...), rest = args; stdin passed on
  local tool="$1" cfg=(); shift
  if [ -n "$KAFKA_CLIENT_CONFIG" ]; then
    case "$tool" in
      kafka-console-producer) cfg=(--producer.config "$KAFKA_CLIENT_CONFIG");;
      kafka-console-consumer) cfg=(--consumer.config "$KAFKA_CLIENT_CONFIG");;
      *) cfg=(--command-config "$KAFKA_CLIENT_CONFIG");;
    esac
  fi
  $KAFKA_EXEC "${KAFKA_TOOLS_DIR:+$KAFKA_TOOLS_DIR/}$tool$KAFKA_TOOL_SUFFIX" --bootstrap-server "$KAFKA_BOOTSTRAP" "$@" ${cfg[@]+"${cfg[@]}"}
}
kafka_tool() { kafka_run "$@" < /dev/null; }   # the same, reading nothing from stdin
kafka_put_file() {   # stdin -> a temporary file where the Kafka tools run; prints its path
  $KAFKA_EXEC sh -c 'f=$(mktemp) && chmod 644 "$f" && cat > "$f" && echo "$f"'
}
kafka_rm_file() { $KAFKA_EXEC rm -f "$1" < /dev/null || true; }

connect_api() {   # $1 = method, $2 = path, $3 = "json" to send stdin as the body; prints the response
  if [ "${3:-}" = json ]; then
    $CONNECT_EXEC curl -s -X "$1" -H 'Content-Type: application/json' --data-binary @- "$CONNECT_URL$2"
  else
    $CONNECT_EXEC curl -s -X "$1" "$CONNECT_URL$2" < /dev/null
  fi
}

ch_query() {   # $1 = SQL; ClickHouse over HTTP (same on every platform)
  curl -sS --fail-with-body "$CH_HTTP/" -H "X-ClickHouse-User: $CH_USER" -H "X-ClickHouse-Key: $CH_PASSWORD" --data-binary "$1"
}

# ---- services: the only place that knows how a service is stopped, started and observed ------------
# A service in SERVICES is a Compose service (PLATFORM=compose), a container (docker) or a Deployment
# (kubernetes) of that name. "stopped" means its process has exited — on Kubernetes not just scaled to
# 0 but with no pod left, since a terminating pod still works through what it had already read.
k() { $KUBECTL ${K8S_NAMESPACE:+-n "$K8S_NAMESPACE"} "$@"; }
compose_raw() { (cd "$COMPOSE_DIR" && docker compose $COMPOSE_OPTS "$@"); }
compose() { compose_raw "$@" 2>&1 | grep -vE 'variable is not set|attribute `version` is obsolete|orphan containers' || true; }

service_container() {   # compose / docker: the service's container id ('' if it has none)
  case "$PLATFORM" in
    compose) compose_raw ps -a -q "$1" 2>/dev/null | head -1 || true;;
    docker)  docker inspect -f '{{.Id}}' "$1" 2>/dev/null || true;;
  esac
}
k8s_selector() {   # kubernetes: the Deployment's pod selector as kubectl -l takes it ('' if it has no matchLabels)
  k get deploy "$1" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null | sed 's/,$//' || true
}
k8s_live_pods() {   # kubernetes: how many of the Deployment's pods still exist, terminating ones included
  local sel; sel=$(k8s_selector "$1")
  if [ -z "$sel" ]; then   # no matchLabels to list them by: fall back to the Deployment's own count
    k get deploy "$1" -o jsonpath='{.status.replicas}' 2>/dev/null | grep -E '^[0-9]+$' || echo 0; return
  fi
  k get pods -l "$sel" --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name 2>/dev/null | grep -c . || true
}

service_state() {   # running | starting | stopping | paused | stopped | absent
  case "$PLATFORM" in
    compose|docker)
      local id st; id=$(service_container "$1")
      [ -n "$id" ] || { echo absent; return; }
      st=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || echo absent)
      case "$st" in
        running) echo running;;
        restarting) echo starting;;   # crash-looping: it comes back by itself, so it is not stopped
        paused) echo paused;;
        removing) echo stopping;;
        absent) echo absent;;
        *) echo stopped;;             # created, exited, dead
      esac;;
    kubernetes)
      local spec ready
      spec=$(k get deploy "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null) || { echo absent; return; }
      if [ "${spec:-0}" = 0 ]; then
        if [ "$(k8s_live_pods "$1")" = 0 ]; then echo stopped; else echo stopping; fi
        return
      fi
      ready=$(k get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
      if [ "${ready:-0}" -ge 1 ]; then echo running; else echo starting; fi;;
  esac
}
service_health() {   # healthy | not-yet | none (the platform has no health signal for this service)
  case "$PLATFORM" in
    compose|docker)
      local id h; id=$(service_container "$1"); [ -n "$id" ] || { echo not-yet; return; }
      # A container that has never run has no health state yet, only its configured healthcheck.
      h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else if .Config.Healthcheck}}starting{{else}}none{{end}}' "$id" 2>/dev/null || echo none)
      case "$h" in healthy) echo healthy;; none) echo none;; *) echo not-yet;; esac;;
    kubernetes)
      [ -n "$(k get deploy "$1" -o jsonpath='{.spec.template.spec.containers[*].readinessProbe}' 2>/dev/null || true)" ] \
        || { echo none; return; }
      if [ "$(service_state "$1")" = running ]; then echo healthy; else echo not-yet; fi;;
  esac
}

services_stop() {   # stop services and wait until their processes have exited
  [ $# -gt 0 ] || return 0
  local s r present=() waited
  for s in "$@"; do
    if [ "$(service_state "$s")" = absent ]; then warn "$s: not deployed here"; else present+=("$s"); fi
  done
  [ ${#present[@]} -gt 0 ] || return 0
  case "$PLATFORM" in
    compose) compose stop "${present[@]}";;
    docker)  for s in "${present[@]}"; do docker stop "$s" >/dev/null; done;;
    kubernetes)
      # Remember the replica count and any autoscaler, to put them back on start.
      mkdir -p "$STATE_DIR"
      for s in "${present[@]}"; do
        r=$(k get deploy "$s" -o jsonpath='{.spec.replicas}')
        if [ "${r:-0}" -gt 0 ]; then echo "$r" > "$STATE_DIR/replicas-$s"; fi
        if k get hpa "$s" >/dev/null 2>&1; then
          k get hpa "$s" -o yaml > "$STATE_DIR/hpa-$s.yaml"; k delete hpa "$s" >/dev/null
          log "  $s: autoscaler saved to $STATE_DIR/hpa-$s.yaml and removed"
        fi
        k scale deploy "$s" --replicas=0 >/dev/null
      done;;
  esac
  # docker and compose return once the process has exited; a Deployment scaled to 0 reports no
  # replicas while its pods are still shutting down, and still processing. Wait for every platform.
  for s in "${present[@]}"; do
    waited=0
    while :; do
      case "$(service_state "$s")" in stopped|absent) break;; esac
      [ "$waited" -lt "$SERVICE_STOP_TIMEOUT" ] || { warn "$s has not exited after ${SERVICE_STOP_TIMEOUT}s"; break; }
      sleep 3; waited=$((waited + 3))
    done
  done
}
services_start() {   # start services; --no-wait: return without waiting for them to be ready
  local wait=1 s r
  if [ "${1:-}" = --no-wait ]; then wait=""; shift; fi
  [ $# -gt 0 ] || return 0
  case "$PLATFORM" in
    compose)
      # 'start', not 'up': up recreates a container whose image or configuration changed since it was
      # created, so the service processing the replay could be another build than the one that built
      # its tables. Only a service with no container yet is created, with 'up'.
      # 'docker start' on the container, not 'compose start': compose start also starts the service's
      # depends_on services (Step SLA depends on Matcher), which must stay stopped while the replay
      # starts one service at a time.
      for s in "$@"; do
        if [ "$(service_state "$s")" = absent ]; then compose up -d --no-deps "$s"
        else docker start "$(service_container "$s")" >/dev/null; fi
      done;;
    docker)
      for s in "$@"; do
        if [ "$(service_state "$s")" = absent ]; then warn "$s: no such container"; continue; fi
        docker start "$s" >/dev/null
      done;;
    kubernetes)
      for s in "$@"; do
        if [ "$(service_state "$s")" = absent ]; then warn "$s: no deployment"; continue; fi
        r=$(cat "$STATE_DIR/replicas-$s" 2>/dev/null || echo 1)
        k scale deploy "$s" --replicas="$r" >/dev/null
        if [ -f "$STATE_DIR/hpa-$s.yaml" ]; then
          grep -vE '^\s*(resourceVersion|uid|creationTimestamp):' "$STATE_DIR/hpa-$s.yaml" | k apply -f - >/dev/null
          rm -f "$STATE_DIR/hpa-$s.yaml"; log "  $s: autoscaler restored"
        fi
      done
      [ -n "$wait" ] || return 0
      for s in "$@"; do
        [ "$(service_state "$s")" != absent ] || continue
        k rollout status deploy "$s" --timeout="${SERVICE_START_TIMEOUT}s" >/dev/null || warn "$s did not become ready within ${SERVICE_START_TIMEOUT}s"
      done;;
  esac
}
service_logs() {   # $1 = service, $2 = UTC time (YYYY-MM-DDTHH:MM:SSZ): its log since then (else the last 100 lines)
  case "$PLATFORM" in
    compose|docker)
      local id; id=$(service_container "$1"); [ -n "$id" ] || return 0
      if [ -n "${2:-}" ]; then docker logs --since "$2" "$id" 2>&1 || true
      else docker logs --tail 100 "$id" 2>&1 || true; fi;;
    kubernetes)
      # Every pod of the Deployment (not the one kubectl would pick), and a crashed container's last run.
      local sel range; sel=$(k8s_selector "$1")
      if [ -n "${2:-}" ]; then range=(--since-time="$2" --tail=-1); else range=(--tail=100); fi
      if [ -n "$sel" ]; then
        k logs -l "$sel" --all-containers=true --prefix --max-log-requests=50 "${range[@]}" 2>&1 || true
        [ -z "${2:-}" ] || k logs -l "$sel" --all-containers=true --prefix --max-log-requests=50 --previous "${range[@]}" 2>/dev/null || true
      else
        k logs "deploy/$1" --all-containers=true "${range[@]}" 2>&1 || true
      fi;;
  esac
}

# ---- Kafka / Postgres helpers (platform-neutral) --------------------------------------------------
topic_exists() { kafka_tool kafka-topics --list 2>/dev/null | grep -qx "$1"; }
topic_end_total() {   # sum of end offsets over all partitions (0 if the topic does not exist)
  topic_exists "$1" || { echo 0; return; }
  kafka_tool kafka-get-offsets --topic "$1" --time -1 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'
}
topic_record_count() {   # records currently in the topic (end minus start: a purge moves the start)
  topic_exists "$1" || { echo 0; return; }
  local ends starts
  ends=$(kafka_tool kafka-get-offsets --topic "$1" --time -1 2>/dev/null | awk -F: '{s+=$3} END{print s+0}')
  starts=$(kafka_tool kafka-get-offsets --topic "$1" --time -2 2>/dev/null | awk -F: '{s+=$3} END{print s+0}')
  echo $((ends - starts))
}
group_lag() {         # total lag of a consumer group on one topic ('-' if the group has no offsets)
  kafka_tool kafka-consumer-groups --describe --group "$1" 2>/dev/null \
    | awk -v t="$2" '$2==t && $6 ~ /^[0-9]+$/ {s+=$6; n++} END{ if (n) print s; else print "-" }'
}
group_is_empty() {    # no running consumer in the group (required before its offsets can be moved)
  local out; out=$(kafka_tool kafka-consumer-groups --describe --group "$1" --state 2>&1 || true)
  case "$out" in *"has no active members"*|*"does not exist"*) return 0;; esac
  [ "$(printf '%s\n' "$out" | awk -v g="$1" '$1==g {print $NF}' | tail -1)" = 0 ]
}
topic_end_offsets() { kafka_tool kafka-get-offsets --topic "$1" --time -1 2>/dev/null; }   # topic:partition:offset lines
offsets_json() {   # $1 = topic, $2 = its topic:partition:offset lines: kafka-delete-records input ('' if all 0)
  printf '%s\n' "$2" \
    | awk -F: -v t="$1" '$3>0 {p=p (p==""?"":",") sprintf("{\"topic\":\"%s\",\"partition\":%s,\"offset\":%s}",t,$2,$3)}
                         END{ if (p!="") print "{\"version\":1,\"partitions\":[" p "]}" }'
}
offsets_total() { printf '%s\n' "$1" | awk -F: '{s+=$3} END{print s+0}'; }   # $1 = topic:partition:offset lines
topic_filled_offsets_json() {   # the same, only for partitions that still hold records ('' if none does)
  # Lines are topic:partition:offset; starts are tagged S, ends E, so one list can be matched to the other.
  { kafka_tool kafka-get-offsets --topic "$1" --time -2 2>/dev/null | sed 's/^/S:/' || true
    kafka_tool kafka-get-offsets --topic "$1" --time -1 2>/dev/null | sed 's/^/E:/' || true
  } | awk -F: -v t="$1" '$1=="S" {start[$3]=$4; next}
                         $1=="E" && $4 > start[$3]+0 {p=p (p==""?"":",") sprintf("{\"topic\":\"%s\",\"partition\":%s,\"offset\":%s}",t,$3,$4)}
                         END{ if (p!="") print "{\"version\":1,\"partitions\":[" p "]}" }'
}
delete_records_up_to() {   # $1 = topic (for the log), $2 = offsets JSON: delete every record before them
  [ -n "$2" ] || return 0
  local f; f=$(printf '%s' "$2" | kafka_put_file)
  kafka_tool kafka-delete-records --offset-json-file "$f" >/dev/null
  kafka_rm_file "$f"
  log "  purged $1"
}
purge_topic() {       # delete every record currently in the topic (the topic itself stays)
  topic_exists "$1" || return 0
  delete_records_up_to "$1" "$(topic_filled_offsets_json "$1")"
}
dump_topic() {   # $1 = topic, $2 = file: every record in it (time, headers, key, value), for inspection
  local n; n=$(topic_record_count "$1")
  [ "$n" -gt 0 ] || return 0
  mkdir -p "$STATE_DIR"
  kafka_tool kafka-console-consumer --topic "$1" --from-beginning --max-messages "$n" --timeout-ms 20000 \
    --property print.timestamp=true --property print.headers=true --property print.key=true > "$2" 2>/dev/null || true
  log "  saved the $n record(s) of $1 to $2"
}
keys_between() {   # $1 = topic, $2 / $3 = start / end offsets (topic:partition:offset lines): the keys in between
  { printf '%s\n' "$2" | sed 's/^/S:/'; printf '%s\n' "$3" | sed 's/^/E:/'; } \
    | awk -F: '$1=="S" {s[$3]=$4; next} $1=="E" && $4 > s[$3]+0 {print $3, s[$3]+0, $4 - s[$3]}' \
    | while read -r partition from n; do
        kafka_tool kafka-console-consumer --topic "$1" --partition "$partition" --offset "$from" --max-messages "$n" \
          --timeout-ms 10000 --property print.key=true --property print.value=false 2>/dev/null || true
      done
}
wait_groups_idle() {   # $@ = consumer groups that must have no members
  local g
  for g in "$@"; do
    for _ in $(seq 1 20); do group_is_empty "$g" && break; sleep 3; done
    group_is_empty "$g" || die "Consumer group $g still has members — a consumer is running somewhere."
  done
  ok "Kafka consumer groups are idle: $*"
}
reset_group_to_earliest() {   # $1 = (stopped) group, $2 = topic, or empty for all the group's topics
  if [ -n "${2:-}" ]; then
    kafka_tool kafka-consumer-groups --group "$1" --topic "$2" --reset-offsets --to-earliest --execute >/dev/null
    log "  $1 now reads $2 from its first remaining record"
  else
    kafka_tool kafka-consumer-groups --group "$1" --all-topics --reset-offsets --to-earliest --execute >/dev/null 2>&1 || true
  fi
}
table_exists() { [ "$(sql_value "SELECT to_regclass('public.$1') IS NOT NULL")" = t ]; }
old_table_exists() { [ "$(sql_value "SELECT to_regclass('$OLD_SCHEMA.$1') IS NOT NULL")" = t ]; }
old_schema_exists() { [ "$(sql_value "SELECT count(*) FROM pg_namespace WHERE nspname = '$OLD_SCHEMA'")" = 1 ]; }
table_rows() { if table_exists "$1"; then sql_value "SELECT count(*) FROM $1"; else echo "absent"; fi; }
column_exists() { [ "$(sql_value "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$1' AND column_name = '$2'")" = 1 ]; }
now_utc_sql() { printf "SELECT to_char((clock_timestamp() %s) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00'" "${1:-}"; }
table_list_sql() { for t in "$@"; do printf 'public.%s, ' "$t"; done | sed 's/, $//'; }
slot_wal_kept() {   # WAL Postgres keeps for the CDC slot (it grows while the connector is paused)
  local v; v=$(sql_value "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots WHERE slot_name = '$CDC_SLOT'" 2>/dev/null || true)
  echo "${v:-no slot}"
}

state_set() { mkdir -p "$STATE_DIR"; printf '%s\n' "$2" > "$STATE_DIR/$1"; }
state_get() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
# A step run with sudo keeps its state in root's home, one run without in the user's: the two would
# not see each other's backup, cutoff or saved replica counts.
warn_split_state() {
  [ -n "${SUDO_USER:-}" ] || return 0
  local home other; home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
  [ -n "$home" ] || return 0
  other="$home/cce-replay/$DEPLOYMENT_NAME"
  if [ "$other" != "$STATE_DIR" ] && [ -n "$(ls -A "$other" 2>/dev/null || true)" ]; then
    warn "replay state for '$DEPLOYMENT_NAME' is also in $other (steps run without sudo); this run uses $STATE_DIR. Run every step the same way, or set STATE_DIR in $CONFIG_FILE."
  fi
}

# ---- derived from the settings --------------------------------------------------------------------
in_list() { case " $(echo $2) " in *" $1 "*) return 0;; esac; return 1; }
words() { echo $*; }
first_service() { words $SERVICES | cut -d' ' -f1; }
other_services() { words $SERVICES | cut -s -d' ' -f2-; }
reverse_services() { words $SERVICES | tr ' ' '\n' | tac | tr '\n' ' '; }

validate_settings() {
  local t s
  [ -n "$(words $SERVICES)" ] || die "SERVICES is empty in $CONFIG_FILE: list the services the replay stops and starts (the one reading $INBOUND_TOPIC first)."
  for s in $SERVICES; do [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "'$s' in SERVICES is not a service name."; done
  for t in $DROP_TABLES $RESTORE_TABLES; do
    [[ "$t" =~ ^[a-z_][a-z0-9_]*$ ]] || die "'$t' in $CONFIG_FILE is not a table name."
    in_list "$t" "$NEVER_TOUCHED" && die "$t can never be dropped or restored by a replay. Remove it from $CONFIG_FILE."
  done
  for t in $RESTORE_TABLES; do in_list "$t" "$DROP_TABLES" || die "RESTORE_TABLES lists $t, which is not in DROP_TABLES."; done
  for s in $SCHEMA_ORDER; do in_list "$s" "$SERVICES" || die "SCHEMA_ORDER lists $s, which is not in SERVICES."; done
  return 0
}

# A service's Flyway migration record goes with its tables: every flyway_schema_history_<x> whose <x>
# is part of a listed service's name (matcher -> cce-matcher-service), except the never-touched ones.
service_ledgers() {
  local ledger short s out=""
  for ledger in $(sql_value "SELECT string_agg(tablename, ' ') FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'flyway_schema_history_%'"); do
    in_list "$ledger" "$NEVER_TOUCHED" && continue
    short="${ledger#flyway_schema_history_}"; short="${short//_/-}"
    for s in $SERVICES; do case "$s" in *"$short"*) out="$out $ledger"; break;; esac; done
  done
  words $out
}
tables_to_move() {   # DROP_TABLES that exist, plus the services' migration records
  local t out=""
  for t in $DROP_TABLES; do table_exists "$t" && out="$out $t"; done
  words $out $(service_ledgers)
}
# The consumers' record of processed events: the first of DROP_TABLES with cloudevents_id and source
# (matcher_event_log in 2.0, compliance_event_log in 1.x).
processed_table() {
  local t
  for t in $DROP_TABLES; do
    column_exists "$t" cloudevents_id && column_exists "$t" source && { echo "$t"; return; }
  done
  state_get processed_table
}
# The consumer group reading the inbound topic (the first service's).
consumer_group() {
  local saved g groups found=""
  saved=$(state_get consumer_group); [ -n "$saved" ] && { echo "$saved"; return; }
  # Set explicitly when the group reading the topic today is not the one that will (1.x -> 2.0 upgrade:
  # cce-compliance-service reads it now, cce-matcher-service will).
  [ -n "${CONSUMER_GROUP:-}" ] && { echo "$CONSUMER_GROUP"; return; }
  groups=$(kafka_tool kafka-consumer-groups --list 2>/dev/null | grep -vE '^(connect|clickhouse|console-consumer-|_)' || true)
  for g in $groups; do
    kafka_tool kafka-consumer-groups --describe --group "$g" 2>/dev/null \
      | awk -v t="$INBOUND_TOPIC" '$2==t {f=1} END{exit !f}' || continue
    [ "$g" = "$(first_service)" ] && { echo "$g"; return; }
    found="$found $g"
  done
  found=$(words $found)
  [ -n "$found" ] && [ "$(echo $found | wc -w)" = 1 ] && { echo "$found"; return; }
  echo "$(first_service)"
}
# CCE consumer groups (GROUP_PATTERN), other than the replay's own, with a running member reading the
# inbound topic: a consumer outside SERVICES (e.g. 1.x compliance left running during an upgrade to
# 2.0) would process the replayed events too, against its own tables.
foreign_inbound_readers() {
  local g cg out=""; cg=$(consumer_group)
  for g in $(kafka_tool kafka-consumer-groups --list 2>/dev/null | grep -E "$GROUP_PATTERN" || true); do
    [ "$g" = "$cg" ] && continue
    kafka_tool kafka-consumer-groups --describe --group "$g" 2>/dev/null \
      | awk -v t="$INBOUND_TOPIC" '$2==t && $7!="-" && $7!="" {f=1} END{exit !f}' && out="$out $g"
  done
  words $out
}
require_no_foreign_inbound_readers() {
  local readers; readers=$(foreign_inbound_readers)
  [ -z "$readers" ] || die "Consumer group(s) $readers also read $INBOUND_TOPIC and have running consumers, and they are not the replay's ($(consumer_group)). They would process the replayed events too. Stop or remove the service(s) behind them (e.g. 1.x cce-compliance-service after an upgrade to 2.0), or add them to SERVICES. Nothing was changed."
}
# CCE's topics (TOPIC_PATTERN) except the inbound one and the CDC topics (cce.public.*, emptied by
# rebuild-clickhouse). The inbound topic's dead-letter topic is one of them. Other applications'
# topics on a shared broker are left alone.
output_topics() {
  kafka_tool kafka-topics --list 2>/dev/null \
    | grep -E "$TOPIC_PATTERN" | grep -vxF "$INBOUND_TOPIC" | grep -vE '^cce\.public\.' || true
}
# Consumer groups of the stopped services: CCE groups (GROUP_PATTERN) with no running member, except
# the inbound one.
idle_groups() {
  local g cg; cg=$(consumer_group)
  for g in $(kafka_tool kafka-consumer-groups --list 2>/dev/null | grep -E "$GROUP_PATTERN" || true); do
    [ "$g" = "$cg" ] && continue
    group_is_empty "$g" && echo "$g"
  done
}
# What the stopped services would otherwise act on: everything in CCE's output topics, with their
# consumer groups moved to the start of what remains. Options: keep-dlq (leave the dead-letter topic),
# topics-only (leave the groups: between the builds in 'prepare', where the last call resets them).
discard_outputs() {
  local t g opts=" $* "
  for t in $(output_topics); do
    case "$opts" in *" keep-dlq "*) [ "$t" = "$DLQ_TOPIC" ] && continue;; esac
    delete_records_up_to "$t" "$(topic_filled_offsets_json "$t")"
  done
  case "$opts" in *" topics-only "*) return 0;; esac
  for g in $(idle_groups); do reset_group_to_earliest "$g" ""; done
}
snapshot_done() {   # Debezium has finished its initial snapshot (its committed offset no longer says "snapshot")
  local o; o=$(connect_api GET "/connectors/$CONNECTOR/offsets" 2>/dev/null || true)   # Kafka Connect 3.5+
  printf '%s' "$o" | grep -q '"lsn' || return 1
  printf '%s' "$o" | grep -q '"last_snapshot_record":true' && return 0
  ! printf '%s' "$o" | grep -q '"snapshot"'
}
save_topic() {   # $1 = topic, $2 = file name prefix: a copy of its records in STATE_DIR, if it has any
  topic_exists "$1" || return 0
  dump_topic "$1" "$STATE_DIR/$2-$(date -u +%Y%m%d_%H%M%S).txt"
}
# Tables named in the data-pipeline's Debezium connector (the ones ClickHouse is built from).
pipeline_tables() {
  python3 - "$DATA_PIPELINE_DIR/connectors/debezium-postgres-source.json" <<'PY'
import json, re, sys
tables = json.load(open(sys.argv[1]))["config"].get("table.include.list", "")
print(" ".join(m.group(1) for t in tables.split(",") if (m := re.fullmatch(r"\s*public\.([a-z_][a-z0-9_]*)\s*", t))))
PY
}

# The events a replay publishes, rebuilt exactly as the collector published them. raw_payload is
# stored BEFORE the collector's defaults are applied, so re-apply the ones it adds: a correlationid
# when the sender gave none (kept in inbound_event_log.correlation_id) and a time when the sender
# gave none (the receive time). Older collector versions stored some envelope fields only in their
# own columns, so id, source and specversion are also filled in from there when raw_payload lacks
# them. Kafka key = subject, the collector's key (per-patient ordering).
events_sql() {   # $1 = select list, $2 = from, $3 = to, $4 = cutoff, $5 = mode
  local from="${2:-}" to="${3:-}" cutoff="${4:-}" mode="$5" where pt
  where="i.status = 'ACCEPTED'"
  [ -n "$from" ]   && where="$where AND i.received_at >= '$from'::timestamptz"
  [ -n "$to" ]     && where="$where AND i.received_at <  '$to'::timestamptz"
  [ -n "$cutoff" ] && where="$where AND i.received_at <  '$cutoff'::timestamptz"
  if [ "$mode" = "fill-gaps" ]; then
    pt=$(processed_table); [ -n "$pt" ] || die "No table in DROP_TABLES records processed events (cloudevents_id, source): fill-gaps cannot tell what is missing."
    where="$where AND NOT EXISTS (SELECT 1 FROM $pt m WHERE m.cloudevents_id = i.cloudevents_id AND m.source = i.source)"
  fi
  printf 'SELECT %s FROM inbound_event_log i WHERE %s' "$1" "$where"
}
MESSAGE_SELECT="coalesce(nullif(i.raw_payload::jsonb ->> 'subject', ''), '__NULL__') || E'\t' ||
  (i.raw_payload::jsonb
     || CASE WHEN coalesce(i.raw_payload::jsonb ->> 'id', '') = '' AND i.cloudevents_id IS NOT NULL
             THEN jsonb_build_object('id', i.cloudevents_id) ELSE '{}'::jsonb END
     || CASE WHEN coalesce(i.raw_payload::jsonb ->> 'source', '') = '' AND i.source IS NOT NULL
             THEN jsonb_build_object('source', i.source) ELSE '{}'::jsonb END
     || CASE WHEN coalesce(i.raw_payload::jsonb ->> 'specversion', '') = ''
             THEN jsonb_build_object('specversion', '1.0') ELSE '{}'::jsonb END
     || CASE WHEN coalesce(i.raw_payload::jsonb ->> 'correlationid', '') = '' AND i.correlation_id IS NOT NULL
             THEN jsonb_build_object('correlationid', i.correlation_id) ELSE '{}'::jsonb END
     || CASE WHEN coalesce(i.raw_payload::jsonb ->> 'time', '') = ''
             THEN jsonb_build_object('time', to_char(i.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'))
             ELSE '{}'::jsonb END)::text"

subjects_with_history() {   # stdin: patient keys, one per line; $1 = cutoff: those with events received before it
  { echo "CREATE TEMP TABLE replay_keys (subject text);"
    echo "COPY replay_keys FROM STDIN;"
    sed 's/\\/\\\\/g'
    printf '%s\n' '\.'
    echo "SELECT DISTINCT k.subject FROM replay_keys k WHERE EXISTS (SELECT 1 FROM inbound_event_log h
            WHERE h.status = 'ACCEPTED' AND h.raw_payload::jsonb ->> 'subject' = k.subject AND h.received_at < '$1'::timestamptz);"
  } | psql_q
}

# ---- guards ---------------------------------------------------------------------------------------
require_mode() { case "${MODE:-}" in rebuild|fill-gaps) ;; *) die "Give --mode rebuild or --mode fill-gaps.";; esac; }
require_yes() { [ "${YES:-}" = 1 ] || die "This step changes data. Re-run it with --yes once you have read what it does."; }
require_recent_backup() {
  local f; f=$(ls -1t "$STATE_DIR"/ccedb_before_replay_*.dump 2>/dev/null | head -1 || true)
  [ -n "$f" ] || die "No backup found in $STATE_DIR. Run the 'backup' step first."
  [ -n "$(find "$f" -mmin -$((BACKUP_MAX_AGE_HOURS * 60)) 2>/dev/null)" ] \
    || die "The newest backup ($f) is older than ${BACKUP_MAX_AGE_HOURS}h. Run the 'backup' step again."
  ok "backup present: $f"
}
require_stopped() {
  local s st
  for s in "$@"; do
    st=$(service_state "$s")
    [ "$st" = stopped ] || [ "$st" = absent ] || die "$s is $st, not stopped. Its process must have exited before the replay goes on."
  done
}
# Built in, whatever the settings: intelligence (demo-rw image) checks for alerts the moment it starts,
# before notification_tracker's rows are copied back, so an open incident would be alerted again.
require_no_open_incidents() {
  in_list notification_tracker "$DROP_TABLES" && table_exists notification_tracker || return 0
  local n; n=$(sql_value "SELECT count(*) FROM notification_tracker WHERE status = 'ACTIVE'")
  [ "$n" = 0 ] || die "notification_tracker has $n open alert incident(s): rebuilding it now would alert them again. Wait until they are resolved, or take notification_tracker out of DROP_TABLES. Nothing was changed."
}
require_no_foreign_keys_into() {   # $@ = tables to move: none of the tables that stay may point at them
  local moving="$*" blocking
  blocking=$(sql_value "SELECT string_agg(conrelid::regclass || ' -> ' || confrelid::regclass, ', ')
                          FROM pg_constraint WHERE contype = 'f'
                           AND confrelid::regclass::text = ANY (string_to_array('${moving// /,}', ','))
                           AND NOT conrelid::regclass::text = ANY (string_to_array('${moving// /,}', ','))")
  [ -z "$blocking" ] || die "Tables that stay point at tables in DROP_TABLES: $blocking. Add them to DROP_TABLES (or, if they are configuration, to RESTORE_TABLES as well). Nothing was changed."
}

# ---- commands -------------------------------------------------------------------------------------
cmd_check() {
  validate_settings
  log "Deployment '$DEPLOYMENT_NAME' (settings: $CONFIG_FILE): services on $PLATFORM${K8S_NAMESPACE:+, namespace $K8S_NAMESPACE}"
  log "Postgres via '${PG_EXEC:-this host}', Kafka via '${KAFKA_EXEC:-this host}', Kafka Connect via '${CONNECT_EXEC:-this host}'; state in $STATE_DIR"
  local fail=0 v s missing
  if v=$(sql_value "SELECT current_database() || ' / PostgreSQL ' || current_setting('server_version')" 2>&1); then ok "Postgres: $v"; else warn "Postgres: $v"; fail=1; fi
  if old_schema_exists 2>/dev/null; then warn "schema $OLD_SCHEMA exists: old tables from an earlier rebuild (drop-old-tables or revert)"; fi
  if topic_exists "$INBOUND_TOPIC"; then ok "Kafka: $INBOUND_TOPIC reachable, read by consumer group $(consumer_group)"; else warn "Kafka: $INBOUND_TOPIC not reachable (via '${KAFKA_EXEC:-this host}', bootstrap $KAFKA_BOOTSTRAP)"; fail=1; fi
  v=$(foreign_inbound_readers)
  if [ -z "$v" ]; then ok "no other CCE consumer reads $INBOUND_TOPIC"
  else warn "consumer group(s) $v also read $INBOUND_TOPIC with running consumers: stop or remove the service(s) behind them (e.g. 1.x compliance after an upgrade), or add them to SERVICES"; fail=1; fi
  if v=$(connect_api GET "/connectors/$CONNECTOR/status" 2>&1) && [ -n "$v" ]; then ok "Kafka Connect: $(printf '%s' "$v" | grep -oE '"state":"[A-Z]+"' | head -1)"; else warn "Kafka Connect not reachable (via '${CONNECT_EXEC:-this host}', $CONNECT_URL)"; fail=1; fi
  if v=$(ch_query "SELECT version()" 2>&1); then ok "ClickHouse: $v at $CH_HTTP"; else warn "ClickHouse: $v"; fail=1; fi
  command -v python3 >/dev/null || { warn "python3 is not installed on this host (rebuild-clickhouse needs it)"; fail=1; }
  if [ -f "$DATA_PIPELINE_DIR/cdc/01-configure-replication.sql" ] && [ -f "$DATA_PIPELINE_DIR/connectors/debezium-postgres-source.json" ]; then
    ok "data-pipeline folder: $DATA_PIPELINE_DIR"
    # A pipeline that captures tables neither in the database nor created by the replay belongs to
    # another release (e.g. 1.x's compliance_event_log against a 2.0 database).
    if command -v python3 >/dev/null; then
      missing=""; for v in $(pipeline_tables); do table_exists "$v" || in_list "$v" "$DROP_TABLES" || missing="$missing $v"; done
      [ -z "$missing" ] || { warn "the data-pipeline captures tables this database does not have:$missing — is it the deployed release's?"; fail=1; }
    fi
  else warn "data-pipeline folder not found at $DATA_PIPELINE_DIR"; fail=1; fi
  log "SERVICES (stopped and started by the replay)"
  for s in $SERVICES; do
    printf '  %-30s %s\n' "$s" "$(service_state "$s")"
    if [ "$(service_state "$s")" = absent ]; then warn "$s is not deployed here"; fail=1; continue; fi
    # How 'prepare' knows a service has started: Spring Boot's "Started ..." line in its log, or the
    # platform's own health signal where it has one (a Docker healthcheck, a Kubernetes readiness probe).
    [ "$(service_health "$s")" != none ] || printf '  %-30s %s\n' "" "(no healthcheck or readiness probe: its start is recognised by its log)"
  done
  missing=""; for v in $DROP_TABLES; do table_exists "$v" || missing="$missing $v"; done
  [ -z "$missing" ] && ok "every table in DROP_TABLES exists" || warn "not in the database (nothing to drop, the services create them):$missing"
  [ "$fail" = 0 ] && ok "all components reachable" || die "Fix the WARN lines (in $CONFIG_FILE or the deployment) before replaying."
}

cmd_status() {
  log "SERVICES ($PLATFORM)"
  local s t; for s in $SERVICES; do printf '  %-30s %s\n' "$s" "$(service_state "$s")"; done
  log "Postgres (rows)"
  printf '  %-34s %s\n' "inbound_event_log (accepted)" "$(sql_value "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")"
  for t in $DROP_TABLES; do printf '  %-34s %s\n' "$t" "$(table_rows "$t")"; done
  printf '  %-34s %s\n' "WAL kept for CDC slot $CDC_SLOT" "$(slot_wal_kept)"
  log "Kafka"
  printf '  %-34s lag %s\n' "$(consumer_group)" "$(group_lag "$(consumer_group)" "$INBOUND_TOPIC")"
  printf '  %-34s %s records\n' "$DLQ_TOPIC" "$(topic_record_count "$DLQ_TOPIC")"
  log "Replay state ($STATE_DIR)"
  printf '  mode=%s  cutoff=%s  published=%s\n' "$(state_get mode)" "$(state_get cutoff)" "$(state_get published)"
  if old_schema_exists; then printf '  old tables kept in schema %s (remove with drop-old-tables once verified)\n' "$OLD_SCHEMA"; fi
}

cmd_plan() {
  require_mode; validate_settings
  log "What a '$MODE' replay would do on '$DEPLOYMENT_NAME' (nothing is changed by this command)"
  local n first last t dir
  IFS='|' read -r n first last < <(sql_value "$(events_sql "count(*), min(i.received_at), max(i.received_at)" "${FROM:-}" "${TO:-}" "" "$MODE")")
  printf '  events to publish            %s\n' "$n"
  printf '  received between             %s  and  %s\n' "${first:-—}" "${last:-—}"
  printf '  window asked for             from %s  to %s\n' "${FROM:-(start)}" "${TO:-(now)}"
  dir="$STATE_DIR"; while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
  printf '  database size                %s  (backup goes to %s: %s free)\n' \
    "$(sql_value "SELECT pg_size_pretty(pg_database_size(current_database()))")" "$STATE_DIR" "$(df -Ph "$dir" | awk 'NR==2 {print $4}')"
  if [ "$MODE" = fill-gaps ]; then
    log "Stopped until 'finish': $(other_services). $(first_service) keeps running and processes the missing events."
    log "Nothing is dropped: only events $(processed_table) has no record of are sent."
    return
  fi
  log "Stopped: $(reverse_services)"
  log "Started once each, in this order, to create their tables: $(words $SCHEMA_ORDER)"
  log "Started again: $(first_service) after 'publish', then $(other_services) in 'finish'"
  log "The cutoff is taken by 'publish'; events received until then are replayed, later ones are live"
  log "Dropped, then created again by the services' migrations when they start:"
  for t in $(tables_to_move); do
    if in_list "$t" "$RESTORE_TABLES"; then printf '  %-34s %8s rows  (data restored)\n' "$t" "$(table_rows "$t")"
    else printf '  %-34s %8s rows\n' "$t" "$(table_rows "$t")"; fi
  done
  log "Every other table stays as it is, including: $(words $NEVER_TOUCHED)"
  log "Kafka topics emptied: $(words $(output_topics)) (prepare; $DLQ_TOPIC is saved to a file first), $INBOUND_TOPIC (publish), cce.public.* (rebuild-clickhouse)"
  if in_list notification_tracker "$DROP_TABLES" && table_exists notification_tracker; then
    n=$(sql_value "SELECT count(*) FROM notification_tracker WHERE status = 'ACTIVE'")
    [ "$n" = 0 ] || warn "notification_tracker has $n open alert incident(s): 'prepare' will refuse until they are resolved"
  fi
  if [ -n "${FROM:-}" ]; then warn "rebuild with --from: history before $FROM is NOT rebuilt (patients' earlier events are left out)"; fi
}

cmd_backup() {
  mkdir -p "$STATE_DIR"
  local f="$STATE_DIR/ccedb_before_replay_$(date -u +%Y%m%d_%H%M%S).dump"
  log "Backing up $PG_DB to $f (read-only pg_dump, services keep running)"
  pg_dump_to "$f"
  [ "$(head -c 5 "$f")" = "PGDMP" ] || die "The backup file is not a valid pg_dump. Do not continue."
  state_set backup "$f"
  ok "backup written: $(du -h "$f" | cut -f1)  $f"
}

cmd_prepare() {
  require_mode; require_yes; validate_settings
  if [ "$MODE" = rebuild ]; then
    old_schema_exists && die "Schema $OLD_SCHEMA already exists: old tables from an earlier rebuild are still there. Run 'drop-old-tables --yes' (if that replay was verified) or 'revert --yes' first."
    require_no_open_incidents
  fi
  require_recent_backup
  state_set consumer_group ""; state_set consumer_group "$(consumer_group)"
  require_no_foreign_inbound_readers
  # The numbers 'report' compares against, taken before anything changes.
  report_facts > "$STATE_DIR/report-before.tsv"; state_set prepare_started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local pt; pt=$(processed_table); state_set processed_table "$pt"
  if [ "$MODE" = fill-gaps ]; then prepare_fill_gaps; else prepare_rebuild; fi
}

prepare_rebuild() {
  local moving t s
  moving=$(tables_to_move)
  [ -n "$moving" ] || die "None of DROP_TABLES exists, and no migration record of SERVICES was found: nothing to rebuild."
  require_no_foreign_keys_into $moving
  log "Stopping $(reverse_services)(the collector keeps accepting events)"
  services_stop $(reverse_services)
  require_stopped $SERVICES
  ok "stopped"
  wait_groups_idle "$(state_get consumer_group)"

  log "Pausing the Debezium connector (ClickHouse is rebuilt afterwards with 'rebuild-clickhouse')"
  connect_api PUT "/connectors/$CONNECTOR/pause" >/dev/null 2>&1 && ok "paused" || warn "could not pause $CONNECTOR — continuing"

  log "Moving DROP_TABLES and the services' migration records to schema $OLD_SCHEMA (one transaction)"
  { echo "BEGIN;"; echo "CREATE SCHEMA $OLD_SCHEMA;"
    for t in $moving; do echo "ALTER TABLE public.$t SET SCHEMA $OLD_SCHEMA;"; done
    echo "COMMIT;"; } | psql_q >/dev/null
  state_set moved "$moving"; state_set returned ""; state_set emptied ""
  ok "moved: $moving"

  log "Emptying Kafka topics (CCE's, except $INBOUND_TOPIC: it is emptied by 'publish')"
  # The inbound topic is NOT touched here and no cutoff is taken yet: the collector keeps publishing,
  # and every live event arriving from now until 'publish' is also in inbound_event_log, so 'publish'
  # replays it in order with the history. Taking the cutoff here would leave those events in the topic
  # AHEAD of the history, and the consumer would process a patient's new event before their old ones.
  topic_exists "$INBOUND_TOPIC" || die "Topic $INBOUND_TOPIC does not exist."
  save_topic "$DLQ_TOPIC" dlq-before-replay   # failures from before the replay: their events are replayed
  discard_outputs
  state_set mode rebuild; state_set cutoff ""; state_set published ""; state_set created ""

  # While a service is up for its migrations, what it produces is for services that are stopped:
  # discard it before the next one starts (else, e.g., intelligence would deliver Matcher's alerts),
  # and after the last one.
  local n=0
  for s in $SCHEMA_ORDER; do
    [ "$n" = 0 ] || discard_outputs topics-only
    build_service_tables "$s"; n=$((n + 1))
  done
  discard_outputs
  ok "emptied what the services produced while they were up"
  empty_rebuilt_tables
  put_back_tables_not_created
  restore_rows
  state_set prepared rebuild
  ok "ready to publish. The cutoff is taken by 'publish': events received before it are replayed, later ones are live"
}

empty_rebuilt_tables() {   # what the services processed while up for their migrations is thrown away
  # While a service ran to create its tables, the consumer read the live events waiting in the inbound
  # topic, against empty tables and out of order with the history. Those events are all in
  # inbound_event_log, so 'publish' replays them in order; their rows here must go. This also clears
  # any rows the migrations seeded, so the restored rows cannot collide with them.
  local t list=""
  for t in $(state_get created); do case "$t" in flyway_schema_history_*) ;; *) list="$list $t";; esac; done
  [ -n "$(words $list)" ] || return 0
  sql_value "TRUNCATE TABLE $(table_list_sql $list) RESTART IDENTITY" >/dev/null
  ok "emptied the rebuilt tables (rows written while the services were up for their migrations)"
}

prepare_fill_gaps() {
  # The first service keeps running and keeps its place in the topic: fill-gaps only adds events it
  # never recorded. The others are paused so what the old events make them do can be discarded.
  local first cg; first=$(first_service); cg=$(state_get consumer_group)
  [ "$(service_state "$first")" = running ] || die "$first must be running for fill-gaps."
  # '-' = the group has committed no offset yet (e.g. a service just brought back after a revert, with
  # nothing new since): no lag, as long as the topic holds nothing it could still have to read.
  local lag; lag=$(group_lag "$cg" "$INBOUND_TOPIC")
  [ "$lag" = 0 ] || { [ "$lag" = "-" ] && [ "$(topic_record_count "$INBOUND_TOPIC")" = 0 ]; } \
    || die "$cg has lag ($lag) — let it catch up before filling gaps."
  [ -n "$(processed_table)" ] || die "No table in DROP_TABLES records processed events (cloudevents_id, source): fill-gaps cannot tell what is missing."
  log "Stopping $(other_services) (what the replayed events make them do is discarded in 'finish')"
  services_stop $(other_services); require_stopped $(other_services)
  ok "stopped"
  # Leave the last 10 minutes alone: an event that recent may still be on its way through.
  local cutoff; cutoff=$(sql_value "$(now_utc_sql "- interval '10 minutes'")")
  state_set mode fill-gaps; state_set cutoff "$cutoff"; state_set published ""; state_set prepared fill-gaps
  ok "ready to publish. cutoff = $cutoff UTC (only events received before this, and never recorded in $(processed_table))"
}

build_service_tables() {   # $1 = service: start it so its migrations create its tables, then stop it
  local service="$1" started
  if [ "$(service_state "$service")" = absent ]; then warn "$service is not deployed here"; return; fi
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  BUILD_TABLES_BEFORE=$(public_tables)
  log "Starting $service so it creates its tables"
  services_start --no-wait "$service"
  wait_for_service_start "$service" "$started"
  local created; created=$(record_created_tables)
  ok "$service started${created:+; created: $created}"
  log "Stopping $service again"
  services_stop "$service"; require_stopped "$service"
}

public_tables() { sql_value "SELECT string_agg(tablename, ' ') FROM pg_tables WHERE schemaname = 'public'"; }
# Every table that appeared since BUILD_TABLES_BEFORE, whether or not it existed before the rebuild
# (a 1.x -> 2.0 upgrade creates tables 1.x never had, e.g. matcher_event_log): these are what the
# replay empties, and what 'revert' removes. Prints the new ones.
record_created_tables() {
  local t new=""
  for t in $(public_tables); do
    in_list "$t" "$BUILD_TABLES_BEFORE" || in_list "$t" "$(state_get created)" || new="$new $t"
  done
  state_set created "$(words $(state_get created) $new)"
  words $new
}

# Tables the services created that the old data never had (e.g. 2.0's matcher_event_log in a 1.x -> 2.0
# upgrade): '' for a replay on the same release. Read from what 'prepare' recorded, so it also holds
# when 'prepare' stopped partway.
new_release_tables() {
  local t out=""
  for t in $(state_get created); do in_list "$t" "$(state_get moved)" || out="$out $t"; done
  words $out
}

own_ledger() {   # cce-protocol-service -> flyway_schema_history_protocol (same rule as service_ledgers)
  local ledger short
  for ledger in $(sql_value "SELECT string_agg(tablename, ' ') FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'flyway_schema_history_%'"); do
    in_list "$ledger" "$NEVER_TOUCHED" && continue
    short="${ledger#flyway_schema_history_}"; short="${short//_/-}"
    case "$1" in *"$short"*) echo "$ledger"; return;; esac
  done
  short="${1#cce-}"; short="${short%-service}"; echo "flyway_schema_history_${short//-/_}"
}
# Its own migrations ran to the end: its ledger exists, every row succeeded, and Flyway said so.
own_migrations_done() {   # $1 = service, $2 = its log since it started
  local ledger; ledger=$(own_ledger "$1")
  table_exists "$ledger" || return 1
  [ "$(sql_value "SELECT count(*) FILTER (WHERE success) > 0 AND count(*) FILTER (WHERE NOT success) = 0 FROM public.$ledger")" = t ] || return 1
  printf '%s' "$2" | grep -qE 'Successfully applied [0-9]+ migration|is up to date'
}

wait_for_service_start() {   # $1 = service, $2 = start time: until it has started (or failed)
  local service="$1" started="$2" waited=0 logs t ledgers
  # The migration records to watch: the ones moved aside (their services create them again) and the
  # service's own, which may be new (an upgrade creates records the old release never had).
  ledgers="$(state_get moved) $(own_ledger "$service")"
  while :; do
    logs=$(service_logs "$service" "$started")
    if printf '%s' "$logs" | grep -qE 'APPLICATION FAILED TO START|Application run failed'; then
      # A service can create its tables and still fail to start because it checks tables a LATER
      # service creates (2.0 Protocol validates a sequence only Matcher's V6 sets up). Its tables exist,
      # which is all this step needs; it starts normally in 'finish', once every table is there.
      if own_migrations_done "$service" "$logs"; then
        warn "$service created its tables but did not start (it needs a later service's tables; it starts in 'finish')"
        return
      fi
      service_build_failed "$service" "$started" "it failed to start"
    fi
    for t in $ledgers; do
      case "$t" in flyway_schema_history_*) ;; *) continue;; esac
      table_exists "$t" || continue
      [ -z "$(sql_value "SELECT string_agg(version || ' ' || description, ', ') FROM public.$t WHERE NOT success")" ] \
        || service_build_failed "$service" "$started" "a migration failed (see $t)"
      [ "$(sql_value "SELECT count(*) FROM public.$t WHERE type = 'BASELINE' AND version <> '0'")" = 0 ] \
        || service_build_failed "$service" "$started" "Flyway recorded a baseline above 0 in $t, so it skipped the first migrations. Set the service's Flyway baseline version to 0"
    done
    # Started: Spring Boot logs "Started <Application> in N seconds" once Flyway, Hibernate and the
    # rest are done. Where the platform has a health signal (a Docker healthcheck, a Kubernetes
    # readiness probe through the application), that counts too: it only passes once the app is up.
    if printf '%s' "$logs" | grep -qE 'Started [A-Za-z0-9]+ in [0-9.]+ seconds'; then return; fi
    if [ "$(service_health "$service")" = healthy ]; then return; fi
    waited=$((waited + 5))
    [ "$waited" -le "$SERVICE_START_TIMEOUT" ] || service_build_failed "$service" "$started" "it did not finish starting within ${SERVICE_START_TIMEOUT}s"
    sleep 5
  done
}

service_build_failed() {   # $1 = service, $2 = start time, $3 = reason
  record_created_tables >/dev/null || true   # what its migrations did create, so 'revert' removes it
  printf '\n  Lines of %s since it started that mention Flyway, migrations or errors:\n' "$1" >&2
  service_logs "$1" "$2" | grep -iE 'flyway|migration|error|caused by' | grep -v '^\s*at ' | tail -8 | cut -c1-220 | sed 's/^/    /' >&2 || true
  services_stop "$1" >/dev/null 2>&1 || true
  die "$1 could not create its tables: $3. It is stopped. The old tables are safe in schema $OLD_SCHEMA; undo with 'revert --yes'. Usual causes: a migration that fails on an empty database (e.g. Matcher's V2 without the missed_date fix), a table the service's migrations create missing from DROP_TABLES ('already exists'), Flyway turned off or not allowed to baseline (SPRING_FLYWAY_ENABLED, SPRING_FLYWAY_BASELINE_ON_MIGRATE), or a Flyway baseline other than 0."
}

old_fk_neighbours() {   # $1 = table in $OLD_SCHEMA: the $OLD_SCHEMA tables it has a foreign key to or from
  sql_value "SELECT string_agg(DISTINCT replace(other, '$OLD_SCHEMA.', ''), ' ') FROM (
               SELECT confrelid::regclass::text AS other FROM pg_constraint WHERE contype = 'f' AND conrelid = '$OLD_SCHEMA.$1'::regclass
               UNION SELECT conrelid::regclass::text FROM pg_constraint WHERE contype = 'f' AND confrelid = '$OLD_SCHEMA.$1'::regclass) x
              WHERE other LIKE '$OLD_SCHEMA.%'"
}
put_back_tables_not_created() {   # tables no service created: back as they were (emptied, unless restored)
  local t n returned="" emptied="" kept="" candidates="" changed=1
  for t in $(state_get moved); do
    table_exists "$t" && continue
    old_table_exists "$t" && candidates="$candidates $t"
  done
  # A table tied by a foreign key to an old table the services created again (or to one kept here)
  # belongs to the old data model, which the deployed release rebuilt without it (1.x -> 2.0:
  # compliance_event_log, which 1.x step_instance points at). It stays in $OLD_SCHEMA with the
  # tables it is tied to: 'revert' puts it back with them, 'drop-old-tables' deletes it with them.
  while [ "$changed" = 1 ]; do
    changed=0
    for t in $candidates; do
      in_list "$t" "$kept" && continue
      for n in $(old_fk_neighbours "$t"); do
        if table_exists "$n" || in_list "$n" "$kept"; then kept="$kept $t"; changed=1; break; fi
      done
    done
  done
  for t in $candidates; do
    in_list "$t" "$kept" && continue
    sql_value "ALTER TABLE $OLD_SCHEMA.$t SET SCHEMA public" >/dev/null
    returned="$returned $t"
    case "$t" in flyway_schema_history_*) continue;; esac
    in_list "$t" "$RESTORE_TABLES" || emptied="$emptied $t"
  done
  [ -z "$emptied" ] || sql_value "TRUNCATE TABLE $(table_list_sql $emptied) RESTART IDENTITY" >/dev/null
  state_set returned "$returned"; state_set emptied "$emptied"
  [ -z "$returned" ] || ok "not created by any of SERVICES, put back as they were:$returned${emptied:+ (emptied:$emptied)}"
  [ -z "$kept" ] || ok "not created by any of SERVICES and tied by a foreign key to the old tables, so kept with them in $OLD_SCHEMA:$kept"
}

restore_rows() {   # copy RESTORE_TABLES' old rows into the tables the services created, by column name
  local t columns n_new n_old
  for t in $RESTORE_TABLES; do
    in_list "$t" "$(state_get returned)" && continue
    table_exists "$t" && old_table_exists "$t" || continue
    columns=$(sql_value "SELECT string_agg(quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position)
                           FROM information_schema.columns n JOIN information_schema.columns o
                             ON o.table_schema = '$OLD_SCHEMA' AND o.table_name = '$t' AND o.column_name = n.column_name
                          WHERE n.table_schema = 'public' AND n.table_name = '$t'")
    # OVERRIDING SYSTEM VALUE keeps the old ids of identity columns, so rows that point at them still match.
    sql_value "INSERT INTO public.$t ($columns) OVERRIDING SYSTEM VALUE SELECT $columns FROM $OLD_SCHEMA.$t" >/dev/null \
      || die "$t: putting its data back failed (see the error above). Undo with 'revert --yes'."
    n_new=$(table_rows "$t"); n_old=$(sql_value "SELECT count(*) FROM $OLD_SCHEMA.$t")
    [ "$n_new" = "$n_old" ] || die "$t: put back $n_new rows, the old table has $n_old. Undo with 'revert --yes'."
    # The rebuilt table's sequences start at 1; move them past the restored ids, or the service's next
    # insert collides with a restored row (duplicate key).
    sql_value "SELECT count(setval(pg_get_serial_sequence('public.$t', a.attname),
                 coalesce((xpath('/row/m/text()', query_to_xml(format('select max(%I) as m from public.%I', a.attname, '$t'),
                   false, true, '')))[1]::text::bigint, 0) + 1, false))
                 FROM pg_attribute a
                WHERE a.attrelid = 'public.$t'::regclass AND a.attnum > 0 AND NOT a.attisdropped
                  AND pg_get_serial_sequence('public.$t', a.attname) IS NOT NULL" >/dev/null
    ok "$t: $n_new rows restored"
  done
}

cmd_publish() {
  MODE="${MODE:-$(state_get mode)}"; require_mode; validate_settings
  [ "$(state_get prepared)" = "$MODE" ] || die "No '$MODE' prepare recorded. Run 'prepare --mode $MODE --yes' first."
  # Publishing twice would send the same events twice. After a publish (finished or not), the way
  # back is 'prepare' again, which starts the replay's Kafka side from clean.
  local previous; previous=$(state_get published)
  [ -z "$previous" ] || die "Events were already published after the last 'prepare' (published=$previous). Publishing again would send them twice. If that publish finished, go on with 'wait'. If it failed partway: rebuild — 'revert --yes', then start again from 'backup'; fill-gaps — run 'wait', then 'prepare --mode fill-gaps --yes' again, then 'publish'."
  local s; for s in $(other_services); do [ "$(service_state "$s")" != running ] || die "$s is running — run 'prepare' first."; done
  require_no_foreign_inbound_readers
  local cutoff window_start="" inbound_end=""
  mkdir -p "$STATE_DIR"
  topic_exists "$INBOUND_TOPIC" || die "Topic $INBOUND_TOPIC does not exist."
  if [ "$MODE" = rebuild ]; then
    require_stopped "$(first_service)"
    wait_groups_idle "$(state_get consumer_group)"
    # The cutoff is taken HERE, right before sending, so every live event received until now is part
    # of the replay and goes out in order with the history. Note where the inbound topic ends, THEN take
    # the cutoff, THEN delete only up to the noted positions: every event deleted was stored before the
    # cutoff (so it is replayed), and every event left in the topic, or arriving from now on, is live.
    # None is lost. From here until the history is sent, live events land in the topic AHEAD of it, so
    # only what must come first is done in between; the rest waits until after sending.
    window_start=$(sql_value "$(now_utc_sql)")
    inbound_end=$(topic_end_offsets "$INBOUND_TOPIC")
    cutoff=$(sql_value "$(now_utc_sql)")
    delete_records_up_to "$INBOUND_TOPIC" "$(offsets_json "$INBOUND_TOPIC" "$inbound_end")"
    state_set cutoff "$cutoff"
    ok "cutoff = $cutoff UTC (events received before this are replayed; later ones are processed live)"
  else
    cutoff=$(state_get cutoff)
    [ -n "$cutoff" ] || die "No cutoff recorded. Run the 'prepare' step first."
  fi
  local expected before_offsets before after publish_started sent sent_file="$STATE_DIR/publish-sent" producer_log="$STATE_DIR/publish-producer.log"
  expected=$(sql_value "$(events_sql "count(*)" "${FROM:-}" "${TO:-}" "$cutoff" "$MODE")")
  if [ "$expected" -eq 0 ] && [ -n "${FROM:-}" ] && [ "$(sql_value "SELECT timestamptz '$FROM' >= timestamptz '$cutoff'")" = t ]; then
    die "--from ($FROM) is not before the cutoff ($cutoff). Fill-gaps leaves out the last 10 minutes: wait until 10 minutes after --from, then run 'prepare --mode fill-gaps --yes' again."
  fi
  [ "$expected" -gt 0 ] || die "No events match (mode=$MODE from=${FROM:-start} to=${TO:-now} cutoff=$cutoff)."
  before_offsets=$(topic_end_offsets "$INBOUND_TOPIC"); before=$(offsets_total "$before_offsets")
  publish_started=$(sql_value "$(now_utc_sql)")
  state_set published "started, not finished"
  rm -f "$sent_file"
  log "Publishing $expected events to $INBOUND_TOPIC in the order CCE received them (mode=$MODE)"
  if ! sql_value "$(events_sql "$MESSAGE_SELECT" "${FROM:-}" "${TO:-}" "$cutoff" "$MODE") ORDER BY i.received_at, i.id" \
      | awk -v f="$sent_file" '{print} END {print NR > f}' \
      | kafka_run kafka-console-producer --topic "$INBOUND_TOPIC" \
          --property parse.key=true --property "key.separator=$(printf '\t')" --property null.marker=__NULL__ \
          --producer-property acks=all --producer-property enable.idempotence=true \
          --producer-property max.in.flight.requests.per.connection=5 --producer-property linger.ms=10 \
          2> "$producer_log"; then
    tail -20 "$producer_log" >&2
    die "Publishing failed (the producer's log is above, in full in $producer_log). Some events may have been sent. Undo with 'revert --yes' (fill-gaps: 'prepare' again), fix the cause, and start again."
  fi
  # The console producer reports a record it could not send on stderr and carries on: any such line
  # means an event is missing. (Live events arriving meanwhile make the topic grow too, so its growth
  # alone could hide one.)
  if grep -qE '\bERROR\b|Error when sending' "$producer_log"; then
    grep -E '\bERROR\b|Error when sending' "$producer_log" | head -10 >&2
    die "The producer could not send some events (above; full log in $producer_log). Do not continue: undo with 'revert --yes' (fill-gaps: 'prepare' again), fix the cause, and start again."
  fi
  local publish_ended; publish_ended=$(sql_value "$(now_utc_sql)")   # events received from now on come after the history
  sent=$(cat "$sent_file" 2>/dev/null || echo 0)
  [ "$sent" = "$expected" ] || die "$sent events were handed to the producer, but $expected were selected. Do not continue."
  after=$(topic_end_total "$INBOUND_TOPIC")
  [ $((after - before)) -ge "$expected" ] \
    || die "Kafka took $((after - before)) records but $expected were sent. Check the output above; do not continue."
  state_set published "$expected"; state_set published_at "$publish_started"
  ok "published $expected events (topic grew by $((after - before)); any extra are live events)"
  if [ "$MODE" = rebuild ]; then
    reset_group_to_earliest "$(state_get consumer_group)" "$INBOUND_TOPIC"
    # A live event can sit in the topic ahead of an older event of the same patient:
    #  - one that landed between the cutoff and the start of sending — exactly the records between
    #    the noted end and the end just before sending, read here. Some were received before the
    #    cutoff (the collector stamps received_at before it validates and publishes), so they are also
    #    replayed, and the first service keeps the first copy it sees: this one, out of order;
    #  - one received between the cutoff and the end of sending, which may have reached the topic among
    #    the history (seconds), found by its receive time.
    # List those patients, if they have history, so they can be checked after 'wait'.
    local window_file="$STATE_DIR/publish-window-subjects.txt" ahead_keys="$STATE_DIR/publish-ahead-keys.txt" n
    keys_between "$INBOUND_TOPIC" "$inbound_end" "$before_offsets" > "$ahead_keys"
    { sql_value "SELECT DISTINCT i.raw_payload::jsonb ->> 'subject' FROM inbound_event_log i
                  WHERE i.status = 'ACCEPTED' AND i.received_at >= '$window_start'::timestamptz
                    AND i.received_at < '$publish_ended'::timestamptz
                    AND EXISTS (SELECT 1 FROM inbound_event_log h WHERE h.status = 'ACCEPTED'
                                 AND h.raw_payload::jsonb ->> 'subject' = i.raw_payload::jsonb ->> 'subject'
                                 AND h.received_at < '$cutoff'::timestamptz)"
      if [ -s "$ahead_keys" ]; then subjects_with_history "$cutoff" < "$ahead_keys"; fi
    } | grep . | sort -u > "$window_file" || true
    n=$(grep -c . "$window_file" || true)
    if [ "$n" -gt 0 ]; then warn "$n patient(s) got a live event ahead of their history; their order is not guaranteed — check them after 'wait' ($window_file)"
    else ok "no live event arrived for a replayed patient ahead of their history"; fi
  fi
  local first; first=$(first_service)
  if [ "$(service_state "$first")" != running ]; then log "Starting $first"; services_start "$first"; ok "started — now run the 'wait' step"; fi
}

cmd_wait() {
  local published cg pt first; published=$(state_get published); cg=$(consumer_group); pt=$(processed_table); first=$(first_service)
  [ -n "$published" ] || die "Nothing published yet. Run the 'publish' step first."
  [ "$published" != "started, not finished" ] || die "The last publish did not finish, so some events may be missing. Rebuild: 'revert --yes', then start again from 'backup'. Fill-gaps: run 'prepare --mode fill-gaps --yes' again 10 minutes from now, then 'publish'."
  log "Waiting for $first to process everything (checks every 15 s; Ctrl-C is safe, re-run to keep watching)"
  local stable=0 lag processed="" progress_sql="" s
  [ -n "$pt" ] && column_exists "$pt" received_at \
    && progress_sql="SELECT count(*) FROM $pt WHERE received_at >= '$(state_get published_at)'::timestamptz"
  while :; do
    lag=$(group_lag "$cg" "$INBOUND_TOPIC")
    [ -z "$progress_sql" ] || processed=$(sql_value "$progress_sql")
    log "  lag=$lag${progress_sql:+   recorded in $pt since publishing began=$processed} (published $published)   WAL kept for CDC=$(slot_wal_kept)"
    if [ "$lag" = 0 ]; then stable=$((stable + 1)); [ "$stable" -ge 4 ] && break; else stable=0; fi
    [ "$(service_state "$first")" != stopped ] || die "$first is not running."
    # The other services start only in 'finish'. One started by hand (or by a re-applied manifest) while
    # the history is being processed acts on it half-done: e.g. the deadline service judges steps whose
    # completing event is still in the topic, and records false OVERDUE / MISSED deviations.
    for s in $(other_services); do
      [ "$(service_state "$s")" != running ] || die "$s was started during the replay: it may be acting on a half-processed history (e.g. judging deadlines before their completing events are processed). Revert ('revert --yes'), then start again from 'prepare'."
    done
    sleep 15
  done
  ok "$first has caught up (lag 0 for a minute). $DLQ_TOPIC now holds $(topic_record_count "$DLQ_TOPIC") records."
}

cmd_finish() {
  require_yes
  local cg s mode n published; cg=$(consumer_group); mode=$(state_get mode); published=$(state_get published)
  # Publishing must be over: in fill-gaps the first service consumes while 'publish' sends, so its lag
  # can read 0 between batches with part of the history still to come.
  [ -n "$published" ] || die "Nothing published yet. Run the 'publish' step first."
  [ "$published" != "started, not finished" ] || die "'publish' has not finished (or failed): events may still be on their way. Let it finish, then run 'wait' until it reports caught up."
  [ "$(group_lag "$cg" "$INBOUND_TOPIC")" = 0 ] || die "$cg still has lag — run the 'wait' step until it reports caught up."
  for s in $(other_services); do [ "$(service_state "$s")" != running ] || die "$s is running; it may already have acted on what the replayed events produced."; done
  log "Discarding what the replayed events produced for the other services, so nothing is sent again"
  # The dead-letter topic stays: it holds the events the first service gave up on, to look at.
  discard_outputs keep-dlq
  n=$(topic_record_count "$DLQ_TOPIC")
  if [ "$n" != 0 ]; then
    save_topic "$DLQ_TOPIC" dlq-after-replay
    warn "$DLQ_TOPIC holds $n record(s): events $(first_service) gave up on. They stay in the topic; a copy is in $STATE_DIR (dlq-after-replay-*.txt)"
  fi
  log "Starting $(other_services)"
  services_start $(other_services)
  if [ "$mode" = rebuild ]; then ok "started. Next: 'rebuild-clickhouse --yes', then 'verify'"
  else ok "started. Next: 'verify' (ClickHouse picks fill-gaps changes up through CDC as usual)"; fi
}

cmd_rebuild_clickhouse() {
  require_yes
  [ "$(state_get mode)" = rebuild ] || [ -n "${REVERTING:-}" ] || warn "last prepare was not a rebuild — ClickHouse normally needs no rebuild after fill-gaps"
  local dp="$DATA_PIPELINE_DIR" f t missing
  [ -f "$dp/cdc/01-configure-replication.sql" ] || die "data-pipeline folder not found at $dp."
  [ -n "$CH_PASSWORD" ] || die "No ClickHouse password (set CH_PASSWORD/CLICKHOUSE_PASSWORD, or SECRETS_FILE in $CONFIG_FILE)."
  for f in $CH_SCHEMA_FILES; do [ -f "$dp/schema/$f.sql" ] || die "ClickHouse schema file $dp/schema/$f.sql not found. Nothing was changed."; done
  # The pipeline must be the deployed release's: one that captures tables this database does not have
  # (1.x's compliance_event_log against a 2.0 database) would build a ClickHouse Insights cannot read.
  missing=""; for t in $(pipeline_tables); do table_exists "$t" || missing="$missing $t"; done
  [ -z "$missing" ] || die "The data-pipeline at $dp captures tables this database does not have:$missing. Point DATA_PIPELINE_DIR (in $CONFIG_FILE) at the deployed release's data-pipeline. Nothing was changed."
  # The schema's Kafka tables take their broker from this server-side setting; without it the
  # re-created tables would never read Kafka. Check before anything is dropped.
  [ "$(ch_query "SELECT count() FROM system.named_collections WHERE name = '$CH_NAMED_COLLECTION'" 2>/dev/null)" = 1 ] \
    || die "ClickHouse at $CH_HTTP has no '$CH_NAMED_COLLECTION' named collection (or $CH_USER may not read it). Nothing was changed."
  # Keep the connector's current configuration: its connection details are reused in step 6, so no CDC
  # credentials are needed. (Kept from an earlier run if the connector is already gone.)
  mkdir -p "$STATE_DIR"
  local saved_config="$STATE_DIR/connector-config.json" current_config
  current_config=$(connect_api GET "/connectors/$CONNECTOR/config" || true)
  if printf '%s' "$current_config" | grep -q '"connector.class"'; then
    ( umask 077; printf '%s' "$current_config" > "$saved_config" )
    ok "connector configuration saved to $saved_config"
  elif [ -s "$saved_config" ]; then
    ok "connector is gone; using the configuration saved earlier ($saved_config)"
  else
    warn "no connector configuration found; step 6 registers it from data-pipeline (needs the CDC_* credentials)"
  fi

  log "1/7 Stopping Insights ($( [ -n "$(words $INSIGHTS_SERVICES)" ] && words $INSIGHTS_SERVICES || echo none configured)) while ClickHouse is rebuilt"
  # Only the ones running now are started again in 7/7: one that was already stopped stays stopped.
  # Recorded once, so a re-run after a failure still knows what was running before the first attempt.
  local s running=""
  if [ ! -f "$STATE_DIR/insights_running" ]; then
    for s in $INSIGHTS_SERVICES; do [ "$(service_state "$s")" = running ] && running="$running $s"; done
    state_set insights_running "$(words $running)"
  fi
  running=$(state_get insights_running)
  services_stop $running
  ok "stopped: ${running:-none running} (started again in 7/7, once the copy has settled)"

  log "2/7 Removing the Debezium connector, its stored offsets and its replication slot"
  connect_api PUT "/connectors/$CONNECTOR/stop" >/dev/null || true
  sleep 5
  connect_api DELETE "/connectors/$CONNECTOR/offsets" >/dev/null || true
  connect_api DELETE "/connectors/$CONNECTOR" >/dev/null || true
  sleep 3
  sql_value "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$CDC_SLOT' AND NOT active;" >/dev/null
  [ "$(sql_value "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$CDC_SLOT'")" = 0 ] \
    || die "Replication slot $CDC_SLOT still exists (still in use?)."
  ok "connector and slot removed"

  log "3/7 Dropping ClickHouse database $CH_DB and emptying the CDC topics"
  ch_query "DROP DATABASE IF EXISTS $CH_DB SYNC" >/dev/null
  for t in $(kafka_tool kafka-topics --list 2>/dev/null | grep '^cce\.public\.' || true); do
    delete_records_up_to "$t" "$(topic_filled_offsets_json "$t")"
  done
  ok "dropped and emptied"

  log "4/7 Re-applying CDC settings on Postgres ($dp/cdc/01-configure-replication.sql)"
  psql_q < "$dp/cdc/01-configure-replication.sql" >/dev/null
  ok "publication tables: $(sql_value "SELECT count(*) FROM pg_publication_tables WHERE pubname = '$CDC_PUBLICATION'")"

  log "5/7 Applying the ClickHouse schema"
  ( cd "$dp" && CH_HTTP="$CH_HTTP" CH_USER="$CH_USER" CLICKHOUSE_USER="$CH_USER" CLICKHOUSE_PASSWORD="$CH_PASSWORD" \
      CH_DB="$CH_DB" CLICKHOUSE_DB="$CH_DB" python3 scripts/apply-schema.py schema $CH_SCHEMA_FILES ) | sed 's/^/  /'

  log "6/7 Registering the connector (full snapshot of the rebuilt Postgres)"
  if [ -s "$saved_config" ]; then
    # What the connector captures comes from the data-pipeline's connector file, so it matches the
    # schema now deployed. Only the values the file leaves as ${...} placeholders (host, database,
    # user, password) are taken from the saved configuration, so no CDC credentials are needed.
    local merged="$STATE_DIR/connector-config-new.json" missing_keys
    missing_keys=$(umask 077; python3 - "$dp/connectors/debezium-postgres-source.json" "$saved_config" "$merged" <<'PY'
import json, sys
wanted = json.load(open(sys.argv[1]))["config"]
saved = json.load(open(sys.argv[2]))
merged, missing = {}, []
for key, value in wanted.items():
    if isinstance(value, str) and "${" in value:
        if key in saved: merged[key] = saved[key]
        else: missing.append(key)
    else:
        merged[key] = value
json.dump(merged, open(sys.argv[3], "w"))
print(" ".join(missing))
PY
)
    [ -z "$missing_keys" ] || die "The saved connector configuration has no value for: $missing_keys. Register the connector with data-pipeline/scripts/register-connectors.sh (needs the CDC_* settings)."
    connect_api PUT "/connectors/$CONNECTOR/config" json < "$merged" | grep -q '"name"' \
      || die "Kafka Connect refused the connector configuration ($merged). Register it with data-pipeline/scripts/register-connectors.sh."
    ok "connector $CONNECTOR created again: tables from the data-pipeline, connection from its previous configuration"
  else
    # register-connectors.sh runs on this host, so it needs Kafka Connect's address as seen from here.
    local reg_url="$CONNECT_URL"; [ -n "${CONNECT_HOST_URL:-}" ] && reg_url="$CONNECT_HOST_URL"
    ( cd "$dp" && CONNECT_URL="$reg_url" bash scripts/register-connectors.sh ) 2>&1 | grep -viE 'password' | sed 's/^/  /'
  fi
  ok "snapshot started"

  log "7/7 Waiting for the snapshot to settle, then backfilling past days and starting Insights (up to ${CH_SETTLE_MINUTES} min)"
  # Settled, checked every 15 s: either the rows in ClickHouse are unchanged for 3 checks (a quiet
  # system), or Debezium has finished its snapshot and ClickHouse only grows at the live rate (under
  # a twentieth of its fastest growth during the copy) for 2 checks — live events keep adding rows, so
  # on a busy system "unchanged" may never come.
  local prev="" cur growth peak=0 quiet=0 live=0 settled="" i snap
  for i in $(seq 1 $((CH_SETTLE_MINUTES * 4))); do
    cur=$(ch_query "SELECT sum(total_rows) FROM system.tables WHERE database = '$CH_DB' AND engine LIKE '%MergeTree'" 2>/dev/null | tr -d '[:space:]' || true)
    if snapshot_done; then snap="snapshot done"; else snap="snapshot running"; fi
    log "  rows in ClickHouse: ${cur:-?} ($snap)"
    if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" != 0 ] && [ -n "$prev" ]; then
      growth=$((cur - prev)); [ "$growth" -ge 0 ] || growth=$((-growth))   # merges can lower the count a little
      [ "$growth" -le "$peak" ] || peak=$growth
      if [ "$growth" = 0 ]; then quiet=$((quiet + 1)); else quiet=0; fi
      if [ "$snap" = "snapshot done" ] && [ $((growth * 20)) -le "$peak" ]; then live=$((live + 1)); else live=0; fi
      if [ "$quiet" -ge 3 ] || [ "$live" -ge 2 ]; then settled=1; break; fi
    fi
    [[ "$cur" =~ ^[0-9]+$ ]] && prev="$cur"
    sleep 15
  done
  if [ -n "$settled" ]; then
    ok "copy settled"
    cmd_backfill_clickhouse || warn "the backfill had failures (above); past days' compliance KPIs may be incomplete — fix and run 'backfill-clickhouse'"
    services_start $running
    rm -f "$STATE_DIR/insights_running"
    if [ -n "$running" ]; then
      ok "Insights started again: $running — run 'verify'; the step counts must match"
    else
      ok "Insights not started: none of INSIGHTS_SERVICES was running before step 1/7 (start them with '\$R service start <name>' if wanted) — run 'verify'; the step counts must match"
    fi
  else
    warn "the copy had not settled after ${CH_SETTLE_MINUTES} min; the backfill was not run and Insights is left stopped. Once 'verify' shows '— match': \$R backfill-clickhouse, then \$R service start <name> (${running:-none was running})"
  fi
}

# The daily compliance KPIs (mv_daily_compliance_kpis) are a snapshot the view takes of TODAY only, so a
# rebuilt ClickHouse has no past days for them. schema/09 refills the current-state rollups (the view
# reads them), then rebuilds every past day from the base tables' clinical and deadline times
# (enrolled_at, completed_at, the SLA thresholds), which a replay does not move (the other daily KPIs
# rebuild themselves from the clinical event time — see schema/09's header). Run after every ClickHouse
# rebuild; safe to repeat.
cmd_backfill_clickhouse() {
  local file="$DATA_PIPELINE_DIR/schema/09-historical-backfill.sql" from to
  [ -f "$file" ] || { warn "no $file in this data-pipeline: backfill skipped"; return 0; }
  [ -n "$CH_PASSWORD" ] || die "No ClickHouse password (set CH_PASSWORD/CLICKHOUSE_PASSWORD, or SECRETS_FILE in $CONFIG_FILE)."
  from=$(sql_value "SELECT coalesce(to_char(min(received_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD'), to_char(now(), 'YYYY-MM-DD')) FROM inbound_event_log")
  to=$(date -u +%Y-%m-%d)
  log "Backfilling past days of the daily compliance KPIs ($from .. $to, schema/09)"
  # ClickHouse's HTTP interface takes one statement per request, so the file is split (comment- and
  # quote-aware) and each statement sent with the date parameters.
  BACKFILL_FILE="$file" FROM_DATE="$from" TO_DATE="$to" CH_HTTP="$CH_HTTP" CH_USER="$CH_USER" \
  CH_PASSWORD="$CH_PASSWORD" CH_DB="$CH_DB" python3 - <<'PY' || return 1
import os, urllib.request, urllib.parse, urllib.error

def strip_comments(s):
    out, i, n, inq = [], 0, len(s), None
    while i < n:
        c = s[i]
        if inq:
            out.append(c)
            if c == inq: inq = None
            i += 1; continue
        if c in ("'", "`"):
            inq = c; out.append(c); i += 1; continue
        if c == '-' and i + 1 < n and s[i + 1] == '-':
            while i < n and s[i] != '\n': i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'): i += 1
            i += 2; continue
        out.append(c); i += 1
    return "".join(out)

def split_stmts(s):
    stmts, cur, inq = [], [], None
    for c in s:
        if inq:
            cur.append(c)
            if c == inq: inq = None
            continue
        if c in ("'", "`"):
            inq = c; cur.append(c); continue
        if c == ';':
            stmts.append("".join(cur).strip()); cur = []; continue
        cur.append(c)
    if "".join(cur).strip(): stmts.append("".join(cur).strip())
    return [x for x in stmts if x]

base = os.environ["CH_HTTP"].rstrip("/") + "/"
params = {"database": os.environ["CH_DB"], "param_from_date": os.environ["FROM_DATE"],
          "param_to_date": os.environ["TO_DATE"]}
headers = {"X-ClickHouse-User": os.environ["CH_USER"], "X-ClickHouse-Key": os.environ["CH_PASSWORD"]}
stmts = [st for st in split_stmts(strip_comments(open(os.environ["BACKFILL_FILE"]).read()))
         if not st.lower().startswith("use ")]
failed = 0
for i, st in enumerate(stmts, 1):
    req = urllib.request.Request(base + "?" + urllib.parse.urlencode(params), data=st.encode(),
                                 headers=headers, method="POST")
    try:
        urllib.request.urlopen(req, timeout=600).read()
    except urllib.error.HTTPError as e:
        failed += 1
        print("  FAIL statement %d: %s" % (i, e.read().decode()[:300]))
print("  %d statement(s) sent, %d failed" % (len(stmts), failed))
raise SystemExit(1 if failed else 0)
PY
  ok "backfill done"
}

cmd_verify() {
  local cutoff mode t pt cg; cutoff=$(state_get cutoff); mode=$(state_get mode); pt=$(processed_table); cg=$(consumer_group)
  log "Replay on '$DEPLOYMENT_NAME': mode=$mode, cutoff=$cutoff"
  printf '  %-42s %s\n' "accepted inbound events (all time)" "$(sql_value "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")"
  if [ -n "$pt" ] && table_exists "$pt"; then
    printf '  %-42s %s\n' "accepted events never processed" "$(sql_value "SELECT count(*) FROM inbound_event_log i WHERE i.status = 'ACCEPTED'
         AND NOT EXISTS (SELECT 1 FROM $pt m WHERE m.cloudevents_id = i.cloudevents_id AND m.source = i.source)")"
  fi
  for t in $DROP_TABLES; do printf '  %-42s %s\n' "$t" "$(table_rows "$t")"; done
  printf '  %-42s %s\n' "lag of $cg" "$(group_lag "$cg" "$INBOUND_TOPIC")"
  printf '  %-42s %s\n' "records in $DLQ_TOPIC" "$(topic_record_count "$DLQ_TOPIC")"
  if table_exists step_instance; then
    local pg ch
    pg=$(table_rows step_instance)
    ch=$(ch_query "SELECT count() FROM $CH_DB.step_instances FINAL WHERE _is_deleted = 0" 2>/dev/null || echo "n/a")
    printf '  %-42s Postgres %s / ClickHouse %s %s\n' "steps (CDC check)" "$pg" "$ch" "$([ "$pg" = "$ch" ] && echo '— match' || echo '— not yet equal (snapshot running?)')"
  fi
  printf '  %-42s %s\n' "CDC connector" "$(connect_api GET "/connectors/$CONNECTOR/status" 2>/dev/null | grep -oE '"state":"[A-Z]+"' | tr '\n' ' ')"
  log "SERVICES"
  local s; for s in $SERVICES; do printf '  %-30s %s\n' "$s" "$(service_state "$s")"; done
  if old_schema_exists; then log "Old tables are still kept in schema $OLD_SCHEMA (Revert can go back to them). Next: 'report', then, once you won't go back: 'drop-old-tables --yes'"; fi
}

# The numbers the report compares, as "section|key|value" lines. Rows are read as JSON
# (to_jsonb), so the same queries work on any release's tables (1.x step_instance.state, 2.0
# step_status + sla_status). 'prepare' saves them before it changes anything; 'report' reads them again.
report_facts() {
  local t pt
  pt=$(processed_table)
  {
    echo "SELECT 'events', 'accepted inbound events', count(*) FROM inbound_event_log WHERE status = 'ACCEPTED';"
    for t in $DROP_TABLES; do table_exists "$t" && echo "SELECT 'rows', '$t', count(*) FROM public.$t;"; done
    if [ -n "$pt" ] && table_exists "$pt"; then
      echo "SELECT 'events', 'processed', count(*) FROM $pt;"
      echo "SELECT 'events', 'accepted, never processed', count(*) FROM inbound_event_log i WHERE i.status = 'ACCEPTED'
              AND NOT EXISTS (SELECT 1 FROM $pt m WHERE m.cloudevents_id = i.cloudevents_id AND m.source = i.source);"
      echo "SELECT 'not-replayable', coalesce(m.source, '?'), count(*) FROM $pt m WHERE NOT EXISTS (SELECT 1 FROM inbound_event_log i
              WHERE i.cloudevents_id = m.cloudevents_id AND i.source = m.source AND i.status = 'ACCEPTED') GROUP BY 2;"
      echo "SELECT 'processing', coalesce(to_jsonb(m)->>'processing_status', '?'), count(*) FROM $pt m GROUP BY 2;"
    fi
    if table_exists protocol_instance; then
      echo "SELECT 'enrolments', p, count(*) FROM (SELECT regexp_replace(coalesce(to_jsonb(d)->>'url', to_jsonb(d)->'definition'->>'url',
              to_jsonb(pi)->>'protocol_canonical', '?'), '^.*/', '') AS p FROM protocol_instance pi
              LEFT JOIN protocol_definition d ON d.id = pi.protocol_definition_id) x GROUP BY 2;"
    fi
    if table_exists step_instance; then
      echo "SELECT 'steps', coalesce(to_jsonb(s)->>'step_status', to_jsonb(s)->>'state', '?'), count(*) FROM step_instance s GROUP BY 2;"
      echo "SELECT 'step-verdicts', coalesce(to_jsonb(s)->>'sla_status', to_jsonb(s)->>'completion_status', '(none)'), count(*) FROM step_instance s GROUP BY 2;"
    fi
    table_exists deviation && echo "SELECT 'deviations', coalesce(to_jsonb(d)->>'deviation_type', '?'), count(*) FROM deviation d GROUP BY 2;"
  } | psql_q
}

top_errors_since() {   # $1 = service, $2 = UTC time: its 3 most frequent error lines since then ("N text", \036-separated)
  [ -n "$2" ] || return 0
  { service_logs "$1" "$2" | grep -E ' ERROR |Exception:' | grep -v '^\s*at ' \
      | sed -E 's/^[^A-Za-z]*[0-9T:.Z+-]{10,}[^A-Za-z]*//' | cut -c1-160 | sort | uniq -c | sort -rn | head -3 \
      | sed 's/^ *//' | tr '\n' '\036'; } || true
}
cmd_report() {   # before/after comparison of a replay, as a markdown file to share
  local before="$STATE_DIR/report-before.tsv" after out s since
  [ -f "$before" ] || die "No 'before' numbers in $STATE_DIR: they are saved by 'prepare'. Run 'report' after a replay prepared by this version of the script."
  after=$(mktemp); report_facts > "$after"
  out="$STATE_DIR/replay-report-$(date -u +%Y%m%d_%H%M%S).md"
  since=$(state_get prepare_started)
  local errors=""
  for s in $SERVICES; do errors="$errors$s"$'\t'"$(top_errors_since "$s" "$since")"$'\n'; done
  DEPLOYMENT="$DEPLOYMENT_NAME" MODE="$(state_get mode)" CUTOFF="$(state_get cutoff)" BACKUP="$(state_get backup)" \
  SERVICES_LIST="$(words $SERVICES)" SINCE="$since" ERRORS="$errors" \
  DLQ="$(topic_record_count "$DLQ_TOPIC")" LAG="$(group_lag "$(consumer_group)" "$INBOUND_TOPIC")" \
  python3 - "$before" "$after" > "$out" <<'PY'
import os, sys, datetime
def load(p):
    d = {}
    for line in open(p):
        parts = line.rstrip("\n").rsplit("|", 1)
        head = parts[0].split("|", 1)
        if len(parts) == 2 and len(head) == 2 and parts[1].strip().lstrip("-").isdigit():
            d[(head[0], head[1])] = int(parts[1])
    return d
b, a = load(sys.argv[1]), load(sys.argv[2])
env = os.environ.get
def table(section, title, note=""):
    keys = sorted({k for (s, k) in list(b) + list(a) if s == section})
    if not keys: return
    print(f"\n## {title}\n")
    if note: print(note + "\n")
    print("| | Before | After | Difference |\n|---|---:|---:|---:|")
    for k in keys:
        x, y = b.get((section, k)), a.get((section, k))
        diff = "" if x is None or y is None else f"{y - x:+d}"
        print(f"| {k} | {'—' if x is None else x} | {'—' if y is None else y} | {diff} |")
def g(d, s, k): return d.get((s, k), 0)
print(f"# Replay report: {env('DEPLOYMENT')}\n")
print(f"- Written: {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC; mode `{env('MODE')}`, cutoff `{env('CUTOFF') or '—'}`")
print(f"- Services replayed through: {env('SERVICES_LIST')}")
print(f"- Backup of the data before: `{env('BACKUP') or '—'}`")
print(f"- Now: lag of the first service `{env('LAG')}`, records in the inbound DLQ `{env('DLQ')}`")
table("events", "Events")
table("rows", "Rows per table", "`—` = the table did not exist on that side (e.g. a table the new release creates, or one the old release had).")
table("enrolments", "Enrolments per protocol")
table("steps", "Steps by status")
table("step-verdicts", "Steps by deadline verdict")
table("deviations", "Deviations by type")
table("processing", "Processed events by result")
print("\n## Why the counts differ\n")
nr = {k: v for (s, k), v in b.items() if s == "not-replayable"}
if nr:
    tot = sum(nr.values())
    print(f"- **{tot} events processed before are not in `inbound_event_log`** ("
          + ", ".join(f"{k}: {v}" for k, v in sorted(nr.items())) + "). They reached the old services without "
          "going through the collector (e.g. test events sent straight to Kafka), so the replay cannot process them; "
          "enrolments and steps that came only from them are gone.")
never_before = g(b, "events", "accepted, never processed")
if never_before:
    print(f"- **{never_before} accepted events had never been processed before the replay** (in `inbound_event_log`, "
          "missing from the old processed-events table). The replay processed them, so enrolments, steps and deviations "
          "of those patients are new, not changed.")
never = g(a, "events", "accepted, never processed")
if never:
    print(f"- **{never} accepted events are still not processed.** Look at the DLQ and the first service's log (below).")
else:
    print("- Every accepted event in `inbound_event_log` has been processed.")
zb, za = g(b, "processing", "ZERO_MATCH"), g(a, "processing", "ZERO_MATCH")
if zb or za:
    print(f"- **Events that matched no protocol step: {zb} before, {za} after.** Events are matched against the protocols and "
          "trigger index loaded *today*, not the ones in force when they first arrived; a protocol loaded or fixed later "
          "matches events it missed before (and the other way round).")
db_, da = sum(v for (s, k), v in b.items() if s == "deviations"), sum(v for (s, k), v in a.items() if s == "deviations")
print(f"- **Deviations: {db_} before, {da} after.** Every deadline is judged again at replay time, in one sweep, by the "
      "deadline rules of the release now deployed; the old deviations were raised over time by the old rules.")
if set(k for (s, k) in b if s == "steps") != set(k for (s, k) in a if s == "steps"):
    print("- **Step statuses have different names before and after:** the two sides are different releases "
          "(e.g. 1.x `state` → 2.0 `step_status` + `sla_status`); compare the totals, not the rows.")
print("- Steps and enrolments are rebuilt from the events alone, by the current release's logic (e.g. how repeated "
      "or resent events create step rows), so the totals move with it.")
print("\n## Errors logged by the services during the replay\n")
rows = [l.split("\t", 1) for l in env("ERRORS", "").splitlines() if "\t" in l]
if not any(e.strip("\x1e") for _, e in rows):
    print(f"None since `prepare` ({env('SINCE') or '—'}).")
for svc, e in rows:
    msgs = [m for m in e.split("\x1e") if m.strip()]
    if msgs:
        print(f"- **{svc}**")
        for m in msgs:
            n, _, text = m.partition(" ")
            print(f"  - {n}×: `{text.strip()}`")
PY
  rm -f "$after"
  ok "report written: $out"
  printf '  (markdown: paste it into a ticket, chat or doc as it is)\n'
}

cmd_service() {
  [ -n "$ARG2" ] || die "Usage: service stop|start|state <service>"
  case "$ARG1" in
    stop)  services_stop "$ARG2"; ok "$ARG2: $(service_state "$ARG2")";;
    start) services_start "$ARG2"; ok "$ARG2: $(service_state "$ARG2")";;
    state) echo "$ARG2: $(service_state "$ARG2")";;
    *) die "Usage: service stop|start|state <service>";;
  esac
}

cmd_logs() { [ -n "$ARG1" ] || die "Say which service, e.g.: logs $(first_service)"; service_logs "$ARG1"; }

stop_and_clear_kafka() {   # for restore/revert: nothing replayed may reach the restored data
  local g
  log "Stopping $(reverse_services)"
  services_stop $(reverse_services); require_stopped $SERVICES
  wait_groups_idle "$(consumer_group)"
  log "Emptying $INBOUND_TOPIC and the other topics (replayed events and what they produced)"
  save_topic "$DLQ_TOPIC" dlq-at-revert
  purge_topic "$INBOUND_TOPIC"; discard_outputs
  reset_group_to_earliest "$(consumer_group)" "$INBOUND_TOPIC"
}

cmd_restore() {
  require_yes; validate_settings
  [ -f "$RESTORE_FILE" ] || die "Give the backup to restore: --file $STATE_DIR/ccedb_before_replay_<time>.dump"
  [ "$(head -c 5 "$RESTORE_FILE")" = "PGDMP" ] || die "$RESTORE_FILE is not a pg_dump backup."
  # After an upgrade, SERVICES are the new release: started on the old tables, their migrations would
  # fail or change them. Going back to the old release is always tables only (as --no-start).
  local new_tables; new_tables=$(new_release_tables)
  if [ -n "$new_tables" ]; then
    old_schema_exists || die "This replay was an upgrade (the services created tables the old data never had: $new_tables), and its old tables are gone (drop-old-tables). The old release's data can only come back with the whole database restored: 'restore-database --file $RESTORE_FILE --yes' (REPLAY-RUNBOOK.md part U, 'Going back to 1.x', 'After A11'). Nothing was changed."
    if [ -z "$NO_START" ]; then
      warn "this replay was an upgrade (the services created tables the old data never had: $new_tables): the tables go back as they were and SERVICES stay stopped, as with --no-start"
      NO_START=1
    fi
  fi
  stop_and_clear_kafka
  if old_schema_exists; then put_old_tables_back; else restore_from_backup_file; fi
  if [ -n "$NO_START" ]; then
    log "--no-start: SERVICES are left stopped ($(words $SERVICES))"
  else
    log "Starting the services again"
    services_start $SERVICES
  fi
  state_set mode ""; state_set cutoff ""; state_set published ""; state_set moved ""; state_set created ""; state_set prepared ""
  [ -n "${REVERTING:-}" ] || ok "done. Next: 'rebuild-clickhouse --yes', then fill-gaps with --from = the backup's time for events that arrived after it"
}

put_old_tables_back() {   # undo a rebuild: the old tables back from $OLD_SCHEMA, exactly as they were
  local old_tables remove="" t ledger repaired emptied repair=1
  old_tables=$(sql_value "SELECT string_agg(tablename, ' ') FROM pg_tables WHERE schemaname = '$OLD_SCHEMA'")
  emptied=$(state_get emptied)
  # Remove what the services created: the rebuilt copies of the old tables, and tables that did not
  # exist before the rebuild at all (e.g. 2.0's matcher_event_log after a 1.x -> 2.0 upgrade). Tables
  # put back unchanged by 'prepare' ('returned') stay.
  for t in $(words $old_tables $(state_get created)); do
    table_exists "$t" && ! in_list "$t" "$remove" && ! in_list "$t" "$(state_get returned)" && remove="$remove $t"
  done
  # The old migration records go back. Where the deployed image carries a changed migration file,
  # record the image's checksum, as 'flyway repair' does; otherwise the service would refuse to start.
  # Not when going back from an upgrade (--no-start): the OLD release comes back, and it validates the
  # records against its own files, so they must keep the old checksums.
  [ -z "$NO_START" ] || { repair=""; log "--no-start: the old migration records go back unchanged (the old release validates them)"; }
  for ledger in $old_tables; do
    [ -n "$repair" ] || break
    case "$ledger" in flyway_schema_history_*) ;; *) continue;; esac
    table_exists "$ledger" || continue
    repaired=$(sql_value "SELECT string_agg(o.version, ',') FROM $OLD_SCHEMA.$ledger o JOIN public.$ledger n
                            ON n.version = o.version AND n.script = o.script WHERE o.checksum IS DISTINCT FROM n.checksum")
    [ -z "$repaired" ] || log "$ledger: the deployed image has changed migration(s) $repaired; recording their new checksums"
  done
  log "Putting back the tables kept in schema $OLD_SCHEMA and removing the ones the services created"
  [ -z "$emptied" ] || log "Refilling$emptied from $RESTORE_FILE"
  {
    echo "BEGIN;"
    for ledger in $old_tables; do
      [ -n "$repair" ] || break
      case "$ledger" in flyway_schema_history_*) ;; *) continue;; esac
      table_exists "$ledger" || continue
      echo "UPDATE $OLD_SCHEMA.$ledger o SET checksum = n.checksum FROM public.$ledger n
             WHERE n.version = o.version AND n.script = o.script AND o.checksum IS DISTINCT FROM n.checksum;"
    done
    [ -z "$remove" ] || echo "DROP TABLE $(table_list_sql $remove);"
    for t in $old_tables; do echo "ALTER TABLE $OLD_SCHEMA.$t SET SCHEMA public;"; done
    echo "DROP SCHEMA $OLD_SCHEMA;"
    if [ -n "$emptied" ]; then
      echo "TRUNCATE $(table_list_sql $emptied) RESTART IDENTITY;"
      for t in $emptied; do pg_table_data_sql "$RESTORE_FILE" "$t"; done
    fi
    echo "COMMIT;"
  } | psql_raw -v ON_ERROR_STOP=1 -X -q >/dev/null \
    || die "Putting the old tables back failed and was rolled back: nothing changed. Services are left stopped. Fix the error above and run the same command again."
  ok "restored: the tables are the ones from before the rebuild"
}

restore_from_backup_file() {   # after drop-old-tables: DROP_TABLES' rows from the backup file
  local existing="" t
  for t in $DROP_TABLES; do table_exists "$t" && existing="$existing $t"; done
  [ -n "$existing" ] || die "None of DROP_TABLES exists: nothing to restore."
  log "Restoring the rows of DROP_TABLES from $RESTORE_FILE (one transaction: all or nothing)"
  {
    echo "BEGIN;"
    echo "TRUNCATE $(table_list_sql $existing) RESTART IDENTITY;"
    for t in $existing; do pg_table_data_sql "$RESTORE_FILE" "$t"; done
    cat <<SQL
SELECT count(setval(pg_get_serial_sequence(format('public.%I', c.table_name), c.column_name),
         coalesce((xpath('/row/m/text()', query_to_xml(format('select max(%I) as m from public.%I',
           c.column_name, c.table_name), false, true, '')))[1]::text::bigint, 0) + 1, false))
  FROM information_schema.columns c
 WHERE c.table_schema = 'public'
   AND c.table_name = ANY (string_to_array('$(words $existing | tr ' ' ',')', ','))
   AND pg_get_serial_sequence(format('public.%I', c.table_name), c.column_name) IS NOT NULL;
COMMIT;
SQL
  } | psql_raw -v ON_ERROR_STOP=1 -X -q >/dev/null \
    || die "Restore failed and was rolled back: nothing changed. Services are left stopped. Fix the error above and run 'restore' again."
  ok "restored"
}

# The whole database back from a backup, keeping the events received since: the way back after an
# upgrade's old tables are gone (drop-old-tables), where 'restore' would put old rows into new tables.
# 'pg_restore --clean' is not enough there: the new release's tables are not in the backup and their
# foreign keys block it. So the database is dropped and created again, as the backup has it.
cmd_restore_database() {
  require_yes; validate_settings
  [ -f "$RESTORE_FILE" ] || die "Give the backup to restore: --file <backup.dump> (e.g. $STATE_DIR/ccedb_before_replay_<time>.dump)"
  [ "$(head -c 5 "$RESTORE_FILE")" = "PGDMP" ] || die "$RESTORE_FILE is not a pg_dump backup."
  local since owner saved n s stopped=""
  # The backup's own creation time (pg_dump records it), as UTC.
  since=$($PG_EXEC sh -c "$(pg_cmd pg_restore -l)" < "$RESTORE_FILE" 2>/dev/null | sed -n 's/^;[[:space:]]*Archive created at //p' | head -1)
  [ -n "$since" ] || die "Could not read when $RESTORE_FILE was taken (pg_restore -l). Nothing was changed."
  since=$(sql_value "SELECT to_char(timestamptz '$since' AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')") || die "Could not read the backup time '$since'. Nothing was changed."
  owner=$(sql_value "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")
  log "Restoring the whole database $PG_DB from $RESTORE_FILE (taken $since UTC); events received since then are kept"

  log "1/6 Stopping every CCE service that uses the database"
  for s in $(reverse_services) $INSIGHTS_SERVICES $COLLECTOR_SERVICE; do
    case "$(service_state "$s")" in absent|stopped) ;; *) stopped="$stopped $s";; esac
  done
  services_stop $stopped; ok "stopped:${stopped:- none was running}"

  log "2/6 Keeping the events received since the backup"
  mkdir -p "$STATE_DIR"; saved="$STATE_DIR/events-since-backup-$(date -u +%Y%m%d_%H%M%S).copy"
  ( umask 077; printf '%s\n' "COPY (SELECT * FROM inbound_event_log WHERE received_at >= '$since'::timestamptz) TO STDOUT" | psql_q > "$saved" ) \
    || die "Could not save the events received since the backup. Nothing was changed (the services are stopped: $(words $stopped))."
  ok "$(grep -c '' "$saved") event(s) saved to $saved"

  log "3/6 Emptying Kafka (what the current release processed must not be processed again on the restored data)"
  stop_and_clear_kafka

  log "4/6 Stopping the CDC connector and dropping its replication slot (ClickHouse is rebuilt afterwards)"
  connect_api PUT "/connectors/$CONNECTOR/stop" >/dev/null 2>&1 || warn "could not stop $CONNECTOR (continuing)"
  for _ in $(seq 1 20); do
    [ "$(sql_value "SELECT count(*) FROM pg_replication_slots WHERE database = current_database() AND active")" = 0 ] && break; sleep 3
  done
  sql_value "SELECT count(pg_drop_replication_slot(slot_name)) FROM pg_replication_slots WHERE database = current_database()" >/dev/null \
    || die "Could not drop the replication slot(s) of $PG_DB (still in use?). Nothing in the database was changed."
  ok "connector stopped, slot dropped"

  log "5/6 Dropping $PG_DB and creating it again from the backup"
  $PG_EXEC sh -c "$(pg_cmd psql -d postgres -v ON_ERROR_STOP=1 -X -q)" <<SQL || die "Dropping and creating $PG_DB failed (the user needs to be allowed to; see the error above). The events are saved in $saved."
DROP DATABASE "$PG_DB" WITH (FORCE);
CREATE DATABASE "$PG_DB" OWNER "$owner";
SQL
  $PG_EXEC sh -c "$(pg_cmd pg_restore -d "$PG_DB" --no-owner)" < "$RESTORE_FILE" \
    || die "pg_restore reported errors (above). The events received since the backup are saved in $saved."
  ok "$PG_DB is as it was at $since UTC"

  log "6/6 Putting back the events received since the backup (those the backup already has are skipped)"
  n=$({ echo "CREATE TEMP TABLE saved_events (LIKE inbound_event_log);"
        echo "COPY saved_events FROM STDIN;"; cat "$saved"; printf '%s\n' '\.'
        echo "WITH added AS (INSERT INTO inbound_event_log SELECT * FROM saved_events ON CONFLICT DO NOTHING RETURNING 1) SELECT count(*) FROM added;"
      } | psql_q | tail -1) || die "Putting the saved events back failed. They are in $saved."
  ok "$n event(s) added back"

  services_start $COLLECTOR_SERVICE
  state_set mode ""; state_set cutoff ""; state_set published ""; state_set moved ""; state_set created ""; state_set prepared ""
  ok "done. The collector runs again; every other service is stopped."
  printf '\n  Next (REPLAY-RUNBOOK.md, part U, "Going back to 1.x", steps 2-5): remove the new services, deploy\n'
  printf '  and start the old ones, rebuild ClickHouse with the old data-pipeline, then fill-gaps\n'
  printf "  with --from '%s'.\n\n" "$since"
}

cmd_drop_old_tables() {   # after a verified rebuild: delete the old copies for good
  require_yes
  old_schema_exists || die "There is no schema $OLD_SCHEMA: nothing to drop."
  [ "$(state_get published)" != "" ] && [ "$(state_get published)" != "started, not finished" ] \
    || die "No finished replay recorded after the rebuild. Finish and verify it first, or undo with 'revert --yes'."
  log "Deleting the old tables kept in schema $OLD_SCHEMA: $(sql_value "SELECT string_agg(tablename, ' ') FROM pg_tables WHERE schemaname = '$OLD_SCHEMA'")"
  sql_value "DROP SCHEMA $OLD_SCHEMA CASCADE" >/dev/null
    if [ -n "$(new_release_tables)" ]; then ok "dropped. 'revert' can no longer go back to before this upgrade; only 'restore-database --file <backup> --yes' can (REPLAY-RUNBOOK.md part U, 'Going back to 1.x', 'After A11')."
  else ok "dropped. 'revert' can no longer go back to before this replay (the backup file still can, with 'restore')."; fi
}

cmd_revert() {   # undo a replay: old tables back (or the backup's rows), ClickHouse rebuilt
  require_yes
  RESTORE_FILE="$(state_get backup)"
  [ -n "$RESTORE_FILE" ] && [ -f "$RESTORE_FILE" ] || die "No backup recorded in $STATE_DIR. Use 'restore --file <backup.dump> --yes' with a backup from $STATE_DIR."
  local stamp backup_time
  stamp=$(basename "$RESTORE_FILE" .dump); stamp=${stamp##*_before_replay_}
  backup_time="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
  log "Reverting '$DEPLOYMENT_NAME' to the backup taken at $backup_time UTC ($RESTORE_FILE)"
  REVERTING=1
  log "Part 1 of 2: putting the tables back"; cmd_restore
  if [ -n "$NO_START" ]; then
    # Going back from an upgrade: SERVICES are the new release, which must not run on the restored old
    # tables, and ClickHouse must be rebuilt with the OLD release's data-pipeline once it is back.
    ok "tables put back as they were at $backup_time UTC. SERVICES are left stopped and ClickHouse is NOT rebuilt (--no-start)."
    printf '\n  Next (REPLAY-RUNBOOK.md, "U. Upgrade 1.x to 2.0", going back): remove the new services, deploy and\n'
    printf '  start the old ones, then rebuild ClickHouse with the old release\x27s data-pipeline.\n\n'
    return
  fi
  log "Part 2 of 2: rebuilding ClickHouse from the restored data"; cmd_rebuild_clickhouse
  ok "reverted. Data is as it was at $backup_time UTC; events received since then are still in inbound_event_log."
  printf '\n  Events received since the backup are processed with fill-gaps (runbook part C) with\n'
  printf "  --from '%s'. Start it 10 minutes after this revert.\n\n" "$backup_time"
}

warn_split_state
case "$COMMAND" in
  check) cmd_check;;  status) cmd_status;;  plan) cmd_plan;;  backup) cmd_backup;;  prepare) cmd_prepare;;
  publish) cmd_publish;;  wait) cmd_wait;;  finish) cmd_finish;;
  rebuild-clickhouse) cmd_rebuild_clickhouse;;  backfill-clickhouse) cmd_backfill_clickhouse || die "The backfill had failures (shown above). It changes nothing else and is safe to run again.";;  verify) cmd_verify;;  report) cmd_report;;  logs) cmd_logs;;  restore) cmd_restore;;
  revert) cmd_revert;;  restore-database) cmd_restore_database;;  drop-old-tables) cmd_drop_old_tables;;  service) cmd_service;;
  *) usage; exit 1;;
esac
