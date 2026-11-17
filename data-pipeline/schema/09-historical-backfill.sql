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
--   They cannot rebuild PAST snapshot_date rows. After a full ClickHouse re-snapshot (or to fill a
--   gap), this script reconstructs historical daily rows of mv_daily_compliance_kpis.
--   (Only section 1 backfills. The event_time MVs — deviation-page, event, adoption, referral —
--    self-heal on refresh, so this script does not touch them.)
--
-- HOW A PAST DAY IS RECONSTRUCTED: FROM THE ENTITIES' OWN CLINICAL AND DEADLINE TIMES
--   Each day D is worked out from timestamps that do not move with processing, on the base tables
--   (protocol_instances, step_instances, step_sla_state_transitions, deviations) — NOT from the
--   history tables. The history tables' changed_at and deviation.detected_at are when a row was
--   WRITTEN: after a replay, an offline device syncing a backlog, or a DLQ re-run they all carry the
--   processing day, and an as-of reconstruction on them shows every earlier day empty (0 steps,
--   0 deviations, 100 % compliance). The history stays what it is: an audit of changes.
--
--     enrolment counted       enrolled_at <= D (clinical); status as now, except that a non-ACTIVE
--                             status counts as ACTIVE until its updated_at day (2.0 never changes an
--                             enrolment's status; 1.x-migrated ones changed in 1.x)
--     step counted            from the day it was due or done: least(completed_at, due_date) <= D
--                             (created_at when it has neither). A step created ahead of time for a
--                             deadline after D is not counted on D, so past days' step_not_started
--                             reads a little low.
--     step_status             COMPLETED if completed_at <= D (clinical time), else NOT_STARTED
--     sla_status              the step's CURRENT verdict, from the day it was reached: MET from
--                             completed_at; OVERDUE from the due threshold; MISSED from the missed
--                             threshold (OVERDUE from the due threshold until then); unjudged before.
--                             So today's row equals the live view's, and past days follow the
--                             services' actual judgements.
--     deviation counted       from the day it occurred — the threshold it breached (OVERDUE: due,
--                             MISSED: missed, ORDER_VIOLATION: completed_at) — exactly as
--                             mv_daily_deviation_kpis in schema/07 dates it
--   Thresholds come from step_sla_state_transitions.process_by (DUE_DATE_REACHED /
--   MISSED_DATE_REACHED, written once), else the step's due_date.
--
-- IMPORTANT
--   * This aggregation MUST stay in lockstep with mv_daily_compliance_kpis in schema/07: the same
--     columns, meaning the same things. For D = today it gives the live view's row exactly
--     (checked on a copy of UAT, all 16 columns equal).
--   * Safe to re-run: ReplacingMergeTree(refreshed_at) keeps the latest refreshed_at per key.
--   * Section 0 refills the rollup_*_current tables (schema/06) that the live view (schema/07)
--     reads; section 1 writes the past days. Both run after the re-snapshot has settled.
-- ============================================================================

USE cce_analytics;

-- ============================================================
-- 0. rollup_*_current (schema/06) — refill from their source tables
-- ============================================================
-- The live mv_daily_compliance_kpis (schema/07) reads these current-state rollups. They are fed by
-- MVs on protocol_instances / step_instances / intelligence_deliveries, and after a rebuild into a
-- just-dropped database the snapshot has been seen to reach the source tables but NOT the rollups
-- (so the live daily view wrote no row from then on). Refill them from their sources with each
-- rollup MV's own SELECT. Idempotent: argMaxState keeps the highest _version per entity, so rows
-- the MVs did capture are not counted twice. Keep these SELECTs identical to schema/06's MVs.
INSERT INTO rollup_protocol_instance_current SELECT
    protocol_definition_id,
    id,
    argMaxState(patient_id,         _version) AS patient_id,
    argMaxState(status,             _version) AS status,
    argMaxState(enrolled_at,        _version) AS enrolled_at,
    argMaxState(_is_deleted, _version) AS is_deleted
FROM protocol_instances
GROUP BY protocol_definition_id, id;

INSERT INTO rollup_step_current SELECT
    protocol_instance_id,
    id,
    argMaxState(action_id,          _version) AS action_id,
    argMaxState(step_status,        _version) AS step_status,
    argMaxState(sla_status,         _version) AS sla_status,
    argMaxState(_is_deleted, _version) AS is_deleted
FROM step_instances
GROUP BY protocol_instance_id, id;

INSERT INTO rollup_delivery_current SELECT
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
-- 1. mv_daily_compliance_kpis  (per snapshot_date × protocol_definition_id)
-- ============================================================
INSERT INTO mv_daily_compliance_kpis
WITH
dates AS (
    SELECT toDate({from_date:Date}) + number AS snapshot_date
    FROM numbers(toUInt64(dateDiff('day', toDate({from_date:Date}), toDate({to_date:Date})) + 1))
),
-- Each step's deadline thresholds: the SLA transition rows (written once), else its due date.
thresholds AS (
    SELECT step_instance_id,
           minIfOrNull(process_by, transition_type = 'DUE_DATE_REACHED')    AS due_threshold,
           minIfOrNull(process_by, transition_type = 'MISSED_DATE_REACHED') AS missed_threshold
    FROM step_sla_state_transitions FINAL
    WHERE _is_deleted = 0
    GROUP BY step_instance_id
),
enrollments AS (
    SELECT id AS protocol_instance_id, protocol_definition_id, status, enrolled_at, updated_at
    FROM protocol_instances FINAL
    WHERE _is_deleted = 0
),
steps AS (
    SELECT s.id AS step_instance_id, s.protocol_instance_id, s.completed_at, s.sla_status,
           coalesce(t.due_threshold, s.due_date)                         AS due_at,
           coalesce(t.missed_threshold, t.due_threshold, s.due_date)     AS missed_at,
           -- counted from the day it was due or done (else from its creation)
           coalesce(least(coalesce(s.completed_at, toDateTime64('2999-12-31 00:00:00', 6)),
                          coalesce(s.due_date,     toDateTime64('2999-12-31 00:00:00', 6))),
                    s.created_at)                                        AS counted_from_raw,
           s.created_at
    FROM step_instances AS s FINAL
    LEFT JOIN thresholds AS t ON t.step_instance_id = s.id
    WHERE s._is_deleted = 0
),
steps_dated AS (
    SELECT *, if(counted_from_raw = toDateTime64('2999-12-31 00:00:00', 6), created_at, counted_from_raw) AS counted_from
    FROM steps
),
-- Each deviation's clinical occurrence: the threshold it breached (as mv_daily_deviation_kpis, schema/07).
deviations_dated AS (
    SELECT si.protocol_instance_id AS protocol_instance_id, d.deviation_type AS deviation_type,
           coalesce(multiIf(d.deviation_type = 'OVERDUE', t.due_threshold,
                            d.deviation_type = 'MISSED', t.missed_threshold,
                            d.deviation_type = 'ORDER_VIOLATION', si.completed_at,
                            CAST(NULL AS Nullable(DateTime64(6)))), si.due_date, d.detected_at) AS occurred_at
    FROM deviations AS d FINAL
    INNER JOIN step_instances AS si FINAL ON si.id = d.step_instance_id
    LEFT JOIN thresholds AS t ON t.step_instance_id = d.step_instance_id
    WHERE d._is_deleted = 0
),
enrollment_asof AS (
    SELECT d.snapshot_date, e.protocol_definition_id, e.protocol_instance_id,
           if(e.status != 'ACTIVE' AND toDate(e.updated_at) > d.snapshot_date, 'ACTIVE', e.status) AS status
    FROM dates d
    INNER JOIN enrollments e ON toDate(e.enrolled_at) <= d.snapshot_date
),
deviations_asof AS (
    SELECT d.snapshot_date, dv.protocol_instance_id,
           count()                                        AS deviation_count,
           countIf(dv.deviation_type = 'OVERDUE')         AS overdue_count,
           countIf(dv.deviation_type = 'MISSED')          AS missed_count,
           countIf(dv.deviation_type = 'ORDER_VIOLATION') AS order_violation_count
    FROM dates d
    INNER JOIN deviations_dated dv ON toDate(dv.occurred_at) <= d.snapshot_date
    GROUP BY d.snapshot_date, dv.protocol_instance_id
),
step_asof AS (
    SELECT d.snapshot_date, s.protocol_instance_id,
           if(s.completed_at IS NOT NULL AND toDate(s.completed_at) <= d.snapshot_date, 'COMPLETED', 'NOT_STARTED') AS step_status,
           -- the step's current verdict, from the day it was reached
           multiIf(ifNull(s.sla_status, '') = 'MET'     AND toDate(s.completed_at) <= d.snapshot_date, 'MET',
                   ifNull(s.sla_status, '') = 'MISSED'  AND toDate(s.missed_at)    <= d.snapshot_date, 'MISSED',
                   ifNull(s.sla_status, '') IN ('MISSED', 'OVERDUE') AND toDate(s.due_at) <= d.snapshot_date, 'OVERDUE',
                   '') AS sla_status
    FROM dates d
    INNER JOIN steps_dated s ON toDate(s.counted_from) <= d.snapshot_date
),
enrollment_agg AS (
    SELECT snapshot_date, protocol_definition_id,
           toUInt32(count()) AS total_enrollments,
           toUInt32(countIf(status = 'ACTIVE')) AS status_active, toUInt32(countIf(status = 'COMPLETED')) AS status_completed,
           toUInt32(countIf(status = 'WITHDRAWN')) AS status_withdrawn, toUInt32(countIf(status = 'EXPIRED')) AS status_expired
    FROM enrollment_asof GROUP BY snapshot_date, protocol_definition_id
),
patient_agg AS (
    SELECT e.snapshot_date AS snapshot_date, e.protocol_definition_id AS protocol_definition_id,
           toUInt32(count()) AS tracked_patients,
           toUInt32(countIf(coalesce(dv.deviation_count, 0) = 0)) AS compliant_count,
           toUInt32(countIf(coalesce(dv.deviation_count, 0) > 0)) AS non_compliant_count,
           toUInt32(sum(coalesce(dv.deviation_count, 0))) AS total_deviations,
           toUInt32(sum(coalesce(dv.overdue_count, 0))) AS overdue_deviations,
           toUInt32(sum(coalesce(dv.missed_count, 0))) AS missed_deviations,
           toUInt32(sum(coalesce(dv.order_violation_count, 0))) AS order_violation_deviations
    FROM enrollment_asof e
    LEFT JOIN deviations_asof dv ON dv.snapshot_date = e.snapshot_date AND dv.protocol_instance_id = e.protocol_instance_id
    GROUP BY e.snapshot_date, e.protocol_definition_id
),
step_agg AS (
    SELECT s.snapshot_date AS snapshot_date, e.protocol_definition_id AS protocol_definition_id,
           toUInt32(count()) AS step_total,
           toUInt32(countIf(s.step_status = 'COMPLETED')) AS step_completed,
           toUInt32(countIf(s.step_status = 'NOT_STARTED')) AS step_not_started,
           toUInt32(countIf(s.sla_status = 'MET')) AS step_sla_met,
           toUInt32(countIf(s.sla_status = 'OVERDUE')) AS step_sla_overdue,
           toUInt32(countIf(s.sla_status = 'MISSED')) AS step_sla_missed,
           toUInt32(countIf(s.sla_status = '')) AS step_sla_unjudged,
           toUInt32(countIf(s.step_status = 'COMPLETED' AND s.sla_status = 'MET')) AS step_completed_on_time,
           toUInt32(countIf(s.step_status = 'COMPLETED' AND s.sla_status IN ('OVERDUE', 'MISSED'))) AS step_completed_late
    FROM step_asof s
    INNER JOIN enrollment_asof e ON e.snapshot_date = s.snapshot_date AND e.protocol_instance_id = s.protocol_instance_id
    GROUP BY s.snapshot_date, e.protocol_definition_id
)
SELECT ea.snapshot_date AS snapshot_date, now64(3) AS refreshed_at, ea.protocol_definition_id AS protocol_definition_id,
       ea.total_enrollments, ea.status_active, ea.status_completed, ea.status_withdrawn, ea.status_expired,
       pa.tracked_patients, pa.compliant_count, pa.non_compliant_count,
       coalesce(toFloat32(round(pa.compliant_count / nullIf(pa.tracked_patients, 0) * 100, 1)), 0.0) AS compliance_rate_pct,
       pa.total_deviations, pa.overdue_deviations, pa.missed_deviations, pa.order_violation_deviations,
       coalesce(sa.step_total, 0) AS step_total, coalesce(sa.step_completed, 0) AS step_completed,
       coalesce(sa.step_not_started, 0) AS step_not_started, coalesce(sa.step_sla_met, 0) AS step_sla_met,
       coalesce(sa.step_sla_overdue, 0) AS step_sla_overdue, coalesce(sa.step_sla_missed, 0) AS step_sla_missed,
       coalesce(sa.step_sla_unjudged, 0) AS step_sla_unjudged, coalesce(sa.step_completed_on_time, 0) AS step_completed_on_time,
       coalesce(sa.step_completed_late, 0) AS step_completed_late
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
-- Section 0 refills the current-state rollups; section 1 backfills the now()-keyed compliance state
-- snapshot. Sections 4, 5, 6, 7
-- self-heal via their schema/07 event_time refreshable MVs — nothing to run there. Sections 2 & 3
-- were removed (their MVs no longer exist). Section 1 is independent.
-- For very large windows, run section 1 in monthly date chunks (adjust from_date/to_date) to
-- bound the as-of join fan-out. Safe to re-run: ReplacingMergeTree(refreshed_at)
-- keeps the latest refreshed_at per key.
