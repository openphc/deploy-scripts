# Upgrading CCE 1.x → 2.0

There are two ways to upgrade a 1.x deployment's data to 2.0. Use the **replay** one (see "Which one").

| Folder | Way | How |
|---|---|---|
| `replay/` | **Replay** (recommended) | 1.x's tables are set aside and every accepted event in `inbound_event_log` is processed again by the 2.0 services. Runbook: `replay/REPLAY-RUNBOOK.md`, part U |
| `data-migration/` | **Database migration** | the 1.x tables are reshaped in place by the 2.0 services' Flyway migrations (baseline 1). Tested on a copy only. Runbook: `data-migration/MIGRATION-TEST-RUNBOOK.md` |

## `replay/`

| File | What |
|---|---|
| `replay-inbound-events.sh` | the replay, one step per command |
| `REPLAY-RUNBOOK.md` | the runbook (part U: the 1.x → 2.0 upgrade) |
| `replay.env` | settings template, every setting explained |
| `replay-local.env` | example: a plain replay on a laptop copy of UAT (1.x) |
| `replay-local-upgrade.env` | example: the 1.x → 2.0 upgrade on a laptop copy of UAT |
| `replay-uat-upgrade.env` | settings: the 1.x → 2.0 upgrade of Rwanda UAT (Kubernetes, infra in Docker) |
| `replay-prod-upgrade.env` | settings: the 1.x → 2.0 upgrade of Rwanda prod (Kubernetes, infra installed on the server) |
| `performance-test/` | performance test: times a full rebuild at increasing sizes on a local copy (see `performance-test/README.md`); `suite-combined-20260930-report.md` is the 30 Sep run, 18k–1M events |

## `data-migration/`

| File | What |
|---|---|
| `migrate-1x-to-2x.sh` | the migration, one step per command |
| `MIGRATION-TEST-RUNBOOK.md` | the test runbook |
| `migration-local.env` | example settings (laptop, Docker Compose) |
| `docker-compose.baseline-1.yml` | Flyway baseline 1 on Protocol and Matcher, added after your compose files |

Both use the 2.0 data-pipeline in `data-pipeline/` at the deploy-scripts root to rebuild ClickHouse.

## Which one

Both were tested on a copy of Rwanda UAT (3,733 events). Use the **replay**:

- it processes every accepted event, including any 1.x never processed (on UAT, 618 events, 48 patients);
  the migration leaves those out;
- every enrolment, step and deviation is computed by 2.0's rules; the migration keeps 1.x's rows
  (duplicate enrolments included) and gives optional steps a deadline verdict 2.0 doesn't;
- it needs no data fixes first; the migration needs three (`fix-orphans`, `fix-history-ids`, `copy-offsets`);
- until its last step the 1.x tables are kept aside, so it can be undone; the migration changes the
  tables in place (the way back is the backup).

Expect the dashboard numbers to change after a replay: 2.0 judges every deadline again.
