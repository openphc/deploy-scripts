#!/usr/bin/env bash
# Validate ClickHouse schema deployment
# Usage: ./scripts/validate-clickhouse.sh [host] [port]

set -euo pipefail

CLICKHOUSE_HOST="${1:-localhost}"
CLICKHOUSE_PORT="${2:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

echo "=== ClickHouse Schema Validation ==="
echo "Target: ${CH_URL}"
echo ""

# Check connectivity
if ! curl -sf "${CH_URL}/ping" > /dev/null 2>&1; then
    echo "ERROR: Cannot reach ClickHouse at ${CH_URL}"
    exit 1
fi
echo "✓ ClickHouse is reachable"

# Check database exists
DB_EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.databases+WHERE+name='cce_analytics'" | tr -d '[:space:]')
if [[ "$DB_EXISTS" != "1" ]]; then
    echo "ERROR: Database 'cce_analytics' does not exist"
    exit 1
fi
echo "✓ Database 'cce_analytics' exists"

# Expected CDC base tables (created via schema/01, populated by the Kafka consumer MVs)
EXPECTED_TABLES=(
    "protocol_instances"
    "step_instances"
    "deviations"
    "inbound_event_logs"
    "intelligence_deliveries"
    "intelligence_event_logs"
    "action_definitions"
    "protocol_definitions"
    "compliance_event_logs"
    "receiver_adaptor"
    "destination_adaptor_mapping"
)

echo ""
echo "--- Tables (${#EXPECTED_TABLES[@]} expected) ---"
MISSING=0
for table in "${EXPECTED_TABLES[@]}"; do
    EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.tables+WHERE+database='cce_analytics'+AND+name='${table}'" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
        echo "  ✓ ${table}"
    else
        echo "  ✗ ${table} MISSING"
        MISSING=$((MISSING + 1))
    fi
done

# MV backing tables (the actual data stores — named without suffix, queryable directly)
EXPECTED_MV_TABLES=(
    "mv_event_volume_hourly"
    "mv_compliance_processing_quality"
    "mv_deviation_trends"
    "mv_deviation_by_protocol"
    "mv_deviation_by_patient"
    "mv_ingestion_quality"
    "mv_intelligence_summary"
    "mv_intelligence_by_patient"
    "mv_intelligence_by_protocol"
    "mv_practitioner_summary"
    "mv_facility_summary"
    "mv_patient_facility_latest"
)

echo ""
echo "--- MV Backing Tables (${#EXPECTED_MV_TABLES[@]} expected) ---"
for tbl in "${EXPECTED_MV_TABLES[@]}"; do
    EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.tables+WHERE+database='cce_analytics'+AND+name='${tbl}'" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
        echo "  ✓ ${tbl}"
    else
        echo "  ✗ ${tbl} MISSING"
        MISSING=$((MISSING + 1))
    fi
done

# MV trigger views (fire on INSERT, write to backing tables above)
EXPECTED_MV_TRIGGERS=(
    "mv_event_volume_hourly_mv"
    "mv_compliance_processing_quality_mv"
    "mv_deviation_trends_mv"
    "mv_deviation_by_protocol_mv"
    "mv_deviation_by_patient_mv"
    "mv_ingestion_quality_mv"
    "mv_intelligence_summary_mv"
    "mv_intelligence_by_patient_mv"
    "mv_intelligence_by_protocol_mv"
    "mv_practitioner_summary_mv"
    "mv_facility_summary_mv"
    "mv_patient_facility_latest_mv"
)

echo ""
echo "--- MV Triggers (${#EXPECTED_MV_TRIGGERS[@]} expected) ---"
for mv in "${EXPECTED_MV_TRIGGERS[@]}"; do
    EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.tables+WHERE+database='cce_analytics'+AND+name='${mv}'+AND+engine='MaterializedView'" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
        echo "  ✓ ${mv}"
    else
        echo "  ✗ ${mv} MISSING"
        MISSING=$((MISSING + 1))
    fi
done

# Kafka-engine ingestion: one queue table + one consumer MV per source table (schema/02)
INGEST=(
    inbound_event_logs protocol_definitions protocol_instances step_instances deviations
    compliance_event_logs action_definitions intelligence_event_logs intelligence_deliveries
)
echo ""
echo "--- Kafka Ingestion (queue + consumer MV per table, ${#INGEST[@]} tables) ---"
for t in "${INGEST[@]}"; do
    Q=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.tables+WHERE+database='cce_analytics'+AND+name='${t}_queue'+AND+engine='Kafka'" | tr -d '[:space:]')
    M=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.tables+WHERE+database='cce_analytics'+AND+name='${t}_mv'+AND+engine='MaterializedView'" | tr -d '[:space:]')
    if [[ "$Q" == "1" && "$M" == "1" ]]; then
        echo "  ✓ ${t}_queue + ${t}_mv"
    else
        echo "  ✗ ${t}: queue=${Q:-0} consumer_mv=${M:-0}"
        MISSING=$((MISSING + 1))
    fi
done

# All three dictionaries
EXPECTED_DICTS=(
    "dict_protocol_definitions"
    "dict_patient_facility"
    "dict_action_definitions"
)

echo ""
echo "--- Dictionaries (${#EXPECTED_DICTS[@]} expected) ---"
for dict in "${EXPECTED_DICTS[@]}"; do
    EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.dictionaries+WHERE+database='cce_analytics'+AND+name='${dict}'" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
        echo "  ✓ ${dict}"
    else
        echo "  ✗ ${dict} MISSING"
        MISSING=$((MISSING + 1))
    fi
done

# Check MATERIALIZED columns were added to inbound_event_logs
echo ""
echo "--- MATERIALIZED columns on inbound_event_logs ---"
MAT_COLS=("subject" "event_type" "facility_id" "event_time" "resource_type" "practitioner_ref" "practitioner_display")
for col in "${MAT_COLS[@]}"; do
    EXISTS=$(curl -sf "${CH_URL}/?query=SELECT+count()+FROM+system.columns+WHERE+database='cce_analytics'+AND+table='inbound_event_logs'+AND+name='${col}'" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
        echo "  ✓ ${col}"
    else
        echo "  ✗ ${col} MISSING — run schema/01-create-tables.sql"
        MISSING=$((MISSING + 1))
    fi
done

echo ""
if [[ $MISSING -eq 0 ]]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== ${MISSING} CHECK(S) FAILED ==="
    exit 1
fi
