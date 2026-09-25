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

-- Hourly CLINICAL event volume by facility/source/type. Keyed on event_time (when the clinical
-- event happened), NOT received_at (ingestion) — so facility "Active/Events" reflect clinical
-- activity. Incremental SummingMergeTree: fires per insert, no rescan (right for this large,
-- append-only table). event_time is Nullable, so NULLs are excluded (hour is non-nullable).
-- NOTE: on (re)create, the trigger only captures FUTURE inserts — backfill existing history once:
--   INSERT INTO mv_event_volume_hourly SELECT toStartOfHour(event_time), facility_id, source,
--   event_type, resource_type, count() FROM inbound_event_logs
--   WHERE status='ACCEPTED' AND event_time IS NOT NULL GROUP BY 1,2,3,4,5;
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_event_volume_hourly_mv
TO mv_event_volume_hourly
AS SELECT
    toStartOfHour(event_time) AS hour,
    facility_id,
    source,
    event_type,
    resource_type,
    count() AS event_count
FROM inbound_event_logs
WHERE status = 'ACCEPTED' AND event_time IS NOT NULL
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
-- 2.0.0 dropped deviation.protocol_instance_id (reachable as step_instance.protocol_instance_id,
-- Matcher V2 §8), so it has to be looked up from step_instances. That lookup is why this and
-- mv_deviation_by_patient are REFRESHABLE full recomputes rather than insert-triggered MVs:
--   * An insert-triggered MV joins against whatever step_instances holds when the deviation block
--     lands. Topics are consumed independently, so during an initial snapshot deviations routinely
--     arrive before their steps, and an insert-time join would file them under the nil UUID for good.
--   * deviation rows are UPDATEd after insert (IntelligenceActionEvaluator links
--     intelligence_event_id), so an insert-triggered count would count those deviations twice.
-- A refresh over deviations FINAL sees each deviation once, joined to its step, and heals itself
-- once late rows arrive. The target tables keep their engines and columns, so readers are unchanged
-- (sum() / countMerge() still work); each refresh atomically replaces the contents.
-- The pair (id, protocol_instance_id) never changes for a step, so any() over the plain table is
-- exact without FINAL.
CREATE TABLE IF NOT EXISTS mv_deviation_by_protocol (
    day                  DateTime,
    protocol_instance_id UUID,
    deviation_type       LowCardinality(String),
    deviation_count      UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (protocol_instance_id, deviation_type, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_deviation_by_protocol_mv
REFRESH EVERY 30 SECOND
TO mv_deviation_by_protocol
AS SELECT
    toStartOfDay(d.detected_at) AS day,
    si.protocol_instance_id     AS protocol_instance_id,
    d.deviation_type            AS deviation_type,
    count() AS deviation_count
FROM deviations AS d FINAL
INNER JOIN (
    SELECT id, any(protocol_instance_id) AS protocol_instance_id FROM step_instances GROUP BY id
) AS si ON si.id = d.step_instance_id
WHERE d._is_deleted = 0
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
    step_status              LowCardinality(String),   -- lowercase FHIR code: not-started | completed
    sla_status               LowCardinality(String),   -- lowercase: '' | overdue | missed | met
    trigger_reason           String,
    trigger_count            AggregateFunction(count),
    unique_patients          AggregateFunction(uniq, String)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (action_type, intelligence_destination, trigger_reason, step_status, sla_status, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_intelligence_summary_mv
TO mv_intelligence_summary
AS SELECT
    toStartOfDay(created_at) AS day,
    action_type,
    intelligence_destination,
    step_status,
    sla_status,
    trigger_reason,
    countState() AS trigger_count,
    uniqState(subject) AS unique_patients
FROM intelligence_event_logs
GROUP BY day, action_type, intelligence_destination, step_status, sla_status, trigger_reason;

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

-- Patient-level deviations (deviations → step_instances → protocol_instances for patient_id)
-- Two hops since 2.0.0 dropped deviation.protocol_instance_id; refreshable for the reasons given at
-- mv_deviation_by_protocol. step → protocol_instance_id and instance → patient_id are both
-- immutable, so any() over the plain tables is exact without FINAL.
-- LEFT JOIN on the instance: if it hasn't arrived yet via CDC, the deviation is still counted with
-- patient_id='' until the next refresh picks it up.
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
REFRESH EVERY 30 SECOND
TO mv_deviation_by_patient
AS SELECT
    toStartOfDay(d.detected_at) AS day,
    coalesce(pi.patient_id, '') AS patient_id,
    d.deviation_type            AS deviation_type,
    countState() AS deviation_count,
    uniqState(si.protocol_instance_id) AS unique_protocols
FROM deviations AS d FINAL
INNER JOIN (
    SELECT id, any(protocol_instance_id) AS protocol_instance_id FROM step_instances GROUP BY id
) AS si ON si.id = d.step_instance_id
LEFT JOIN (
    SELECT id, any(patient_id) AS patient_id FROM protocol_instances GROUP BY id
) AS pi ON pi.id = si.protocol_instance_id
WHERE d._is_deleted = 0
GROUP BY day, patient_id, deviation_type;

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
-- Matcher Event Processing Quality  (1.x mv_compliance_processing_quality)
-- ============================================================

CREATE TABLE IF NOT EXISTS mv_matcher_processing_quality (
    day               DateTime,
    source            String,
    processing_status LowCardinality(String),
    event_count       UInt64
) ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (source, processing_status, day);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_matcher_processing_quality_mv
TO mv_matcher_processing_quality
AS SELECT
    toStartOfDay(received_at) AS day,
    source,
    processing_status,
    count() AS event_count
FROM matcher_event_logs
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
