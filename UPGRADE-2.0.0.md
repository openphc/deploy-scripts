# Upgrading dev from CCE 1.x to 2.0.0

CCE 2.0.0 splits the 1.x `cce-compliance-service` into **Protocol**, **Matcher** and **Step SLA**
services and retires `cce-scheduler-service`. `ccedb` changes shape with it (`compliance_event_log` →
`matcher_event_log`, `step_instance.state` → `step_status` + `sla_status`, deadlines move to the new
`step_sla_state_transition`), and ClickHouse follows.

> **Dev (`13.206.132.44`) was upgraded on 2026-09-25** following this plan. Every correction found on
> the day is folded into the steps below; open follow-ups are under **Known issues after 2.0.0**.

The compose file here is the 2.0.0 end state. What cannot be automated is the **one-time cutover** of
an existing 1.x database, below. After it, deploys are the usual service-pipeline → `deploy.yml` flow.

| Repo | Branch |
|---|---|
| cce-collector-service, cce-matcher-service, cce-step-sla-service, cce-protocol-service, cce-common-util | `release-2.0.0` |
| cce-insights-service, cce-insights-ui | `demo-dev` |
| cce-data-pipeline (copied into `data-pipeline/` here) | `demo-v2` |
| deploy-scripts | `main` |

## How deploys are triggered — why the order below matters

`deploy.yml` (and every other deploy-scripts workflow) is `workflow_dispatch` only: **merging to
deploy-scripts deploys nothing by itself**. It runs when a service build succeeds after a **push** to
that service's release branch (`demo-dev` for the two insights repos), and it deploys deploy-scripts
`main` with rsync + `compose pull` + `up -d --remove-orphans` — only containers whose image changed
are recreated.

That gives two periods with different rules:

- **Phase A (before the window) — pushes are fine, except insights.** `main` is still the 1.x compose.
  Protocol, Matcher and Step SLA are not in it, so the deploy their build triggers starts nothing.
  The 2.0.0 collector *is* in it and gets swapped in — which is safe: it publishes the same
  `cce.events.inbound` topic and message the 1.x compliance service consumes, and has the same two
  `inbound_event_log` migrations. The two insights repos must **not** be pushed: their 2.0.0 builds
  cannot query the 1.x ClickHouse.
- **Phase B (the window) — push freeze** on every service `release-2.0.0` branch, the collector's
  `release-1.0.0` branch and insights `demo-dev`, from step 9 until the insights merges in steps
  20–21. From step 11 the host holds the 2.0.0 compose (synced by hand) while `main` is still 1.x, so
  any deploy would rsync the 1.x compose back, start Protocol / Matcher with
  `CCE_FLYWAY_BASELINE_VERSION=0` (they fail on the existing tables and leave a version-0 baseline row
  to repair by hand) or start Step SLA before Matcher has drained (permanent false deviations).

## Phase A — Preparation (no downtime)

1. **cce-common-util first.** Push `release-2.0.0`. It is a library — no image, no deploy — but every
   service build checks out the `cce-common-util` branch of the same name (falling back to `main`), so
   it must be in place before the service builds below.
2. **Protocol image.** Merge `BuildAndPushGHCR.yml` into `cce-protocol-service` `release-2.0.0` and
   confirm `ghcr.io/openphc/cce-protocol-service:latest` exists. The deploy it triggers starts nothing.
3. **Matcher / Step SLA images.** Push (or re-run the workflow for) `cce-matcher-service` and
   `cce-step-sla-service` `release-2.0.0`, and confirm both `:latest` images are current. Their deploys
   start nothing. Push one repo at a time so deploy runs do not overlap, and note every `vN` tag.
4. **2.0.0 collector.** Before merging, note the collector's current `vN` tag (its rollback) and confirm
   the host `.env` has `CCE_COLLECTOR_SERVICE_IMAGE=ghcr.io/openphc/cce-collector-service:latest`
   (a pinned `vN` would keep the 1.x build). Merge the collector workflow PR into `release-2.0.0`; its
   deploy swaps in the 2.0.0 collector alongside the 1.x compliance service. Then send one Tiberbu
   test event — it must be accepted and `MATCHED` in `compliance_event_log`. From now on **do not push
   the collector's `release-1.0.0`**: its workflow also pushes `:latest` and would bring 1.x back.
   (1.x compose still sets `CCE_COLLECTOR_KAFKA_TOPICS_INBOUND`, which 2.0.0 ignores; its own
   `CCE_KAFKA_TOPICS_INBOUND_EVENTS` defaults to the same `cce.events.inbound`.)
5. **Open, don't merge:** the deploy-scripts PR → `main`, and the two insights 2.0.0 PRs → `demo-dev`
   (`cce-insights-service`, `cce-insights-ui`). Get them reviewed and green. Note the **current** `vN`
   tags of `ghcr.io/openphc/cce-insights-service` and `ghcr.io/openphc/cce-insights-ui` (the 1.x
   builds on dev) — they are the insights rollback.
6. **Rollback point.** Tag the current deploy-scripts `main` as `pre-2.0.0` (or note its commit SHA —
   the tag is only needed to roll back by running `deploy.yml`, which cannot target a bare SHA).
7. **Rehearse (strongly recommended).** Run `rehearse-2.0.0.sh` with `precheck-2.0.0.sh`, `verify.sql`
   and the Protocol / Matcher `db/migration/*.sql` from their `release-2.0.0` repos beside it — on the
   dev host, or on a laptop against a downloaded dump (`DUMP_FILE=<dump> bash rehearse-2.0.0.sh`). It
   restores `ccedb` into a throwaway Postgres container, runs V2's refusal checks, applies Protocol then
   Matcher migrations with the dev Flyway settings, and runs `verify.sql`. The dump holds patient data —
   delete it afterwards. Two `verify.sql` checks are stale against the current migrations and can be
   ignored: check 2 (`step_instance.due_date` — V2 keeps it) and check 11
   (`idx_step_instance_matched_event` — V2 drops it).
   Rehearsed 2026-09-25 against a dev dump: all refusal checks clean, all 5 protocols already use
   `after-*` `relatedAction`, Protocol V2 and Matcher V2–V6 succeed.
   The rehearsal runs the **migrations only**, not the services — it cannot catch start-up problems such
   as the Protocol / Matcher ordering in step 13.
8. **Heads-up.** Warn whoever watches compliance and deviations, then announce the window and the push
   freeze:
   - **First Step SLA sweep:** `verify.sql` check 8 — 2,361 deadlines already past on the rehearsal
     dump — become OVERDUE / MISSED verdicts and deviations in one burst when Step SLA starts (step 16).
   - **~10,100 completed steps turn "completed late"** (mostly `registration`). V2 judges a completed
     step on time only if `completed_at < due_date`, and on dev the two were written microseconds
     apart. No deviations are created and patient compliance is unaffected, but the Compliance
     *Overdue* tile, the *Late* split and patient-journey LATE badges jump. **Open decision:** fix in
     matcher V2 upstream (then re-rehearse), correct with a one-off `UPDATE` after step 14, or accept.
   - The Kenya insights dashboard is unavailable from the ClickHouse rebuild (step 18) until the
     insights merges (steps 20–21).

## Phase B — Cutover window

On the dev host, `cd /opt/deployment`. Push freeze from here until step 21 (see above).

9. **Stop the 1.x writers.** `docker compose stop cce-compliance-service cce-scheduler-service`.
   Both must be down: two versions writing `step_instance` across the rename will corrupt it, and the
   scheduler cannot run against the 2.0.0 schema. The collector (2.0.0 since step 4) keeps running —
   inbound events queue on `cce.events.inbound` for Matcher (none of Matcher's migrations touch
   `inbound_event_log`).
10. **Back up.**
    `docker exec cce-postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d ccedb -Fc' > ~/ccedb_pre_2.0.0_$(date +%Y%m%d).dump`
    — with the writers stopped, row counts must now match live exactly.
    Then re-run `bash precheck-2.0.0.sh` against live (read-only, seconds). Data has grown since the
    rehearsal, so this confirms no row V2 refuses has appeared since: checks 1–3 must still read
    `none` / `0` / `0`. If not, fix those rows (or roll back) before step 13.
    The migration's "monolith V9 or later" precondition does not apply to dev: dev ran
    `cce-compliance-service` `release-1.0.0`, whose ledger ends at V7. What that V9 guaranteed is the
    `relatedAction` direction 2.0.0 reads — each step naming what it waits on (`after-*`) —
    `precheck-2.0.0.sh` check 4 lists it per protocol, and the rehearsal confirmed it.
11. **Sync files to the host** from the **unmerged** deploy-scripts PR branch. Copy **only files git
    tracks** — a local working copy usually has its own `.env`, and a plain `rsync ./` would overwrite the
    host's real one (the workflow never hits this: its checkout has no `.env`):
    ```bash
    git ls-files -co --exclude-standard | grep -vE '^\.github/|^\.gitignore$' > /tmp/ds-files.txt
    rsync -avnc --files-from=/tmp/ds-files.txt ./ <host>:/opt/deployment/   # dry run: only 2.0.0 files may differ
    rsync -ac   --files-from=/tmp/ds-files.txt ./ <host>:/opt/deployment/
    ```
12. **Edit the host `.env`:**
    ```bash
    CCE_PROTOCOL_SERVICE_IMAGE=ghcr.io/openphc/cce-protocol-service:latest
    CCE_MATCHER_SERVICE_IMAGE=ghcr.io/openphc/cce-matcher-service:latest
    CCE_STEP_SLA_SERVICE_IMAGE=ghcr.io/openphc/cce-step-sla-service:latest
    CCE_FLYWAY_BASELINE_VERSION=1        # this cutover ONLY
    ```
    Back the file up first (`cp -p .env ~/env_pre_2.0.0.bak`). The host `.env` cannot be `source`d by a
    shell (a gateway regex value breaks it) — read single keys with `grep`.
    Also confirm `CCE_INSIGHTS_SERVICE_IMAGE` / `CCE_INSIGHTS_UI_IMAGE` point at
    `ghcr.io/openphc/cce-insights-service:latest` / `ghcr.io/openphc/cce-insights-ui:latest` — a pinned
    `vN` would keep the 1.x insights build running after steps 20–21.
13. **Migrate `ccedb`** — Protocol first, then Matcher; not Step SLA. Start them one at a time with
    `--no-deps` (so compose does not also recreate Postgres or Kafka):
    ```bash
    docker compose pull cce-protocol-service cce-matcher-service cce-step-sla-service
    docker compose up -d --no-deps cce-protocol-service
    docker compose logs cce-protocol-service | grep -E 'Successfully (baselined|applied)'   # V2 applied
    docker compose stop cce-protocol-service
    docker compose up -d --no-deps cce-matcher-service      # wait for "Started MatcherServiceApplication"
    docker compose up -d --no-deps cce-protocol-service     # now starts healthy
    ```
    **Why this order:** Protocol's migration succeeds, but the application then fails to start
    (Hibernate: `protocol_instance_history_id_seq` increment 50 expected) until **Matcher's V6** has
    changed the sequence. Protocol's V2 is all Matcher's V2 needs, so starting Matcher next is safe.
    Compose now makes Matcher wait only for Protocol to be *started* (not healthy), so a plain
    `docker compose up -d cce-protocol-service cce-matcher-service` also converges — Protocol restarts
    until V6 is in — but the explicit sequence above is the one proven on dev.
14. **Verify.** `flyway_schema_history_protocol` shows V2 and `flyway_schema_history_matcher` V2–V6,
    all `success`; then run `verify.sql` (checks 2 and 11 are stale — see step 7).
    Compose sets two Flyway overrides on Matcher that this step depends on: `baseline-on-migrate`
    (the `prod` profile turns it off, which would fail the baseline at 1) and
    `postgresql.transactional-lock=false` (without it V5's `CREATE INDEX CONCURRENTLY` waits on
    Flyway's own lock and Matcher hangs at V5). If Matcher is ever stopped mid-V5, drop the INVALID
    `idx_sslt_due_order` before retrying — `IF NOT EXISTS` would otherwise keep the broken index.
    > `migration/run-upgrade.sh` (the one-transaction DBA option) is not used: on current
    > `release-2.0.0` its copy `02-matcher-upgrade-from-monolith.sql` already folds in V3/V4, so its own
    > drift check against `V2__upgrade_from_monolith_schema.sql` aborts. The services' Flyway chain is
    > the authoritative path.
15. **Reset the baseline.** Set `CCE_FLYWAY_BASELINE_VERSION=0` in `.env` **now** — the automatic deploy
    in step 20 reads it, and left at 1 a future fresh deployment would skip V1.
16. **Skip Matcher's replay, then start Step SLA.** Matcher's consumer group is new
    (`auto-offset-reset: earliest`), so it starts replaying everything `cce.events.inbound` retains —
    events the 1.x compliance service already processed. Because of the Matcher duplicate bug (see
    **Known issues**) each of those fails, is retried with back-off and lands in
    `cce.events.inbound.dlq`: on dev that was a few events a minute, **hours** for one busy partition.
    Instead, start Matcher from exactly where compliance stopped — no event is skipped, because the
    stopped compliance group's committed offsets are the processed-up-to point:
    ```bash
    K="docker exec kafka kafka-consumer-groups --bootstrap-server kafka:9092"
    $K --describe --group cce-compliance-service > ~/cutover/compliance-offsets.txt   # LAG should be 0
    $K --describe --group cce-matcher-service    > ~/cutover/matcher-offsets-before.txt
    awk '/cce.events.inbound /{print $2","$3","$4}' ~/cutover/compliance-offsets.txt > ~/cutover/matcher-target.csv
    docker compose stop cce-matcher-service                  # the group must be idle to move its offsets
    docker cp ~/cutover/matcher-target.csv kafka:/tmp/matcher-target.csv
    $K --group cce-matcher-service --reset-offsets --from-file /tmp/matcher-target.csv --dry-run
    $K --group cce-matcher-service --reset-offsets --from-file /tmp/matcher-target.csv --execute
    docker compose up -d --no-deps cce-matcher-service
    $K --describe --group cce-matcher-service                # LAG 0 (or a few new events), held a few minutes
    docker compose up -d --no-deps cce-step-sla-service
    ```
    Step SLA must not start before this — it would record OVERDUE / MISSED against steps whose completing
    event is still queued, and it never revises a verdict. Its first sweep then judges every deadline
    already past (dev: 2,376 deviations in about a minute; `verify.sql` check 8 predicts it).
17. **Gateway.** `docker compose up -d --no-deps gateway-service` — picks up the `/v1/protocol/**` route (the 1.x
    `/v1/compliance/**` PlanDefinition / ActionDefinition API moved to Protocol) and re-resolves backend
    container IPs. A request without a token answers `500` ("Invalid Authorization header") — that is
    the gateway's existing behaviour, not a routing failure; `/v1/compliance/**` now answers "No static
    resource".
18. **Rebuild ClickHouse** — no in-place upgrade; `cce_analytics` is derived from `ccedb`. From
    `/opt/deployment/data-pipeline` with its `.env` sourced (`set -a; source .env; set +a`):
    1. Stop the connector, reset its stored offsets, delete it, then drop the (now inactive) slot —
       otherwise a re-registered connector resumes from old offsets instead of snapshotting:
       ```bash
       C="docker exec cce-kafka-connect curl -s"; U=http://localhost:8083/connectors/cce-ccedb-source
       $C -X PUT $U/stop; $C -X DELETE $U/offsets; $C -X DELETE $U
       # in psql on ccedb:  SELECT pg_drop_replication_slot('cce_analytics_slot');
       ```
    2. `DROP DATABASE cce_analytics SYNC` in ClickHouse.
    3. Re-run `cdc/01-configure-replication.sql` on Postgres (15 tables, incl. `matcher_event_log` and
       `step_sla_state_transition`). It is safe on an existing setup: the CDC role is only created if
       missing, so its password is untouched. Check `pg_publication_tables` lists 15 tables.
       (`scripts/validate-cdc-config.sh` runs `psql` on the host and just waits at a password prompt —
       run its checks inside the Postgres container instead.)
    4. Apply the schema (08 before 07):
       ```bash
       CH_HTTP=http://localhost:8123 python3 scripts/apply-schema.py schema \
         01-create-tables 02-kafka-ingestion 03-create-materialized-views 04-create-indexes \
         05-create-dictionary 06-current-state-rollups 08-reference-tables 07-daily-summary-aggregates
       ```
    5. `scripts/register-connectors.sh` — Debezium takes a full initial snapshot of the upgraded `ccedb`.
       The connector JSON uses `POSTGRES_*` placeholders; dev's `data-pipeline/.env` defines `CDC_*`
       (the main `.env`'s `POSTGRES_READ_ONLY_USER` does not exist in Postgres). The script now falls
       back to the `CDC_*` names and refuses to run with a blank credential:
       ```bash
       set -a; . ./.env; set +a; bash scripts/register-connectors.sh
       ```
       Done when the connector's consumer groups (`clickhouse_*`) show lag 0 and table counts match
       Postgres. The event-log tables keep only **90 days** (`04-create-indexes.sql` TTL — unchanged from
       1.x): ClickHouse briefly holds everything, then background merges drop older rows. Compare those
       two tables with Postgres over the last 90 days only.
19. **Merge the deploy-scripts PR into `main`.** Nothing deploys — deploy-scripts workflows are
    manual-only. `main` now matches what is already on the host.
20. **Merge the insights-service PR into `demo-dev` — the convergence deploy.** Its build pushes the
    2.0.0 `cce-insights-service:latest` and triggers `deploy.yml` on `main`: `compose pull` +
    `up -d --remove-orphans` swaps in the 2.0.0 insights service and removes the stopped
    `cce-compliance-service` / `cce-scheduler-service` containers; everything else is already current.
    It reads the rebuilt ClickHouse from step 18 — `matcher_event_logs`, `step_status` / `sla_status`,
    `step_sla_state_transitions`. Wait for the deploy to finish, then check `/actuator/health` on
    `cce-insights-service` and that `GET /v1/insights/dashboard/compliance-summary` through the gateway
    returns 200.
21. **Merge the insights-ui PR into `demo-dev`** — after the service, since the 2.0.0 UI reads the new
    `stepStatus` / `slaStatus` fields. Its build and `deploy.yml` swap in the 2.0.0 UI. (On dev all three
    PRs were merged together; the builds landed in the right order.) A browser that visited before keeps
    the **cached 1.x UI** — Compliance then shows Due / Pending tiles reading 0. A hard refresh
    (Ctrl+Shift+R) loads the new one.

    The deploy also recreates any container whose `:latest` changed and, because `postgres:16` is a
    floating tag, can restart Postgres when a new 16.x image is out (harmless on dev: data is on the
    `postgres_data` volume and CDC reconnects).

## Phase C — Verify and clean up

22. `/actuator/health` UP on Protocol (host 8094), Matcher (8101), Step SLA (8098) and the collector;
    all three new Prometheus targets up.
23. End to end: send one test event through Tiberbu → a `MATCHED` row in `matcher_event_log`, the
    patient's step advances, and the event appears in ClickHouse `matcher_event_logs`.
24. `scripts/validate-clickhouse.sh` and `scripts/data-quality-checks.sh` — Postgres and ClickHouse
    counts agree.
25. Insights UI: Dashboard (incl. Tiberbu Consent Metrics), Compliance (Transactions tiles show
    Not Started / Not Yet Judged), Patients → a patient's journey and protocol tracking, Deviations and
    Non-Compliant Hotspots all load without errors, and the numbers reflect the step 23 test event.
26. After a stable period: delete the 1.x topics `cce.public.compliance_event_log` and
    `cce.scheduler.triggers`, and the consumer groups `cce-compliance-service` / `cce-scheduler-service`.
    Lift the push freeze.

## Known issues after 2.0.0 (found on dev, 2026-09-25)

| # | Where | Issue | Effect | Fix |
|---|---|---|---|---|
| 1 | cce-matcher-service `MatcherEngine` | On a duplicate event it calls `recordEvent(..., DUPLICATE)`, re-inserting the same `(cloudevents_id, source)` → unique-key error → retries → DLQ | Every resent event (Tiberbu resends bundles; same deterministic id) is retried and dead-lettered; slows the partition. No data loss | Record the duplicate without a second insert (or skip recording) |
| 2 | cce-matcher-service `StepSlaScheduleService:126`, cce-step-sla-service `SlaTransitionApplier:272/310`, matcher V2 | On time only if `completedAt < dueDate` (strict) | A step completed at its due instant is judged late; the V2 migration marked ~10,100 steps completed microseconds after due as OVERDUE (mostly `registration`). Deviations unaffected; *Late* / *Overdue* step counts and LATE badges inflated | Use `<=` (not after) at runtime; decide a correction for migrated rows |
| 3 | cce-protocol-service / cce-common-util | Protocol's Hibernate needs `protocol_instance_history_id_seq` to step by 50, which only Matcher's V6 sets; compose started Matcher only after Protocol was healthy | Start-up deadlock on an upgraded database (and likely on a fresh one) | **Fixed in compose:** Matcher now waits for Protocol `service_started` |
| 4 | data-pipeline `register-connectors.sh` / connector JSON | Placeholders are `POSTGRES_*`, dev's pipeline `.env` has `CDC_*` | Registration failed with blank credentials | **Fixed:** the script falls back to `CDC_*` and refuses blank values (also worth upstreaming to cce-data-pipeline) |
| 5 | docker-compose health checks | `wget` checks on gateway, intelligence, insights-service and openmrs-cce-receiver-adaptor, whose buildpack images have no shell or `wget` | They read `unhealthy` forever; nothing depends on them | **Fixed:** those four checks disabled (use `/actuator/health`) |
| 6 | docker-compose `postgres:16` | Floating tag | Any automatic deploy could restart Postgres | **Fixed:** pinned to `postgres:16.15` (same digest dev runs; the deploy that applies it recreates Postgres once) |
| 7 | Source data (SPICE emitter) | `Encounter.subject` sent as `Group/<id>` | 342 "patients" `Group/…`; their detail page returned 400 (Tomcat rejects `%2F` in the path — same before 2.0.0) | **Fixed in insights-service** (`TomcatConfig` passes `%2F` through). The source still sends group ids — emit the patient id and clean up the 342 enrolments |

## Rollback

- **Phase A:** nothing needs undoing except the collector, and the 2.0.0 collector works with 1.x. To
  go back anyway, set `CCE_COLLECTOR_SERVICE_IMAGE` to the `vN` noted in step 4 and
  `docker compose up -d cce-collector-service`.
- **Phase B, up to step 20:** restore the dump from step 10, rsync the `pre-2.0.0` tag (or noted SHA)
  to the host (or run `deploy.yml` on the tag), and re-run step 18 with the `pre-2.0.0` copy of
  `data-pipeline/`.
- **After steps 20–21** the insights `:latest` images are 2.0.0 builds, which cannot read the 1.x
  ClickHouse. Rolling back also means setting `CCE_INSIGHTS_SERVICE_IMAGE` / `CCE_INSIGHTS_UI_IMAGE` in
  the host `.env` to the 1.x `vN` tags noted in step 5, then
  `docker compose up -d cce-insights-service cce-insights-ui`, and reverting the two `demo-dev` merges
  so the next insights push does not bring 2.0.0 back.
