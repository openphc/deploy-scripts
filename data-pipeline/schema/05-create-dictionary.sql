-- CCE Analytics ClickHouse Schema
-- Dictionaries for fast lookups (replaces JOINs on dimension tables)
-- Run: clickhouse-client --database cce_analytics < schema/05-create-dictionary.sql

USE cce_analytics;

-- Protocol definitions lookup (protocol_definition_id → name, canonical, etc.)
-- Uses QUERY with FINAL: protocol_definitions is a ReplacingMergeTree; reading via TABLE
-- without FINAL can return duplicate rows from unmerged parts, corrupting dict lookups.
CREATE DICTIONARY IF NOT EXISTS dict_protocol_definitions (
    id UUID,
    name String,
    version String,
    url String,
    canonical String,
    status String
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT id, name, version, url, concat(url, ''|'', version) AS canonical, status FROM cce_analytics.protocol_definitions FINAL'
    DB 'cce_analytics'
))
LIFETIME(MIN 60 MAX 300)
LAYOUT(HASHED());

-- Patient → most recent facility mapping
-- Enables facility-level behavioral metrics without JOINs at query time
-- Uses a QUERY with argMax to force deduplication at load time — reading the table
-- directly without FINAL would return duplicate rows from unmerged ReplacingMergeTree parts.
CREATE DICTIONARY IF NOT EXISTS dict_patient_facility (
    patient_id String,
    facility_id String,
    last_seen DateTime64(3)
)
PRIMARY KEY patient_id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT patient_id, argMax(facility_id, last_seen) AS facility_id, max(last_seen) AS last_seen FROM cce_analytics.mv_patient_facility_latest GROUP BY patient_id'
    DB 'cce_analytics'
))
LIFETIME(MIN 300 MAX 600)
LAYOUT(COMPLEX_KEY_HASHED());

-- Action definitions lookup (action_definition_id → name, action_type, canonical_url)
-- Uses QUERY with FINAL for same reason as dict_protocol_definitions above.
CREATE DICTIONARY IF NOT EXISTS dict_action_definitions (
    id UUID,
    canonical_url String,
    name String DEFAULT '',
    action_type String,
    status String
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT id, canonical_url, name, action_type, status FROM cce_analytics.action_definitions FINAL'
    DB 'cce_analytics'
))
LIFETIME(MIN 60 MAX 300)
LAYOUT(HASHED());

-- Delivery adaptor lookup (destination_adaptor_mapping_id → adaptor name/endpoint/destination)
-- Resolves the adaptor metadata that is NOT denormalized onto intelligence_deliveries, by joining
-- destination_adaptor_mapping → receiver_adaptor. Use in delivery queries, e.g.:
--   dictGet('dict_delivery_adaptor', 'adaptor_name', destination_adaptor_mapping_id)
-- Both source tables are ReplacingMergeTree, so the QUERY reads them with FINAL to avoid dupes.
CREATE DICTIONARY IF NOT EXISTS dict_delivery_adaptor (
    destination_adaptor_mapping_id UUID,
    destination    String,
    adaptor_name   String,
    endpoint_url   String,
    adaptor_status String
)
PRIMARY KEY destination_adaptor_mapping_id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT m.id AS destination_adaptor_mapping_id, m.destination AS destination, r.name AS adaptor_name, r.endpoint_url AS endpoint_url, r.status AS adaptor_status FROM cce_analytics.destination_adaptor_mapping AS m FINAL INNER JOIN cce_analytics.receiver_adaptor AS r FINAL ON m.receiver_adaptor_id = r.id'
    DB 'cce_analytics'
))
LIFETIME(MIN 300 MAX 600)
LAYOUT(HASHED());
