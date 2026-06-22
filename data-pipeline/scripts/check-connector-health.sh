#!/usr/bin/env bash
# Check the health of the Debezium connector and the ClickHouse ingestion path.
# Usage: ./scripts/check-connector-health.sh

set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
NAME="cce-ccedb-source"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

UNHEALTHY=0

echo "=== Debezium / Kafka Connect ==="
if ! curl -sf "${CONNECT_URL}/connectors" >/dev/null 2>&1; then
    echo "  ✗ Kafka Connect not reachable at ${CONNECT_URL}"
    exit 1
fi

STATUS_JSON="$(curl -sf "${CONNECT_URL}/connectors/${NAME}/status" 2>/dev/null || echo '{}')"
if command -v jq >/dev/null 2>&1 && [[ "$STATUS_JSON" != "{}" ]]; then
    CONN_STATE=$(echo "$STATUS_JSON" | jq -r '.connector.state // "ABSENT"')
    [[ "$CONN_STATE" == "RUNNING" ]] && echo "  ✓ connector: RUNNING" || { echo "  ✗ connector: ${CONN_STATE}"; UNHEALTHY=$((UNHEALTHY+1)); }
    # task states
    echo "$STATUS_JSON" | jq -r '.tasks[]? | "    task \(.id): \(.state)"'
    FAILED=$(echo "$STATUS_JSON" | jq '[.tasks[]? | select(.state != "RUNNING")] | length')
    [[ "${FAILED:-0}" -gt 0 ]] && UNHEALTHY=$((UNHEALTHY+1))
else
    echo "  ✗ connector '${NAME}' not found (register it: ./scripts/register-connectors.sh)"
    UNHEALTHY=$((UNHEALTHY+1))
fi

echo ""
echo "=== ClickHouse ingestion ==="
ch() { curl -sf "${CH_URL}/?query=$(echo "$1" | sed 's/ /+/g')" 2>/dev/null | tr -d '[:space:]'; }
if curl -sf "${CH_URL}/ping" >/dev/null 2>&1; then
    echo "  ✓ ClickHouse reachable"
    INBOUND=$(ch "SELECT count() FROM cce_analytics.inbound_event_logs" || echo "?")
    echo "    inbound_event_logs rows: ${INBOUND:-0}"
    # Kafka consumer errors surface in system.kafka_consumers / the error log; surface last exceptions:
    ERRS=$(ch "SELECT count() FROM system.kafka_consumers WHERE database='cce_analytics' AND last_exception != ''" || echo "0")
    [[ "${ERRS:-0}" != "0" && "${ERRS:-0}" != "?" ]] && { echo "    ⚠ ${ERRS} Kafka-engine consumer(s) reporting last_exception — check system.kafka_consumers"; }
else
    echo "  ✗ ClickHouse not reachable at ${CH_URL}"
    UNHEALTHY=$((UNHEALTHY+1))
fi

echo ""
echo "Detail: ${CONNECT_URL}/connectors/${NAME}/status  ·  kafka-ui (topics cce.public.*)"
echo ""
if [[ $UNHEALTHY -eq 0 ]]; then echo "=== HEALTHY ==="; exit 0; else echo "=== ${UNHEALTHY} CHECK(S) FAILED ==="; exit 1; fi
