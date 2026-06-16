#!/usr/bin/env bash
# =============================================================================
# PROD Infrastructure Setup — PostgreSQL 16 & Kafka (KRaft) via systemd
# Run this script once on the VM to install and configure PROD infrastructure.
#
# Usage:
#   chmod +x setup-prod-infra.sh
#   sudo ./setup-prod-infra.sh
# =============================================================================

set -euo pipefail

echo "=== CCE PROD Infrastructure Setup ==="
echo ""

# --- Configuration ---
POSTGRES_VERSION=16
POSTGRES_DB="ccedb"
POSTGRES_USER="admin"
POSTGRES_PASSWORD="${POSTGRES_PROD_PASSWORD:?set POSTGRES_PROD_PASSWORD in the environment}"
POSTGRES_PORT=5432

KAFKA_VERSION="3.7.0"
KAFKA_SCALA_VERSION="2.13"
KAFKA_PORT=9092
KAFKA_CONTROLLER_PORT=9094
KAFKA_HOME="/opt/kafka"
KAFKA_DATA_DIR="/var/lib/kafka/data"
KAFKA_LOG_DIR="/var/log/kafka"
KAFKA_USER="kafka"

# =============================================================================
# 1. PostgreSQL Installation
# =============================================================================
echo "[1/4] Installing PostgreSQL ${POSTGRES_VERSION}..."

# Add PostgreSQL APT repository
if ! command -v psql &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq gnupg2 lsb-release
    echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
        sudo tee /etc/apt/sources.list.d/pgdg.list
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo apt-get update -qq
    sudo apt-get install -y -qq postgresql-${POSTGRES_VERSION}
    echo "  PostgreSQL ${POSTGRES_VERSION} installed."
else
    echo "  PostgreSQL already installed, skipping."
fi

# Configure PostgreSQL
echo "[2/4] Configuring PostgreSQL..."

# Allow connections from k3s pod network (10.42.0.0/16) and localhost
PG_HBA="/etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf"
PG_CONF="/etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf"

# Listen on all interfaces (needed for k3s pods to connect via host IP)
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "${PG_CONF}"
sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" "${PG_CONF}"

# Add k3s pod network to pg_hba if not already present
if ! grep -q "10.42.0.0/16" "${PG_HBA}"; then
    echo "# Allow k3s pods to connect" | sudo tee -a "${PG_HBA}"
    echo "host    all    all    10.42.0.0/16    md5" | sudo tee -a "${PG_HBA}"
    echo "host    all    all    10.43.0.0/16    md5" | sudo tee -a "${PG_HBA}"
fi

# Restart PostgreSQL to apply config
sudo systemctl restart postgresql
sudo systemctl enable postgresql

# Create database and user
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}' CREATEDB;"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"

echo "  PostgreSQL configured: port=${POSTGRES_PORT}, db=${POSTGRES_DB}, user=${POSTGRES_USER}"

# =============================================================================
# 2. Kafka Installation (KRaft mode — no Zookeeper)
# =============================================================================
echo "[3/4] Installing Kafka ${KAFKA_VERSION} (KRaft mode)..."

# Install Java if not present
if ! command -v java &>/dev/null; then
    sudo apt-get install -y -qq openjdk-17-jre-headless
fi

# Create kafka user
if ! id "${KAFKA_USER}" &>/dev/null; then
    sudo useradd -r -s /bin/false "${KAFKA_USER}"
fi

# Download and install Kafka
if [ ! -d "${KAFKA_HOME}" ]; then
    KAFKA_TARBALL="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    KAFKA_URL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_TARBALL}"

    echo "  Downloading Kafka from ${KAFKA_URL}..."
    wget -q "${KAFKA_URL}" -O "/tmp/${KAFKA_TARBALL}"
    sudo mkdir -p "${KAFKA_HOME}"
    sudo tar -xzf "/tmp/${KAFKA_TARBALL}" -C "${KAFKA_HOME}" --strip-components=1
    rm -f "/tmp/${KAFKA_TARBALL}"

    sudo chown -R "${KAFKA_USER}:${KAFKA_USER}" "${KAFKA_HOME}"
    echo "  Kafka extracted to ${KAFKA_HOME}"
else
    echo "  Kafka already installed at ${KAFKA_HOME}, skipping download."
fi

# Create data and log directories
sudo mkdir -p "${KAFKA_DATA_DIR}" "${KAFKA_LOG_DIR}"
sudo chown -R "${KAFKA_USER}:${KAFKA_USER}" "${KAFKA_DATA_DIR}" "${KAFKA_LOG_DIR}"

# Generate cluster ID if not exists
CLUSTER_ID_FILE="${KAFKA_HOME}/.cluster-id"
if [ ! -f "${CLUSTER_ID_FILE}" ]; then
    CLUSTER_ID=$(${KAFKA_HOME}/bin/kafka-storage.sh random-uuid)
    echo "${CLUSTER_ID}" | sudo tee "${CLUSTER_ID_FILE}"
    sudo chown "${KAFKA_USER}:${KAFKA_USER}" "${CLUSTER_ID_FILE}"
else
    CLUSTER_ID=$(cat "${CLUSTER_ID_FILE}")
fi

# Configure Kafka for KRaft mode
cat <<EOF | sudo tee "${KAFKA_HOME}/config/kraft/server.properties"
# KRaft mode configuration — PROD
node.id=1
process.roles=broker,controller
controller.quorum.voters=1@localhost:${KAFKA_CONTROLLER_PORT}

# Listeners
listeners=PLAINTEXT://0.0.0.0:${KAFKA_PORT},CONTROLLER://0.0.0.0:${KAFKA_CONTROLLER_PORT}
advertised.listeners=PLAINTEXT://localhost:${KAFKA_PORT}
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
controller.listener.names=CONTROLLER
inter.broker.listener.name=PLAINTEXT

# Log/data directories
log.dirs=${KAFKA_DATA_DIR}

# Topic defaults
num.partitions=3
default.replication.factor=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1

# Auto-create topics
auto.create.topics.enable=true

# Retention
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# Performance
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
EOF

sudo chown "${KAFKA_USER}:${KAFKA_USER}" "${KAFKA_HOME}/config/kraft/server.properties"

# Format storage if not already done
if [ ! -f "${KAFKA_DATA_DIR}/meta.properties" ]; then
    sudo -u "${KAFKA_USER}" ${KAFKA_HOME}/bin/kafka-storage.sh format \
        -t "${CLUSTER_ID}" \
        -c "${KAFKA_HOME}/config/kraft/server.properties"
fi

# Create systemd service
echo "[4/4] Creating systemd services..."

cat <<EOF | sudo tee /etc/systemd/system/kafka.service
[Unit]
Description=Apache Kafka (KRaft mode) — PROD
Documentation=https://kafka.apache.org
After=network.target

[Service]
Type=simple
User=${KAFKA_USER}
Group=${KAFKA_USER}
Environment="KAFKA_HEAP_OPTS=-Xmx1G -Xms1G"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j.configuration=file:${KAFKA_HOME}/config/log4j.properties"
ExecStart=${KAFKA_HOME}/bin/kafka-server-start.sh ${KAFKA_HOME}/config/kraft/server.properties
ExecStop=${KAFKA_HOME}/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable kafka
sudo systemctl start kafka

echo ""
echo "=== Setup Complete ==="
echo ""
echo "PostgreSQL:"
echo "  Status:   sudo systemctl status postgresql"
echo "  Port:     ${POSTGRES_PORT}"
echo "  Database: ${POSTGRES_DB}"
echo "  User:     ${POSTGRES_USER}"
echo "  Connect:  psql -h localhost -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB}"
echo ""
echo "Kafka:"
echo "  Status:   sudo systemctl status kafka"
echo "  Port:     ${KAFKA_PORT}"
echo "  Topics:   ${KAFKA_HOME}/bin/kafka-topics.sh --list --bootstrap-server localhost:${KAFKA_PORT}"
echo ""
echo "Firewall: Ensure ports ${POSTGRES_PORT} and ${KAFKA_PORT} are accessible from k3s pod network (10.42.0.0/16)"
