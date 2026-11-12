#!/usr/bin/env bash
# one-click-installer/tools/connector-repoint.sh <prod|uat> — make the Debezium connector's DB address independent of the public IP.
#
#   bash one-click-installer/tools/connector-repoint.sh prod     # -> localhost:5432        (native Postgres on the same host)
#   bash one-click-installer/tools/connector-repoint.sh uat      # -> postgres-uat:5432     (same docker network as cce-kafka-connect)
#
# WHY: register-connectors.sh / 04-data-pipeline.sh render database.hostname from ${POSTGRES_HOST}, which is the host's
# public IP — so every (re-)registration re-bakes the IP into the connector, and when the IP changes the CDC task dies
# (PROD's did, 2026-10: "Couldn't obtain encoding for database ccedb"). Run this AFTER any (re-)registration.
#
# Takes the connector's OWN live config and changes only host/port/password, so the replicated table list cannot drift
# (the repo has two differing connector templates). Idempotent: if already IP-free it changes nothing and does not restart
# the task. The password is injected from Infisical (Connect's GET masks it as "[hidden]"); it is never printed.
set -euo pipefail
ENVN="${1:?usage: connector-repoint.sh <prod|uat>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${POSTGRES_READ_ONLY_PASSWORD:-}" ]; then exec bash "$HERE/../lib/infisical-run.sh" "$ENVN" bash "$0" "$ENVN"; fi   # self-wrap
export ENVN
python3 - <<'PY'
import json, os, sys, time, urllib.request
env = os.environ["ENVN"]
# One-click topology: Kafka Connect and PostgreSQL are both native on this host -> localhost is IP-free and stable.
URL  = os.environ.get("CONNECT_URL", "http://localhost:8083")
HOST = os.environ.get("CDC_DB_HOST", "localhost")
PORT = os.environ.get("POSTGRES_PORT", "5432")
NAME = "cce-ccedb-source"
def call(method, path, body=None):
    req = urllib.request.Request(URL + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read().decode(); return json.loads(raw) if raw else {}
cfg = call("GET", f"/connectors/{NAME}/config")
print(f"[{env}] now: {cfg.get('database.hostname')}:{cfg.get('database.port')}")
if cfg.get("database.hostname") == HOST and cfg.get("database.port") == PORT:
    print(f"[{env}] already IP-free — nothing to do"); sys.exit(0)
if cfg.get("database.user") != os.environ.get("POSTGRES_READ_ONLY_USER"):
    sys.exit(f"[{env}] ABORT: connector user differs from POSTGRES_READ_ONLY_USER; not touching it")
cfg.update({"database.hostname": HOST, "database.port": PORT,
            "database.password": os.environ["POSTGRES_READ_ONLY_PASSWORD"]})
call("PUT", f"/connectors/{NAME}/config", cfg)
print(f"[{env}] re-pointed -> {HOST}:{PORT}")
for i in range(12):
    time.sleep(5); st = call("GET", f"/connectors/{NAME}/status"); tasks = [t["state"] for t in st["tasks"]]
    print(f"  t+{(i+1)*5:>2}s connector={st['connector']['state']} tasks={tasks}")
    if tasks and all(t == "RUNNING" for t in tasks): break
else:
    sys.exit(f"[{env}] task did not reach RUNNING — check: curl {URL}/connectors/{NAME}/status")
PY
