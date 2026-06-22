#!/usr/bin/env bash
# Data quality checks for ClickHouse analytics tables
# Usage: ./scripts/data-quality-checks.sh [clickhouse-host]
#
# Runs a suite of quality checks and exits non-zero if any fail.

set -euo pipefail

CLICKHOUSE_HOST="${1:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_DB="cce_analytics"
FAILURES=0

query() {
    curl -s "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/?database=${CH_DB}" --data-binary "$1"
}

check() {
    local name="$1"
    local sql="$2"
    local expected="$3"

    local result
    result=$(query "$sql" | tr -d '[:space:]')

    if [[ "$result" == "$expected" ]]; then
        echo "  [PASS] ${name}"
    else
        echo "  [FAIL] ${name} — expected '${expected}', got '${result}'"
        FAILURES=$((FAILURES + 1))
    fi
}

check_gt() {
    local name="$1"
    local sql="$2"
    local threshold="$3"

    local result
    result=$(query "$sql" | tr -d '[:space:]')

    if [[ "$result" -gt "$threshold" ]] 2>/dev/null; then
        echo "  [PASS] ${name} (value: ${result})"
    else
        echo "  [FAIL] ${name} — value '${result}' not > ${threshold}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_eq_zero() {
    local name="$1"
    local sql="$2"

    local result
    result=$(query "$sql" | tr -d '[:space:]')

    if [[ "$result" == "0" ]]; then
        echo "  [PASS] ${name}"
    else
        echo "  [WARN] ${name} — found ${result} issues"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "=== CCE Data Quality Checks ==="
echo "Host: ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT} | Database: ${CH_DB}"
echo ""

echo "--- Table Row Counts ---"
check_gt "inbound_event_logs has rows" "SELECT count() FROM inbound_event_logs FINAL" 0
check_gt "protocol_definitions has rows" "SELECT count() FROM protocol_definitions FINAL" 0
check_gt "protocol_instances has rows" "SELECT count() FROM protocol_instances FINAL" 0
check_gt "step_instances has rows" "SELECT count() FROM step_instances FINAL" 0
check_gt "intelligence_event_logs has rows" "SELECT count() FROM intelligence_event_logs FINAL" 0

echo ""
echo "--- Referential Integrity ---"
check_eq_zero "inbound_event_logs: no empty source" \
    "SELECT count() FROM inbound_event_logs FINAL WHERE source = ''"
check_eq_zero "inbound_event_logs: no future received_at" \
    "SELECT count() FROM inbound_event_logs FINAL WHERE received_at > now() + INTERVAL 1 HOUR"
# Use LEFT JOIN instead of NOT IN: NOT IN returns no rows (silent false-pass) when
# the subquery contains any NULLs, and is slow on large tables.
check_eq_zero "step_instances: orphaned protocol_instance_id" \
    "SELECT count() FROM step_instances si FINAL LEFT JOIN protocol_instances pi FINAL ON si.protocol_instance_id = pi.id WHERE pi.id = toUUID('00000000-0000-0000-0000-000000000000') OR isNull(pi.id)"
check_eq_zero "deviations: orphaned step_instance_id" \
    "SELECT count() FROM deviations d FINAL LEFT JOIN step_instances si FINAL ON d.step_instance_id = si.id WHERE si.id = toUUID('00000000-0000-0000-0000-000000000000') OR isNull(si.id)"

echo ""
echo "--- Freshness ---"
check "inbound_event_logs fresh (last 10min)" \
    "SELECT if(max(received_at) >= now() - INTERVAL 10 MINUTE, 'ok', 'stale') FROM inbound_event_logs" \
    "ok"
check "intelligence_event_logs fresh (last 1h)" \
    "SELECT if(max(created_at) >= now() - INTERVAL 1 HOUR, 'ok', 'stale') FROM intelligence_event_logs" \
    "ok"

echo ""
echo "--- Materialized View Consistency ---"
# Verify ingestion quality MV matches raw table (accepted event counts should align)
check_eq_zero "mv_ingestion_quality vs inbound_event_logs drift (today)" \
    "SELECT if(abs(a - b) > greatest(a, 1) * 0.01, 1, 0) FROM (SELECT sum(event_count) as a FROM mv_ingestion_quality WHERE day = today() AND status = 'ACCEPTED') x, (SELECT sum(event_count) as b FROM mv_event_volume_hourly WHERE toDate(hour) = today()) y"

echo ""
echo "--- Duplicates ---"
check_eq_zero "inbound_event_logs: no duplicate cloudevents_id (last hour)" \
    "SELECT count() FROM (SELECT cloudevents_id, count() as c FROM inbound_event_logs WHERE received_at >= now() - INTERVAL 1 HOUR GROUP BY cloudevents_id HAVING c > 1)"

echo ""
echo "=== Results ==="
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All checks passed!"
    exit 0
else
    echo "${FAILURES} check(s) failed."
    exit 1
fi
