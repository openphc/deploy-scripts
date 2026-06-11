-- CCE Analytics ClickHouse Schema — Current-State Rollups (argMaxState)
-- Run: clickhouse-client --database cce_analytics < schema/06-current-state-rollups.sql
--
-- WHY THIS EXISTS
-- The mutable entities (protocol_instances, step_instances, intelligence_deliveries) emit a
-- new row on every CDC UPDATE. Counting their CURRENT state therefore needs either FINAL
-- (slow on big tables; also disables projections) or a periodic full recompute (stale).
--
-- Instead, these MVs keep ONE logical row per entity using AggregatingMergeTree +
-- argMaxState(col, _version): the partial states merge in the background and a report
-- resolves the winner with argMaxMerge() — no FINAL, no double-counting, incremental, and
-- ALWAYS FRESH (unlike a refreshable MV). This replaces the earlier refreshable rollup.
--
-- DELETE HANDLING (important — the generic argMax pattern omits this):
--   Debezium emits a delete (op='d'); the schema/02 consumer MV sets _is_deleted=1 on that
--   (highest-version) row. We carry argMaxState(_is_deleted, _version) and every report filters
--   `WHERE is_deleted = 0`, so deleted entities drop out. (The base tables also physically
--   purge deletes via clean_deleted_rows='Always', but the MV sees the delete event in the
--   insert stream, so the guard is required here.)
--
-- TRADE-OFFS
--   - Each CDC event to these tables also writes one argMaxState partial (write amplification;
--     step_instances is the highest-churn source). Worth it for fast, fresh current-state reads.
--   - Reports use a nested GROUP BY (resolve per-entity state, then aggregate) — slightly more
--     verbose than reading a flat table, but no staleness. See examples at the bottom.
--
-- Apply AFTER schema/01. Like any MV, it only captures rows inserted after creation; if you
-- apply it after the snapshot, backfill once with: INSERT INTO rollup_* SELECT ... FROM <source>.

USE cce_analytics;

-- ============================================================
-- protocol_instances → current status per enrollment
-- (outcome-distribution, compliance-summary status counts, enrollment lists)
-- ============================================================
CREATE TABLE IF NOT EXISTS rollup_protocol_instance_current
(
    protocol_definition_id UUID,                                       -- stable dim (sort key)
    id                     UUID,                                       -- enrollment id (sort key)
    patient_id             AggregateFunction(argMax, String, UInt64),
    protocol_canonical     AggregateFunction(argMax, String, UInt64),
    status                 AggregateFunction(argMax, String, UInt64),
    enrolled_at            AggregateFunction(argMax, DateTime64(6), UInt64),
    is_deleted             AggregateFunction(argMax, UInt8, UInt64)
) ENGINE = AggregatingMergeTree
ORDER BY (protocol_definition_id, id);

CREATE MATERIALIZED VIEW IF NOT EXISTS rollup_protocol_instance_current_mv
TO rollup_protocol_instance_current
AS SELECT
    protocol_definition_id,
    id,
    argMaxState(patient_id,         _version) AS patient_id,
    argMaxState(protocol_canonical, _version) AS protocol_canonical,
    argMaxState(status,             _version) AS status,
    argMaxState(enrolled_at,        _version) AS enrolled_at,
    argMaxState(_is_deleted, _version) AS is_deleted
FROM protocol_instances
GROUP BY protocol_definition_id, id;

-- ============================================================
-- step_instances → current state per step (keyed for per-enrollment rollup)
-- (compliance rate completed/total, step-analytics, step-state distribution)
-- ============================================================
CREATE TABLE IF NOT EXISTS rollup_step_current
(
    protocol_instance_id UUID,                                         -- stable dim (sort key)
    id                   UUID,                                         -- step id (sort key)
    action_id            AggregateFunction(argMax, String, UInt64),    -- PlanDefinition action.id (VARCHAR in source)
    state                AggregateFunction(argMax, String, UInt64),
    completion_status    AggregateFunction(argMax, String, UInt64),
    is_deleted           AggregateFunction(argMax, UInt8, UInt64)
) ENGINE = AggregatingMergeTree
ORDER BY (protocol_instance_id, id);

CREATE MATERIALIZED VIEW IF NOT EXISTS rollup_step_current_mv
TO rollup_step_current
AS SELECT
    protocol_instance_id,
    id,
    argMaxState(action_id,          _version) AS action_id,
    argMaxState(state,              _version) AS state,
    argMaxState(completion_status,  _version) AS completion_status,
    argMaxState(_is_deleted, _version) AS is_deleted
FROM step_instances
GROUP BY protocol_instance_id, id;

-- ============================================================
-- intelligence_deliveries → current delivery outcome per delivery
-- (adaptor success rate, latency, retry analysis, status breakdown)
-- ============================================================
-- NOTE: adaptor_name / endpoint are NOT on intelligence_deliveries — resolve them from
-- `destination` (carried here) or via dict_delivery_adaptor. Latency is not a stored column;
-- derive it on the base table as dateDiff('ms', created_at, delivered_at) when needed.
CREATE TABLE IF NOT EXISTS rollup_delivery_current
(
    id            UUID,                                                -- delivery id (sort key)
    destination   AggregateFunction(argMax, String, UInt64),
    action_type   AggregateFunction(argMax, String, UInt64),
    subject       AggregateFunction(argMax, String, UInt64),
    status        AggregateFunction(argMax, String, UInt64),
    attempt_count AggregateFunction(argMax, Int32, UInt64),
    created_at    AggregateFunction(argMax, DateTime64(6), UInt64),
    is_deleted    AggregateFunction(argMax, UInt8, UInt64)
) ENGINE = AggregatingMergeTree
ORDER BY (id);

CREATE MATERIALIZED VIEW IF NOT EXISTS rollup_delivery_current_mv
TO rollup_delivery_current
AS SELECT
    id,
    argMaxState(destination,        _version) AS destination,
    argMaxState(action_type,        _version) AS action_type,
    argMaxState(subject,            _version) AS subject,
    argMaxState(status,             _version) AS status,
    argMaxState(attempt_count,      _version) AS attempt_count,
    argMaxState(created_at,         _version) AS created_at,
    argMaxState(_is_deleted, _version) AS is_deleted
FROM intelligence_deliveries
GROUP BY id;

-- ============================================================
-- HOW insights-service queries these — nested GROUP BY, no FINAL, always fresh.
-- Inner query resolves the current value per entity (argMaxMerge), outer aggregates.
-- ALWAYS filter WHERE is_deleted = 0.
-- ============================================================
--
-- Protocol outcome distribution (count enrollments by current status):
--   SELECT protocol_definition_id, status, count() AS enrollments
--   FROM (
--       SELECT protocol_definition_id, id,
--              argMaxMerge(status)     AS status,
--              argMaxMerge(is_deleted) AS is_deleted
--       FROM rollup_protocol_instance_current
--       GROUP BY protocol_definition_id, id
--   ) WHERE is_deleted = 0
--   GROUP BY protocol_definition_id, status;
--
-- Per-enrollment compliance rate (completed/total steps):
--   SELECT protocol_instance_id,
--          count()                                   AS total_steps,
--          countIf(state IN ('COMPLETED','SKIPPED')) AS completed_steps,
--          round(countIf(state IN ('COMPLETED','SKIPPED')) / nullIf(count(),0) * 100, 1) AS compliance_rate
--   FROM (
--       SELECT protocol_instance_id, id,
--              argMaxMerge(state)      AS state,
--              argMaxMerge(is_deleted) AS is_deleted
--       FROM rollup_step_current
--       GROUP BY protocol_instance_id, id
--   ) WHERE is_deleted = 0
--   GROUP BY protocol_instance_id;
--
-- Delivery success rate by destination (resolve adaptor_name via dict_delivery_adaptor if needed;
-- latency is derived on the base table, not stored in this rollup):
--   SELECT destination,
--          count()                              AS total,
--          countIf(status = 'DELIVERED')        AS delivered,
--          round(countIf(status='DELIVERED')/nullIf(count(),0)*100, 1) AS success_rate_pct,
--          round(avg(attempt_count), 2)         AS avg_attempts
--   FROM (
--       SELECT id,
--              argMaxMerge(destination)   AS destination,
--              argMaxMerge(status)        AS status,
--              argMaxMerge(attempt_count) AS attempt_count,
--              argMaxMerge(is_deleted)    AS is_deleted
--       FROM rollup_delivery_current
--       GROUP BY id
--   ) WHERE is_deleted = 0
--   GROUP BY destination;
--
-- Latency (from the base table, since it is not a stored column):
--   SELECT destination,
--          round(avg(dateDiff('ms', created_at, delivered_at)), 0) AS avg_latency_ms
--   FROM intelligence_deliveries FINAL
--   WHERE _is_deleted = 0 AND delivered_at IS NOT NULL
--   GROUP BY destination;
