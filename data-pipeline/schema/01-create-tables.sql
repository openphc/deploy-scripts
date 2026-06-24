-- CCE Analytics ClickHouse Schema — Base Tables
-- ReplacingMergeTree(_version, _is_deleted), ClickHouse 23.2+.
--
-- These tables are populated by the ClickHouse Kafka-engine consumer MVs (schema/02), which
-- parse the Debezium JSON change events from Kafka. CDC-metadata columns:
--   - _version     Debezium source.lsn (monotonic) — ReplacingMergeTree dedup version
--   - _is_deleted  1 when op='d' (PostgreSQL DELETE) — set by the consumer MV
--   - clean_deleted_rows = 'Always' physically removes deleted rows during background merges
--   - min_age_to_force_merge_seconds = 120 force-merges settled parts (no new part for ~2 min),
--     so CDC dedup / delete-purge / roll-up actually happen promptly and FINAL reads stay cheap
--     (dedup only occurs on merge; the size-based scheduler alone may never collapse small parts)
--
-- All source timestamp columns are PostgreSQL `timestamptz` (verified on live ccedb) → Debezium
-- emits ISO-8601 strings → the consumer MVs parse with parseDateTime64BestEffort*.
--
-- Execution order:
--   1. Run this script:                     schema/01-create-tables.sql
--   2. Kafka-engine queues + consumer MVs:  schema/02-kafka-ingestion.sql
--   3. Register the Debezium connector:     ./scripts/register-connectors.sh (initial snapshot)
--   4. Aggregation MVs:                      schema/03-create-materialized-views.sql
--   5. Indexes:                              schema/04-create-indexes.sql
--   6. Dictionaries:                         schema/05-create-dictionary.sql
--   7. Current-state rollups:                schema/06-current-state-rollups.sql

CREATE DATABASE IF NOT EXISTS cce_analytics;

USE cce_analytics;

-- ============================================================
-- COLLECTOR SERVICE: Event Ingestion
-- ============================================================

-- Immutable audit trail of all inbound CloudEvents received by the collector.
-- Status: RECEIVED → ACCEPTED | REJECTED | DUPLICATE
CREATE TABLE IF NOT EXISTS inbound_event_logs
(
    id                   UUID,
    cloudevents_id       String,
    source               String,
    correlation_id       String,
    raw_payload          String,              -- JSONB: original CloudEvent body, unchanged
    status               String,              -- RECEIVED | ACCEPTED | REJECTED | DUPLICATE
    rejection_reason     String,
    error_details        String,
    received_at          DateTime64(6),
    updated_at           DateTime64(6),

    -- Debezium CDC metadata (set by the schema/02 consumer MV)
    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0,

    -- MATERIALIZED: zero-cost extraction from raw_payload JSONB at insert time
    subject              String    MATERIALIZED JSONExtractString(raw_payload, 'subject'),
    event_type           String    MATERIALIZED JSONExtractString(raw_payload, 'type'),
    facility_id          String    MATERIALIZED JSONExtractString(raw_payload, 'facilityid'),
    event_time           Nullable(DateTime64(3))
                                   MATERIALIZED toDateTime64OrNull(
                                       JSONExtractString(raw_payload, 'time'), 3),
    resource_type        String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'resourceType'),
    practitioner_ref     String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'practitionerRef'),
    practitioner_display String    MATERIALIZED JSONExtractString(
                                       JSONExtractRaw(raw_payload, 'data'), 'practitionerDisplay'),

    -- ALIAS: patient_id resolves to subject without extra storage
    patient_id           String    ALIAS subject
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(received_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- ============================================================
-- COMPLIANCE SERVICE: Protocol & Step Management
-- ============================================================

-- FHIR PlanDefinition templates defining protocol structure and triggers.
-- Status: ACTIVE | RETIRED.
CREATE TABLE IF NOT EXISTS protocol_definitions
(
    id           UUID,
    url          String,
    version      String,
    status       String,    -- ACTIVE | RETIRED
    definition   String,    -- JSONB: full FHIR PlanDefinition resource
    loaded_at    DateTime64(6),
    updated_at   DateTime64(6),

    _version     UInt64,
    _is_deleted  UInt8 DEFAULT 0,

    -- MATERIALIZED: human label from the FHIR PlanDefinition (title, falling back to name)
    name         String MATERIALIZED if(
                     JSONExtractString(definition, 'title') != '',
                     JSONExtractString(definition, 'title'),
                     JSONExtractString(definition, 'name'))
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Patient enrollments in a protocol. One row per patient × protocol.
-- Status: ACTIVE | COMPLETED | WITHDRAWN | EXPIRED
CREATE TABLE IF NOT EXISTS protocol_instances
(
    id                     UUID,
    patient_id             String,
    protocol_canonical     String,    -- denormalized: url|version for join-free queries
    protocol_definition_id UUID,
    status                 String,    -- ACTIVE | COMPLETED | WITHDRAWN | EXPIRED
    enrolled_at            DateTime64(6),
    created_at             DateTime64(6),
    updated_at             DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(enrolled_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Individual action step occurrences within a protocol enrollment.
-- State machine: PENDING → DUE → OVERDUE → MISSED | COMPLETED | SKIPPED
CREATE TABLE IF NOT EXISTS step_instances
(
    id                    UUID,
    protocol_instance_id  UUID,
    action_id             String,        -- PlanDefinition action.id (e.g. 'anc-visit-2') — VARCHAR in source
    repeat_index          Int32,         -- for recurring actions; 0 = first occurrence
    state                 String,        -- PENDING | DUE | OVERDUE | MISSED | COMPLETED | SKIPPED
    due_date              Nullable(DateTime64(6)),
    overdue_date          Nullable(DateTime64(6)),
    missed_date           Nullable(DateTime64(6)),
    completed_at          Nullable(DateTime64(6)),
    completed_by_source   String,        -- CloudEvent source that completed this step
    completion_status     String,        -- EARLY | ON_TIME | LATE  (set when state = COMPLETED)
    completed_by_event_id Nullable(UUID),-- FK → compliance_event_logs.id; null until completed
    required_behavior     String,        -- FHIR requiredBehavior: must | could | must-unless-documented
    created_at            DateTime64(6),
    updated_at            DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Compliance gaps recorded when steps become overdue or missed.
-- Types: OVERDUE | MISSED | ORDER_VIOLATION
CREATE TABLE IF NOT EXISTS deviations
(
    id                    UUID,
    protocol_instance_id  UUID,
    step_instance_id      UUID,
    deviation_type        String,    -- OVERDUE | MISSED | ORDER_VIOLATION
    detected_at           DateTime64(6),
    intelligence_event_id Nullable(UUID),  -- links to the published intelligence event
    metadata              String,    -- JSONB: deviation-type-specific timing details
    updated_at            DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(detected_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Idempotency log for inbound CloudEvents processed by the compliance service.
-- Processing status: MATCHED | ZERO_MATCH | DUPLICATE
CREATE TABLE IF NOT EXISTS compliance_event_logs
(
    id                UUID,
    cloudevents_id    String,
    source            String,
    correlation_id    String,
    processing_status String,    -- MATCHED | ZERO_MATCH | DUPLICATE
    data              String,    -- JSONB: full CloudEvent data body (optional)
    received_at       DateTime64(6),
    updated_at        DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(received_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- FHIR ActivityDefinition resources defining intelligence actions.
-- action_type: CommunicationRequest | Task | ServiceRequest
CREATE TABLE IF NOT EXISTS action_definitions
(
    id            UUID,
    canonical_url String,    -- FHIR canonical URL (ActivityDefinition reference)
    version       String,
    name          String,    -- computer-friendly name
    title         String,    -- human-readable title
    status        String,    -- ACTIVE | RETIRED
    action_type   String,    -- FHIR ActivityDefinition.kind: CommunicationRequest | Task | ServiceRequest
    definition    String,    -- JSONB: full FHIR ActivityDefinition resource

    created_at    DateTime64(6),
    updated_at    DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Self-contained intelligence action execution records (compliance service).
-- event_payload (JSONB) is excluded at the connector — unused by analytics.
CREATE TABLE IF NOT EXISTS intelligence_event_logs
(
    id                       UUID,
    action_definition_id     UUID,
    protocol_instance_id     UUID,
    step_instance_id         Nullable(UUID),  -- null for protocol-level actions
    deviation_id             Nullable(UUID),  -- null for completion triggers
    subject                  String,    -- patient UPID (denormalized)
    action_type              String,    -- CommunicationRequest | Task | ServiceRequest
    intelligence_destination String,
    step_state               String,
    trigger_reason           String,    -- overdue | missed | completion
    step_action_id           String,    -- PlanDefinition intelligence action ID that fired
    evaluation_expression    String,    -- TEXT: condition expression evaluated (audit)
    evaluation_context       String,    -- JSONB: runtime variables for the evaluator
    published                UInt8,     -- whether successfully published to Kafka
    published_at             Nullable(DateTime64(6)),
    created_at               DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- ============================================================
-- INTELLIGENCE SERVICE: Delivery & Adaptors
-- ============================================================

-- Webhook delivery lifecycle per intelligence_event × destination_adaptor_mapping pair.
-- Status: PENDING | EXECUTING | DELIVERED | FAILED | CANCELLED
-- fhir_payload (JSONB resource sent) is excluded at the connector — unused by analytics.
CREATE TABLE IF NOT EXISTS intelligence_deliveries
(
    id                             UUID,
    intelligence_event_id          UUID,
    action_definition_id           UUID,
    destination_adaptor_mapping_id Nullable(UUID),
    action_type                    String,     -- CommunicationRequest | Task | ServiceRequest
    status                         String,     -- PENDING | EXECUTING | DELIVERED | FAILED | CANCELLED
    subject                        String,     -- patient UPID (denormalized)
    protocol_canonical             String,
    action_id                      String,     -- PlanDefinition action ID (e.g., anc-visit-2)
    severity                       String,     -- LOW | MEDIUM | HIGH | CRITICAL
    destination                    String,
    delivery_result                String,     -- JSONB: {httpStatus, responseBody, attempts[]} (feeds MATERIALIZED cols)
    attempt_count                  Int32,
    created_at                     DateTime64(6),
    updated_at                     DateTime64(6),
    delivered_at                   Nullable(DateTime64(6)),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0,

    -- MATERIALIZED: extracted from delivery_result JSONB at insert time
    http_status_code     Nullable(Int32) MATERIALIZED
                             nullIf(JSONExtractInt(delivery_result, 'httpStatus'), 0),
    error_message        String MATERIALIZED
                             JSONExtractString(delivery_result, 'responseBody')
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
PARTITION BY toYYYYMM(created_at)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Registered delivery adaptors (FHIR Endpoint resources). Reference/dimension table.
-- adaptor name/endpoint are NOT denormalized onto intelligence_deliveries — resolve via
-- destination_adaptor_mapping → receiver_adaptor (see dict_delivery_adaptor in schema/05).
CREATE TABLE IF NOT EXISTS receiver_adaptor
(
    id          UUID,
    name        String,    -- human-readable adaptor name
    definition  String,    -- JSONB: FHIR R4 Endpoint resource (address, connectionType, ...)
    status      String,    -- active | inactive
    config      String,    -- JSONB: auth headers, retry overrides, custom headers
    created_at  DateTime64(6),
    updated_at  DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0,

    -- MATERIALIZED: endpoint URL from the FHIR Endpoint resource (.address)
    endpoint_url String MATERIALIZED JSONExtractString(definition, 'address')
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- Maps an intelligence destination → a receiver_adaptor. Reference/dimension table.
CREATE TABLE IF NOT EXISTS destination_adaptor_mapping
(
    id                  UUID,
    destination         String,    -- intelligence destination name (e.g. 'supervisor')
    receiver_adaptor_id UUID,      -- FK → receiver_adaptor.id
    status              String,    -- active | inactive
    created_at          DateTime64(6),
    updated_at          DateTime64(6),

    _version             UInt64,
    _is_deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;


-- ============================================================
-- COMPLIANCE SERVICE: Reference Data
-- ============================================================

-- Facility roster auto-captured from inbound FHIR clinical events by FacilityReferenceService.
-- CDC-sourced: PostgreSQL (compliance service) → Kafka → ClickHouse.
-- Used as denominator in facility activity rate and e-Buzima adoption KPI calculations.
CREATE TABLE IF NOT EXISTS facility
(
    id                        UUID,
    facility_id               String,    -- HIE-assigned facility identifier (UNIQUE in source)
    facility_name             String,    -- display name from FHIR Reference.display
    expected_patients_per_day UInt32     DEFAULT 0,
    created_at                DateTime64(6),
    updated_at                DateTime64(6),

    _version                  UInt64,
    _is_deleted               UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY (id)
SETTINGS clean_deleted_rows = 'Always', min_age_to_force_merge_seconds = 120;
