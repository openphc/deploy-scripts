#!/usr/bin/env bash
# one-click-installer/lib/redeploy-clickhouse.sh <envcode> [schema-basename ...]
#
# The ClickHouse counterpart of one-click-installer/lib/redeploy.sh (which rolls the k8s services): (re)apply the
# data-pipeline ClickHouse schema (data-pipeline/schema/*.sql) over HTTP and force-refresh any
# refreshable materialized views. Use after a SCHEMA change — new/edited tables, MVs, dictionaries,
# rollups (e.g. adding the daily-summary aggregate MVs + reference tables).
#
# Schema-only: this does NOT re-snapshot data from Postgres. CREATE is additive (won't alter an
# existing object) — to REPLACE a changed table/MV pass DROP_FIRST, and for a full rebuild
# (drop DB + re-snapshot from Postgres) is a separate procedure — this script never moves data.
#
#   sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env>   # apply all schema/*.sql (sorted) + refresh MVs
#   sudo bash one-click-installer/lib/redeploy-clickhouse.sh <env> 08-reference-tables 07-daily-summary-aggregates
#                                                             # explicit order (a file needs a higher-numbered one)
#   DRY_RUN=1 ...        # preview files + statement counts + MVs to refresh; change nothing
#   REFRESH_MV=0 ...     # skip the post-apply SYSTEM REFRESH of refreshable MVs
#   DROP_FIRST="x y" ... # DROP TABLE IF EXISTS cce_analytics.x, .y before applying (replace changed objects)
#
# Creds (CLICKHOUSE_USER/PASSWORD/HOST/PORT) are pulled from Infisical. Run on the host.
set -euo pipefail

ENVNAME="${1:?usage: redeploy-clickhouse.sh <envcode> [schema-basename ...]}"; shift || true
DRY_RUN="${DRY_RUN:-}"
REFRESH_MV="${REFRESH_MV:-1}"
DROP_FIRST="${DROP_FIRST:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCHEMA="$REPO/data-pipeline/schema"
DB="cce_analytics"

CH_PORT_DEFAULT="${CLICKHOUSE_PORT:-8123}"   # dedicated machine: standard ClickHouse HTTP port

# Pull ClickHouse creds from Infisical unless they're already injected (CLICKHOUSE_PASSWORD present).
if [ -z "${__CCE_CH_REEXEC:-}" ] && [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
  export __CCE_CH_REEXEC=1
  echo "redeploy-clickhouse: pulling ClickHouse creds from Infisical ($ENVNAME)…"
  exec bash "$HERE/infisical-run.sh" "$ENVNAME" bash "$0" "$ENVNAME" "$@"
fi

export CH_USER="${CLICKHOUSE_USER:-cce_pipeline}"
: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD not set (Infisical)}"
export CLICKHOUSE_PASSWORD CH_DB="$DB"
# Same host:port the data-pipeline scripts use from the host (uat: docker bridge 172.18.0.1:8123;
# prod: host IP:8124). Override with CH_HTTP if needed.
export CH_HTTP="${CH_HTTP:-http://${CLICKHOUSE_HOST:?CLICKHOUSE_HOST not set (Infisical)}:${CLICKHOUSE_PORT:-$CH_PORT_DEFAULT}}"

# URL-encode the password once; run a single statement against $DB over HTTP.
PW_ENC="$(python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["CLICKHOUSE_PASSWORD"]))')"
CH_QS="user=${CH_USER}&password=${PW_ENC}&database=${DB}"
ch() { curl -s "${CH_HTTP}/?${CH_QS}" --data-binary "$1"; }

echo "== redeploy-clickhouse ($ENVNAME) → $CH_HTTP db=$DB =="

# Optional: drop objects that changed (CREATE alone won't alter an existing table/MV).
if [ -n "$DROP_FIRST" ]; then
  for obj in $DROP_FIRST; do
    if [ -n "$DRY_RUN" ]; then
      echo "  DRY_RUN: would DROP TABLE IF EXISTS $DB.\`$obj\`"
    else
      echo "  drop $obj"; ch "DROP TABLE IF EXISTS \`$obj\`"
    fi
  done
fi

# Default apply order when no basenames are given: 01..06 numeric, then 08-reference-tables BEFORE
# 07-daily-summary-aggregates (07's MVs depend on 08's table; a plain numeric sort gets this wrong).
# Only includes files that exist (a fork may not have 07/08).
if [ "$#" -eq 0 ]; then
  for b in 01-create-tables 02-kafka-ingestion 03-create-materialized-views \
           04-create-indexes 05-create-dictionary 06-current-state-rollups \
           08-reference-tables 07-daily-summary-aggregates; do
    [ -f "$SCHEMA/$b.sql" ] && set -- "$@" "$b"
  done
fi
# Apply the schema (DRY_RUN is honoured inside the helper).
python3 "$REPO/data-pipeline/scripts/apply-schema.py" "$SCHEMA" "$@"

# Force an immediate refresh of refreshable MVs (24.3+). A freshly (re)created refreshable MV is empty
# until its first scheduled refresh, so refresh now to avoid empty dashboards.
if [ "$REFRESH_MV" != "0" ]; then
  mapfile -t RVIEWS < <(ch "SELECT view FROM system.view_refreshes WHERE database='$DB' FORMAT TSV" 2>/dev/null || true)
  if [ "${#RVIEWS[@]}" -gt 0 ] && [ -n "${RVIEWS[0]:-}" ]; then
    for v in "${RVIEWS[@]}"; do
      [ -z "$v" ] && continue
      if [ -n "$DRY_RUN" ]; then
        echo "  DRY_RUN: would SYSTEM REFRESH VIEW $DB.$v"
      else
        echo "  refresh MV $v"; ch "SYSTEM REFRESH VIEW \`$v\`"
      fi
    done
  else
    echo "  (no refreshable MVs found)"
  fi
fi

echo "redeploy-clickhouse: done."
