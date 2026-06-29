#!/usr/bin/env bash
# Register (or update) the Debezium PostgreSQL source connector on Kafka Connect.
#
# Prerequisites (run in this order):
#   1. ClickHouse schema applied:        schema/01-create-tables.sql + schema/02-kafka-ingestion.sql (+ 03-06)
#   2. PostgreSQL logical replication:   psql ... -f cdc/01-configure-replication.sql
#   3. Kafka Connect (debezium/connect) up on the shared network and reachable at $CONNECT_URL
#
# The connector config (connectors/debezium-postgres-source.json) uses ${CDC_*} placeholders;
# they are interpolated from the environment here, so source your .env first:
#   set -a; source .env; set +a
#
# Usage: ./scripts/register-connectors.sh

set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTOR_FILE="connectors/debezium-postgres-source.json"
NAME="cce-ccedb-source"

command -v jq >/dev/null      || { echo "✗ jq is required"; exit 1; }
command -v envsubst >/dev/null || { echo "✗ envsubst (gettext) is required"; exit 1; }
[[ -f "$CONNECTOR_FILE" ]]     || { echo "✗ ${CONNECTOR_FILE} not found — run from the repo root"; exit 1; }

echo "=== Registering Debezium connector '${NAME}' @ ${CONNECT_URL} ==="

# Interpolate ${CDC_*} into the connector JSON.
PAYLOAD="$(envsubst < "$CONNECTOR_FILE")"

# Wait for Kafka Connect REST.
echo "Waiting for Kafka Connect..."
for i in $(seq 1 30); do
    if curl -sf "${CONNECT_URL}/connectors" >/dev/null 2>&1; then echo "  ✓ Connect is up"; break; fi
    [[ $i -eq 30 ]] && { echo "  ✗ Kafka Connect not reachable at ${CONNECT_URL}"; exit 1; }
    sleep 3
done

if curl -sf "${CONNECT_URL}/connectors/${NAME}" >/dev/null 2>&1; then
    echo "Connector exists — updating config (PUT /connectors/${NAME}/config)..."
    echo "$PAYLOAD" | jq -c '.config' \
      | curl -sf -X PUT -H 'Content-Type: application/json' \
             "${CONNECT_URL}/connectors/${NAME}/config" -d @- >/dev/null \
      && echo "  ✓ updated" || { echo "  ✗ update failed"; exit 1; }
else
    echo "Creating connector (POST /connectors)..."
    echo "$PAYLOAD" | curl -sf -X POST -H 'Content-Type: application/json' \
             "${CONNECT_URL}/connectors" -d @- >/dev/null \
      && echo "  ✓ created — initial snapshot starting" || { echo "  ✗ create failed"; exit 1; }
fi

echo ""
echo "Monitor:  ./scripts/check-connector-health.sh"
echo "Topics:   kafka-ui (cce.public.*)   |   Connect: ${CONNECT_URL}/connectors/${NAME}/status"
