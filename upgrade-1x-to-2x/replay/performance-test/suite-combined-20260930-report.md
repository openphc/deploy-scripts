# Replay step-load test: local-perf

The same full rebuild (runbook part A, A0–A11) at 5 size(s). The synthetic events are copies of
the stored ones, each copy a new set of patients and ids, so every size has the same mix of event types.

## The steps

Each step of the replay, in the order it runs. The runbook step code is in brackets.

| Step | What it does | Its time depends on |
|---|---|---|
| Check access (A0) | Confirms the script can reach Postgres, Kafka, Kafka Connect, ClickHouse and every service. Changes nothing. | fixed: a few seconds |
| Plan (dry run) (A2) | Counts the events to replay and lists the tables, topics and services it will touch. Changes nothing. | fixed: a few seconds |
| Back up the database (A3) | Dumps the whole CCE database to a file: the restore point if the replay is undone. | the database size |
| Prepare empty tables (A4) | Stops Matcher, Step SLA and intelligence; moves the tables they build aside; starts each service once so its migrations create the tables again, empty; puts protocol definitions and facilities back; empties the services' output topics. | mostly fixed: starting and stopping each service (1-2 minutes in total) |
| Re-send stored events to the inbound topic (A5) | Takes the cutoff, empties cce.events.inbound up to it, sends every accepted event from inbound_event_log back onto it, oldest first, sets Matcher to read it from the start and starts Matcher. | the number of events (sending is fast), plus a fixed setup |
| Matcher re-processes the events (A6) | Matcher reads every replayed event and rebuilds enrolments, steps and deadlines. Ends once Matcher has had nothing left to read for one minute. | the number of events: the main cost per event; plus that one-minute check |
| Start Step SLA and intelligence (A7) | Throws away what the replayed events produced for the other services (so no alert is sent again), then starts Step SLA and intelligence. | fixed: a few seconds |
| Step SLA judges every past deadline (A7+) | Step SLA's first run: every deadline already past gets its verdict (met, overdue, missed) and any deviation. Timed until no deadline is left to judge. | the number of steps with a deadline |
| Rebuild the Insights data (ClickHouse) (A8) | Stops Insights, drops its ClickHouse database, applies the schema again, copies all Postgres data across again (a fresh CDC snapshot), fills in the past daily figures, starts Insights. | mostly fixed (schema, connector, a 45-second settle check), plus the rows to copy |
| Verify the result (A9) | Checks every event was processed, nothing is in the dead-letter topic, and Postgres and ClickHouse hold the same steps. | fixed: a few seconds |
| Write the before/after report (A10) | Writes the comparison of the numbers before and after the replay. | fixed: a few seconds |
| Delete the old tables (A11) | Deletes the tables set aside in 'Prepare empty tables' (after this the replay can't be undone from them). | the size of the old tables |

## Results per size

Total and each step in h:mm:ss. Steps not shown (check, plan, backup, verify, report, delete the old
tables) take a few seconds each.

| Events | Run | Total | Prepare empty tables (A4) | Re-send stored events to the inbound topic (A5) | Matcher re-processes the events (A6) | Step SLA judges every past deadline (A7+) | Rebuild the Insights data (ClickHouse) (A8) | Matcher events/s | Checks |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 18,670 | 1 | 0:05:59 | 0:01:29 | 0:00:13 | 0:01:26 | 0:00:10 | 0:02:02 | 566 | OK |
| 52,276 | 1 | 0:06:54 | 0:01:27 | 0:00:13 | 0:01:59 | 0:00:30 | 0:02:04 | 792 | OK |
| 100,818 | 1 | 0:07:36 | 0:01:24 | 0:00:13 | 0:02:33 | 0:00:41 | 0:02:04 | 1,018 | OK |
| 250,178 | 1 | 0:10:46 | 0:01:25 | 0:00:14 | 0:04:45 | 0:01:31 | 0:02:04 | 1,083 | OK |
| 1,000,712 | 1 | 0:27:14 | 0:01:28 | 0:00:20 | 0:15:03 | 0:05:53 | 0:03:17 | 1,177 | OK |

## How each step scales (seconds per 1 000 events)

**This table is not the time each step took** (that is the table above). It divides each step's time
by the number of events, in thousands, to show whether a step costs the same per event at every size.

**How a number is calculated:** the step's time in seconds ÷ (events ÷ 1 000).
For example, Prepare empty tables (A4) took 89 s at 18,670 events: 89 ÷ 18.67 = **4.78**. At 1,000,712 events it took 88 s: 88 ÷ 1,000.71 = **0.09**. About the same time both runs, so the cost per event falls as the same time is shared by 54× more events.

**How to read a row:**

- **falling** (high at the left, low at the right): a fixed cost, about the same time at every size,
  such as starting the services or a one-minute check. It matters for small runs only;
- **flat**: real work per event; the step's time grows in step with the data (linear);
- **rising**: the step slows down as the data grows; look there first.

**The last row, whole replay,** does the same with the total time of the run (every step, including
the short ones not listed here, so it is more than the rows above added up): 359 s ÷ 18.67 = **19.24** at 18,670 events, 1,634 s ÷ 1,000.71 = **1.63** at 1,000,712. A higher number does not mean a slower run: the 18,670-event run took 0:05:59 in all, the 1,000,712-event run 0:27:14.

| Step | 18,670 | 52,276 | 100,818 | 250,178 | 1,000,712 |
|---|---:|---:|---:|---:|---:|
| Prepare empty tables (A4) | 4.78 | 1.67 | 0.83 | 0.34 | 0.09 |
| Re-send stored events to the inbound topic (A5) | 0.67 | 0.25 | 0.13 | 0.06 | 0.02 |
| Matcher re-processes the events (A6) | 4.62 | 2.28 | 1.51 | 1.14 | 0.90 |
| Step SLA judges every past deadline (A7+) | 0.55 | 0.58 | 0.40 | 0.36 | 0.35 |
| Rebuild the Insights data (ClickHouse) (A8) | 6.52 | 2.37 | 1.23 | 0.50 | 0.20 |
| **whole replay** (total time ÷ events) | 19.24 | 7.92 | 4.53 | 2.58 | 1.63 |

Total time of each run, for comparison (h:mm:ss): 18,670 events 0:05:59, 52,276 events 0:06:54, 100,818 events 0:07:36, 250,178 events 0:10:46, 1,000,712 events 0:27:14.

## Fit and estimates

Total time ≈ **0:05:33 fixed + 1.30 s per 1 000 events** (R² = 1.000: close
to 1 means the line describes the runs well; well below 1 means the replay does not grow linearly, and
the estimates below are rough).

| Events | Estimated total |
|---:|---:|
| 1,000,000 | 0:27:10 |
| 4,000,000 | 1:32:02 |
| 5,000,000 | 1:53:39 |
| 10,000,000 | 3:41:45 |

For this machine only. Beyond about 4× the largest size run it is an extrapolation: run the suite with
a size near the target to be sure.

## Where the time goes at 1,000,712 events

| Step | Time | Share |
|---|---:|---:|
| Matcher re-processes the events (A6) | 0:15:03 | 55 % |
| Step SLA judges every past deadline (A7+) | 0:05:53 | 22 % |
| Rebuild the Insights data (ClickHouse) (A8) | 0:03:17 | 12 % |
| Prepare empty tables (A4) | 0:01:28 | 5 % |
| Write the before/after report (A10) | 0:00:22 | 1 % |
| Re-send stored events to the inbound topic (A5) | 0:00:20 | 1 % |
| Start Step SLA and intelligence (A7) | 0:00:14 | 1 % |
| Verify the result (A9) | 0:00:13 | 1 % |
| Back up the database (A3) | 0:00:11 | 1 % |
| Check access (A0) | 0:00:06 | 0 % |
| Plan (dry run) (A2) | 0:00:06 | 0 % |

Busiest containers (CPU peak, 100 % = one core): cce-clickhouse 634 % (6.1 GB), cce-matcher-service 536 % (935.7 MB), cce-step-sla-service 462 % (633.2 MB), cce-collector-kafka 306 % (1.1 GB).

Per-run reports: `perf-report-20260930_164142.md`, `perf-report-20260930_164744.md`, `perf-report-20260930_165444.md`, `perf-report-20260930_170959.md`, `perf-report-20260930_172150.md`, in `/home/shashankakkasali/cce-replay/local-perf-perf`.
