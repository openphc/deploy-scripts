#!/usr/bin/env bash
# one-click-installer/lib/native/02-install-clickhouse.sh <envcode>
# Install ClickHouse server + client NATIVELY (apt) and drop in this env's config.
#
# Ports default to ClickHouse's own standard values (HTTP 8123, native 9000, interserver 9009,
# Prometheus metrics 9363) — correct for a DEDICATED machine. The CH_*_PORT variables override them (a host shared with
# another ClickHouse, e.g. 8124/9001/9010/9364).
#
# Requires: CLICKHOUSE_USER, CLICKHOUSE_PASSWORD, KAFKA_BOOTSTRAP_SERVERS in the env.
set -euo pipefail

ENVCODE="${1:?usage: 02-install-clickhouse.sh <envcode>}"
CH_HTTP_PORT="${CH_HTTP_PORT:-8123}"
CH_TCP_PORT="${CH_TCP_PORT:-9000}"
CH_INTERSERVER_PORT="${CH_INTERSERVER_PORT:-9009}"
CH_METRICS_PORT="${CH_METRICS_PORT:-9363}"

CH_USER="${CLICKHOUSE_USER:-cce_pipeline}"
: "${CLICKHOUSE_PASSWORD:?set CLICKHOUSE_PASSWORD}"
: "${KAFKA_BOOTSTRAP_SERVERS:?set KAFKA_BOOTSTRAP_SERVERS (e.g. \${VM_HOST_IP:-localhost}:9092)}"

echo "=== [$ENVCODE 1/4] add ClickHouse apt repo + install ==="
if ! command -v clickhouse-server >/dev/null 2>&1; then
  sudo apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
  # NOTE: https://packages.clickhouse.com/deb/key.gpg returns 404. Fetch the signing key
  # (id 8919F6BD2B48D754 / 3E4AD4719DDE9A38) from the Ubuntu keyserver instead.
  curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3E4AD4719DDE9A38" \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/clickhouse-keyring.gpg
  sudo chmod 644 /usr/share/keyrings/clickhouse-keyring.gpg   # apt verifies as _apt; under a restrictive umask gpg writes 0600
  ARCH=$(dpkg --print-architecture)
  echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/clickhouse.list >/dev/null
  sudo apt-get update -qq
  # Preseed the default-user password prompt to empty (we manage users via users.d).
  echo "clickhouse-server clickhouse-server/default-password password" | sudo debconf-set-selections
  # PIN the version. The repo's "stable" channel moves on: an unpinned install gets whatever is newest (26.10 at the time of
  # writing), but the reference production environment runs the 26.5 series — and 26.10 REJECTS the analytics schema that 26.5 accepts
  # ("Code 36: Column(s) intelligence_destination, trigger_reason of the AggregatingMergeTree table are neither part of the
  # sorting key nor aggregate measures"), so an unpinned "PROD-like" install failed halfway through the data pipeline.
  # CLICKHOUSE_VERSION is a series ("26.5", the default = newest 26.5.x) or an exact version ("26.5.7.64").
  CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION:-26.5}"
  CH_PKG_VER="$(apt-cache madison clickhouse-server | awk '{print $3}' | grep -E "^${CLICKHOUSE_VERSION//./\\.}(\\.|$)" | head -1)"
  if [ -z "$CH_PKG_VER" ]; then
    echo "ERROR: the ClickHouse apt repo has no version matching '${CLICKHOUSE_VERSION}'. Available: $(apt-cache madison clickhouse-server | awk '{print $3}' | head -8 | tr '\n' ' ')"
    echo "       (set CLICKHOUSE_VERSION=<series or exact version>; the reference production environment runs 26.5.2.39)"; exit 1
  fi
  echo "  installing ClickHouse ${CH_PKG_VER} (pinned to the ${CLICKHOUSE_VERSION} series; PROD runs 26.5.2.39)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "clickhouse-common-static=${CH_PKG_VER}" "clickhouse-server=${CH_PKG_VER}" "clickhouse-client=${CH_PKG_VER}"
  # hold, so a routine `apt upgrade` cannot silently move a PROD-like environment onto a schema-incompatible major
  sudo apt-mark hold clickhouse-common-static clickhouse-server clickhouse-client >/dev/null
else
  echo "  clickhouse-server already installed ($(clickhouse-server --version 2>/dev/null | awk '{print $NF" "$(NF-1)}' | head -1)), skipping."
fi

echo "=== [$ENVCODE 2/4] drop in config (HTTP $CH_HTTP_PORT, named collection) ==="
sudo tee "/etc/clickhouse-server/config.d/cce-${ENVCODE}.xml" >/dev/null <<EOF
<clickhouse>
  <listen_host>0.0.0.0</listen_host>
  <http_port>${CH_HTTP_PORT}</http_port>
  <tcp_port>${CH_TCP_PORT}</tcp_port>
  <interserver_http_port>${CH_INTERSERVER_PORT}</interserver_http_port>
  <mysql_port remove="remove"/>
  <postgresql_port remove="remove"/>
  <prometheus>
    <endpoint>/metrics</endpoint>
    <port>${CH_METRICS_PORT}</port>
    <metrics>true</metrics>
    <events>true</events>
    <asynchronous_metrics>true</asynchronous_metrics>
  </prometheus>
  <named_collections>
    <cce_kafka>
      <kafka_broker_list>${KAFKA_BOOTSTRAP_SERVERS}</kafka_broker_list>
    </cce_kafka>
  </named_collections>
</clickhouse>
EOF

echo "=== [$ENVCODE 3/4] pipeline user (password as sha256_hex) ==="
CH_PW_SHA=$(printf '%s' "$CLICKHOUSE_PASSWORD" | sha256sum | cut -d' ' -f1)
sudo tee "/etc/clickhouse-server/users.d/cce-${ENVCODE}-users.xml" >/dev/null <<EOF
<clickhouse>
  <users>
    <${CH_USER}>
      <password_sha256_hex>${CH_PW_SHA}</password_sha256_hex>
      <networks><ip>::/0</ip></networks>
      <profile>default</profile>
      <quota>default</quota>
      <access_management>1</access_management>
      <named_collection_control>1</named_collection_control>
    </${CH_USER}>
  </users>
</clickhouse>
EOF
# Only root and the clickhouse server may read it (the password hash; tee leaves it 644 = every local user).
sudo chown root:clickhouse "/etc/clickhouse-server/users.d/cce-${ENVCODE}-users.xml"
sudo chmod 640 "/etc/clickhouse-server/users.d/cce-${ENVCODE}-users.xml"

# The package's "default" user has an EMPTY password and accepts connections from any address: from every pod, the host IP,
# and on a cloud install with 8123 open in the security group, the internet. CCE never uses it remotely (everything connects
# as the pipeline user; host-side tools use localhost), so confine it to the loopback.
sudo tee /etc/clickhouse-server/users.d/zz-cce-default-user-localhost.xml >/dev/null <<'EOF'
<clickhouse>
  <users>
    <default>
      <networks replace="replace">
        <ip>::1</ip>
        <ip>127.0.0.1</ip>
      </networks>
    </default>
  </users>
</clickhouse>
EOF
sudo chown root:clickhouse /etc/clickhouse-server/users.d/zz-cce-default-user-localhost.xml 2>/dev/null || true
sudo chmod 640 /etc/clickhouse-server/users.d/zz-cce-default-user-localhost.xml

echo "=== [$ENVCODE 4/4] enable + start ==="
sudo systemctl daemon-reload
sudo systemctl enable clickhouse-server
sudo systemctl restart clickhouse-server
for i in $(seq 1 30); do
  curl -sf "http://localhost:${CH_HTTP_PORT}/ping" >/dev/null 2>&1 && { echo "  ClickHouse up (HTTP $CH_HTTP_PORT)"; break; }
  sleep 2
done

echo ""
echo "Verify: curl -s 'http://localhost:${CH_HTTP_PORT}/?user=${CH_USER}&password=****' --data-binary 'SELECT version()'"
echo "Next: 03-install-kafka-connect.sh $ENVCODE"
