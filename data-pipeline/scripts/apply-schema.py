#!/usr/bin/env python3
"""Apply ClickHouse schema .sql files over the HTTP interface.

The native TCP protocol resets on some ClickHouse builds, so the schema is applied over HTTP: this
splits each .sql file into statements (comment/quote aware) and POSTs them with ?database=<db>.

Usage (source .env first — it reads the same CLICKHOUSE_* vars as the other scripts):
  set -a; source .env; set +a
  python3 scripts/apply-schema.py schema [basename ...]

With no basenames it applies the standard set in dependency order:
  01 02 03 04 05 06 08 07   (07 daily-summary-aggregates needs 08 reference-tables first)
schema/09-historical-backfill is a manual, parameterised backfill and is never applied by default.
Pass explicit basenames (with or without .sql) to apply a subset or a different order, e.g.:
  python3 scripts/apply-schema.py schema 07-daily-summary-aggregates

Env: CH_HTTP (default http://${CLICKHOUSE_HOST:-localhost}:${CLICKHOUSE_PORT:-8123}),
     CLICKHOUSE_USER (default cce_pipeline), CLICKHOUSE_PASSWORD (required),
     CLICKHOUSE_DB (default cce_analytics),
     DRY_RUN (non-empty = list files + statement counts, apply nothing).
Exit: non-zero if any statement failed (or a named file is missing).
"""
import os, sys, urllib.request, urllib.parse, urllib.error

SCHEMA = sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: apply-schema.py <schema-dir> [basename ...]")
# Default apply order: 07 depends on 08 (facility); 09 is a manual backfill and is excluded.
DEFAULT_ORDER = ["01-create-tables", "02-kafka-ingestion", "03-create-materialized-views",
                 "04-create-indexes", "05-create-dictionary", "06-current-state-rollups",
                 "08-reference-tables", "07-daily-summary-aggregates"]
ORDER = sys.argv[2:] or DEFAULT_ORDER
BASE = os.environ.get("CH_HTTP", "http://%s:%s" % (os.environ.get("CLICKHOUSE_HOST", "localhost"),
                                                  os.environ.get("CLICKHOUSE_PORT", "8123"))).rstrip("/") + "/"
USER = os.environ.get("CLICKHOUSE_USER", "cce_pipeline")
PW = os.environ.get("CLICKHOUSE_PASSWORD")
DB = os.environ.get("CLICKHOUSE_DB", "cce_analytics")
DRY = os.environ.get("DRY_RUN", "")

if not PW:
    sys.exit("ERROR: CLICKHOUSE_PASSWORD not set")


def post(sql, db=None):
    p = {"user": USER, "password": PW}
    if db:
        p["database"] = db
    req = urllib.request.Request(BASE + "?" + urllib.parse.urlencode(p), data=sql.encode(), method="POST")
    try:
        urllib.request.urlopen(req, timeout=120).read()
        return None
    except urllib.error.HTTPError as e:
        return e.read().decode()[:300]


def strip_comments(s):
    out = []; i = 0; n = len(s); inq = None
    while i < n:
        c = s[i]
        if inq:
            out.append(c)
            if c == inq:
                inq = None
            i += 1; continue
        if c in ("'", "`"):
            inq = c; out.append(c); i += 1; continue
        if c == '-' and i + 1 < n and s[i + 1] == '-':
            while i < n and s[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'):
                i += 1
            i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def split_stmts(s):
    stmts = []; cur = []; inq = None
    for c in s:
        if inq:
            cur.append(c)
            if c == inq:
                inq = None
            continue
        if c in ("'", "`"):
            inq = c; cur.append(c); continue
        if c == ';':
            stmts.append("".join(cur).strip()); cur = []; continue
        cur.append(c)
    if "".join(cur).strip():
        stmts.append("".join(cur).strip())
    return [x for x in stmts if x]


files = [os.path.join(SCHEMA, b if b.endswith(".sql") else b + ".sql") for b in ORDER]

for f in files:
    if not os.path.exists(f):
        sys.exit("ERROR: schema file not found: %s" % f)

if DRY:
    print("  DRY_RUN: would CREATE DATABASE IF NOT EXISTS %s and apply over %s:" % (DB, BASE))
    for f in files:
        n = len(split_stmts(strip_comments(open(f).read())))
        print("    %s: %d statements" % (os.path.basename(f), n))
    sys.exit(0)

err = post("CREATE DATABASE IF NOT EXISTS %s" % DB)
print("  CREATE DATABASE:", "ok" if not err else err)
failed = 0
for f in files:
    stmts = split_stmts(strip_comments(open(f).read()))
    n = 0
    for st in stmts:
        if st.lower().startswith("use "):
            continue
        e = post(st, db=DB); n += 1
        if e:
            failed += 1
            print("  FAIL [%s #%d]: %s" % (os.path.basename(f), n, e))
    print("  %s: %d statements" % (os.path.basename(f), n))
sys.exit(1 if failed else 0)
