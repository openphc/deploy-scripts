#!/usr/bin/env bash
# one-click-installer/lib/infisical-native.sh <up|migrate|status> — Infisical installed NATIVELY (infisical-core package), no docker.
#
#   up       install + start (fresh machine): Redis and PostgreSQL from apt, the "infisical" database, infisical-core, first org-admin
#   migrate  move an existing docker Infisical (one-click-installer/lib/infisical-local.sh, project cce-local-infisical) to native:
#            same ENCRYPTION_KEY/AUTH_SECRET, its database copied into native PostgreSQL, verified, then the containers removed
#   status   health + version
#
# Same contract as infisical-local.sh, so everything downstream is unchanged: API on 127.0.0.1:8080 (HOST=localhost — never on
# the network), state in $CCE_LOCAL_INFISICAL_DIR (default /opt/cce-local-infisical): .env (ENCRYPTION_KEY, AUTH_SECRET,
# PG_PASSWORD; 0600) and admin.env (the org-admin login one-click-install.sh picks up).
#
# INFISICAL_CORE_VERSION pins the package (default 0.162.24-1: there is no native 0.161.x, and a database written by the v0.161.0
# image must not go backwards — the server only migrates forward). Redis: Ubuntu's redis-server (6.x/7.x supported), loopback only.
# PostgreSQL: installed here only if absent, from PGDG exactly like k8s/infrastructure/setup-prod-infra.sh (which later finds it
# and configures it for CCE). Infisical connects over 127.0.0.1 with its own role.
set -euo pipefail
CMD="${1:-status}"
STATE="${CCE_LOCAL_INFISICAL_DIR:-/opt/cce-local-infisical}"
VER="${INFISICAL_CORE_VERSION:-0.162.24-1}"
PG_VER="${POSTGRES_VERSION:-16}"
BASE="http://127.0.0.1:8080"
CONF=/etc/infisical/infisical.rb
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $CMD" >&2; exit 1; }
log() { echo "[infisical-native] $*"; }
healthy() { curl -sf --max-time 5 "$BASE/api/status" >/dev/null 2>&1; }
apt_q() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null; }
psql_su() { sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA "$@"; }

ensure_secrets() {
  install -d -m 700 "$STATE"
  if [ ! -f "$STATE/.env" ]; then
    # umask in a subshell: left set, it made everything this script creates later 0600 — including the PGDG apt keyring,
    # which apt's unprivileged _apt user then could not read ("repository ... is not signed"), on a fresh machine.
    ( umask 077
      { echo "ENCRYPTION_KEY=$(openssl rand -hex 16)"; echo "AUTH_SECRET=$(openssl rand -base64 32)"
        echo "PG_PASSWORD=$(openssl rand -hex 24)"; } > "$STATE/.env" )
    log "generated secrets -> $STATE/.env (0600)"
  fi
  set -a; . "$STATE/.env"; set +a
  : "${ENCRYPTION_KEY:?}" "${AUTH_SECRET:?}" "${PG_PASSWORD:?}"
}

ensure_redis() {
  command -v redis-server >/dev/null || { log "installing redis-server"; apt_q redis-server; }
  # Loopback only, whatever the package default is. IPv4 only: Ubuntu 22.04's Redis 6 reads 7.x's optional "-::1" as a host name
  # and refuses to start; Infisical connects to 127.0.0.1 anyway.
  sed -i -E 's/^#?\s*bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
  sed -i -E 's/^#?\s*protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
  systemctl enable --now redis-server >/dev/null 2>&1; systemctl restart redis-server
  redis-cli -h 127.0.0.1 ping | grep -q PONG || { echo "ERROR: redis not answering on 127.0.0.1:6379" >&2; exit 1; }
  log "redis-server $(redis-server --version | grep -oE 'v=[0-9.]+' | cut -d= -f2) on 127.0.0.1:6379"
}

ensure_postgres() {
  if ! command -v psql >/dev/null; then
    log "installing PostgreSQL ${PG_VER} (PGDG — same source as setup-prod-infra.sh)"
    apt_q gnupg2 lsb-release
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/postgresql.gpg
    chmod 644 /etc/apt/trusted.gpg.d/postgresql.gpg   # apt verifies as _apt: an unreadable keyring = "not signed"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq; apt_q "postgresql-${PG_VER}"
    systemctl enable --now postgresql >/dev/null 2>&1
  fi
  for _ in $(seq 1 30); do psql_su -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  if [ "$(psql_su -c "select 1 from pg_roles where rolname='infisical'")" = 1 ]; then
    psql_su -c "ALTER ROLE infisical WITH LOGIN PASSWORD '${PG_PASSWORD}'"
  else
    psql_su -c "CREATE ROLE infisical WITH LOGIN PASSWORD '${PG_PASSWORD}'"
  fi
  [ "$(psql_su -c "select 1 from pg_database where datname='infisical'")" = 1 ] || psql_su -c "CREATE DATABASE infisical OWNER infisical"
}

ensure_package() {
  if [ ! -f /etc/apt/sources.list.d/infisical-core.list ]; then   # (not `apt-cache policy | grep -q`: SIGPIPE + pipefail = false miss)
    log "adding the infisical-core apt repository"
    local s; s="$(mktemp)"; curl -1sLf 'https://artifacts-infisical-core.infisical.com/setup.deb.sh' -o "$s"; bash "$s" >/dev/null; rm -f "$s"
  fi
  if [ "$(dpkg-query -W -f='${Version}' infisical-core 2>/dev/null || true)" != "$VER" ]; then
    # The package is held (below) so a routine apt upgrade cannot move it; changing INFISICAL_CORE_VERSION must override that.
    log "installing infisical-core $VER"; apt_q --allow-downgrades --allow-change-held-packages "infisical-core=$VER"
    apt-mark hold infisical-core >/dev/null
  fi
}

write_config_and_start() {
  install -d -m 755 /etc/infisical
  ( umask 077; cat > "$CONF" <<RB
# Written by one-click-installer/lib/infisical-native.sh — secrets come from $STATE/.env; edit there, then re-run.
infisical_core['ENCRYPTION_KEY'] = '${ENCRYPTION_KEY}'
infisical_core['AUTH_SECRET'] = '${AUTH_SECRET}'
infisical_core['DB_CONNECTION_URI'] = 'postgres://infisical:${PG_PASSWORD}@127.0.0.1:5432/infisical'
infisical_core['REDIS_URL'] = 'redis://127.0.0.1:6379'
infisical_core['SITE_URL'] = 'http://localhost:8080'
infisical_core['HOST'] = '127.0.0.1'
infisical_core['PORT'] = '8080'
infisical_core['TELEMETRY_ENABLED'] = 'false'
RB
  )
  # reconfigure enables and starts the runit supervisor only when it (re)writes its systemd unit. A unit left from an earlier
  # install (it is not package-owned, so a purge keeps it) is "up to date", nothing starts runsvdir, and reconfigure fails with
  # "runsv not running". Start it ourselves when the unit is already there.
  if [ -f /usr/lib/systemd/system/infisical-runsvdir.service ]; then systemctl enable --now infisical-runsvdir >/dev/null 2>&1 || true; fi
  infisical-ctl reconfigure >/tmp/infisical-reconfigure.log 2>&1 || { echo "ERROR: infisical-ctl reconfigure failed:"; tail -20 /tmp/infisical-reconfigure.log; exit 1; }
  for _ in $(seq 1 90); do healthy && break; sleep 2; done
  healthy || { echo "ERROR: native Infisical not answering on $BASE — see: infisical-ctl tail" >&2; exit 1; }
  local where; where="$(ss -tlnp | awk '$4 ~ /:8080$/ {print $4}' | tr '\n' ' ')"
  case "$where" in *0.0.0.0:8080*|*'*:8080'*|*'[::]:8080'*) echo "ERROR: Infisical listens on $where — expected 127.0.0.1 only" >&2; exit 1;; esac
  log "native Infisical $VER UP at $BASE (listening on ${where% })"
}

first_admin() {
  [ -f "$STATE/admin.env" ] && { log "admin already created ($STATE/admin.env)"; return; }
  local email="admin@cce.local" pass code; pass="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)Aa1!"
  code="$(curl -s -o "$STATE/.signup.json" -w '%{http_code}' -X POST "$BASE/api/v1/admin/signup" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2],"firstName":"CCE","lastName":"Admin"}))' "$email" "$pass")")"
  if [ "$code" = 200 ]; then
    ( umask 077; printf 'INFISICAL_ADMIN_EMAIL=%s\nINFISICAL_ADMIN_PASSWORD=%s\nINFISICAL_DOMAIN=%s\n' "$email" "$pass" "$BASE" > "$STATE/admin.env" )
    rm -f "$STATE/.signup.json"; log "created first org-admin -> $STATE/admin.env (0600)"
  else
    echo "ERROR: first-admin signup returned HTTP $code: $(head -c 300 "$STATE/.signup.json")" >&2; exit 1
  fi
}

case "$CMD" in
  status)
    healthy && echo "native Infisical: UP at $BASE ($(dpkg-query -W -f='${Version}' infisical-core 2>/dev/null))" || echo "native Infisical: DOWN"
    ;;
  up)
    ensure_secrets; ensure_redis; ensure_postgres; ensure_package; write_config_and_start; first_admin
    ;;
  migrate)
    command -v docker >/dev/null && docker ps -a --format '{{.Names}}' | grep -q '^cce-local-infisical-db-1$' \
      || { echo "nothing to migrate: no docker Infisical (cce-local-infisical) on this machine — use: up" >&2; exit 1; }
    ensure_secrets   # the docker install's .env: the SAME keys must decrypt the copied data
    ensure_redis; ensure_postgres; ensure_package
    DUMP="$STATE/docker-infisical-$(date +%Y%m%d-%H%M%S).sql.gz"
    log "stopping the docker Infisical server (its database stays up for the copy)"
    docker stop cce-local-infisical-backend-1 >/dev/null
    docker exec cce-local-infisical-db-1 pg_dump -U infisical -d infisical --no-owner --no-privileges | gzip > "$DUMP"; chmod 600 "$DUMP"
    log "dumped the docker database -> $DUMP ($(du -h "$DUMP" | cut -f1))"
    psql_su -c "DROP DATABASE IF EXISTS infisical" -c "CREATE DATABASE infisical OWNER infisical"
    # Restore AS infisical (over 127.0.0.1, its own password), so every object belongs to the role the server uses — a restore as
    # postgres cannot be fixed afterwards (REASSIGN OWNED BY postgres refuses: the system objects belong to postgres too).
    zcat "$DUMP" | PGPASSWORD="$PG_PASSWORD" psql -h 127.0.0.1 -U infisical -d infisical -v ON_ERROR_STOP=1 -q >/dev/null
    log "restored into native PostgreSQL (database infisical, owner infisical): $(psql_su -d infisical -c "select count(*) from pg_tables where schemaname='public'") tables"
    write_config_and_start
    log "native server is up on the copied data; the docker containers are still there (stopped backend) until you remove them:"
    log "  docker compose --project-name cce-local-infisical --project-directory $STATE down    # data volume kept"
    ;;
  *) echo "usage: $0 <up|migrate|status>" >&2; exit 2;;
esac
