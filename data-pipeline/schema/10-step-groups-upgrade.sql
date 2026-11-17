-- ==============================================================================
-- CCE Analytics — upgrade an existing cce_analytics to the step-group schema (Matcher V8)
-- ==============================================================================
-- Run this once, on a ClickHouse that already holds data. A fresh install doesn't need it, because
-- 01 and 02 create everything. Like 09, apply-schema.py doesn't run it by default.
--
-- What Matcher V8 changed in ccedb:
--   * A new table, step_group_instance. It has one row each time a patient's step group opens,
--     such as one visit.
--   * A new column, step_group_instance_id, on step_instance, step_sla_state_transition, deviation
--     and intelligence_event_log.
--   * step_instance_id can now be null on step_sla_state_transition and deviation. A group with its
--     own deadline gets rows that point at its group instance, not at a step.
--
-- Do these steps in this order, before any protocol with step groups is loaded:
--   1. Check that Matcher V8 has run, so ccedb has step_group_instance.
--   2. PostgreSQL: re-run cdc/01-configure-replication.sql. Or, to keep the publication, run only:
--        GRANT SELECT ON step_group_instance TO cce_cdc_user;
--        ALTER TABLE step_group_instance REPLICA IDENTITY FULL;
--        ALTER PUBLICATION cce_analytics_pub ADD TABLE step_group_instance;
--   3. ClickHouse: run this file, then `python3 scripts/apply-schema.py schema`. 01 and 02 then
--      create step_group_instances with its queue and view. They also recreate the four views this
--      file drops.
--   4. Kafka Connect: update the connector from connectors/debezium-postgres-source.json. Its
--      table.include.list now has public.step_group_instance. The table is empty until a protocol
--      with groups is loaded, so no snapshot is needed.
--
-- The views and rollups in 03-09 join deviations and SLA rows to steps on step_instance_id. A
-- group's row has no step_instance_id, so it stays out of every step-level number. The one
-- exception is mv_deviation_trends: it counts every deviation by day and type, a group's included.
-- ==============================================================================

USE cce_analytics;

-- ── Tables ──

ALTER TABLE step_instances
    ADD COLUMN IF NOT EXISTS step_group_instance_id Nullable(UUID) AFTER action_id;

ALTER TABLE step_sla_state_transitions
    MODIFY COLUMN step_instance_id Nullable(UUID);
ALTER TABLE step_sla_state_transitions
    ADD COLUMN IF NOT EXISTS step_group_instance_id Nullable(UUID) AFTER step_instance_id;

-- 04's skip index covers deviations.step_instance_id; it is dropped for the type change and rebuilt
-- here, so this file leaves the table as 04 expects it.
ALTER TABLE deviations DROP INDEX IF EXISTS idx_step_instance;
ALTER TABLE deviations
    MODIFY COLUMN step_instance_id Nullable(UUID);
ALTER TABLE deviations
    ADD COLUMN IF NOT EXISTS step_group_instance_id Nullable(UUID) AFTER step_instance_id;
ALTER TABLE deviations
    ADD INDEX IF NOT EXISTS idx_step_instance step_instance_id TYPE bloom_filter GRANULARITY 4;
ALTER TABLE deviations MATERIALIZE INDEX idx_step_instance;

ALTER TABLE intelligence_event_logs
    ADD COLUMN IF NOT EXISTS step_group_instance_id Nullable(UUID) AFTER step_instance_id;

-- ── Ingestion views ──

-- Each of these reads a column that changed. They are dropped so 02 recreates them with the new
-- columns; until then the old deviations and step_sla_state_transitions views would stop their
-- consumers on the first group row (toUUID throws on its empty step_instance_id). Dropping a view
-- keeps its target table and rows (the TO pattern), and a Kafka table with no view attached does not
-- consume, so nothing is skipped in between.
DROP VIEW IF EXISTS step_instances_mv;
DROP VIEW IF EXISTS step_sla_state_transitions_mv;
DROP VIEW IF EXISTS deviations_mv;
DROP VIEW IF EXISTS intelligence_event_logs_mv;
