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
--       step_instance_history      (step_status / sla_status as-of date D)
--   joined with the already-durable, time-anchored source:
--       deviations (detected_at).
--   (Only section 1 / mv_daily_compliance_kpis still backfills this way. The event_time MVs —
--    event, deviation-page, adoption, referral — self-heal on refresh, so this script no longer
--    reads inbound_event_log / matcher_event_log / facility.)
--
-- AS-OF PATTERN (used throughout)
--   For a snapshot_date D, an entity's state = the history row with the latest
--   changed_at whose DATE is <= D:
--       INNER JOIN history h ON toDate(h.changed_at) <= d.snapshot_date
--       ... argMax(h.step_status, h.changed_at) GROUP BY d.snapshot_date, entity_id
--   This vectorizes the as-of lookup across the whole date range in one pass.
--
-- IMPORTANT
--   * Reconstruction is only as complete as the history: every transition is captured
--     forward from enrollment (a fresh start has no pre-existing rows), so an instance
--     appears from its first history row onward.
--   * step_instance_history.changed_at is when the row was RECORDED (processing time), not the
--     clinical time — a backdated completion lands on the day it was processed. Both writers
--     (Matcher for step_status, Step SLA for sla_status) snapshot the whole pair on every row, so
--     the latest row as-of D carries both statuses.
--   * History ids are allocated in blocks per writer (Matcher V6) and are NOT in insert order;
--     every as-of pick here orders by changed_at, never by id.
--   * The history tables carry only their direct parent id; protocol_definition_id and
--     protocol_instance_id are recovered by INNER JOIN to the immutable base tables
--     (protocol_instances / step_instances). A hard-deleted instance/step (purged by
--     clean_deleted_rows) therefore drops out of the backfill — by design, a deleted
--     entity is excluded from historical rollups too.
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
        any(pi.protocol_definition_id)                             AS protocol_definition_id,
        argMax(h.status, h.changed_at)                             AS status
    FROM dates d
    INNER JOIN protocol_instance_history h FINAL
            ON toDate(h.changed_at) <= d.snapshot_date
    -- protocol_definition_id is no longer denormalized on the history row; recover it from
    -- the immutable base table. INNER JOIN: a hard-deleted (and purged) instance drops out.
    INNER JOIN protocol_instances pi FINAL
            ON pi.id = h.protocol_instance_id
    GROUP BY d.snapshot_date, h.protocol_instance_id
),
-- Deviations attributable to each enrollment as-of D (deviations are append-only). 2.0.0 dropped
-- deviation.protocol_instance_id, so it is recovered from the step (immutable per step id).
deviations_asof AS (
    SELECT
        d.snapshot_date                                            AS snapshot_date,
        si.protocol_instance_id                                    AS protocol_instance_id,
        countIf(dv.id != toUUID('00000000-0000-0000-0000-000000000000')) AS deviation_count,
        countIf(dv.deviation_type = 'OVERDUE')                     AS overdue_count,
        countIf(dv.deviation_type = 'MISSED')                      AS missed_count,
        countIf(dv.deviation_type = 'ORDER_VIOLATION')             AS order_violation_count
    FROM dates d
    INNER JOIN deviations dv FINAL
            ON toDate(dv.detected_at) <= d.snapshot_date
    INNER JOIN (
        SELECT id, any(protocol_instance_id) AS protocol_instance_id
        FROM step_instances
        GROUP BY id
    ) si ON si.id = dv.step_instance_id
    WHERE dv._is_deleted = 0
    GROUP BY d.snapshot_date, si.protocol_instance_id
),
-- Step status pair as-of each day (latest history row at or before D), keyed to its enrollment.
step_asof AS (
    SELECT
        d.snapshot_date                                            AS snapshot_date,
        h.step_instance_id                                         AS step_instance_id,
        any(si.protocol_instance_id)                               AS protocol_instance_id,
        argMax(h.step_status, h.changed_at)                        AS step_status,
        argMax(h.sla_status, h.changed_at)                         AS sla_status
    FROM dates d
    INNER JOIN step_instance_history h FINAL
            ON toDate(h.changed_at) <= d.snapshot_date
    -- protocol_instance_id is no longer denormalized on the history row; recover it from
    -- the immutable base table. INNER JOIN: a hard-deleted (and purged) step drops out.
    INNER JOIN step_instances si FINAL
            ON si.id = h.step_instance_id
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
        toUInt32(count())                                                        AS step_total,
        toUInt32(countIf(s.step_status = 'COMPLETED'))                          AS step_completed,
        toUInt32(countIf(s.step_status = 'NOT_STARTED'))                        AS step_not_started,
        toUInt32(countIf(s.sla_status = 'MET'))                                 AS step_sla_met,
        toUInt32(countIf(s.sla_status = 'OVERDUE'))                             AS step_sla_overdue,
        toUInt32(countIf(s.sla_status = 'MISSED'))                              AS step_sla_missed,
        toUInt32(countIf(s.sla_status = ''))                                    AS step_sla_unjudged,
        toUInt32(countIf(s.step_status = 'COMPLETED' AND s.sla_status = 'MET')) AS step_completed_on_time,
        toUInt32(countIf(s.step_status = 'COMPLETED'
                         AND s.sla_status IN ('OVERDUE', 'MISSED')))            AS step_completed_late
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
    coalesce(sa.step_total,             0)   AS step_total,
    coalesce(sa.step_completed,         0)   AS step_completed,
    coalesce(sa.step_not_started,       0)   AS step_not_started,
    coalesce(sa.step_sla_met,           0)   AS step_sla_met,
    coalesce(sa.step_sla_overdue,       0)   AS step_sla_overdue,
    coalesce(sa.step_sla_missed,        0)   AS step_sla_missed,
    coalesce(sa.step_sla_unjudged,      0)   AS step_sla_unjudged,
    coalesce(sa.step_completed_on_time, 0)   AS step_completed_on_time,
    coalesce(sa.step_completed_late,    0)   AS step_completed_late
FROM enrollment_agg ea
LEFT JOIN patient_agg pa ON ea.snapshot_date = pa.snapshot_date AND ea.protocol_definition_id = pa.protocol_definition_id
LEFT JOIN step_agg    sa ON ea.snapshot_date = sa.snapshot_date AND ea.protocol_definition_id = sa.protocol_definition_id;


-- ============================================================
-- 2 & 3. mv_daily_facility_kpis / mv_daily_facility_activity_summary — REMOVED.
-- ============================================================
-- Both MVs were dropped (no live reader; the Facilities ranking and active-facility
-- tiles are computed live in the insights service). Nothing to backfill here.

-- ============================================================
-- 4. mv_daily_deviation_kpis — NO historical backfill needed.
-- ============================================================
-- Redesigned (schema/07) as a refreshable FULL-RECOMPUTE MV keyed on the deviation's CLINICAL
-- OCCURRENCE day (the breached SLA threshold or completed_at, all event_time-derived), not a now() snapshot
-- of detected_at-as-of-D. A re-snapshot restores the stored clinical dates and the MV rebuilds
-- every past day itself. After a re-snapshot just run:
--   SYSTEM REFRESH VIEW mv_daily_deviation_kpis_mv;
-- (The old detected_at as-of-D reconstruction is gone — it targeted removed columns and the wrong
--  model. A deviation belongs to one occurrence-day bucket, not "every day it was active".)


-- ============================================================
-- 5. mv_daily_event_kpis — NO historical backfill needed.
-- ============================================================
-- Redesigned (schema/07) as a refreshable FULL-RECOMPUTE MV keyed on the CLINICAL event_time day ×
-- facility (inbound_event_logs ⋈ matcher_event_logs by cloudevents_id; pipeline_loss is the
-- non-negative anti-join). Not a now()/received_at cumulative snapshot. A re-snapshot restores the
-- stored event_time + cloudevents_id and the MV rebuilds every past day itself:
--   SYSTEM REFRESH VIEW mv_daily_event_kpis_mv;
-- (The old cumulative as-of-D reconstruction is gone — it targeted removed rate columns, lacked the
--  facility dimension, and used the wrong received_at/cumulative model.)


-- ============================================================
-- 6. mv_daily_adoption_kpis — NO historical backfill needed.
-- ============================================================
-- Redesigned (schema/07) as a refreshable FULL-RECOMPUTE MV keyed on the CLINICAL event_time day
-- (patients who walked in that day), not toDate(received_at). A re-snapshot restores event_time
-- and the MV rebuilds every past day itself. After a re-snapshot just run:
--   SYSTEM REFRESH VIEW mv_daily_adoption_kpis_mv;
-- (The old received_at-based reconstruction is gone — it would have written data inconsistent with
--  the live event_time MV.)


-- ============================================================
-- 7. mv_daily_referral_kpis — NO historical backfill needed.
-- ============================================================
-- Refreshable FULL-RECOMPUTE MV (schema/07) keyed on the CLINICAL event_time day of accepted
-- referral events ("received by HIE": prod TRANSFER_ENCOUNTER Encounters + dev/demo referral-step
-- match fallback, deduped). A re-snapshot restores event_time + raw_payload + the join keys and the
-- MV rebuilds every past day itself:
--   SYSTEM REFRESH VIEW mv_daily_referral_kpis_mv;


-- ============================================================
-- RUN ORDER
-- ============================================================
-- Only section 1 still backfills (the now()-keyed compliance state snapshot). Sections 4, 5, 6, 7
-- self-heal via their schema/07 event_time refreshable MVs — nothing to run there. Sections 2 & 3
-- were removed (their MVs no longer exist). Section 1 is independent.
-- For very large windows, run section 1 in monthly date chunks (adjust from_date/to_date) to
-- bound the as-of join fan-out. Safe to re-run: ReplacingMergeTree(refreshed_at)
-- keeps the latest refreshed_at per key.
