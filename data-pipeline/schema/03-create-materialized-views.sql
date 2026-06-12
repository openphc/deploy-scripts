-- CCE Analytics ClickHouse Schema
-- Materialized Views (pre-aggregated from CDC tables)
--
-- Pattern: each MV consists of two objects:
--   1. A named backing table (e.g. mv_event_volume_hourly)     — stores the data, queryable directly
--   2. A materialized view trigger (e.g. mv_event_volume_hourly_mv) — fires on INSERT, writes to the backing table
--
-- Using explicit TO <table> instead of the default implicit inner table (.inner_id.<uuid>):
--   - Backing tables are visible in SHOW TABLES and system.tables
--   - You can DROP/CREATE the MV trigger without losing accumulated data
--   - You can OPTIMIZE, ALTER, or inspect the backing table independently
--   - All existing dashboard queries reference the backing table name — no query changes needed
--
-- Run: clickhouse-client --database cce_analytics < schema/03-create-materialized-views.sql

USE cce_analytics;

-- ============================================================
-- Event Volume (from inbound_event_logs CDC)
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_event_volume_hourly (
    hour          DateTime,
    facility_id   String,
    source        String,
    event_type    String,
    resource_type String,
    event_count   UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(hour)
ORDER BY (facility_id, source, event_type, resource_type, hour);

-- Hourly event volume by facility/source/type
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_event_volume_hourly_mv
TO mv_event_volume_hourly
AS SELECT
    toStartOfHour(received_at) AS hour,
    facility_id,
    source,
    event_type,
    resource_type,
    count() AS event_count
FROM inbound_event_logs
WHERE status = 'ACCEPTED'
GROUP BY hour, facility_id, source, event_type, resource_type;

-- ============================================================
-- Protocol Compliance
-- ============================================================
-- NOTE: there is intentionally NO compliance-count MV here. Status counts and step
-- compliance rates require CURRENT state from the mutable protocol_instances /
-- step_instances tables, which an incremental MV cannot maintain without double-counting
-- CDC UPDATE events. Query those tables with FINAL, or use the always-fresh argMaxState
-- current-state rollups (schema/06-current-state-rollups.sql) for the hot path.

-- Daily deviation counts by type
CREATE TABLE IF NOT EXISTS mv_deviation_trends (
    day             DateTime,
    deviation_type  LowCardinality(String),
    deviation_count UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (deviation_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_deviation_trends_mv
TO mv_deviation_trends
AS SELECT
    toStartOfDay(detected_at) AS day,
    deviation_type,
    count() AS deviation_count
FROM deviations
GROUP BY day, deviation_type;

-- Deviation aggregation by protocol instance
CREATE TABLE IF NOT EXISTS mv_deviation_by_protocol (
    day                  DateTime,
    protocol_instance_id UUID,
    deviation_type       LowCardinality(String),
    deviation_count      UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (protocol_instance_id, deviation_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_deviation_by_protocol_mv
TO mv_deviation_by_protocol
AS SELECT
    toStartOfDay(detected_at) AS day,
    protocol_instance_id,
    deviation_type,
    count() AS deviation_count
FROM deviations
GROUP BY day, protocol_instance_id, deviation_type;

-- ============================================================
-- Ingestion Quality
-- ============================================================

-- RECEIVED is excluded: inbound_event_log rows are inserted as RECEIVED then updated
-- to a terminal state (ACCEPTED, REJECTED, DUPLICATE). Each CDC UPDATE arrives as a
-- new INSERT; filtering out RECEIVED ensures only terminal-state rows are counted,
-- exactly once, with no double-counting.
CREATE TABLE IF NOT EXISTS mv_ingestion_quality (
    day              DateTime,
    source           String,
    status           LowCardinality(String),
    rejection_reason String,
    event_count      UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (source, status, rejection_reason, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_ingestion_quality_mv
TO mv_ingestion_quality
AS SELECT
    toStartOfDay(received_at) AS day,
    source,
    status,
    rejection_reason,
    count() AS event_count
FROM inbound_event_logs
WHERE status != 'RECEIVED'
GROUP BY day, source, status, rejection_reason;

-- ============================================================
-- Intelligence (from intelligence_event_logs CDC)
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_intelligence_summary (
    day                      DateTime,
    action_type              String,
    intelligence_destination String,
    step_state               LowCardinality(String),
    trigger_reason           String,
    trigger_count            AggregateFunction(count),
    unique_patients          AggregateFunction(uniq, String)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (action_type, intelligence_destination, trigger_reason, step_state, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_intelligence_summary_mv
TO mv_intelligence_summary
AS SELECT
    toStartOfDay(created_at) AS day,
    action_type,
    intelligence_destination,
    step_state,
    trigger_reason,
    countState() AS trigger_count,
    uniqState(subject) AS unique_patients
FROM intelligence_event_logs
GROUP BY day, action_type, intelligence_destination, step_state, trigger_reason;

-- ============================================================
-- Practitioner Metrics (from inbound_event_logs MATERIALIZED columns)
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_practitioner_summary (
    day                  DateTime,
    facility_id          String,
    practitioner_ref     String,
    practitioner_display AggregateFunction(any, String),
    event_count          AggregateFunction(count),
    unique_patients      AggregateFunction(uniq, String),
    resource_type_count  AggregateFunction(uniq, String)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (facility_id, practitioner_ref, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_practitioner_summary_mv
TO mv_practitioner_summary
AS SELECT
    toStartOfDay(received_at)   AS day,
    facility_id,
    practitioner_ref,
    anyState(practitioner_display) AS practitioner_display,
    countState()                AS event_count,
    uniqState(subject)          AS unique_patients,
    uniqState(resource_type)    AS resource_type_count
FROM inbound_event_logs
WHERE practitioner_ref != '' AND status = 'ACCEPTED'
GROUP BY day, facility_id, practitioner_ref;

-- ============================================================
-- Facility Metrics (from inbound_event_logs MATERIALIZED columns)
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_facility_summary (
    day                  DateTime,
    facility_id          String,
    resource_type        String,
    event_count          AggregateFunction(count),
    unique_patients      AggregateFunction(uniq, String),
    unique_practitioners AggregateFunction(uniq, String)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (facility_id, resource_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_facility_summary_mv
TO mv_facility_summary
AS SELECT
    toStartOfDay(received_at)   AS day,
    facility_id,
    resource_type,
    countState()                AS event_count,
    uniqState(subject)          AS unique_patients,
    uniqState(practitioner_ref) AS unique_practitioners
FROM inbound_event_logs
WHERE facility_id != '' AND status = 'ACCEPTED'
GROUP BY day, facility_id, resource_type;

-- ============================================================
-- Entity × Behavior Cross-Dimensional Views
-- ============================================================

-- Patient-level deviations (JOIN deviations → protocol_instances for patient_id)
-- LEFT JOIN with FINAL: protocol_instances is a ReplacingMergeTree; without FINAL,
-- unmerged duplicate rows for the same id would inflate countState() by returning
-- multiple JOIN matches per deviation row. FINAL deduplicates at execution time.
-- coalesce: if the protocol_instance hasn't arrived yet via CDC, the deviation is
-- still captured with patient_id='' rather than silently dropped.
CREATE TABLE IF NOT EXISTS mv_deviation_by_patient (
    day              DateTime,
    patient_id       String,
    deviation_type   LowCardinality(String),
    deviation_count  AggregateFunction(count),
    unique_protocols AggregateFunction(uniq, UUID)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (patient_id, deviation_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_deviation_by_patient_mv
TO mv_deviation_by_patient
AS SELECT
    toStartOfDay(d.detected_at) AS day,
    coalesce(pi.patient_id, '') AS patient_id,
    d.deviation_type,
    countState() AS deviation_count,
    uniqState(d.protocol_instance_id) AS unique_protocols
FROM deviations d
LEFT JOIN protocol_instances AS pi FINAL ON d.protocol_instance_id = pi.id
GROUP BY day, patient_id, d.deviation_type;

-- Patient-level intelligence actions
CREATE TABLE IF NOT EXISTS mv_intelligence_by_patient (
    day                      DateTime,
    subject                  String,
    action_type              String,
    intelligence_destination String,
    trigger_reason           String,
    trigger_count            AggregateFunction(count)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (subject, action_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_intelligence_by_patient_mv
TO mv_intelligence_by_patient
AS SELECT
    toStartOfDay(created_at) AS day,
    subject,
    action_type,
    intelligence_destination,
    trigger_reason,
    countState() AS trigger_count
FROM intelligence_event_logs
GROUP BY day, subject, action_type, intelligence_destination, trigger_reason;

-- Intelligence triggers per protocol
CREATE TABLE IF NOT EXISTS mv_intelligence_by_protocol (
    day                      DateTime,
    protocol_instance_id     UUID,
    action_type              String,
    intelligence_destination String,
    trigger_reason           String,
    trigger_count            AggregateFunction(count),
    unique_patients          AggregateFunction(uniq, String)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (protocol_instance_id, action_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_intelligence_by_protocol_mv
TO mv_intelligence_by_protocol
AS SELECT
    toStartOfDay(created_at) AS day,
    protocol_instance_id,
    action_type,
    intelligence_destination,
    trigger_reason,
    countState() AS trigger_count,
    uniqState(subject) AS unique_patients
FROM intelligence_event_logs
GROUP BY day, protocol_instance_id, action_type, intelligence_destination, trigger_reason;

-- ============================================================
-- Compliance Event Processing Quality
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_compliance_processing_quality (
    day               DateTime,
    source            String,
    processing_status LowCardinality(String),
    event_count       UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (source, processing_status, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_compliance_processing_quality_mv
TO mv_compliance_processing_quality
AS SELECT
    toStartOfDay(received_at) AS day,
    source,
    processing_status,
    count() AS event_count
FROM compliance_event_logs
GROUP BY day, source, processing_status;

-- ============================================================
-- Patient → Facility Latest Mapping (dict source)
-- ============================================================

-- ReplacingMergeTree(last_seen) keeps only the latest row per patient after merges.
-- status != 'RECEIVED': inbound_event_log rows are inserted as RECEIVED then updated
-- to a terminal state. Both CDC events carry identical subject/facility_id/received_at,
-- so filtering to terminal states halves writes without any correctness impact.
-- Used as the SOURCE for dict_patient_facility (see schema/05-create-dictionary.sql).
CREATE TABLE IF NOT EXISTS mv_patient_facility_latest (
    patient_id  String,
    facility_id String,
    last_seen   DateTime64(3)
) ENGINE = ReplacingMergeTree(last_seen)
ORDER BY (patient_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_patient_facility_latest_mv
TO mv_patient_facility_latest
AS SELECT
    subject     AS patient_id,
    facility_id,
    received_at AS last_seen
FROM inbound_event_logs
WHERE subject != '' AND facility_id != '' AND status != 'RECEIVED';
