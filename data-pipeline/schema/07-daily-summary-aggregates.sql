-- CCE Analytics ClickHouse Schema — Daily KPI Aggregates (Refreshable, APPEND mode)
-- Run: clickhouse-client --database cce_analytics < schema/07-daily-summary-aggregates.sql
--
-- WHY THIS EXISTS
-- Compliance, facility, and deviation KPIs require either current mutable state
-- (protocol_instances, step_instances) or cross-source aggregation — neither can be done
-- with standard incremental MVs without double-counting CDC UPDATE rows. Refreshable MVs
-- (ClickHouse 24.3+) solve this by running a full SELECT every 30 minutes.
--
-- DOMAIN SPLIT — one MV per domain, reused across pages:
--
--   mv_daily_compliance_kpis           → Compliance page header + step metrics + deviation breakdown
--                                        Dashboard compliance cards (trackedPatients, rate)
--
--   (mv_daily_facility_kpis / mv_daily_facility_activity_summary REMOVED — see section 2 & 3.
--    Facilities ranking is computed live from the enrolled-patient cohort + inbound_event_logs;
--    active-facility tiles read mv_event_volume_hourly directly, event_time-keyed.)
--
--   mv_daily_adoption_kpis             → e-Buzima adoption indicator (per facility, per day)
--                                        actual patients vs expected patients per day × 100
--                                        (reporting_gap = expected − actual)
--                                        Requires: facility (schema/08)
--
--   mv_daily_deviation_kpis            → Deviations page: header cards + trend chart + Most Deviated
--                                        Steps. Keyed on clinical OCCURRENCE day × protocol × facility
--                                        × action × type (count + uniqState patients). Not a snapshot.
--
--   mv_daily_event_kpis                → Events page header cards
--                                        (total / matched / zero-match / duplicate / pipeline loss)
--
--   mv_daily_referral_kpis             → Dashboard Referrals card (total + per-facility)
--                                        accepted referral-initiated events per event_time day × facility
--
-- WHAT IS NOT COVERED (requires live queries to base tables):
--   - getDeviations()            paginated row-level list, runtime filters
--   - getDeviationsByAction()    step-keyed aggregation (no step-keyed MV exists yet)
--   - recentActivity windows     last24h/7d/30d rolling counts — incompatible with 30-min refresh
--   - getAtRiskHotspots()        three-way patient segmentation (on_track/at_risk/non_compliant)
--   - Patient timeline/detail    individual patient data — inherently row-level
--   - rank ordinal               runtime window function over live results
--   - patientsFromHIE            requires live filter on inbound_event_logs by source
--   - facility_name              resolved via dictionary/lookup at query time, not stored
--   - Trend charts               already covered by schema/03 MVs (mv_deviation_trends,
--                                mv_event_volume_hourly, mv_ingestion_quality, etc.)
--
-- APPEND MODE — how daily history works:
--
--   Each 30-minute refresh APPENDs a new set of rows into the backing table.
--   The backing tables use ReplacingMergeTree(refreshed_at) with ORDER BY starting
--   on (snapshot_date, <dimension_key>). This means:
--
--     - Within the same calendar day, multiple refreshes produce multiple rows for
--       (snapshot_date, dimension_key). ClickHouse background merges deduplicate them,
--       keeping only the row with the latest refreshed_at.
--
--     - Across different days, rows are retained permanently — one final row per
--       (day, dimension_key) survives after dedup.
--
--   Example for mv_daily_compliance_kpis (per protocol_definition_id):
--
--     snapshot_date | protocol_definition_id | tracked_patients | refreshed_at
--     2026-06-20    | proto-A                | 78               | 2026-06-20 23:30:00   ← last refresh day1
--     2026-06-21    | proto-A                | 82               | 2026-06-21 23:30:00   ← last refresh day2
--     2026-06-22    | proto-A                | 89               | 2026-06-22 10:00:00   ← current, updates every 30min
--
--   Querying:
--     Latest snapshot:    SELECT ... FROM mv_daily_compliance_kpis FINAL WHERE snapshot_date = today()
--     Specific day:       SELECT ... FROM mv_daily_compliance_kpis FINAL WHERE snapshot_date = '2026-06-20'
--     Trend across days:  SELECT snapshot_date, sum(tracked_patients) ... GROUP BY snapshot_date ORDER BY snapshot_date
--
--   FINAL is required to see deduplicated rows (suppresses multiple 30-min inserts
--   within the same day before ClickHouse background merge runs).
--
-- INITIAL REFRESH (run once immediately after applying this script):
--   SYSTEM REFRESH VIEW mv_daily_compliance_kpis_mv;
--   SYSTEM REFRESH VIEW mv_daily_deviation_kpis_mv;
--   SYSTEM REFRESH VIEW mv_daily_event_kpis_mv;
--   SYSTEM REFRESH VIEW mv_daily_adoption_kpis_mv;
--   SYSTEM REFRESH VIEW mv_daily_referral_kpis_mv;
--
-- Prerequisites: schema/06 rollup tables must be populated.
--                schema/08 (facility) must exist and contain at least one row.

USE cce_analytics;

-- ============================================================
-- 1. Compliance KPIs  (per snapshot_date × protocol_definition_id)
-- ============================================================
-- Covers: Compliance page (all header fields), Dashboard compliance cards.
--
-- Mirrors the backend aggregations:
--   ComplianceSummaryService.getAllProtocolsComplianceSummary()
--     → StepInstanceRepository.aggregateStepMetrics()      (step_* columns)
--     → DeviationRepository.aggregateDeviationMetrics()    (deviation_* columns)
--     → ProtocolInstanceRepository.countByStatus()         (status_* columns)
--
-- NOTE: tracked_patients counts ALL non-deleted enrollments (all statuses), matching
-- the backend's LEFT JOIN pattern (not filtered to ACTIVE-only).

CREATE TABLE IF NOT EXISTS mv_daily_compliance_kpis
(
    snapshot_date               Date,             -- calendar day this snapshot represents
    refreshed_at                DateTime64(3),    -- version: latest 30-min refresh wins per day

    protocol_definition_id      UUID,

    -- Enrollment status breakdown (maps to ComplianceSummary.statusBreakdown)
    total_enrollments           UInt32,
    status_active               UInt32,
    status_completed            UInt32,
    status_withdrawn            UInt32,
    status_expired              UInt32,

    -- Patient compliance (maps to ComplianceSummary patient fields)
    tracked_patients            UInt32,          -- = total_enrollments (non-deleted)
    compliant_count             UInt32,          -- enrollments with zero deviations
    non_compliant_count         UInt32,          -- enrollments with one or more deviations
    compliance_rate_pct         Float32,

    -- Deviation breakdown (maps to ComplianceSummary.deviationBreakdown)
    total_deviations            UInt32,
    overdue_deviations          UInt32,
    missed_deviations           UInt32,
    order_violation_deviations  UInt32,

    -- Step metrics (maps to ComplianceSummary.stepMetrics)
    step_total                  UInt32,
    step_completed              UInt32,          -- state IN (COMPLETED, SKIPPED)
    step_overdue                UInt32,
    step_missed                 UInt32,
    step_due                    UInt32,
    step_pending                UInt32,
    step_on_time                UInt32,          -- completion_status = ON_TIME
    step_early                  UInt32,          -- completion_status = EARLY
    step_late                   UInt32           -- completion_status = LATE

) ENGINE = ReplacingMergeTree(refreshed_at)
ORDER BY (snapshot_date, protocol_definition_id);
-- ReplacingMergeTree(refreshed_at): within the same (snapshot_date, protocol_definition_id)
-- the row with the latest refreshed_at survives — one authoritative row per day per protocol.

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_compliance_kpis_mv
REFRESH EVERY 30 MINUTE APPEND
TO mv_daily_compliance_kpis
AS
WITH
-- 1. Resolve current state for every enrollment from argMaxState rollup.
--    protocol_definition_id and id are ORDER BY key columns (plain, not AggregateFunction).
all_instances AS (
    SELECT
        protocol_definition_id,
        id                               AS protocol_instance_id,
        argMaxMerge(status)              AS enrollment_status,
        toUInt8(argMaxMerge(is_deleted)) AS is_deleted
    FROM rollup_protocol_instance_current
    GROUP BY protocol_definition_id, id
),
-- 2. Non-deleted enrollments (all statuses) — used for status breakdown and compliance counts.
live_instances AS (
    SELECT protocol_definition_id, protocol_instance_id, enrollment_status
    FROM all_instances
    WHERE is_deleted = 0
),
-- 3. Enrollment status breakdown per protocol.
enrollment_agg AS (
    SELECT
        protocol_definition_id,
        toUInt32(count())                                    AS total_enrollments,
        toUInt32(countIf(enrollment_status = 'ACTIVE'))      AS status_active,
        toUInt32(countIf(enrollment_status = 'COMPLETED'))   AS status_completed,
        toUInt32(countIf(enrollment_status = 'WITHDRAWN'))   AS status_withdrawn,
        toUInt32(countIf(enrollment_status = 'EXPIRED'))     AS status_expired
    FROM live_instances
    GROUP BY protocol_definition_id
),
-- 4. Deviation counts per enrollment (all statuses, deviations are append-only).
instance_deviations AS (
    SELECT
        li.protocol_definition_id,
        li.protocol_instance_id,
        countIf(d.id != toUUID('00000000-0000-0000-0000-000000000000'))       AS deviation_count,
        countIf(d.deviation_type = 'OVERDUE')               AS overdue_count,
        countIf(d.deviation_type = 'MISSED')                AS missed_count,
        countIf(d.deviation_type = 'ORDER_VIOLATION')       AS order_violation_count
    FROM live_instances li
    LEFT JOIN deviations d ON li.protocol_instance_id = d.protocol_instance_id
    GROUP BY li.protocol_definition_id, li.protocol_instance_id
),
-- 5. Patient compliance and deviation summary per protocol.
patient_agg AS (
    SELECT
        protocol_definition_id,
        toUInt32(count())                                   AS tracked_patients,
        toUInt32(countIf(deviation_count = 0))              AS compliant_count,
        toUInt32(countIf(deviation_count > 0))              AS non_compliant_count,
        toUInt32(sum(deviation_count))                      AS total_deviations,
        toUInt32(sum(overdue_count))                        AS overdue_deviations,
        toUInt32(sum(missed_count))                         AS missed_deviations,
        toUInt32(sum(order_violation_count))                AS order_violation_deviations
    FROM instance_deviations
    GROUP BY protocol_definition_id
),
-- 6. Step metrics from rollup_step_current.
--    Inner query: resolve one current row per step (protocol_instance_id, id).
--    Outer: aggregate counts per protocol_definition_id via the live_instances join.
step_agg AS (
    SELECT
        li.protocol_definition_id,
        toUInt32(count())                                              AS step_total,
        toUInt32(countIf(rs.rs_state IN ('COMPLETED', 'SKIPPED')))    AS step_completed,
        toUInt32(countIf(rs.rs_state = 'OVERDUE'))                    AS step_overdue,
        toUInt32(countIf(rs.rs_state = 'MISSED'))                     AS step_missed,
        toUInt32(countIf(rs.rs_state = 'DUE'))                        AS step_due,
        toUInt32(countIf(rs.rs_state = 'PENDING'))                    AS step_pending,
        toUInt32(countIf(rs.rs_completion_status = 'ON_TIME'))         AS step_on_time,
        toUInt32(countIf(rs.rs_completion_status = 'EARLY'))           AS step_early,
        toUInt32(countIf(rs.rs_completion_status = 'LATE'))            AS step_late
    FROM (
        -- One resolved row per (protocol_instance_id, step_id)
        SELECT
            protocol_instance_id,
            id,
            argMaxMerge(state)               AS rs_state,
            argMaxMerge(completion_status)   AS rs_completion_status,
            toUInt8(argMaxMerge(is_deleted)) AS rs_is_deleted
        FROM rollup_step_current
        GROUP BY protocol_instance_id, id
    ) rs
    INNER JOIN live_instances li ON rs.protocol_instance_id = li.protocol_instance_id
    WHERE rs.rs_is_deleted = 0
    GROUP BY li.protocol_definition_id
)
SELECT
    toDate(now())                                                                        AS snapshot_date,
    now64(3)                                                                             AS refreshed_at,
    ea.protocol_definition_id                                                            AS protocol_definition_id,
    -- Enrollment breakdown
    ea.total_enrollments,
    ea.status_active,
    ea.status_completed,
    ea.status_withdrawn,
    ea.status_expired,
    -- Patient compliance
    pa.tracked_patients,
    pa.compliant_count,
    pa.non_compliant_count,
    coalesce(toFloat32(round(pa.compliant_count / nullIf(pa.tracked_patients, 0) * 100, 1)), 0.0) AS compliance_rate_pct,
    -- Deviation breakdown
    pa.total_deviations,
    pa.overdue_deviations,
    pa.missed_deviations,
    pa.order_violation_deviations,
    -- Step metrics
    coalesce(sa.step_total,     0)   AS step_total,
    coalesce(sa.step_completed, 0)   AS step_completed,
    coalesce(sa.step_overdue,   0)   AS step_overdue,
    coalesce(sa.step_missed,    0)   AS step_missed,
    coalesce(sa.step_due,       0)   AS step_due,
    coalesce(sa.step_pending,   0)   AS step_pending,
    coalesce(sa.step_on_time,   0)   AS step_on_time,
    coalesce(sa.step_early,     0)   AS step_early,
    coalesce(sa.step_late,      0)   AS step_late
FROM enrollment_agg ea
LEFT JOIN patient_agg pa ON ea.protocol_definition_id = pa.protocol_definition_id
LEFT JOIN step_agg    sa ON ea.protocol_definition_id = sa.protocol_definition_id;


-- ============================================================
-- 2 & 3. Facility KPIs / Facility Activity Summary  — REMOVED
-- ============================================================
-- mv_daily_facility_kpis and mv_daily_facility_activity_summary were dropped:
--   * mv_daily_facility_kpis had no live reader (the insights getFacilityKpis*
--     repo methods were unused; the Facilities ranking is computed live from the
--     enrolled-patient cohort + inbound_event_logs).
--   * mv_daily_facility_activity_summary depended on it and was likewise unread
--     (active-facility tiles read mv_event_volume_hourly directly, event_time-keyed).
-- Section numbers below are kept as-is to match schema/09 and existing references.

-- ============================================================
-- 4. Deviation KPIs  (per snapshot_date × protocol_definition_id)
-- ============================================================
-- Covers: Deviations page — header cards (total/overdue/missed/order-violation) and trend chart.
-- Keyed on the deviation's CLINICAL OCCURRENCE day (when it happened), NOT detected_at (when our
-- system flagged it). Occurrence = the linked step's clinical date by type: OVERDUE→overdue_date,
-- MISSED→missed_date, ORDER_VIOLATION→completed_at, then due_date, then detected_at (fallback) —
-- the compliance engine already computes those step dates from clinical event_time.
--
-- Dimensions: protocol_definition_id, facility_id, action_id, deviation_type — so the page can
-- filter by protocol/facility and group by type/day/action. deviation_count is additive over a
-- date range; affected_patients is a uniq STATE (uniqMerge at query time) so distinct patients are
-- correct across days. Full-recompute (REFRESH without APPEND) so backdated deviations land on the
-- day they occurred. The paginated deviation list stays live (row-level detail).

CREATE TABLE IF NOT EXISTS mv_daily_deviation_kpis
(
    snapshot_date           Date,             -- clinical occurrence day (toDate(occurred_at))
    refreshed_at            DateTime64(3),
    protocol_definition_id  String,
    protocol_canonical      String,           -- 1:1 with protocol_definition_id; carried for by-action
    facility_id             String,
    action_id               String,
    deviation_type          String,
    deviation_count         UInt64,           -- additive: sum() over a date range
    affected_patients_state AggregateFunction(uniq, String)   -- distinct patients: uniqMerge() at read
) ENGINE = ReplacingMergeTree(refreshed_at)
ORDER BY (snapshot_date, protocol_definition_id, facility_id, action_id, deviation_type);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_deviation_kpis_mv
REFRESH EVERY 30 MINUTE
TO mv_daily_deviation_kpis
AS
SELECT
    toDate(occurred_at)                     AS snapshot_date,
    now64(3)                                AS refreshed_at,
    protocol_definition_id,
    protocol_canonical,
    facility_id,
    action_id,
    deviation_type,
    count()                                 AS deviation_count,
    uniqState(patient_id)                   AS affected_patients_state
FROM (
    -- Resolve each deviation's CLINICAL occurrence date from the linked step, by type.
    SELECT
        coalesce(multiIf(
            d.deviation_type = 'OVERDUE',         si.overdue_date,
            d.deviation_type = 'MISSED',          si.missed_date,
            d.deviation_type = 'ORDER_VIOLATION', si.completed_at,
            CAST(NULL AS Nullable(DateTime64(6)))), si.due_date, d.detected_at)  AS occurred_at,
        toString(pi.protocol_definition_id)                                     AS protocol_definition_id,
        pi.protocol_canonical                                                   AS protocol_canonical,
        coalesce(pf.facility_id, '')                                            AS facility_id,
        si.action_id                                                            AS action_id,
        d.deviation_type                                                        AS deviation_type,
        pi.patient_id                                                           AS patient_id
    FROM cce_analytics.deviations AS d FINAL
    JOIN cce_analytics.step_instances AS si FINAL ON si.id = d.step_instance_id
    JOIN cce_analytics.protocol_instances AS pi FINAL ON pi.id = d.protocol_instance_id
    LEFT JOIN cce_analytics.mv_patient_facility_latest AS pf ON pf.patient_id = pi.patient_id
    WHERE d._is_deleted = 0
)
-- Rolling window: only recompute recent occurrence days so refresh cost stays flat as history grows.
WHERE occurred_at >= (now() - INTERVAL 12 MONTH)
GROUP BY snapshot_date, protocol_definition_id, protocol_canonical, facility_id, action_id, deviation_type;


-- ============================================================
-- 5. Event Processing KPIs  (per CLINICAL event_time day × facility)
-- ============================================================
-- Covers: Events page header cards — total / matched / zero-match / duplicate / pipeline loss.
-- Keyed on the inbound event's CLINICAL event_time day (same clock + same event set as the volume
-- breakdowns in mv_event_volume_hourly), so every date-filtered card reconciles: Matched Rate =
-- matched/total over the SAME events. The processing OUTCOME per event is joined from
-- compliance_event_logs by cloudevents_id (one outcome per event, latest wins).
--
-- total_events        → inbound_event_logs ACCEPTED, event_time = day
-- matched/zero/dup    → of those, the joined compliance processing_status
-- pipeline_loss_count → accepted events with NO compliance row (LEFT-JOIN anti-match) — ALWAYS >= 0
--                       (total = matched + zero_match + duplicate + pipeline_loss). Rates are
--                       computed at query time (matched/total), so no rate columns stored here.

CREATE TABLE IF NOT EXISTS mv_daily_event_kpis
(
    snapshot_date         Date,        -- clinical event_time day
    refreshed_at          DateTime64(3),
    facility_id           String,
    total_events          UInt64,
    matched_count         UInt64,
    zero_match_count      UInt64,
    duplicate_count       UInt64,
    pipeline_loss_count   UInt64       -- accepted but never reached compliance (>= 0)
) ENGINE = ReplacingMergeTree(refreshed_at)
ORDER BY (snapshot_date, facility_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_event_kpis_mv
REFRESH EVERY 30 MINUTE
TO mv_daily_event_kpis
AS
SELECT
    toDate(iel.event_time)                                                         AS snapshot_date,
    now64(3)                                                                       AS refreshed_at,
    iel.facility_id                                                                AS facility_id,
    count()                                                                        AS total_events,
    countIf(cel.processing_status = 'MATCHED')                                     AS matched_count,
    countIf(cel.processing_status = 'ZERO_MATCH')                                  AS zero_match_count,
    countIf(cel.processing_status = 'DUPLICATE')                                   AS duplicate_count,
    countIf(cel.processing_status NOT IN ('MATCHED', 'ZERO_MATCH', 'DUPLICATE'))   AS pipeline_loss_count
FROM cce_analytics.inbound_event_logs AS iel FINAL
LEFT JOIN (
    -- one processing outcome per event (dedup by cloudevents_id; latest received wins)
    SELECT cloudevents_id, argMax(processing_status, received_at) AS processing_status
    FROM cce_analytics.compliance_event_logs FINAL
    GROUP BY cloudevents_id
) AS cel ON cel.cloudevents_id = iel.cloudevents_id
WHERE iel.status = 'ACCEPTED' AND iel.event_time IS NOT NULL
  AND iel.event_time >= (now() - INTERVAL 12 MONTH)   -- rolling window, caps refresh cost
GROUP BY snapshot_date, iel.facility_id;


-- ============================================================
-- 6. e-Buzima Adoption KPIs  (per snapshot_date × facility_id)
-- ============================================================
-- Covers: e-Buzima Adoption indicator on the Dashboard / Facilities page.
--
-- Metrics (per facility per day):
--   actual_patients          → unique patients who WALKED IN (had a clinical event) at the facility
--                              on snapshot_date = the clinical event day, toDate(event_time)
--   expected_patients_per_day → static validated baseline from facility
--   adoption_rate_pct        → actual / expected × 100
--   reporting_gap            → expected − actual
--                              positive = under-reporting; negative = over-reporting
--
-- Requires: facility (schema/08) with expected_patients_per_day populated.
--
-- For multi-day reporting periods (date range from UI) the backend service should:
--   SELECT snapshot_date, facility_id, actual_patients, expected_patients_per_day
--   FROM mv_daily_adoption_kpis FINAL
--   WHERE snapshot_date BETWEEN :from AND :to
--   and compute:
--     total_actual   = sum(actual_patients)
--     total_expected = expected_patients_per_day × count(distinct snapshot_date)
--     period_rate    = total_actual / total_expected × 100

CREATE TABLE IF NOT EXISTS mv_daily_adoption_kpis
(
    snapshot_date              Date,
    refreshed_at               DateTime64(3),
    facility_id                String,
    expected_patients_per_day  UInt32,        -- from facility (static baseline)
    actual_patients            UInt32,        -- unique patients with events on snapshot_date
    adoption_rate_pct          Float32,       -- actual / expected × 100
    reporting_gap              Int64          -- expected − actual (positive = under-reporting)
) ENGINE = ReplacingMergeTree(refreshed_at)
ORDER BY (snapshot_date, facility_id);
-- facility_name is intentionally NOT stored — resolved at query time from the facility table.
-- Storing it caused duplicate rows when the name changed between 30-min refreshes
-- (GROUP BY facility_id, facility_name produced two groups for the same facility_id).

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_adoption_kpis_mv
REFRESH EVERY 30 MINUTE
TO mv_daily_adoption_kpis
AS
-- e-Buzima Adoption = clinical footfall: unique patients who WALKED IN (had a clinical event) at a
-- facility on each clinical day, keyed on event_time (when the visit happened), NOT received_at
-- (when we ingested it). So a backdated/batch upload credits the day the patient was actually seen.
--
-- Event-driven + full-recompute: the MV is REFRESH EVERY 30 MINUTE *without* APPEND, so each cycle
-- atomically REPLACES the whole target table — every clinical day is recomputed (a late upload
-- updates its own past day). uniq(subject) dedupes patients, so it is robust to CDC row duplication
-- (no FINAL needed on inbound_event_logs). Rows are emitted only for (facility, day) that had a
-- visit; zero-activity facilities are filled in at query time (AdoptionService.mergeWithReference).
SELECT
    toDate(iel.event_time)                                                                 AS snapshot_date,
    now64(3)                                                                               AS refreshed_at,
    fr.facility_id                                                                          AS facility_id,
    fr.expected_patients_per_day                                                            AS expected_patients_per_day,
    toUInt32(uniq(iel.subject))                                                            AS actual_patients,
    coalesce(toFloat32(round(
        uniq(iel.subject) / nullIf(toFloat64(fr.expected_patients_per_day), 0) * 100, 1
    )), 0.0)                                                                               AS adoption_rate_pct,
    toInt64(fr.expected_patients_per_day) - toInt64(toUInt32(uniq(iel.subject)))           AS reporting_gap
FROM cce_analytics.inbound_event_logs AS iel
JOIN (
    SELECT facility_id, expected_patients_per_day
    FROM cce_analytics.facility FINAL
    WHERE _is_deleted = 0
) AS fr ON fr.facility_id = iel.facility_id
WHERE iel.status = 'ACCEPTED'
  AND iel.facility_id != ''
  AND iel.subject != ''
  AND iel.event_time IS NOT NULL
  AND iel.event_time >= (now() - INTERVAL 12 MONTH)   -- rolling window, caps refresh cost
GROUP BY snapshot_date, fr.facility_id, fr.expected_patients_per_day;


-- ============================================================
-- 7. Referral KPIs  (per CLINICAL event_time day × facility)
-- ============================================================
-- Covers: Dashboard "Referrals" card — total referrals received by HIE + per-facility breakdown.
-- Definition: a "referral form successfully received by HIE" is an ACCEPTED inbound event that was
-- matched to (completed) a Referral Initiated step. Keyed on the inbound event's CLINICAL event_time
-- day (same clock + window as the other event_time MVs), so the Dashboard date filter reconciles.
--
-- Join path (the completing event is a COMPLIANCE event log, NOT the collector's inbound row):
--   step_instances.completed_by_event_id → compliance_event_logs.id
--   compliance_event_logs.cloudevents_id → inbound_event_logs.cloudevents_id
-- referral_count = accepted referral-initiated events on that day at that facility.
--
-- action_id pattern (baked in so it works in every environment without config):
--   ^(.+-referral|referral)$  — matches Dev/Demo "anc-visit-1-referral" (…-referral suffix) AND
--   UAT/Prod "referral" (bare). Excludes "-referral-consultation" / "-referral-ack" /
--   "-referral-closure" (they don't end at "-referral" and aren't the bare word).
--
-- Full-recompute (REFRESH without APPEND) + 12-month rolling window: same model as sections 4-6, so
-- a backdated referral lands on the day it clinically occurred and refresh cost stays bounded.

CREATE TABLE IF NOT EXISTS mv_daily_referral_kpis
(
    snapshot_date    Date,          -- clinical event_time day
    refreshed_at     DateTime64(3),
    facility_id      String,
    referral_count   UInt64         -- accepted referral-initiated events that day
) ENGINE = ReplacingMergeTree(refreshed_at)
ORDER BY (snapshot_date, facility_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_referral_kpis_mv
REFRESH EVERY 30 MINUTE
TO mv_daily_referral_kpis
AS
SELECT
    toDate(iel.event_time)   AS snapshot_date,
    now64(3)                 AS refreshed_at,
    iel.facility_id          AS facility_id,
    count()                  AS referral_count
FROM cce_analytics.inbound_event_logs AS iel FINAL
JOIN cce_analytics.compliance_event_logs AS cel FINAL ON cel.cloudevents_id = iel.cloudevents_id
JOIN cce_analytics.step_instances       AS si  FINAL ON si.completed_by_event_id = cel.id
WHERE iel.status = 'ACCEPTED' AND iel.event_time IS NOT NULL
  AND iel.event_time >= (now() - INTERVAL 12 MONTH)   -- rolling window, caps refresh cost
  AND match(si.action_id, '^(.+-referral|referral)$')
GROUP BY snapshot_date, iel.facility_id;


-- ============================================================
-- QUERY EXAMPLES (page-by-page)
-- ============================================================
--
-- DASHBOARD — compliance cards (today's snapshot, all protocols):
--   SELECT sum(tracked_patients), sum(compliant_count), sum(non_compliant_count),
--     round(sum(compliant_count)/nullIf(sum(tracked_patients),0)*100,1) AS compliance_rate_pct
--   FROM mv_daily_compliance_kpis FINAL
--   WHERE snapshot_date = today();
--
-- DASHBOARD — facility activity cards + top/bottom facilities: computed live in the
--   insights service (active facilities from mv_event_volume_hourly; compliance ranking
--   from the enrolled-patient cohort). No daily-summary MV backs these anymore.
--
-- DASHBOARD — e-Buzima adoption overview today (worst under-reporters first):
--   SELECT a.facility_id, f.facility_name, a.expected_patients_per_day, a.actual_patients,
--          a.adoption_rate_pct, a.reporting_gap
--   FROM mv_daily_adoption_kpis a FINAL
--   LEFT JOIN facility f FINAL ON f.facility_id = a.facility_id
--   WHERE a.snapshot_date = today()
--   ORDER BY a.reporting_gap DESC;
--
-- DASHBOARD — Referrals over a reporting period (total + per facility):
--   SELECT facility_id, sum(referral_count) AS referrals
--   FROM mv_daily_referral_kpis FINAL
--   WHERE snapshot_date BETWEEN :from AND :to
--   GROUP BY facility_id
--   ORDER BY referrals DESC;   -- omit GROUP BY for the grand total
--
-- TREND — compliance rate over last 30 days (daily snapshots):
--   SELECT snapshot_date,
--          sum(tracked_patients)  AS tracked_patients,
--          sum(compliant_count)   AS compliant_count,
--          round(sum(compliant_count)/nullIf(sum(tracked_patients),0)*100,1) AS compliance_rate_pct
--   FROM mv_daily_compliance_kpis FINAL
--   WHERE snapshot_date >= today() - 30
--   GROUP BY snapshot_date
--   ORDER BY snapshot_date;
--
-- TREND — adoption rate over a reporting period (multi-day):
--   SELECT a.snapshot_date, a.facility_id, f.facility_name,
--          a.actual_patients, a.expected_patients_per_day, a.adoption_rate_pct
--   FROM mv_daily_adoption_kpis a FINAL
--   LEFT JOIN facility f FINAL ON f.facility_id = a.facility_id
--   WHERE a.snapshot_date BETWEEN '2026-01-01' AND '2026-06-22'
--   ORDER BY a.snapshot_date, a.facility_id;
--
-- COMPLIANCE PAGE — per-protocol summary (today):
--   SELECT protocol_definition_id,
--     total_enrollments, status_active, status_completed, status_withdrawn, status_expired,
--     tracked_patients, compliant_count, non_compliant_count, compliance_rate_pct,
--     step_total, step_completed, step_on_time, step_late, step_early,
--     step_overdue, step_missed, step_due, step_pending,
--     total_deviations, overdue_deviations, missed_deviations, order_violation_deviations
--   FROM mv_daily_compliance_kpis FINAL
--   WHERE snapshot_date = today()
--     AND protocol_definition_id = ?;
--
-- FACILITIES PAGE — ranking table: computed live in the insights service
--   (FacilityRankingService — enrolled-patient cohort + inbound_event_logs event counts).
--
-- FACILITIES PAGE — adoption table (today):
--   SELECT a.facility_id, f.facility_name, a.expected_patients_per_day, a.actual_patients,
--          a.adoption_rate_pct, a.reporting_gap
--   FROM mv_daily_adoption_kpis a FINAL
--   LEFT JOIN facility f FINAL ON f.facility_id = a.facility_id
--   WHERE a.snapshot_date = today()
--   ORDER BY a.adoption_rate_pct DESC;
--
-- DEVIATIONS PAGE — header cards (today):
--   SELECT sum(total_deviations), sum(overdue_count), sum(missed_count), sum(order_violation_count)
--   FROM mv_daily_deviation_kpis FINAL
--   WHERE snapshot_date = today();
--   -- omit snapshot_date filter to get all-time totals
--
-- EVENTS PAGE — header cards (today's refresh):
--   SELECT total_events, matched_rate_pct, zero_match_rate_pct, pipeline_loss_count
--   FROM mv_daily_event_kpis FINAL
--   WHERE snapshot_date = today()
--   LIMIT 1;
