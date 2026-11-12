#!/usr/bin/env bash
# one-click-installer/tools/host-ip-check.sh — READ-ONLY. After the VM's IP changes (or any time), list every place the
# address is still baked in and whether it matches this host's current IP. Exit 1 if anything drifted.
#
#   sudo bash one-click-installer/tools/host-ip-check.sh
#
# Covers what Infisical does NOT (that is handled by one-click-installer/lib/host-ip.sh): Kafka's advertised
# listeners, the NetworkPolicy, the live cce-config, DNS, the Debezium connectors, ClickHouse config.
# It changes nothing; the FIX for each DRIFT line is in rw/docs/OPERATIONS-RUNBOOK.md ("Server IP changed").
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/host-ip.sh"
K="k3s kubectl"
IP="$(cce_detect_host_ip)"
[ -n "$IP" ] || { echo "cannot detect this host's IP"; exit 2; }
bad=0

row() {  # label expected actual
  if [ "$2" = "$3" ]; then printf "  OK     %-46s %s\n" "$1" "$3"
  else printf "  DRIFT  %-46s expected %s, found %s\n" "$1" "$2" "${3:-<none>}"; bad=$((bad+1)); fi
}
host_of() { sed -E 's#^[A-Za-z]+://##; s#:[0-9]+(/.*)?$##'; }

echo "Host IP (detected from routing table): $IP"
echo
echo "── Kafka advertised listeners (clients are told to reconnect to this address)"
if [ -r /opt/kafka/config/kraft/server.properties ]; then
  row "PROD native kafka advertised.listeners" "$IP" \
      "$(sed -n 's/^advertised.listeners=//p' /opt/kafka/config/kraft/server.properties | host_of)"
fi
if docker inspect kafka-uat >/dev/null 2>&1; then
  row "UAT kafka container KAFKA_ADVERTISED_LISTENERS" "$IP" \
      "$(docker inspect kafka-uat --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^KAFKA_ADVERTISED_LISTENERS=//p' | host_of)"
fi

echo "── Kubernetes"
ENVS="${1:-$(k3s kubectl get ns -o name 2>/dev/null | sed -n 's#^namespace/cce-##p' | tr '\n' ' ')}"   # default: every cce-* namespace
for ns in $(for e in $ENVS; do echo "cce-$e"; done); do
  $K get ns "$ns" >/dev/null 2>&1 || continue
  cidrs="$($K -n "$ns" get networkpolicy -o json 2>/dev/null | python3 -c '
import json,sys
for it in json.load(sys.stdin)["items"]:
    for r in it["spec"].get("egress",[])+it["spec"].get("ingress",[]):
        for t in (r.get("to") or r.get("from") or []):
            c=t.get("ipBlock",{}).get("cidr","")
            if c.endswith("/32"): print(c)' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  row "$ns NetworkPolicy host ipBlock" "$IP/32" "$cidrs"
  cm="$($K -n "$ns" get cm cce-config -o json 2>/dev/null)"
  val() { printf '%s' "$cm" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('$1',''))" 2>/dev/null; }
  row "$ns cce-config POSTGRES_HOST"           "$IP" "$(val POSTGRES_HOST)"
  row "$ns cce-config KAFKA_BOOTSTRAP_SERVERS" "$IP" "$(val KAFKA_BOOTSTRAP_SERVERS | host_of)"
  row "$ns cce-config CLICKHOUSE_HOST" "$IP" "$(val CLICKHOUSE_HOST)"
  for h in $($K -n "$ns" get ingress -o jsonpath='{.items[*].spec.rules[*].host}' 2>/dev/null | tr ' ' '\n' | sort -u); do
    row "$ns ingress DNS  $h" "$IP" "$(getent ahostsv4 "$h" | awk 'NR==1{print $1}')"
  done
done

echo "── Debezium connectors (should be IP-free: localhost / docker service name)"
for p in "UAT:8083" "PROD:8086"; do
  e="${p%%:*}"; port="${p##*:}"
  h="$(curl -s --max-time 6 "localhost:$port/connectors/cce-ccedb-source/config" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("database.hostname",""))' 2>/dev/null)"
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then row "$e connector database.hostname" "$IP" "$h"
  elif [ -n "$h" ]; then printf "  OK     %-46s %s (name, not an IP)\n" "$e connector database.hostname" "$h"; fi
  st="$(curl -s --max-time 6 "localhost:$port/connectors/cce-ccedb-source/status" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["connector"]["state"]+" "+",".join(t["state"] for t in d["tasks"]))' 2>/dev/null)"
  [ -n "$st" ] && { case "$st" in *FAILED*) printf "  DRIFT  %-46s %s\n" "$e connector state" "$st"; bad=$((bad+1));;
                    *) printf "  OK     %-46s %s\n" "$e connector state" "$st";; esac; }
done

echo "── ClickHouse config: public-looking IP literals that are not this host"
lits="$(grep -rhoE '([0-9]{1,3}\.){3}[0-9]{1,3}' /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d 2>/dev/null \
        | sort -u | grep -v -E '^(127\.|10\.|0\.0\.0\.0|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | grep -v -x "$IP")"
if [ -z "$lits" ]; then printf "  OK     %-46s none\n" "stray public IPs in config.d/users.d"
else printf "  DRIFT  %-46s %s\n" "stray public IPs in config.d/users.d" "$(echo $lits)"; bad=$((bad+1)); fi

echo
if [ "$bad" -eq 0 ]; then echo "RESULT: no drift — everything agrees with $IP"; else echo "RESULT: $bad item(s) drifted from $IP"; fi
exit $(( bad > 0 ))
