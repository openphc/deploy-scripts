#!/usr/bin/env bash
# one-click-installer/lib/native/01-install-postgres-kafka.sh <envcode>
# Install PostgreSQL 16 and Kafka (KRaft mode) NATIVELY on the host via systemd, by running the
# existing k8s/infrastructure/setup-prod-infra.sh, then fix Kafka's advertised listener so k3s
# pods can reach the broker by host IP.
#
# Standard ports: Postgres 5432 and Kafka 9092 (a dedicated machine).
#
# Requires: POSTGRES_PROD_PASSWORD (or POSTGRES_PASSWORD) and VM_HOST_IP in the env.
set -euo pipefail

ENVCODE="${1:?usage: 01-install-postgres-kafka.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
. "$HERE/../sudo-compat.sh"

export POSTGRES_PROD_PASSWORD="${POSTGRES_PROD_PASSWORD:-${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD or POSTGRES_PROD_PASSWORD}}"
: "${VM_HOST_IP:?set VM_HOST_IP — needed for Kafka advertised listener}"

echo "=== [$ENVCODE] install PostgreSQL + Kafka (KRaft) via setup-prod-infra.sh ==="
# NOT `sudo -E`: sudo-rs (Ubuntu 26.04) ignores -E and drops the variables below (see one-click-installer/lib/sudo-compat.sh).
# KAFKA_VERSION / POSTGRES_VERSION must be passed too: before 2026-11-06 they were not, so the config keys were silently ignored and
# every install got the script defaults. A KAFKA_VERSION newer than the installed one upgrades Kafka in place (setup-prod-infra.sh).
as_root_env "POSTGRES_PROD_PASSWORD=$POSTGRES_PROD_PASSWORD" ${POSTGRES_USER:+"POSTGRES_USER=$POSTGRES_USER"} ${POSTGRES_DB:+"POSTGRES_DB=$POSTGRES_DB"} \
  ${POSTGRES_PORT:+"POSTGRES_PORT=$POSTGRES_PORT"} ${KAFKA_VERSION:+"KAFKA_VERSION=$KAFKA_VERSION"} ${POSTGRES_VERSION:+"POSTGRES_VERSION=$POSTGRES_VERSION"} \
  ${K3S_CLUSTER_CIDR:+"K3S_CLUSTER_CIDR=$K3S_CLUSTER_CIDR"} ${K3S_SERVICE_CIDR:+"K3S_SERVICE_CIDR=$K3S_SERVICE_CIDR"} \
  -- bash "$REPO/k8s/infrastructure/setup-prod-infra.sh"

echo "=== [$ENVCODE] fix Kafka advertised listener -> ${VM_HOST_IP}:9092 (so k3s pods can connect) ==="
KPROPS="/opt/kafka/config/kraft/server.properties"
if [ -f "$KPROPS" ]; then
  sudo sed -i "s#^advertised.listeners=.*#advertised.listeners=PLAINTEXT://${VM_HOST_IP}:9092#" "$KPROPS"
  sudo systemctl restart kafka
  echo "  advertised.listeners=$(grep '^advertised.listeners' "$KPROPS")"
fi

# The k8s keycloak connects to this native PostgreSQL and needs its own database; a native install has none, so create it here.
echo "=== [$ENVCODE] ensure 'keycloak' database exists ==="
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='keycloak'" 2>/dev/null | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE keycloak OWNER ${POSTGRES_USER:-admin};"

# pg_stat_statements — per-query timing/IO stats. the reference production environment runs with it; the Grafana Postgres dashboards and postgres_exporter's
# query panels are empty without it. It must be PRELOADED (shared_preload_libraries -> needs a restart) AND created per database.
# Done here, before any application data exists, so the one restart is free. Idempotent. ENABLE_PG_STAT_STATEMENTS=false to skip.
if [ "${ENABLE_PG_STAT_STATEMENTS:-true}" = "true" ]; then
  echo "=== [$ENVCODE] enable pg_stat_statements ==="
  PRELOAD="$(sudo -u postgres psql -tAc 'SHOW shared_preload_libraries' | tr -d '[:space:]')"
  case ",$PRELOAD," in
    *,pg_stat_statements,*) echo "  already preloaded ($PRELOAD)";;
    *) NEW="${PRELOAD:+$PRELOAD,}pg_stat_statements"
       sudo -u postgres psql -qc "ALTER SYSTEM SET shared_preload_libraries = '$NEW'"
       sudo systemctl restart postgresql
       for _ in $(seq 1 30); do sudo -u postgres psql -tAc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
       echo "  preloaded ($NEW) — postgresql restarted";;
  esac
  for db in "${POSTGRES_DB:-ccedb}" postgres; do
    sudo -u postgres psql -d "$db" -qc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" 2>/dev/null \
      && echo "  extension present in $db" || echo "  WARNING: could not create pg_stat_statements in $db"
  done
fi

# Connection logging, so access to the databases can be audited afterwards (who connected, from where, as which role). Without
# it, past access cannot be ruled out after an exposure (the case on a reference deployment's UAT host, 2026-10). Only NEW connections are logged,
# and the services use connection pools, so the volume is small. A reload is enough. LOG_CONNECTIONS=false to skip.
if [ "${LOG_CONNECTIONS:-true}" = "true" ]; then
  if [ "$(sudo -u postgres psql -tAc 'SHOW log_connections' | tr -d '[:space:]')" != on ]; then
    sudo -u postgres psql -qc "ALTER SYSTEM SET log_connections = on" && sudo -u postgres psql -qtAc "SELECT pg_reload_conf()" >/dev/null
  fi
  echo "=== [$ENVCODE] log_connections = $(sudo -u postgres psql -tAc 'SHOW log_connections' | tr -d '[:space:]') ==="
fi

echo ""
echo "PostgreSQL: sudo systemctl status postgresql   (port 5432, db ${POSTGRES_DB:-ccedb})"
echo "Kafka:      sudo systemctl status kafka         (port 9092, KRaft)"
echo "Next: 02-install-clickhouse.sh $ENVCODE"
