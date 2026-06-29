-- CCE Analytics — Historical Backfill of Daily Summary MVs (schema/07)
-- Run: clickhouse-client --database cce_analytics \
--        --param_from_date=2026-01-01 --param_to_date=2026-06-27 \
--        < schema/09-historical-backfill.sql
--
-- ============================================================================
-- ⚠️  WHEN TO RUN — READ FIRST
-- ============================================================================
--   Run this ONLY to rebuild historical daily-MV rows AFTER a full ClickHouse
--   re-snapshot (or to fill a known gap), AND only if historical backfill is needed.
--
--   It is NOT part of normal operation or any deploy:
--     - deliberately EXCLUDED from the schema-apply list (redeploy-clickhouse.sh
--       applies 01–08 only; 09 is never auto-run);
--     - requires --param_from_date / --param_to_date, so it cannot run by accident.
--
--   In steady state, NEVER run it — the schema/07 refreshable MVs populate today's
--   rows automatically every 30 min. This script is purely for recovering PAST
--   snapshot_date rows that a re-snapshot cannot rebuild on its own.
-- ============================================================================
--
-- WHY THIS EXISTS
--   The schema/07 refreshable MVs only ever snapshot "today" (toDate(now())).
--   They cannot rebuild PAST snapshot_date rows. After a full ClickHouse
--   re-snapshot (or to fill a gap), this script reconstructs historical daily
--   rows by replaying the append-only transition history:
--       protocol_instance_history  (status as-of date D)
--       step_instance_history      (state / completion_status as-of date D)
--   joined with the already-durable, time-anchored sources:
--       deviations (detected_at), inbound_event_log (received_at),
--       compliance_event_log (received_at), facility.
--
-- AS-OF PATTERN (used throughout)
--   For a snapshot_date D, an entity's state = the history row with the latest
--   changed_at whose DATE is <= D:
--       INNER JOIN history h ON toDate(h.changed_at) <= d.snapshot_date
--       ... argMax(h.state, h.changed_at) GROUP BY d.snapshot_date, entity_id
--   This vectorizes the as-of lookup across the whole date range in one pass.
--
-- IMPORTANT
--   * Reconstruction is only as complete as the history. Dates BEFORE the V4
--     triggers were deployed rely on the one-time seed (exact for
--     protocol_instance; best-effort for step_instance DUE/OVERDUE/MISSED/SKIPPED).
--   * This aggregation MUST stay in lockstep with mv_daily_compliance_kpis in
--     schema/07. If that MV's logic changes, change this query to match, so
--     backfilled days and live days are computed identically.
--   * Safe to re-run: ReplacingMergeTree(refreshed_at) dedups by
--     (snapshot_date, protocol_definition_id); a later refreshed_at wins.

USE cce_analytics;

-- ============================================================
-- 1. mv_daily_compliance_kpis  (per snapshot_date × protocol_definition_id)
-- ============================================================
INSERT INTO mv_daily_compliance_kpis
WITH
-- Date series for the requested window (one row per calendar day).
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
-- Enrollment status as-of each day (latest status at or before D). Existence is
-- implicit: an enrollment only appears on days >= its first history row.
enrollment_asof AS (
    SELECT
        d.snapshot_date                                            AS snapshot_date,
        h.protocol_instance_id                                     AS protocol_instance_id,
        any(h.protocol_definition_id)                              AS protocol_definition_id,
        argMax(h.status, h.changed_at)                             AS status
    FROM dates d
    INNER JOIN protocol_instance_history h FINAL
            ON toDate(h.changed_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, h.protocol_instance_id
),
-- Deviations attributable to each enrollment as-of D (deviations are append-only).
deviations_asof AS (
    SELECT
        d.snapshot_date                                            AS snapshot_date,
        dv.protocol_instance_id                                    AS protocol_instance_id,
        countIf(dv.id != toUUID('00000000-0000-0000-0000-000000000000')) AS deviation_count,
        countIf(dv.deviation_type = 'OVERDUE')                     AS overdue_count,
        countIf(dv.deviation_type = 'MISSED')                      AS missed_count,
        countIf(dv.deviation_type = 'ORDER_VIOLATION')             AS order_violation_count
    FROM dates d
    INNER JOIN deviations dv FINAL
            ON toDate(dv.detected_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, dv.protocol_instance_id
),
-- Step state as-of each day (latest state at or before D), keyed to its enrollment.
step_asof AS (
    SELECT
        d.snapshot_date                                            AS snapshot_date,
        h.step_instance_id                                         AS step_instance_id,
        any(h.protocol_instance_id)                                AS protocol_instance_id,
        argMax(h.state, h.changed_at)                              AS state,
        argMax(h.completion_status, h.changed_at)                  AS completion_status
    FROM dates d
    INNER JOIN step_instance_history h FINAL
            ON toDate(h.changed_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, h.step_instance_id
),
-- Enrollment breakdown per (day, protocol_definition_id).
enrollment_agg AS (
    SELECT
        snapshot_date,
        protocol_definition_id,
        toUInt32(count())                                          AS total_enrollments,
        toUInt32(countIf(status = 'ACTIVE'))                       AS status_active,
        toUInt32(countIf(status = 'COMPLETED'))                    AS status_completed,
        toUInt32(countIf(status = 'WITHDRAWN'))                    AS status_withdrawn,
        toUInt32(countIf(status = 'EXPIRED'))                      AS status_expired
    FROM enrollment_asof
    GROUP BY snapshot_date, protocol_definition_id
),
-- Patient compliance + deviation rollup per (day, protocol_definition_id).
patient_agg AS (
    SELECT
        e.snapshot_date                                            AS snapshot_date,
        e.protocol_definition_id                                   AS protocol_definition_id,
        toUInt32(count())                                          AS tracked_patients,
        toUInt32(countIf(coalesce(dv.deviation_count, 0) = 0))     AS compliant_count,
        toUInt32(countIf(coalesce(dv.deviation_count, 0) > 0))     AS non_compliant_count,
        toUInt32(sum(coalesce(dv.deviation_count, 0)))             AS total_deviations,
        toUInt32(sum(coalesce(dv.overdue_count, 0)))               AS overdue_deviations,
        toUInt32(sum(coalesce(dv.missed_count, 0)))                AS missed_deviations,
        toUInt32(sum(coalesce(dv.order_violation_count, 0)))       AS order_violation_deviations
    FROM enrollment_asof e
    LEFT JOIN deviations_asof dv
           ON dv.snapshot_date = e.snapshot_date
          AND dv.protocol_instance_id = e.protocol_instance_id
    GROUP BY e.snapshot_date, e.protocol_definition_id
),
-- Step metrics per (day, protocol_definition_id), joined to the enrollment's protocol.
step_agg AS (
    SELECT
        s.snapshot_date                                            AS snapshot_date,
        e.protocol_definition_id                                   AS protocol_definition_id,
        toUInt32(count())                                          AS step_total,
        toUInt32(countIf(s.state IN ('COMPLETED', 'SKIPPED')))     AS step_completed,
        toUInt32(countIf(s.state = 'OVERDUE'))                     AS step_overdue,
        toUInt32(countIf(s.state = 'MISSED'))                      AS step_missed,
        toUInt32(countIf(s.state = 'DUE'))                         AS step_due,
        toUInt32(countIf(s.state = 'PENDING'))                     AS step_pending,
        toUInt32(countIf(s.completion_status = 'ON_TIME'))         AS step_on_time,
        toUInt32(countIf(s.completion_status = 'EARLY'))           AS step_early,
        toUInt32(countIf(s.completion_status = 'LATE'))            AS step_late
    FROM step_asof s
    INNER JOIN enrollment_asof e
            ON e.snapshot_date = s.snapshot_date
           AND e.protocol_instance_id = s.protocol_instance_id
    GROUP BY s.snapshot_date, e.protocol_definition_id
)
SELECT
    ea.snapshot_date                                                                     AS snapshot_date,
    now64(3)                                                                             AS refreshed_at,
    ea.protocol_definition_id                                                            AS protocol_definition_id,
    ea.total_enrollments,
    ea.status_active,
    ea.status_completed,
    ea.status_withdrawn,
    ea.status_expired,
    pa.tracked_patients,
    pa.compliant_count,
    pa.non_compliant_count,
    coalesce(toFloat32(round(pa.compliant_count / nullIf(pa.tracked_patients, 0) * 100, 1)), 0.0) AS compliance_rate_pct,
    pa.total_deviations,
    pa.overdue_deviations,
    pa.missed_deviations,
    pa.order_violation_deviations,
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
LEFT JOIN patient_agg pa ON ea.snapshot_date = pa.snapshot_date AND ea.protocol_definition_id = pa.protocol_definition_id
LEFT JOIN step_agg    sa ON ea.snapshot_date = sa.snapshot_date AND ea.protocol_definition_id = sa.protocol_definition_id;


-- ============================================================
-- 2. mv_daily_facility_kpis  (per snapshot_date × facility_id)
-- ============================================================
-- ACTIVE enrollments as-of D (protocol_instance_history) × patient->facility as-of D
-- (latest accepted event on/before D from inbound_event_logs — NOT the current
-- mv_patient_facility_latest) + deviations as-of D + events on D.
INSERT INTO mv_daily_facility_kpis
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
-- ACTIVE enrollments as-of D, with immutable patient_id from the base table
active_enr AS (
    SELECT
        e.snapshot_date         AS snapshot_date,
        e.protocol_instance_id  AS protocol_instance_id,
        any(pi.patient_id)      AS patient_id
    FROM (
        SELECT d.snapshot_date, h.protocol_instance_id,
               argMax(h.status, h.changed_at) AS status
        FROM dates d
        INNER JOIN protocol_instance_history h FINAL
                ON toDate(h.changed_at) <= d.snapshot_date
        GROUP BY d.snapshot_date, h.protocol_instance_id
    ) e
    INNER JOIN protocol_instances pi FINAL ON pi.id = e.protocol_instance_id
    WHERE e.status = 'ACTIVE'
    GROUP BY e.snapshot_date, e.protocol_instance_id
),
-- each patient's most-recently-seen facility on/before D
patient_facility AS (
    SELECT
        d.snapshot_date                              AS snapshot_date,
        iel.subject                                  AS patient_id,
        argMax(iel.facility_id, iel.received_at)     AS facility_id
    FROM dates d
    INNER JOIN inbound_event_logs iel
            ON toDate(iel.received_at) <= d.snapshot_date
    WHERE iel.facility_id != ''
    GROUP BY d.snapshot_date, iel.subject
),
dev_asof AS (
    SELECT d.snapshot_date AS snapshot_date, dv.protocol_instance_id AS protocol_instance_id,
           count() AS deviation_count
    FROM dates d
    INNER JOIN deviations dv FINAL ON toDate(dv.detected_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, dv.protocol_instance_id
),
inst AS (
    SELECT
        ae.snapshot_date                    AS snapshot_date,
        ae.protocol_instance_id             AS protocol_instance_id,
        coalesce(pf.facility_id, '')        AS facility_id,
        coalesce(dv.deviation_count, 0)     AS deviation_count
    FROM active_enr ae
    LEFT JOIN patient_facility pf ON pf.snapshot_date = ae.snapshot_date AND pf.patient_id = ae.patient_id
    LEFT JOIN dev_asof dv         ON dv.snapshot_date = ae.snapshot_date AND dv.protocol_instance_id = ae.protocol_instance_id
),
compliance_by_facility AS (
    SELECT
        snapshot_date,
        facility_id,
        toUInt32(count())                       AS tracked_patients,
        toUInt32(countIf(deviation_count = 0))  AS compliant_patients,
        toUInt32(countIf(deviation_count > 0))  AS non_compliant_patients,
        coalesce(toFloat32(round(countIf(deviation_count = 0) / nullIf(count(), 0) * 100, 1)), 0.0) AS compliance_rate_pct,
        toUInt32(sum(deviation_count))          AS total_deviations
    FROM inst
    WHERE facility_id != ''
    GROUP BY snapshot_date, facility_id
),
events_by_day AS (
    SELECT toDate(hour) AS snapshot_date, facility_id, sum(event_count) AS event_count
    FROM mv_event_volume_hourly
    WHERE facility_id != ''
    GROUP BY toDate(hour), facility_id
)
SELECT
    cbf.snapshot_date                AS snapshot_date,
    now64(3)                         AS refreshed_at,
    cbf.facility_id,
    cbf.tracked_patients,
    cbf.compliant_patients,
    cbf.non_compliant_patients,
    cbf.compliance_rate_pct,
    cbf.total_deviations,
    coalesce(eb.event_count, 0)      AS event_count
FROM compliance_by_facility cbf
LEFT JOIN events_by_day eb ON eb.snapshot_date = cbf.snapshot_date AND eb.facility_id = cbf.facility_id;


-- ============================================================
-- 3. mv_daily_facility_activity_summary  (per snapshot_date — single row)
-- ============================================================
-- DEPENDS on section 2: reads the just-backfilled mv_daily_facility_kpis.
-- Mirrors the live MV exactly: "active" = a facility present in facility_kpis with
-- event_count > 0 (a facility with events but no ACTIVE patients counts as inactive).
INSERT INTO mv_daily_facility_activity_summary
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
in_scope AS (
    -- facilities that existed (created) on/before D
    SELECT d.snapshot_date AS snapshot_date, f.facility_id AS facility_id
    FROM dates d
    INNER JOIN facility f FINAL
            ON toDate(f.created_at) <= d.snapshot_date AND f._is_deleted = 0
),
fk AS (
    SELECT snapshot_date, facility_id, event_count
    FROM mv_daily_facility_kpis FINAL
)
SELECT
    isc.snapshot_date                                                                 AS snapshot_date,
    now64(3)                                                                          AS refreshed_at,
    toUInt32(count())                                                                 AS total_in_scope,
    toUInt32(countIf(coalesce(fk.event_count, 0) > 0))                                AS active_facilities,
    toUInt32(countIf(coalesce(fk.event_count, 0) = 0))                                AS inactive_facilities,
    coalesce(toFloat32(round(countIf(coalesce(fk.event_count, 0) > 0) / nullIf(count(), 0) * 100, 1)), 0.0) AS active_facility_rate_pct
FROM in_scope isc
LEFT JOIN fk ON fk.snapshot_date = isc.snapshot_date AND fk.facility_id = isc.facility_id
GROUP BY isc.snapshot_date;


-- ============================================================
-- 4. mv_daily_deviation_kpis  (per snapshot_date × protocol_definition_id)
-- ============================================================
-- Deviations (detected_at <= D) for enrollments that existed as-of D.
INSERT INTO mv_daily_deviation_kpis
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
enr AS (
    SELECT
        d.snapshot_date                 AS snapshot_date,
        h.protocol_instance_id          AS protocol_instance_id,
        any(h.protocol_definition_id)   AS protocol_definition_id
    FROM dates d
    INNER JOIN protocol_instance_history h FINAL
            ON toDate(h.changed_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, h.protocol_instance_id
)
SELECT
    e.snapshot_date                                                  AS snapshot_date,
    now64(3)                                                         AS refreshed_at,
    e.protocol_definition_id                                         AS protocol_definition_id,
    toUInt32(count(dv.id))                                           AS total_deviations,
    toUInt32(countIf(dv.deviation_type = 'OVERDUE'))                 AS overdue_count,
    toUInt32(countIf(dv.deviation_type = 'MISSED'))                  AS missed_count,
    toUInt32(countIf(dv.deviation_type = 'ORDER_VIOLATION'))         AS order_violation_count
FROM enr e
INNER JOIN deviations dv FINAL
        ON dv.protocol_instance_id = e.protocol_instance_id
       AND toDate(dv.detected_at) <= e.snapshot_date
GROUP BY e.snapshot_date, e.protocol_definition_id;


-- ============================================================
-- 5. mv_daily_event_kpis  (per snapshot_date — single row, cumulative as-of D)
-- ============================================================
-- The live MV stamps all-time cumulative totals each refresh, so as-of D =
-- cumulative through end of day D (received_at/hour <= D). processing_status is
-- terminal, so current values reconstruct the past accurately.
INSERT INTO mv_daily_event_kpis
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
ev AS (
    SELECT d.snapshot_date AS snapshot_date, sum(h.event_count) AS total_events
    FROM dates d
    INNER JOIN mv_event_volume_hourly h ON toDate(h.hour) <= d.snapshot_date
    GROUP BY d.snapshot_date
),
proc AS (
    SELECT
        d.snapshot_date                                       AS snapshot_date,
        countIf(c.processing_status = 'MATCHED')              AS matched_count,
        countIf(c.processing_status = 'ZERO_MATCH')           AS zero_match_count,
        countIf(c.processing_status = 'DUPLICATE')            AS duplicate_count,
        count()                                               AS total_processed
    FROM dates d
    INNER JOIN compliance_event_logs c FINAL ON toDate(c.received_at) <= d.snapshot_date
    GROUP BY d.snapshot_date
)
SELECT
    ev.snapshot_date                                                                  AS snapshot_date,
    now64(3)                                                                          AS refreshed_at,
    toUInt64(coalesce(ev.total_events, 0))                                            AS total_events,
    toUInt64(coalesce(p.matched_count, 0))                                            AS matched_count,
    toUInt64(coalesce(p.zero_match_count, 0))                                         AS zero_match_count,
    toUInt64(coalesce(p.duplicate_count, 0))                                          AS duplicate_count,
    coalesce(toFloat32(round(p.matched_count / nullIf(p.total_processed, 0) * 100, 1)), 0.0)    AS matched_rate_pct,
    coalesce(toFloat32(round(p.zero_match_count / nullIf(p.total_processed, 0) * 100, 1)), 0.0) AS zero_match_rate_pct,
    toInt64(coalesce(ev.total_events, 0)) - toInt64(coalesce(p.total_processed, 0))   AS pipeline_loss_count
FROM ev
LEFT JOIN proc p ON p.snapshot_date = ev.snapshot_date;


-- ============================================================
-- 6. mv_daily_adoption_kpis  (per snapshot_date × facility_id)
-- ============================================================
-- Per-DAY (not cumulative): unique ACCEPTED patients whose events landed on day D,
-- per facility, ÷ the facility baseline. Baseline is read from the CURRENT facility
-- row by design — expected_patients_per_day is intentionally NOT historised, so a
-- backfilled adoption_rate uses today's baseline even if it was revised since day D.
INSERT INTO mv_daily_adoption_kpis
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
fac AS (
    SELECT
        d.snapshot_date                          AS snapshot_date,
        f.facility_id                            AS facility_id,
        any(f.expected_patients_per_day)         AS expected_patients_per_day
    FROM dates d
    INNER JOIN facility f FINAL
            ON toDate(f.created_at) <= d.snapshot_date AND f._is_deleted = 0
    GROUP BY d.snapshot_date, f.facility_id
),
actual AS (
    SELECT
        toDate(received_at)        AS snapshot_date,
        facility_id,
        uniq(subject)              AS actual_patients
    FROM inbound_event_logs
    WHERE status = 'ACCEPTED' AND facility_id != ''
    GROUP BY toDate(received_at), facility_id
)
SELECT
    fac.snapshot_date                                                                 AS snapshot_date,
    now64(3)                                                                          AS refreshed_at,
    fac.facility_id,
    fac.expected_patients_per_day,
    toUInt32(coalesce(a.actual_patients, 0))                                          AS actual_patients,
    coalesce(toFloat32(round(
        coalesce(a.actual_patients, 0) / nullIf(toFloat64(fac.expected_patients_per_day), 0) * 100, 1
    )), 0.0)                                                                          AS adoption_rate_pct,
    toInt64(fac.expected_patients_per_day) - toInt64(coalesce(a.actual_patients, 0))  AS reporting_gap
FROM fac
LEFT JOIN actual a ON a.snapshot_date = fac.snapshot_date AND a.facility_id = fac.facility_id;


-- ============================================================
-- RUN ORDER
-- ============================================================
-- Sections 1, 4, 5, 6 are independent. Section 2 (facility_kpis) MUST run before
-- section 3 (facility_activity_summary), which reads the rows section 2 inserts.
-- For very large windows, run in monthly date chunks (adjust from_date/to_date) to
-- bound the as-of join fan-out. Safe to re-run: ReplacingMergeTree(refreshed_at)
-- keeps the latest refreshed_at per key.
