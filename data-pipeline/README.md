# CCE Data Pipeline

Open-source **data pipeline** for the CCE (Clinical Care Engine) platform: a CDC-only path that lands committed PostgreSQL data into ClickHouse for analytics — **PostgreSQL → Debezium → Kafka → ClickHouse**. The `cce-insights-service` + `cce-insights-ui` apps consume ClickHouse to serve dashboards.

## Architecture

```
ccedb (PG16) → Debezium (Kafka Connect) → Kafka topics (cce.public.*)
            → ClickHouse Kafka-engine tables → parsing MVs → ReplacingMergeTree(_version,_is_deleted)
            → MVs / argMaxState rollups → cce-insights-service / cce-insights-ui (separate repos)
```

**Reuses the platform's existing Kafka.** This repo runs only **ClickHouse** + a **Kafka Connect worker** (the Debezium PostgreSQL source connector), joined to the shared `cce-net` network from [openphc/deploy-scripts](https://github.com/openphc/deploy-scripts) (which already provides Kafka, `ccedb`, Prometheus/Grafana, and the insights apps). Debezium publishes change events to Kafka; ClickHouse **Kafka-engine tables** consume them and parsing MVs land them into `ReplacingMergeTree` base tables — **no ClickHouse sink connector, no S3/MinIO staging**. All field enrichment is done by ClickHouse `MATERIALIZED` columns and MVs.

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| ClickHouse | 26.3 LTS | Columnar OLAP store; consumes Kafka directly (Kafka engine) and serves insights-service |
| Kafka Connect + Debezium | `quay.io/debezium/connect:3.0.0.Final` | PostgreSQL CDC source connector (pgoutput) with ReselectColumns for TOAST |
| Kafka | confluentinc/cp-kafka 7.6.1 (KRaft) | **Reused** from the platform deploy (the change-event bus) |

> Prometheus + Grafana are the platform's existing instances on `cce-net`; this repo ships their
> provisioning artifacts (`infra/grafana`, `infra/prometheus`) to add there, not its own services.

## Quick Start

> `ccedb`, Kafka, and the insights apps live in the **platform stack** (openphc/deploy-scripts) on
> the external `cce-net` network. Bring that up first (or `docker network create cce-net`).

```bash
cp .env.example .env   # edit CDC_*/CLICKHOUSE_PASSWORD/KAFKA_BOOTSTRAP_SERVERS
set -a; source .env; set +a

# Start ClickHouse + Kafka Connect (joins the shared cce-net)
docker compose up -d

# 1. ClickHouse schema: base tables, Kafka-engine queues + consumer MVs, aggregation MVs, indexes, dicts, rollups
for f in schema/0*.sql; do clickhouse-client --database cce_analytics --multiquery < "$f"; done

# 2. Configure logical replication on the source ccedb (publication + REPLICA IDENTITY FULL)
psql -h "$CDC_PG_HOST" -U postgres -d "$CDC_PG_DATABASE" -f cdc/01-configure-replication.sql

# 3. Register the Debezium connector on Kafka Connect (starts the initial snapshot)
./scripts/register-connectors.sh

# 4. Verify CDC + ingestion
./scripts/check-connector-health.sh
./scripts/validate-clickhouse.sh
```

**UIs:** Kafka UI http://localhost:8080 (platform) · Kafka Connect http://localhost:8083 · ClickHouse http://localhost:8123

`cce-insights-service` (already on `cce-net`) reads ClickHouse via the `cce_pipeline` user (HTTP 8123 / native 9000).

## CDC Tables

Change Data Capture from committed PostgreSQL records (shared `ccedb`). **11 tables** captured from 3 services (Collector, Compliance, Intelligence) → ClickHouse `cce_analytics`. Columns are reconciled against the live `ccedb` schema. Two large unused JSONB columns (`intelligence_event_log.event_payload`, `intelligence_delivery.fhir_payload`) are excluded at the connector.

For the full table listing and the Kafka-ingestion design, see [Data Flow & Schema Design](docs/data-flow.md).

## Materialized Views

**12 aggregation MVs** computed at insert time (event volume, deviations, intelligence, processing quality) across patient, facility, practitioner, and protocol dimensions. **Current-state** queries (compliance status, step rates, delivery outcomes) on the mutable entities use the always-fresh **`argMaxState` current-state rollups** in `schema/06` — incremental, no `FINAL`, no double-counting — or query the base tables with `FINAL`.

For the complete MV catalog and coverage matrix, see [Data Flow & Schema Design § 4](docs/data-flow.md).

## Documentation

| Document | Purpose |
|----------|---------|
| [Architecture Overview](docs/architecture-overview.md) | System context, principles, technology decisions, capacity planning, security |
| [Data Flow & Schema](docs/data-flow.md) | CDC pipeline, Kafka ingestion, ClickHouse DDL, MV catalog, query patterns |
| [Deployment Guide](docs/deployment-guide.md) | Full lifecycle: setup, deploy, validate, operate, troubleshoot |

## Key Design Decisions

1. **CDC-only** — Analytics based solely on committed database records. No in-flight event consumption.
2. **Debezium + Kafka (not PeerDB)** — chosen for future fan-out to other consumers and because Kafka is already deployed. ClickHouse consumes Kafka directly (Kafka engine), so there's no sink connector and no S3 staging.
3. **ReselectColumns for TOAST** — large unchanged JSONB (e.g. `raw_payload`) is re-read from the source so it never arrives as Debezium's `__debezium_unavailable_value` placeholder (which would corrupt the MATERIALIZED extractions).
4. **No Flink/stream processing** — ClickHouse `MATERIALIZED` columns extract fields from `raw_payload` JSON at insert time; MVs pre-aggregate. Zero custom code.
5. **ReplacingMergeTree(_version, _is_deleted)** — `_version` = Debezium `source.lsn` (monotonic), `_is_deleted` = `op='d'`; `clean_deleted_rows='Always'` purges deletes on merge.
6. **Mutable entities via argMaxState/FINAL, not count-MVs** — status counts and step rates on the mutable tables come from the `argMaxState` current-state rollups (or base-table `FINAL`), never count-based MVs that would double-count CDC UPDATEs.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/register-connectors.sh` | Register/update the Debezium source connector on Kafka Connect |
| `scripts/check-connector-health.sh` | Debezium connector + ClickHouse ingestion health |
| `scripts/resnapshot-mirror.sh` | Reset offsets + drop slot + truncate + re-snapshot |
| `scripts/validate-cdc-config.sh` | Validate PostgreSQL logical-replication config |
| `scripts/validate-clickhouse.sh` | Validate base tables, Kafka queues/consumer MVs, aggregation MVs, dicts |
| `scripts/data-quality-checks.sh` | Row counts, freshness, integrity checks |
