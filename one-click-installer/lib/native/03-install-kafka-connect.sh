#!/usr/bin/env bash
# one-click-installer/lib/native/03-install-kafka-connect.sh <envcode>
# Install Kafka Connect (distributed) + the Debezium PostgreSQL connector plugin NATIVELY,
# reusing the Kafka distribution installed at /opt/kafka by 01-install-postgres-kafka.sh.
#
# REST port defaults to Kafka Connect's standard 8083 — correct for a dedicated machine. PROD's
# wrapper overrides to 8086 because the default is held by UAT's docker Kafka Connect on their
# shared host; not applicable here.
set -euo pipefail

ENVCODE="${1:?usage: 03-install-kafka-connect.sh <envcode>}"
CONNECT_REST_PORT="${CONNECT_REST_PORT:-8083}"

KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
KAFKA_USER="${KAFKA_USER:-kafka}"
BOOTSTRAP="${KAFKA_CONNECT_BOOTSTRAP:-localhost:9092}"
DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-3.0.0.Final}"
PLUGIN_DIR="${KAFKA_HOME}/connect-plugins"
PROPS_FILE="${KAFKA_HOME}/config/connect-${ENVCODE}.properties"

[ -d "$KAFKA_HOME" ] || { echo "ERROR: $KAFKA_HOME not found — run 01-install-postgres-kafka.sh first"; exit 1; }

echo "=== [$ENVCODE 1/3] download Debezium PostgreSQL connector ${DEBEZIUM_VERSION} ==="
sudo mkdir -p "$PLUGIN_DIR"
if [ ! -d "$PLUGIN_DIR/debezium-connector-postgres" ]; then
  TGZ="debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"
  URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/${TGZ}"
  echo "  $URL"
  curl -fsSL "$URL" -o "/tmp/${TGZ}"
  sudo tar -xzf "/tmp/${TGZ}" -C "$PLUGIN_DIR"
  rm -f "/tmp/${TGZ}"
fi
sudo chown -R "${KAFKA_USER}:${KAFKA_USER}" "$PLUGIN_DIR"

echo "=== [$ENVCODE 2/3] connect-distributed.properties (REST $CONNECT_REST_PORT) ==="
sudo tee "$PROPS_FILE" >/dev/null <<EOF
bootstrap.servers=${BOOTSTRAP}
group.id=cce-connect

key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=false
value.converter.schemas.enable=false

offset.storage.topic=connect-offsets
offset.storage.replication.factor=1
config.storage.topic=connect-configs
config.storage.replication.factor=1
status.storage.topic=connect-status
status.storage.replication.factor=1
offset.flush.interval.ms=10000

listeners=HTTP://0.0.0.0:${CONNECT_REST_PORT}
plugin.path=${PLUGIN_DIR}

# CVE-2025-27817 / -27818 (Kafka Connect <= 3.9.0): an unauthenticated REST call can create a connector whose
# producer./consumer./admin.override.* client settings read local files or reach internal URLs. The default policy (All) lets
# any connector set them; the CCE connector sets none. None = every connector-level client override is refused. Exploited on
# the old RW UAT (port 8083) on 2026-10-24. Lasting fix: Kafka/Connect >= 3.9.1.
connector.client.config.override.policy=None
EOF
sudo chown "${KAFKA_USER}:${KAFKA_USER}" "$PROPS_FILE"

echo "=== [$ENVCODE 3/3] systemd service kafka-connect ==="
sudo tee /etc/systemd/system/kafka-connect.service >/dev/null <<EOF
[Unit]
Description=Kafka Connect (distributed) — CCE Debezium (${ENVCODE})
After=network.target kafka.service
Requires=kafka.service

[Service]
Type=simple
User=${KAFKA_USER}
Group=${KAFKA_USER}
Environment="KAFKA_HEAP_OPTS=-Xmx1G -Xms1G"
# Same advisory (CVE-2025-27818, and CVE-2023-25194): refuse the JNDI/LDAP JAAS login modules process-wide.
Environment="KAFKA_OPTS=-Dorg.apache.kafka.disallowed.login.modules=com.sun.security.auth.module.JndiLoginModule,com.sun.security.auth.module.LdapLoginModule"
ExecStart=${KAFKA_HOME}/bin/connect-distributed.sh ${PROPS_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable kafka-connect
sudo systemctl restart kafka-connect

for i in $(seq 1 40); do curl -sf "http://localhost:${CONNECT_REST_PORT}/connectors" >/dev/null 2>&1 && { echo "  Kafka Connect REST up ($CONNECT_REST_PORT)"; break; }; sleep 3; done
echo "Plugins:"; curl -s "http://localhost:${CONNECT_REST_PORT}/connector-plugins" | python3 -c 'import sys,json;[print(" ",p["class"]) for p in json.load(sys.stdin) if "postgres" in p["class"].lower()]' 2>/dev/null || true
echo "Next: 04-data-pipeline.sh $ENVCODE"
