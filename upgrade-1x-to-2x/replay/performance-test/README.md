# Replay performance test

Measures how long a replay takes, and how it scales with the number of events, by running the real
replay script (`../replay-inbound-events.sh`) the way the runbook's part A does. Re-run it after every
change to the replay script: each report compares with the previous run.

**Local only.** It adds synthetic events to `inbound_event_log` and rebuilds every derived table, so it
refuses to run unless the settings file's `DEPLOYMENT_NAME` starts with `local`.

| File | What |
|---|---|
| `replay-perf-test.sh` | seeds synthetic events, runs and times the replay, writes the reports |
| `suite-report.py` | the step-load report (used by `suite`) |
| `step_names.py` | what each step is called in the reports, what it does and what its time depends on |

## Before you start

- A local CCE 2.0 stack (Docker), running, with its data in Postgres.
- A replay settings file for it, e.g. a copy of `../replay-local.env` with `DEPLOYMENT_NAME=local-perf`
  and `SECRETS_FILE` pointing at the ClickHouse credentials.
- Free disk: roughly 5 GB per million events (Postgres, the replay's copy of the old tables, Kafka, ClickHouse).

```bash
P="bash upgrade-1x-to-2x/replay/performance-test/replay-perf-test.sh --config <your settings file>"
```

## The step-load test (the usual way)

```bash
$P suite --yes --sizes "10000 50000 100000 250000" --project "1000000 5000000"
```

For each size, smallest first, it tops `inbound_event_log` up to that size and runs a full rebuild
(A0–A11), timed. Then it writes `suite-<time>-report.md`:

- **Results per size:** every step's time, the first service's events/s, and the result checks (every
  event processed, DLQ empty, Postgres and ClickHouse equal). A size with a failed check is not a valid
  measurement.
- **How each step scales:** seconds per 1 000 events. Flat = linear; rising = the step slows down as
  the data grows (look there first); falling = a fixed cost spread over more events.
- **Fit and estimates:** total ≈ fixed part + part per event, with R², and the estimated total for the
  `--project` sizes. For this machine only; beyond about 4× the largest size run it's an extrapolation.
- **Where the time goes** at the largest size, and the busiest containers.

`--repeat 3` runs each size three times and shows the spread between runs: use it before comparing two
versions of the script, so a difference smaller than the spread isn't read as a change.

## One run

```bash
$P seed --events 50000 --yes      # tops inbound_event_log up to about 50 000 accepted events
$P run --yes                      # one timed full rebuild: perf-report-<time>.md
$P status                         # synthetic events, and a line per previous run
$P cleanup --yes                  # deletes the synthetic events (the next rebuild removes what they produced)
```

`run` options: `--keep-old-tables` (skip A11), `--keep-backup` (keep the run's backup file; by default
it's deleted after a successful run, since it's as big as the database).

## How the synthetic events are made

Each copy of the stored events is a new set of patients and ids: the patient id gets `-perf-<copy>`
everywhere in the payload, every UUID in it gets the same suffix (so references between resources still
match), the event id is set to the new id, and the received time moves by `<copy>` seconds. So every size
has the same mix of event types and protocols as the real data, and Matcher treats each copy as new
patients, never as duplicates.

## Where the results go

`~/cce-replay/<DEPLOYMENT_NAME>-perf/`: `perf-report-<time>.md` per run, `suite-<time>-report.md` per
step-load test, `history.tsv` (one line per run), and `run-<time>/` with every step's output
(`replay.log`), the resource samples (`samples.psv`) and the step times (`steps.tsv`).
