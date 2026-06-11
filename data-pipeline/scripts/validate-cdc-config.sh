#!/usr/bin/env bash
# Validate PostgreSQL CDC configuration for Debezium
# Usage: ./scripts/validate-cdc-config.sh [host] [port] [user] [dbname]

set -euo pipefail

PG_HOST="${1:-localhost}"
PG_PORT="${2:-5432}"
PG_USER="${3:-postgres}"
PG_DB="${4:-ccedb}"

echo "=== PostgreSQL CDC Configuration Validation ==="
echo "Target: ${PG_HOST}:${PG_PORT}/${PG_DB}"
echo ""

FAILURES=0

pg() { psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }

# Check wal_level
WAL_LEVEL=$(pg "SHOW wal_level;")
if [[ "$WAL_LEVEL" == "logical" ]]; then
    echo "✓ wal_level = logical"
else
    echo "✗ wal_level = ${WAL_LEVEL} (expected: logical) — RESTART REQUIRED after ALTER SYSTEM"
    FAILURES=$((FAILURES + 1))
fi

# Check max_slot_wal_keep_size
WAL_KEEP=$(pg "SHOW max_slot_wal_keep_size;" 2>/dev/null || echo "-1")
if [[ "$WAL_KEEP" != "-1" && "$WAL_KEEP" != "0" ]]; then
    echo "✓ max_slot_wal_keep_size = ${WAL_KEEP}"
else
    echo "✗ max_slot_wal_keep_size is unset — unbounded WAL growth risk if Debezium falls behind"
    FAILURES=$((FAILURES + 1))
fi

# Check CDC user exists
USER_EXISTS=$(pg "SELECT 1 FROM pg_roles WHERE rolname = 'cce_cdc_user';")
if [[ "$USER_EXISTS" == "1" ]]; then
    echo "✓ Role cce_cdc_user exists"
else
    echo "✗ Role cce_cdc_user does not exist"
    FAILURES=$((FAILURES + 1))
fi

# Check publication exists
PUB_EXISTS=$(pg "SELECT 1 FROM pg_publication WHERE pubname = 'cce_analytics_pub';")
if [[ "$PUB_EXISTS" == "1" ]]; then
    echo "✓ Publication cce_analytics_pub exists"
else
    echo "✗ Publication cce_analytics_pub does not exist"
    FAILURES=$((FAILURES + 1))
fi

# Check publication tables (all 11)
echo ""
echo "--- Publication Tables ---"
EXPECTED_TABLES=(
    "protocol_definition"
    "protocol_instance"
    "step_instance"
    "deviation"
    "inbound_event_log"
    "intelligence_delivery"
    "intelligence_event_log"
    "action_definition"
    "compliance_event_log"
    "receiver_adaptor"
    "destination_adaptor_mapping"
)

PUB_TABLES=$(pg "SELECT tablename FROM pg_publication_tables WHERE pubname = 'cce_analytics_pub' ORDER BY tablename;")

MISSING=0
for table in "${EXPECTED_TABLES[@]}"; do
    if echo "$PUB_TABLES" | grep -q "^${table}$"; then
        echo "  ✓ ${table}"
    else
        echo "  ✗ ${table} NOT IN PUBLICATION"
        MISSING=$((MISSING + 1))
        FAILURES=$((FAILURES + 1))
    fi
done

TOTAL_TABLES=$(echo "$PUB_TABLES" | grep -c '.' || true)
echo ""
echo "Total tables in publication: ${TOTAL_TABLES}/${#EXPECTED_TABLES[@]}"

# Check REPLICA IDENTITY FULL on all tables
echo ""
echo "--- REPLICA IDENTITY FULL ---"
for table in "${EXPECTED_TABLES[@]}"; do
    REPLICA_IDENTITY=$(pg "SELECT relreplident FROM pg_class WHERE relname = '${table}' AND relnamespace = 'public'::regnamespace;" 2>/dev/null || echo "?")
    if [[ "$REPLICA_IDENTITY" == "f" ]]; then
        echo "  ✓ ${table}"
    else
        ID_LABEL="DEFAULT(d)"
        [[ "$REPLICA_IDENTITY" == "n" ]] && ID_LABEL="NOTHING"
        [[ "$REPLICA_IDENTITY" == "i" ]] && ID_LABEL="USING INDEX"
        echo "  ✗ ${table}: REPLICA IDENTITY is ${ID_LABEL} (expected FULL)"
        FAILURES=$((FAILURES + 1))
    fi
done

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== ${FAILURES} CHECK(S) FAILED ==="
    exit 1
fi
