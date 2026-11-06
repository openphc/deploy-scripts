#!/usr/bin/env bash
# rw/lib/backup-db.sh <envcode> — daily backup of an environment installed by rw/one-click-install.sh (dedicated machine, native
# data stores). Same dumps, layout and retention as rw/prod/backup-prod-db.sh, so rw/docs/BACKUP-RESTORE.md applies unchanged:
#   PostgreSQL  ccedb + keycloak  -> $BACKUP_DIR/<YYYYMMDD>/pg-<db>-<stamp>.sql.gz
#   ClickHouse  cce_analytics base tables (Native, base64) -> clickhouse-cce_analytics-<stamp>.sql.gz  (rebuildable from CDC)
# Run under the Infisical wrapper so CLICKHOUSE_USER/PASSWORD are set (rw/lib/install-cron-backups.sh wires the cron that way):
#   one-click-installer/lib/infisical-run.sh <envcode> bash rw/lib/backup-db.sh <envcode>
# Without them the Postgres dumps still run (peer auth) and only ClickHouse is skipped.
set -euo pipefail
ENVCODE="${1:?usage: backup-db.sh <envcode>}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cce-$ENVCODE}"
RETENTION_DAYS="${RETENTION_DAYS:-10}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_DIR/$(date +%Y%m%d)"
LOG="$BACKUP_DIR/backup.log"
# Dedicated machine: ClickHouse on its standard HTTP port (PROD's 8124 is a shared-host shift).
CH_HTTP="${CH_HTTP:-http://localhost:${CLICKHOUSE_PORT:-8123}}"

mkdir -p "$DEST"; chmod 700 "$BACKUP_DIR"
log(){ echo "$(date -Is) $*" | tee -a "$LOG"; }
log "=== backup start ($STAMP) -> $DEST ==="

for DB in "${POSTGRES_DB:-ccedb}" keycloak; do
  OUT="$DEST/pg-${DB}-${STAMP}.sql.gz"
  if sudo -u postgres pg_dump --no-owner --clean --if-exists "$DB" | gzip > "$OUT"; then
    log "  postgres/$DB -> $(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
  else
    log "  ERROR dumping postgres/$DB"; FAILED=1
  fi
done

if [ -n "${CLICKHOUSE_USER:-}" ] && [ -n "${CLICKHOUSE_PASSWORD:-}" ]; then
  # Credentials go to curl as headers from a config on a file descriptor — not in argv (ps) or the URL.
  ch() { curl -sf -K <(printf 'header = "X-ClickHouse-User: %s"\nheader = "X-ClickHouse-Key: %s"\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD") "$@"; }
  CH_OUT="$DEST/clickhouse-cce_analytics-${STAMP}.sql.gz"
  {
    # base MergeTree tables only (MVs/queues/dictionaries are rebuilt by the schema scripts)
    for T in $(ch "$CH_HTTP/" --data-binary "SELECT name FROM system.tables WHERE database='cce_analytics' AND engine LIKE '%MergeTree%' AND name NOT LIKE '%_mv' AND name NOT LIKE '%_queue' ORDER BY name"); do
      echo "-- TABLE $T"
      ch "$CH_HTTP/?database=cce_analytics" --data-binary "SELECT * FROM ${T} FORMAT Native" | base64
      echo "-- ENDTABLE $T"
    done
  } | gzip > "$CH_OUT" && log "  clickhouse/cce_analytics -> $(basename "$CH_OUT") ($(du -h "$CH_OUT" | cut -f1))" \
     || log "  WARN clickhouse dump incomplete (analytics is rebuildable from CDC)"
else
  log "  clickhouse skipped (CLICKHOUSE_USER/PASSWORD not in env)"
fi

find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
log "=== backup done; retention=${RETENTION_DAYS}d; total $(du -sh "$BACKUP_DIR" | cut -f1) ==="
exit "${FAILED:-0}"
