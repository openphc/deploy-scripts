#!/usr/bin/env bash
# one-click-installer/tools/env-fingerprint.sh <envcode> — print a NORMALISED, diff-able description of an environment's shape.
#
#   sudo bash one-click-installer/tools/env-fingerprint.sh prod  > prod.fp          # on the PROD host
#   sudo bash one-click-installer/tools/env-fingerprint.sh trial > trial.fp         # on the new machine
#   python3 one-click-installer/tools/env-parity.py prod.fp trial.fp                 # compare (anywhere)
#
# Purpose: one-click-installer/install.sh is meant to produce "a setup similar to the reference production environment". This makes that checkable.
# READ-ONLY. No secrets: config keys by NAME only; no passwords, tokens or credential values are ever printed.
#
# Normalisation, so legitimate per-environment differences don't drown real ones: cce-<envcode> -> cce-ENV and every
# IPv4 -> <IP>. PROD's shifted native ports (ClickHouse HTTP 8124, Connect 8086 — rw/docs/ARCHITECTURE.md §3) are probed
# per envcode; override with CH_PORT_OVERRIDE / CONNECT_PORT_OVERRIDE.
# One fact per line:   <section> | <subject> | <detail>
set -uo pipefail
ENVCODE="${1:?usage: env-fingerprint.sh <envcode>}"
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
NS="cce-$ENVCODE"; K="k3s kubectl"
CH_PORT=8123; CONNECT_PORT=8083   # one-click installs use the standard ports; a host with shifted ports sets the *_OVERRIDE vars
CH_PORT="${CH_PORT_OVERRIDE:-$CH_PORT}"; CONNECT_PORT="${CONNECT_PORT_OVERRIDE:-$CONNECT_PORT}"
# 0.0.0.0 means "all interfaces" (identical to an empty listener host) — it is NOT a machine address, so don't mask it as one.
norm() { sed -E "s/cce-${ENVCODE}\b/cce-ENV/g; s#//0\.0\.0\.0:#//:#g; s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<IP>/g"; }
# Version strings are exempt from IP masking: ClickHouse's 26.5.2.39 has four numeric groups and looks exactly like an IPv4.
emit() { if [ "$1" = native-version ]; then printf '%s | %s | %s\n' "$1" "$2" "$3"; else printf '%s | %s | %s\n' "$1" "$2" "$3" | norm; fi; }
pg()   { runuser -u postgres -- psql -d ccedb -tAX -c "$1" 2>/dev/null; }
chq()  { curl -s --max-time 30 "localhost:${CH_PORT}/" --data-binary "$1" 2>/dev/null; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── k8s workloads ────────────────────────────────────────────────────────────────────────────────
cat > "$TMP/k8s.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
for it in sorted(d["items"], key=lambda x: (x["kind"], x["metadata"]["name"])):
    k, n, sp = it["kind"], it["metadata"]["name"], it.get("spec", {})
    if k in ("Deployment", "StatefulSet", "DaemonSet"):
        reps = "ds" if k == "DaemonSet" else sp.get("replicas")
        for c in sp["template"]["spec"]["containers"]:
            r = c.get("resources", {}); rq, lm = r.get("requests", {}), r.get("limits", {})
            print("workload | %s/%s/%s | image=%s replicas=%s req=%s/%s lim=%s/%s readiness=%s liveness=%s" % (
                k, n, c["name"], c["image"], reps, rq.get("cpu", "-"), rq.get("memory", "-"), lm.get("cpu", "-"), lm.get("memory", "-"),
                "y" if c.get("readinessProbe") else "n", "y" if c.get("livenessProbe") else "n"))
            envs = sorted(e["name"] for e in c.get("env", []))
            if envs: print("workload-env | %s/%s/%s | %s" % (k, n, c["name"], ",".join(envs)))
    elif k == "HorizontalPodAutoscaler":
        m = ["%s:%s" % (x.get("resource", {}).get("name"), x.get("resource", {}).get("target", {}).get("averageUtilization")) for x in sp.get("metrics", [])]
        print("hpa | %s | min=%s max=%s target=%s metrics=%s" % (n, sp.get("minReplicas"), sp.get("maxReplicas"), sp["scaleTargetRef"]["name"], ",".join(m)))
    elif k == "Service":
        print("service | %s | %s %s" % (n, sp.get("type"), ",".join("%s/%s" % (p.get("port"), p.get("protocol", "TCP")) for p in sp.get("ports", []))))
    elif k == "Ingress":
        for r in sp.get("rules", []):
            for p in r.get("http", {}).get("paths", []):
                b = p["backend"]["service"]
                print("ingress | %s | %s -> %s:%s tls=%s" % (n, p.get("path"), b["name"], b["port"].get("number"), "y" if sp.get("tls") else "n"))
    elif k == "NetworkPolicy":
        ports = sorted({str(p.get("port")) for e in sp.get("egress", []) for p in e.get("ports", [])})
        print("netpol | %s | policyTypes=%s egress-ports=%s" % (n, ",".join(sp.get("policyTypes", [])), ",".join(ports)))
    elif k == "PodDisruptionBudget":
        print("pdb | %s | min=%s max-unavail=%s" % (n, sp.get("minAvailable"), sp.get("maxUnavailable")))
    elif k == "ConfigMap" and n == "cce-config":
        for key in sorted(it.get("data", {})): print("cce-config-key | %s | present" % key)
PY
$K -n "$NS" get deploy,statefulset,daemonset,hpa,svc,ingress,networkpolicy,cm,pdb -o json 2>/dev/null | python3 "$TMP/k8s.py" | norm
# runtime health: pod "kind" (hash suffixes stripped) -> state, counted
$K -n "$NS" get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); st=($3=="Running"&&a[1]==a[2])?"ready":$3; n=$1; gsub(/-[a-z0-9]+-[a-z0-9]{5}$/,"",n); gsub(/-[a-z0-9]{5}$/,"",n); print n" "st}' \
  | sort | uniq -c | awk '{print "pods | "$2" | "$3" x"$1}' | norm

# ── native services ──────────────────────────────────────────────────────────────────────────────
for u in postgresql kafka clickhouse-server kafka-connect; do
  emit "native-unit" "$u" "enabled=$(systemctl is-enabled "$u" 2>&1 | head -1) active=$(systemctl is-active "$u" 2>&1 | head -1)"
done
emit "native-version" "postgres"   "$(pg 'show server_version' | awk '{print $1}')"
emit "native-version" "kafka"      "$(/opt/kafka/bin/kafka-topics.sh --version 2>/dev/null | awk '{print $1}')"
emit "native-version" "clickhouse" "$(chq 'select version()')"
emit "native-version" "connect"    "$(curl -s --max-time 8 "localhost:${CONNECT_PORT}/" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
emit "native-version" "k3s"        "$(k3s --version | awk 'NR==1{print $3}')"
emit "native-version" "os"         "$(. /etc/os-release; echo "$PRETTY_NAME")"

# ── PostgreSQL ───────────────────────────────────────────────────────────────────────────────────
for s in wal_level max_replication_slots max_wal_senders max_slot_wal_keep_size listen_addresses shared_preload_libraries; do emit "pg-setting" "$s" "$(pg "show $s")"; done
emit "pg-databases"  "list" "$(pg "select string_agg(datname, ',' order by datname) from pg_database where not datistemplate")"
emit "pg-roles"      "list" "$(pg "select string_agg(rolname||case when rolreplication then '(repl)' else '' end||case when rolsuper then '(super)' else '' end, ',' order by rolname) from pg_roles where rolname !~ '^pg_'")"
emit "pg-extensions" "ccedb" "$(pg "select string_agg(extname, ',' order by extname) from pg_extension")"
emit "pg-publication" "list" "$(pg "select string_agg(pubname||':'||(select count(*) from pg_publication_tables t where t.pubname=p.pubname), ',' order by pubname) from pg_publication p")"
emit "pg-slot"       "list" "$(pg "select string_agg(slot_name||':'||plugin, ',') from pg_replication_slots")"
pg "select table_name from information_schema.tables where table_schema='public' order by 1" | while read -r t; do emit "pg-table" "$t" "present"; done
for t in api_permissions protocol_definition; do emit "pg-seed-rows" "$t" "$(pg "select count(*) from $t")"; done

# ── Kafka ────────────────────────────────────────────────────────────────────────────────────────
for kp in listeners advertised.listeners log.retention.hours log.retention.bytes num.partitions auto.create.topics.enable offsets.topic.replication.factor; do
  emit "kafka-prop" "$kp" "$(grep -E "^${kp}=" /opt/kafka/config/kraft/server.properties 2>/dev/null | cut -d= -f2-)"
done
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe 2>/dev/null | awk '/^Topic:/{print $2" "$6" "$8}' | sort \
  | while read -r t p r; do emit "kafka-topic" "$t" "partitions=$p rf=$r"; done

# ── ClickHouse ───────────────────────────────────────────────────────────────────────────────────
emit "ch-databases" "list" "$(chq "select arrayStringConcat(arraySort(groupArray(name)),',') from system.databases where name not in ('system','INFORMATION_SCHEMA','information_schema')")"
chq "select name, engine, ifNull(extract(create_table_query,'TTL [^ ]+ \\\\+ toIntervalDay\\\\([0-9]+\\\\)'),'') from system.tables where database='cce_analytics' order by name format TSV" \
  | while IFS=$'\t' read -r n e ttl; do emit "ch-table" "$n" "engine=$e ${ttl:+$ttl}"; done
emit "ch-named-collections" "list" "$(chq "select arrayStringConcat(arraySort(groupArray(name)),',') from system.named_collections")"
emit "ch-users"        "list" "$(chq "select arrayStringConcat(arraySort(groupArray(name)),',') from system.users")"
emit "ch-dictionaries" "list" "$(chq "select arrayStringConcat(arraySort(groupArray(name)),',') from system.dictionaries")"

# ── Kafka Connect / Debezium ─────────────────────────────────────────────────────────────────────
cat > "$TMP/conn.py" <<'PY'
import json, re, sys
c = json.load(sys.stdin); name = sys.argv[1]; h = c.get("database.hostname", "")
print("connector | %s | class=%s host=%s snapshot=%s slot=%s" % (name, c.get("connector.class", "").split(".")[-1],
      "IP-LITERAL" if re.fullmatch(r"[0-9.]+", h) else "name:" + h, c.get("snapshot.mode"), c.get("slot.name")))
for t in sorted(c.get("table.include.list", "").split(",")): print("connector-table | %s | %s" % (name, t))
PY
for c in $(curl -s --max-time 8 "localhost:${CONNECT_PORT}/connectors" | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin)))' 2>/dev/null); do
  curl -s --max-time 8 "localhost:${CONNECT_PORT}/connectors/$c/config" | python3 "$TMP/conn.py" "$c" | norm
  emit "connector-status" "$c" "$(curl -s --max-time 8 "localhost:${CONNECT_PORT}/connectors/$c/status" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["connector"]["state"], ",".join(t["state"] for t in d["tasks"]))' 2>/dev/null)"
done

# ── network exposure ─────────────────────────────────────────────────────────────────────────────
emit "firewall" "ufw" "$(ufw status 2>/dev/null | head -1)"
ufw status 2>/dev/null | awk '/ALLOW/ && !/v6/ {print $1" "$2" "$3}' | sort -u | while read -r r; do emit "ufw-rule" "$r" ""; done
emit "firewall" "docker-fw-unit" "enabled=$(systemctl is-enabled cce-docker-fw 2>&1 | head -1) active=$(systemctl is-active cce-docker-fw 2>&1 | head -1) rules=$(iptables -S DOCKER-USER 2>/dev/null | grep -c cce-block)"
