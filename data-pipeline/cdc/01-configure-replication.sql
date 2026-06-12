-- CCE Data Pipeline — PostgreSQL CDC Configuration
-- Configure logical replication for Debezium CDC (pgoutput plugin)
--
-- Prerequisites:
--   1. PostgreSQL must have wal_level = 'logical' (requires restart if changing)
--   2. Run this script as a superuser or user with CREATEROLE + REPLICATION privileges
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

-- Step 4: Grant SELECT on all 11 CDC source tables
GRANT USAGE ON SCHEMA public TO cce_cdc_user;
GRANT SELECT ON TABLE
    protocol_definition,
    protocol_instance,
    step_instance,
    deviation,
    inbound_event_log,
    intelligence_delivery,
    intelligence_event_log,
    action_definition,
    compliance_event_log,
    receiver_adaptor,
    destination_adaptor_mapping
TO cce_cdc_user;

-- Step 5: REPLICA IDENTITY FULL on all 11 tables
-- Required by Debezium so UPDATE/DELETE events include the full old-row image
-- (and so ReselectColumns / TOAST reconstruction can recover unchanged large values).
-- Without this, only the primary key is available in the WAL for changed rows.
ALTER TABLE protocol_definition          REPLICA IDENTITY FULL;
ALTER TABLE protocol_instance            REPLICA IDENTITY FULL;
ALTER TABLE step_instance                REPLICA IDENTITY FULL;
ALTER TABLE deviation                    REPLICA IDENTITY FULL;
ALTER TABLE inbound_event_log            REPLICA IDENTITY FULL;
ALTER TABLE intelligence_delivery        REPLICA IDENTITY FULL;
ALTER TABLE intelligence_event_log       REPLICA IDENTITY FULL;
ALTER TABLE action_definition            REPLICA IDENTITY FULL;
ALTER TABLE compliance_event_log         REPLICA IDENTITY FULL;
ALTER TABLE receiver_adaptor             REPLICA IDENTITY FULL;
ALTER TABLE destination_adaptor_mapping  REPLICA IDENTITY FULL;

-- Step 6: Create publication for all 11 CDC tables
DROP PUBLICATION IF EXISTS cce_analytics_pub;
CREATE PUBLICATION cce_analytics_pub FOR TABLE
    protocol_definition,
    protocol_instance,
    step_instance,
    deviation,
    inbound_event_log,
    intelligence_delivery,
    intelligence_event_log,
    action_definition,
    compliance_event_log,
    receiver_adaptor,
    destination_adaptor_mapping;

-- Step 7: Confirm replication role
ALTER ROLE cce_cdc_user WITH REPLICATION;
