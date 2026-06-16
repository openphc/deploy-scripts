#!/usr/bin/env bash
# Debezium Connector Re-snapshot
# Forces a fresh initial snapshot of the Debezium PostgreSQL connector by resetting its
# Kafka Connect offsets (and the replication slot), then truncating the ClickHouse tables.
# Use when: ClickHouse data is corrupted/truncated, or you need to rebuild from scratch.
#
# Requires Kafka Connect 3.6+ (offset reset REST API) — cp-kafka 7.6.1 qualifies.
#
# Usage:  set -a; source .env; set +a;  ./scripts/resnapshot-mirror.sh
#
# WARNING: re-snapshots all CDC tables from PostgreSQL — may take minutes to hours.

set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
NAME="cce-ccedb-source"

CH_HOST="${CH_HOST:-localhost}"
CH_USER="${CH_USER:-cce_pipeline}"
CH_PASS="${CH_PASSWORD:-${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD (or CH_PASSWORD) in the environment}}"
CH_URL="http://${CH_HOST}:${CH_PORT:-8123}"

# Source PG (to drop the replication slot) — optional but recommended for a clean snapshot.
PG_HOST="${CDC_PG_HOST:-localhost}"; PG_PORT="${CDC_PG_PORT:-5432}"
PG_DB="${CDC_PG_DATABASE:-ccedb}"; PG_SUPER="${PG_SUPERUSER:-postgres}"

echo "=== Debezium Connector Re-snapshot ==="
echo "Connect: ${CONNECT_URL}   Connector: ${NAME}"
echo "WARNING: resets offsets, drops the replication slot, truncates ClickHouse tables,"
echo "         and re-runs a full initial snapshot."
read -p "Continue? (y/N) " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# 1. Stop the connector, then reset its committed offsets (forces snapshot on resume).
echo "Step 1: stop connector + reset offsets..."
curl -sf -X PUT "${CONNECT_URL}/connectors/${NAME}/stop" >/dev/null 2>&1 || echo "  (connector not running / absent)"
sleep 3
if curl -sf -X DELETE "${CONNECT_URL}/connectors/${NAME}/offsets" >/dev/null 2>&1; then
    echo "  ✓ offsets reset"
else
    echo "  ⚠ offset reset failed (Kafka Connect < 3.6?) — delete + recreate the connector instead"
fi

# 2. Drop the replication slot so Debezium recreates it from a fresh position.
echo "Step 2: drop replication slot cce_analytics_slot (optional)..."
if command -v psql >/dev/null 2>&1; then
    PGPASSWORD="${PG_SUPERUSER_PASSWORD:-}" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPER" -d "$PG_DB" \
        -c "SELECT pg_drop_replication_slot('cce_analytics_slot') WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='cce_analytics_slot');" \
        >/dev/null 2>&1 && echo "  ✓ slot dropped (or absent)" || echo "  (could not drop slot — Debezium will reuse the existing one)"
else
    echo "  (psql not found — skipping slot drop)"
fi

# 3. Truncate ClickHouse tables (base + MV backing + rollups) so the re-snapshot doesn't double-count.
echo "Step 3: truncate ClickHouse tables..."
chq() { curl -sf "${CH_URL}/" --data-binary "$1" >/dev/null 2>&1; }
if curl -sf "${CH_URL}/ping" >/dev/null 2>&1; then
    TABLES=$(curl -sf "${CH_URL}/?query=SELECT+name+FROM+system.tables+WHERE+database='cce_analytics'+AND+(engine='ReplacingMergeTree'+OR+engine='SummingMergeTree'+OR+engine='AggregatingMergeTree')" 2>/dev/null || true)
    for t in $TABLES; do chq "TRUNCATE TABLE cce_analytics.${t}" && echo "    ✓ ${t}"; done
else
    echo "  ✗ ClickHouse unreachable — truncate manually before resuming"
fi

# 4. Resume → fresh initial snapshot.
echo "Step 4: resume connector (fresh initial snapshot)..."
curl -sf -X PUT "${CONNECT_URL}/connectors/${NAME}/resume" >/dev/null 2>&1 && echo "  ✓ resumed" \
    || { echo "  ⚠ resume failed — re-register: ./scripts/register-connectors.sh"; ./scripts/register-connectors.sh; }

echo ""
echo "=== Re-snapshot initiated ==="
echo "Monitor: ./scripts/check-connector-health.sh"
