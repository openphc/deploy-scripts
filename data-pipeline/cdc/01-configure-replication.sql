-- CCE Data Pipeline — PostgreSQL CDC Configuration
-- Configure logical replication for Debezium CDC (pgoutput plugin)
--
-- Prerequisites:
--   1. PostgreSQL must have wal_level = 'logical' (requires restart if changing)
--   2. Run this script as a superuser or user with CREATEROLE + REPLICATION privileges
--   3. The CCE 2.0.0 schema must be in place (Protocol → Matcher → Collector migrations applied, or
--      cce-matcher-service/migration/run-upgrade.sh run on a 1.x database). The GRANT and
--      PUBLICATION statements name 2.0.0 tables and fail on a 1.x schema.
--
-- Usage: psql -h <host> -U postgres -d ccedb -f cdc/01-configure-replication.sql

-- Step 1: Ensure wal_level is logical (requires a PostgreSQL RESTART to take effect).
-- NOTE: ALTER SYSTEM cannot run inside a DO/function block or a transaction block, so it must be a
-- plain top-level statement (psql runs each as its own autocommit statement).
ALTER SYSTEM SET wal_level = 'logical';

-- Step 2: Set max_replication_slots (ensure enough for the Debezium slot + backup slots)
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;

-- Prevent unbounded WAL growth if Debezium/Connect falls behind
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';

-- Step 3: Create CDC user with minimal privileges
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cce_cdc_user') THEN
        CREATE ROLE cce_cdc_user WITH LOGIN PASSWORD 'CHANGE_ME_IN_PRODUCTION' REPLICATION;
        RAISE NOTICE 'Created role cce_cdc_user';
    ELSE
        RAISE NOTICE 'Role cce_cdc_user already exists';
    END IF;
END $$;

-- Step 4: Grant SELECT on all 15 CDC source tables
GRANT USAGE ON SCHEMA public TO cce_cdc_user;
GRANT SELECT ON TABLE
    protocol_definition,
    protocol_instance,
    step_instance,
    step_sla_state_transition,
    deviation,
    inbound_event_log,
    intelligence_delivery,
    intelligence_event_log,
    action_definition,
    matcher_event_log,
    receiver_adaptor,
    destination_adaptor_mapping,
    facility,
    protocol_instance_history,
    step_instance_history
TO cce_cdc_user;

-- Step 5: REPLICA IDENTITY FULL on all 15 CDC tables (uniform)
-- Required by Debezium so UPDATE/DELETE events include the full old-row image
-- (and so ReselectColumns / TOAST reconstruction can recover unchanged large values).
-- Without this, only the primary key is available in the WAL for changed rows.
-- The 2.0.0 service migrations already set it on every table they own (Protocol V1, Matcher V1/V2,
-- Collector V1); it is repeated here so this script is self-sufficient (ALTER is idempotent).
-- NOTE: the two *_history tables are append-only (INSERT only), so FULL is a harmless no-op for
-- them (the default PK identity would also suffice) — applied here for uniformity so every CDC
-- table follows the same rule. Matcher's migrations leave them on the default identity.
--
-- 2.0.0 changes against the 1.x list:
--   * compliance_event_log was renamed matcher_event_log (Matcher V2 §1) — same columns.
--   * step_sla_state_transition is new (Matcher V1/V2 §3). It carries each step's SLA thresholds
--     (process_by), which 1.x kept on step_instance as overdue_date / missed_date.
--   * trigger_index (Protocol V1) is deliberately NOT captured: it is a derived matching index,
--     rebuilt from protocol_definition on every load, and no analytics reads it.
ALTER TABLE protocol_definition          REPLICA IDENTITY FULL;
ALTER TABLE protocol_instance            REPLICA IDENTITY FULL;
ALTER TABLE step_instance                REPLICA IDENTITY FULL;
ALTER TABLE step_sla_state_transition    REPLICA IDENTITY FULL;
ALTER TABLE deviation                    REPLICA IDENTITY FULL;
ALTER TABLE inbound_event_log            REPLICA IDENTITY FULL;
ALTER TABLE intelligence_delivery        REPLICA IDENTITY FULL;
ALTER TABLE intelligence_event_log       REPLICA IDENTITY FULL;
ALTER TABLE action_definition            REPLICA IDENTITY FULL;
ALTER TABLE matcher_event_log            REPLICA IDENTITY FULL;
ALTER TABLE receiver_adaptor             REPLICA IDENTITY FULL;
ALTER TABLE destination_adaptor_mapping  REPLICA IDENTITY FULL;
ALTER TABLE facility           REPLICA IDENTITY FULL;
ALTER TABLE protocol_instance_history    REPLICA IDENTITY FULL;
ALTER TABLE step_instance_history        REPLICA IDENTITY FULL;

-- Step 6: Create publication for all 15 CDC tables
DROP PUBLICATION IF EXISTS cce_analytics_pub;
CREATE PUBLICATION cce_analytics_pub FOR TABLE
    protocol_definition,
    protocol_instance,
    step_instance,
    step_sla_state_transition,
    deviation,
    inbound_event_log,
    intelligence_delivery,
    intelligence_event_log,
    action_definition,
    matcher_event_log,
    receiver_adaptor,
    destination_adaptor_mapping,
    facility,
    protocol_instance_history,
    step_instance_history;

-- Step 7: Confirm replication role
ALTER ROLE cce_cdc_user WITH REPLICATION;
