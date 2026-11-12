#!/usr/bin/env bash
# rw/lib/install-cron-backups.sh <envcode> — install the daily backup cron (root crontab) + logrotate for an environment installed
# by rw/one-click-install.sh, run under one-click-installer/lib/infisical-run.sh. Idempotent.
#   SCHEDULE (default "0 2 * * *"), BACKUP_DIR (default /var/backups/cce-<envcode>), RETENTION_DAYS (default 10)
set -euo pipefail
ENVCODE="${1:?usage: install-cron-backups.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }
BACKUP_SCRIPT="$HERE/backup-db.sh"
WRAPPER="$REPO/one-click-installer/lib/infisical-run.sh"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cce-$ENVCODE}"
SCHEDULE="${SCHEDULE:-0 2 * * *}"
RETENTION_DAYS="${RETENTION_DAYS:-10}"
# cron runs with no SUDO_USER, so creds-dir.sh would fall back to /root/.cce-infisical — pin the directory the install used.
. "$REPO/one-click-installer/lib/creds-dir.sh"; CREDS_DIR="$(cce_creds_dir)"
[ -r "$CREDS_DIR/$ENVCODE.creds" ] || { echo "ERROR: no Infisical creds at $CREDS_DIR/$ENVCODE.creds — install the environment first"; exit 1; }
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

MARK="# cce-$ENVCODE daily backup"
LINE="$SCHEDULE CCE_INFISICAL_CREDS_DIR=$CREDS_DIR BACKUP_DIR=$BACKUP_DIR RETENTION_DAYS=$RETENTION_DAYS bash $WRAPPER $ENVCODE bash $BACKUP_SCRIPT $ENVCODE >> $BACKUP_DIR/cron.log 2>&1  $MARK"
TMPCRON="$(mktemp)"
crontab -l 2>/dev/null | grep -vF "$MARK" > "$TMPCRON" || true
echo "$LINE" >> "$TMPCRON"
crontab "$TMPCRON"; rm -f "$TMPCRON"
echo "  cron: $(crontab -l | grep -F "$MARK")"

cat > "/etc/logrotate.d/cce-$ENVCODE-backup" <<EOF
$BACKUP_DIR/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
echo "  logrotate: /etc/logrotate.d/cce-$ENVCODE-backup"
echo "  run once now: sudo CCE_INFISICAL_CREDS_DIR=$CREDS_DIR bash $WRAPPER $ENVCODE bash $BACKUP_SCRIPT $ENVCODE"
