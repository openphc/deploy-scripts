#!/usr/bin/env bash
# one-click-installer/lib/native/04-data-pipeline.sh <envcode>
# Apply the ClickHouse analytics schema (over HTTP), configure PostgreSQL logical replication
# (native psql), and register the Debezium connector on the native Kafka Connect.
#
#   - ClickHouse schema is loaded over the HTTP interface. The native TCP protocol resets on some
#     builds, so `clickhouse-client --multiquery` is not used; instead a small splitter posts each
#     statement with ?database=cce_analytics (handles the `USE`s).
#   - The connector reaches PostgreSQL on localhost (Connect runs natively on this host; pg_hba
#     allows 127.0.0.1 via scram). Logical-replication ALTER SYSTEM needs the postgres superuser.
#
# CH_HTTP / CONNECT_URL default to STANDARD ports (8123 / 8083) — correct for a dedicated machine.
# PROD's wrapper overrides both to its historical shifted values (8124 / 8086).
#
# Run AFTER 01–03 and AFTER ccedb has the CCE tables (created by the services on first start).
set -euo pipefail

ENVCODE="${1:?usage: 04-data-pipeline.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DP="$REPO/data-pipeline"

CH_USER="${CLICKHOUSE_USER:-cce_pipeline}"
: "${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD}"
CH_HTTP="${CH_HTTP:-http://localhost:8123}"
PG_USER="${POSTGRES_USER:-admin}"
PG_DB="${POSTGRES_DB:-ccedb}"
: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}"
POSTGRES_READ_ONLY_USER="${POSTGRES_READ_ONLY_USER:-cce_cdc_user}"
: "${POSTGRES_READ_ONLY_PASSWORD:?set POSTGRES_READ_ONLY_PASSWORD}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
# The connector JSON uses POSTGRES_HOST/PORT/DATABASE (consistent with UAT). Kafka Connect reaches
# Postgres over the loopback (pg_hba trusts 127.0.0.1), so pin HOST=localhost here — the Infisical
# POSTGRES_HOST is the host IP that k8s pods use, not the native CDC path.
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export POSTGRES_DATABASE="$PG_DB"; export POSTGRES_READ_ONLY_USER POSTGRES_READ_ONLY_PASSWORD

echo "=== [$ENVCODE 1/4] ClickHouse analytics schema (HTTP $CH_HTTP) ==="
CH_USER="$CH_USER" CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" CH_HTTP="$CH_HTTP" \
  python3 - "$DP/schema" <<'PY'
import sys, os, urllib.request, urllib.parse
SCHEMA=sys.argv[1]
BASE=os.environ["CH_HTTP"].rstrip("/")+"/"
USER=os.environ["CH_USER"]; PW=os.environ["CLICKHOUSE_PASSWORD"]; DB="cce_analytics"
def post(sql, db=None):
    p={"user":USER,"password":PW}
    if db: p["database"]=db
    req=urllib.request.Request(BASE+"?"+urllib.parse.urlencode(p), data=sql.encode(), method="POST")
    try: urllib.request.urlopen(req, timeout=120).read(); return None
    except urllib.error.HTTPError as e: return e.read().decode()[:300]
def strip_comments(s):
    out=[]; i=0; n=len(s); inq=None
    while i<n:
        c=s[i]
        if inq:
            out.append(c)
            if c==inq: inq=None
            i+=1; continue
        if c in ("'","`"): inq=c; out.append(c); i+=1; continue
        if c=='-' and i+1<n and s[i+1]=='-':
            while i<n and s[i]!='\n': i+=1
            continue
        if c=='/' and i+1<n and s[i+1]=='*':
            i+=2
            while i+1<n and not (s[i]=='*' and s[i+1]=='/'): i+=1
            i+=2; continue
        out.append(c); i+=1
    return "".join(out)
def split_stmts(s):
    stmts=[]; cur=[]; inq=None
    for c in s:
        if inq:
            cur.append(c)
            if c==inq: inq=None
            continue
        if c in ("'","`"): inq=c; cur.append(c); continue
        if c==';': stmts.append("".join(cur).strip()); cur=[]; continue
        cur.append(c)
    if "".join(cur).strip(): stmts.append("".join(cur).strip())
    return [x for x in stmts if x]
err=post("CREATE DATABASE IF NOT EXISTS %s"%DB)
print("  CREATE DATABASE:", "ok" if not err else err)
files=["01-create-tables","02-kafka-ingestion","03-create-materialized-views",
       "04-create-indexes","05-create-dictionary","06-current-state-rollups",
       "08-reference-tables","07-daily-summary-aggregates"]
failed=0
for f in files:
    stmts=split_stmts(strip_comments(open(os.path.join(SCHEMA,f+".sql")).read()))
    n=0
    for st in stmts:
        if st.lower().startswith("use "): continue
        e=post(st, db=DB); n+=1
        if e: failed+=1; print("  FAIL [%s #%d]: %s"%(f,n,e))
    print("  %s: %d statements"%(f,n))
sys.exit(1 if failed else 0)
PY

echo "=== [$ENVCODE 2/4] PostgreSQL logical replication (native, as postgres superuser) ==="
# The CDC tables are created by the CCE services' own migrations, so wait for them — a fixed sleep was enough only while the
# images were already cached; on a genuinely fresh machine the pods were still pulling images, every ALTER/PUBLICATION hit
# "relation does not exist" and the connector came up FAILED. The list is read from the CDC SQL itself, so it tracks the schema.
CDC_TABLES="$(grep -o -E '^ALTER TABLE +[a-z_]+ +REPLICA IDENTITY' "$DP/cdc/01-configure-replication.sql" | awk '{print $3}' | sort -u)"
WAIT_SECS="${CDC_TABLE_WAIT_SECS:-1200}"; waited=0
while :; do
  missing=""
  for t in $CDC_TABLES; do
    [ "$(sudo -u postgres psql -d "$PG_DB" -tAc "SELECT to_regclass('public.$t') IS NOT NULL")" = t ] || missing="$missing $t"
  done
  [ -z "$missing" ] && { echo "  all $(echo $CDC_TABLES | wc -w) CDC tables present (waited ${waited}s)"; break; }
  if [ "$waited" -ge "$WAIT_SECS" ]; then
    echo "  ✗ after ${WAIT_SECS}s these tables still do not exist:$missing"
    echo "    The services that own them have not finished starting — check: ${KUBECTL:-sudo k3s kubectl} get pods -n cce-$ENVCODE"
    exit 1
  fi
  [ $((waited % 60)) -eq 0 ] && echo "  waiting for the CCE services to create:$missing"
  sleep 15; waited=$((waited + 15))
done

# ALTER SYSTEM (wal_level etc.) requires superuser; the app role is not one.
# Feed the file on STDIN, not `-f <path>`: psql runs as the postgres user, which cannot read a repo that lives under a home
# directory (Ubuntu 26.04 homes are mode 750 — "Permission denied" and the whole CDC setup aborted). The redirect is done by
# this shell, which can read it.
sudo -u postgres psql -d "$PG_DB" < "$DP/cdc/01-configure-replication.sql"
sudo -u postgres psql -d "$PG_DB" \
  -c "ALTER ROLE ${POSTGRES_READ_ONLY_USER} WITH LOGIN REPLICATION PASSWORD '${POSTGRES_READ_ONLY_PASSWORD}';"
# Let Grafana's datasource user (POSTGRES_USER) see full query text in pg_stat_statements —
# otherwise the PostgreSQL Query Analytics panels show "<insufficient privilege>" for queries
# owned by other roles. pg_read_all_stats is read-only stats visibility, no superuser.
sudo -u postgres psql -d "$PG_DB" \
  -c "GRANT pg_read_all_stats TO ${PG_USER};"

echo "=== [$ENVCODE 3/4] activate wal_level=logical (restart only if not already logical) ==="
WAL=$(sudo -u postgres psql -d "$PG_DB" -tAc 'SHOW wal_level' 2>/dev/null | tr -d '[:space:]')
if [ "$WAL" != "logical" ]; then
  sudo systemctl restart postgresql
  for i in $(seq 1 30); do pg_isready -h localhost -p 5432 >/dev/null 2>&1 && break; sleep 2; done
else
  sudo -u postgres psql -d "$PG_DB" -c "SELECT pg_reload_conf();" >/dev/null
fi
echo "  wal_level=$(sudo -u postgres psql -d "$PG_DB" -tAc 'SHOW wal_level')"

echo "=== [$ENVCODE 4/4] register Debezium connector (REST $CONNECT_URL) ==="
for i in $(seq 1 40); do curl -sf "$CONNECT_URL/connectors" >/dev/null 2>&1 && break; sleep 3; done
PAYLOAD="$(envsubst < "$DP/connectors/debezium-postgres-source.json")"
NAME="$(printf '%s' "$PAYLOAD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')"
if curl -sf "$CONNECT_URL/connectors/$NAME" >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["config"]))' \
    | curl -sf -X PUT -H 'Content-Type: application/json' "$CONNECT_URL/connectors/$NAME/config" -d @- >/dev/null && echo "  updated $NAME"
  # a re-run after a failed first attempt: a config PUT does not revive a FAILED connector/task, a restart does
  curl -sf -X POST "$CONNECT_URL/connectors/$NAME/restart?includeTasks=true&onlyFailed=true" >/dev/null 2>&1 && echo "  restarted any failed $NAME tasks"
else
  printf '%s' "$PAYLOAD" | curl -sf -X POST -H 'Content-Type: application/json' "$CONNECT_URL/connectors" -d @- >/dev/null && echo "  created $NAME"
fi
sleep 5
curl -s "$CONNECT_URL/connectors/$NAME/status" | python3 -m json.tool 2>/dev/null | grep -iE 'state' | head
