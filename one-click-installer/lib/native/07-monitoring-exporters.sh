#!/usr/bin/env bash
# one-click-installer/lib/native/07-monitoring-exporters.sh <envcode>
# Stand up Prometheus exporters for the NATIVE (host-installed) services that k3s can't see:
# PostgreSQL and Kafka. ClickHouse needs no exporter (its native install already serves Prometheus
# metrics — see one-click-installer/lib/native/02-install-clickhouse.sh / the prometheus-config overlay patch).
#
#   - postgres_exporter (prometheus-community): read-only `postgres_exporter` role (pg_monitor,
#     no superuser) against native ccedb on :5432, exposes :9187/metrics.
#   - kafka_exporter (danielqsj): consumer-group lag / topic-partition metrics against the native,
#     unauthenticated Kafka broker on localhost:9092, exposes :9308/metrics.
#
# They run as systemd services by default (EXPORTER_RUNTIME, below), or as `docker run --network host` (not k3s pods — they need to reach native localhost
# services, matching how ClickHouse/Postgres/Kafka themselves are host-resident). --restart
# unless-stopped survives reboots. --log-opt max-size=10m/max-file=3 (30MB cap) — there's no
# /etc/docker/daemon.json default, so an unbounded json-file driver is the alternative. Idempotent:
# re-running reuses the existing Infisical-stored password rather than rotating it, and replaces
# the containers in place (docker log-opts can only be set at container creation, not changed live).
#
# RUN:  sudo -A bash one-click-installer/lib/infisical-run.sh <envcode> bash one-click-installer/lib/native/07-monitoring-exporters.sh <envcode>
set -euo pipefail

ENVCODE="${1:?usage: 07-monitoring-exporters.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../infisical-secret-helpers.sh
. "$REPO/one-click-installer/lib/infisical-secret-helpers.sh"

PSQL="sudo -u postgres psql -p 5432 -d ${POSTGRES_DB:-ccedb} -v ON_ERROR_STOP=1"

log(){ echo "[monitoring-exporters $ENVCODE $(date -u +%H:%M:%S)] $*"; }
# Poll a metrics endpoint for a pattern instead of a fixed sleep (container replace can take a
# few seconds longer than expected, e.g. the old container's port not yet released).
wait_for_metric(){ # url pattern max_tries
  local url="$1" pattern="$2" tries="${3:-10}"
  for _ in $(seq 1 "$tries"); do
    # not `grep -q`: it exits at the first match, curl dies of SIGPIPE writing the rest, and pipefail reports a failure
    curl -sf -m 5 "$url" 2>/dev/null | grep "$pattern" >/dev/null && return 0
    sleep 2
  done
  return 1
}

# ============================================================ postgres_exporter
log "postgres_exporter: resolve credential"
infisical_resolve_project "$ENVCODE"
infisical_login

PGEXP_PW=$(infisical_get_or_generate /postgres POSTGRES_EXPORTER_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG")
log "  password ready (reused existing, or generated + stored in Infisical /postgres)"

log "postgres_exporter: create/update monitoring role (pg_monitor, no superuser)"
$PSQL <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    CREATE ROLE postgres_exporter WITH LOGIN PASSWORD '${PGEXP_PW}';
  ELSE
    ALTER ROLE postgres_exporter WITH LOGIN PASSWORD '${PGEXP_PW}';
  END IF;
END
\$\$;
GRANT pg_monitor TO postgres_exporter;
SQL

# EXPORTER_RUNTIME: systemd (default — release binaries as host services, no container at all) or docker (the reference
# deployment's `docker run --network host`). Same exporters, versions, ports, credentials and flags either way, so Prometheus scrape jobs
# and Grafana dashboards are identical. Switching runtime removes the other one's exporters (they would fight over 9187/9308).
RUNTIME="${EXPORTER_RUNTIME:-systemd}"
case "$RUNTIME" in docker|systemd) ;; *) log "!! EXPORTER_RUNTIME must be docker or systemd (got '$RUNTIME')"; exit 1;; esac
# Pinned releases (versions = what the docker images ran when this was written). kafka_exporter publishes no checksum file: its
# SHA-256 is pinned here. Overriding a version needs the matching *_SHA256.
PGEXP_VER="${POSTGRES_EXPORTER_VERSION:-0.20.1}"
PGEXP_SHA="${POSTGRES_EXPORTER_SHA256:-89d4f7e7920cad48fdc3133f789556ef5253c330a9f5fdace3bdb6344c0a8b5a}"
KEXP_VER="${KAFKA_EXPORTER_VERSION:-1.11.0}"
KEXP_SHA="${KAFKA_EXPORTER_SHA256:-6a14dd10709d627d7be29a4b98fae8bb888761c7da54410e72bef8cdaf906e86}"
EXP_USER=cce-exporter; EXP_ETC=/etc/cce-exporters

install_release(){ # <url> <sha256> <binary> <version> — into /usr/local/bin, verified; skipped if that version is already there
  local url="$1" sum="$2" bin="$3" ver="$4" dst="/usr/local/bin/$3" t
  if [ -x "$dst" ] && "$dst" --version 2>&1 | grep -F "version $ver" >/dev/null; then return 0; fi
  t="$(mktemp -d)"; curl -fsSL --retry 3 --max-time 300 -o "$t/a.tgz" "$url"
  echo "$sum  $t/a.tgz" | sha256sum -c --quiet - || { log "  !! checksum mismatch for $url"; rm -rf "$t"; exit 1; }
  tar xzf "$t/a.tgz" -C "$t"; sudo install -m 0755 "$(find "$t" -type f -name "$bin" | head -1)" "$dst"; rm -rf "$t"
  log "  installed $bin $ver -> $dst (sha256 verified)"
}
exporter_unit(){ # <unit> <description> <after> <ExecStart>
  sudo tee "/etc/systemd/system/$1.service" >/dev/null <<UNIT
[Unit]
Description=$2 (one-click-installer/lib/native/07-monitoring-exporters.sh)
After=network-online.target $3
Wants=network-online.target

[Service]
User=$EXP_USER
Group=$EXP_USER
EnvironmentFile=-$EXP_ETC/$1.env
ExecStart=$4
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
}

if [ "$RUNTIME" = systemd ]; then
  log "exporters as systemd services (no containers)"
  id -u "$EXP_USER" >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$EXP_USER"
  sudo install -d -m 0750 -o root -g "$EXP_USER" "$EXP_ETC"
  install_release "https://github.com/prometheus-community/postgres_exporter/releases/download/v${PGEXP_VER}/postgres_exporter-${PGEXP_VER}.linux-amd64.tar.gz" \
    "$PGEXP_SHA" postgres_exporter "$PGEXP_VER"
  install_release "https://github.com/danielqsj/kafka_exporter/releases/download/v${KEXP_VER}/kafka_exporter-${KEXP_VER}.linux-amd64.tar.gz" \
    "$KEXP_SHA" kafka_exporter "$KEXP_VER"
  printf 'DATA_SOURCE_NAME=postgresql://postgres_exporter:%s@localhost:5432/%s?sslmode=disable\n' "$PGEXP_PW" "${POSTGRES_DB:-ccedb}" \
    | sudo install -m 0640 -o root -g "$EXP_USER" /dev/stdin "$EXP_ETC/cce-postgres-exporter.env"
  exporter_unit cce-postgres-exporter "Prometheus postgres_exporter for native PostgreSQL" postgresql.service \
    "/usr/local/bin/postgres_exporter --web.listen-address=:9187"
  exporter_unit cce-kafka-exporter "Prometheus kafka_exporter for native Kafka" kafka.service \
    "/usr/local/bin/kafka_exporter --kafka.server=localhost:9092 --web.listen-address=:9308"
  command -v docker >/dev/null 2>&1 && docker rm -f postgres-exporter kafka-exporter >/dev/null 2>&1 || true
  sudo systemctl daemon-reload
  sudo systemctl enable cce-postgres-exporter cce-kafka-exporter >/dev/null 2>&1
  sudo systemctl restart cce-postgres-exporter cce-kafka-exporter
else
  # (back to docker from systemd: stop the services first, or the containers cannot bind the ports)
  sudo systemctl disable --now cce-postgres-exporter cce-kafka-exporter >/dev/null 2>&1 || true
  log "postgres_exporter: (re)deploy container"
  docker rm -f postgres-exporter >/dev/null 2>&1 || true
  docker run -d --name postgres-exporter --restart unless-stopped --network host \
    --log-opt max-size=10m --log-opt max-file=3 \
    -e DATA_SOURCE_NAME="postgresql://postgres_exporter:${PGEXP_PW}@localhost:5432/${POSTGRES_DB:-ccedb}?sslmode=disable" \
    quay.io/prometheuscommunity/postgres-exporter:latest >/dev/null
fi
wait_for_metric http://localhost:9187/metrics '^pg_up 1$' \
  && log "  OK: pg_up=1" || { log "  !! postgres_exporter not reporting pg_up=1"; exit 1; }

# ============================================================ kafka_exporter
if [ "$RUNTIME" = docker ]; then
  log "kafka_exporter: (re)deploy container (native broker, unauthenticated, localhost:9092)"
  docker rm -f kafka-exporter >/dev/null 2>&1 || true
  docker run -d --name kafka-exporter --restart unless-stopped --network host \
    --log-opt max-size=10m --log-opt max-file=3 \
    danielqsj/kafka-exporter --kafka.server=localhost:9092 >/dev/null
fi
# kafka_exporter's initial broker-metadata handshake has been observed taking ~40s on the reference VM and well over 90s on a fresh cloud VM
# (each collection round also trips over the Kafka Connect consumer group it cannot decode, which slows the first scrape) —
# so give it a generous budget, and do NOT let a MONITORING sidecar abort provisioning an entire environment: warn and carry on.
# (A 90s budget made the one-click installer die here on a fresh AWS VM although the exporter went healthy moments later.)
wait_for_metric http://localhost:9308/metrics '^kafka_brokers ' 90 \
  && log "  OK: kafka_brokers metric present" \
  || log "  WARNING: kafka_exporter not yet reporting kafka_brokers — continuing (monitoring only). Check: $( [ "$RUNTIME" = docker ] && echo 'docker logs kafka-exporter' || echo 'journalctl -u cce-kafka-exporter' ); curl -s localhost:9308/metrics | grep ^kafka_brokers"

log "DONE. Next: apply the prometheus-config ConfigMap (one-click-installer/lib/native/05-k8s-deploy.sh, or extract+apply"
log "      just that ConfigMap) and run one-click-installer/lib/grafana-redeploy.sh $ENVCODE to wire scrape targets + dashboards."
