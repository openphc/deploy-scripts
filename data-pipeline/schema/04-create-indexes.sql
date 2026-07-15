-- CCE Analytics ClickHouse Schema
-- Secondary indexes and TTL policies
-- Run: clickhouse-client --database cce_analytics < schema/04-create-indexes.sql


USE cce_analytics;

-- ============================================================
-- SECONDARY INDEXES (bloom_filter for point lookups)
-- ============================================================

-- inbound_event_logs
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_cloudevents_id     cloudevents_id    TYPE bloom_filter GRANULARITY 4;
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_correlation         correlation_id    TYPE bloom_filter GRANULARITY 4;
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_source              source            TYPE bloom_filter GRANULARITY 4;
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_subject             subject           TYPE bloom_filter GRANULARITY 4;  -- patient event history (/patients/{id}/events)
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_facility            facility_id       TYPE bloom_filter GRANULARITY 4;  -- facility-scoped raw event browse
ALTER TABLE inbound_event_logs ADD INDEX IF NOT EXISTS idx_event_time          event_time        TYPE minmax GRANULARITY 4;  -- range pruning for the clinical-time global date filter (data is partitioned/ordered by received_at, not event_time)

-- protocol_instances
ALTER TABLE protocol_instances ADD INDEX IF NOT EXISTS idx_patient_id          patient_id                TYPE bloom_filter GRANULARITY 4;
ALTER TABLE protocol_instances ADD INDEX IF NOT EXISTS idx_protocol_definition  protocol_definition_id    TYPE bloom_filter GRANULARITY 4;

-- step_instances
ALTER TABLE step_instances ADD INDEX IF NOT EXISTS idx_protocol_instance        protocol_instance_id  TYPE bloom_filter GRANULARITY 4;
ALTER TABLE step_instances ADD INDEX IF NOT EXISTS idx_state                    state                 TYPE bloom_filter GRANULARITY 4;
ALTER TABLE step_instances ADD INDEX IF NOT EXISTS idx_action_id                action_id             TYPE bloom_filter GRANULARITY 4;

-- deviations
ALTER TABLE deviations ADD INDEX IF NOT EXISTS idx_protocol_instance            protocol_instance_id  TYPE bloom_filter GRANULARITY 4;
ALTER TABLE deviations ADD INDEX IF NOT EXISTS idx_step_instance                step_instance_id      TYPE bloom_filter GRANULARITY 4;

-- intelligence_event_logs
ALTER TABLE intelligence_event_logs ADD INDEX IF NOT EXISTS idx_subject          subject               TYPE bloom_filter GRANULARITY 4;
ALTER TABLE intelligence_event_logs ADD INDEX IF NOT EXISTS idx_protocol_instance protocol_instance_id  TYPE bloom_filter GRANULARITY 4;

-- intelligence_deliveries
ALTER TABLE intelligence_deliveries ADD INDEX IF NOT EXISTS idx_intelligence_event intelligence_event_id TYPE bloom_filter GRANULARITY 4;
ALTER TABLE intelligence_deliveries ADD INDEX IF NOT EXISTS idx_status             status                TYPE bloom_filter GRANULARITY 4;
ALTER TABLE intelligence_deliveries ADD INDEX IF NOT EXISTS idx_subject            subject               TYPE bloom_filter GRANULARITY 4;

-- ============================================================
-- MATERIALIZE INDEXES (backfill for initial snapshot data)
-- ============================================================

ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_cloudevents_id;
ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_correlation;
ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_source;
ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_subject;
ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_facility;
ALTER TABLE inbound_event_logs MATERIALIZE INDEX idx_event_time;

ALTER TABLE protocol_instances MATERIALIZE INDEX idx_patient_id;
ALTER TABLE protocol_instances MATERIALIZE INDEX idx_protocol_definition;

ALTER TABLE step_instances MATERIALIZE INDEX idx_protocol_instance;
ALTER TABLE step_instances MATERIALIZE INDEX idx_state;
ALTER TABLE step_instances MATERIALIZE INDEX idx_action_id;

ALTER TABLE deviations MATERIALIZE INDEX idx_protocol_instance;
ALTER TABLE deviations MATERIALIZE INDEX idx_step_instance;

ALTER TABLE intelligence_event_logs MATERIALIZE INDEX idx_subject;
ALTER TABLE intelligence_event_logs MATERIALIZE INDEX idx_protocol_instance;

ALTER TABLE intelligence_deliveries MATERIALIZE INDEX idx_intelligence_event;
ALTER TABLE intelligence_deliveries MATERIALIZE INDEX idx_status;
ALTER TABLE intelligence_deliveries MATERIALIZE INDEX idx_subject;

-- ============================================================
-- TTL POLICIES (storage retention for high-volume log tables)
-- ============================================================
-- Adjust intervals to match your regulatory retention requirements.
-- Healthcare regulations (e.g., HIPAA) typically require 7 years;
-- set hot-tier TTL to 90 days and cold-tier to 7 years accordingly.

-- Inbound events: 90 days hot retention
ALTER TABLE inbound_event_logs
    MODIFY TTL received_at + INTERVAL 90 DAY;

-- Intelligence event triggers: 90 days hot retention
ALTER TABLE intelligence_event_logs
    MODIFY TTL created_at + INTERVAL 90 DAY;

-- Delivery records: 90 days hot retention
ALTER TABLE intelligence_deliveries
    MODIFY TTL created_at + INTERVAL 90 DAY;

-- Compliance processing log: 90 days hot retention
ALTER TABLE compliance_event_logs
    MODIFY TTL received_at + INTERVAL 90 DAY;
