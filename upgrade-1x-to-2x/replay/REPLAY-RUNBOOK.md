# Replay runbook — rebuild CCE data from `inbound_event_log`

Every event CCE accepts is stored in Postgres, in `inbound_event_log`. A replay sends those events to
Kafka again, as if they had just arrived. The services that process events then rebuild everything
they derive from them: enrolments, steps, deadlines, deviations. Kafka itself is **not** a usable
source for this: it keeps only 7 days of events.

Use a replay whenever the derived data can no longer be trusted or is missing, for example:

- after a redeployment that starts the services on empty tables;
- after a bug fix in a service or a protocol, to re-derive everything with the fixed logic;
- after a Kafka or service outage, to process events that were never processed.

Everything is done by one script, `upgrade-1x-to-2x/replay/replay-inbound-events.sh`, one step at a time. It works for
any CCE release and any way of deploying it: services on Docker Compose, plain Docker or Kubernetes;
Postgres, Kafka and Kafka Connect in containers, in pods or installed on the server. A short settings
file, `upgrade-1x-to-2x/replay/replay.env`, says:
- how to reach the deployment (services, Postgres, Kafka, Kafka Connect, ClickHouse);
- `SERVICES`: which services to stop and start again;
- `DROP_TABLES`: which tables those services create, so the rebuild drops them;
- `RESTORE_TABLES`: which of those get their data back;
- `SCHEMA_ORDER` (optional): the order the services build their tables in, when it differs from
  `SERVICES`.

Only the tables in `DROP_TABLES` are dropped. Nothing else in the database is touched, because other
applications (gateway, Keycloak on some servers) keep their own tables in the same database.

Each step checks what it needs before it changes anything, and stops with a clear **STOP** message
if something is wrong. Every step also says what to check before going on and what to do if it goes
wrong; **Revert** undoes a replay. Run the steps in order and copy each command exactly.

## Pick the kind of replay

| You want to… | Use | Existing data | Events before `--from` / from `--to` on | Order |
|---|---|---|---|---|
| Rebuild **everything** from all stored events (after a bug fix, or a redeployment on empty tables) | **A. Full rebuild** | dropped (`DROP_TABLES`) and rebuilt | no range: everything is rebuilt | kept, except live events that arrive during the seconds `publish` sends (listed, checked in A9: [Live events during the replay](#live-events-during-the-replay-where-the-order-can-overlap)) |
| Rebuild, but keep **only** the events received in a range (e.g. leave out test events sent after a moment, or events before a date that are known to be bad) | **B. Rebuild from a date range** | dropped and rebuilt, as in A | **gone** from the rebuilt data, counted as `never processed`; only in the A3 backup (and in `replay_old` until A11) | kept, except live events that arrive during the seconds `publish` sends (listed, checked in A9: [Live events during the replay](#live-events-during-the-replay-where-the-order-can-overlap)) |
| Process events that were **never processed** (after a Kafka or service outage) | **C. Fill gaps** | **kept**: only what is missing is added | **untouched**: still processed as before | **not kept** for a patient with a gap and later activity: the missing events are processed after newer ones |
| Move a **1.x deployment to 2.0** by rebuilding its data under 2.0 | **[U. Upgrade 1.x → 2.0](#u-upgrade-1x--20-by-replay)** (deploys 2.0 first, then A) | the 1.x tables dropped and 2.0's built | no range | kept, except live events that arrive during the seconds `publish` sends (listed, checked in A9: [Live events during the replay](#live-events-during-the-replay-where-the-order-can-overlap)) |

B is not a faster A on part of the data: what it leaves out is lost from the rebuilt data. And B
followed by C for the left-out events is C, with C's order: to have the whole history, in order,
run A.

**Date ranges.** `plan` and `publish` take `--from` and `--to`, in UTC, on the time CCE *received*
each event (`inbound_event_log.received_at`). `--from` is inclusive, `--to` exclusive, either can be
left out, and a time is optional: `--from '2026-09-01'`, `--to '2026-09-15 06:00'`. Use the same
range in `plan` and `publish`.

## What a rebuild does

1. **Stops** `SERVICES`, last one first, and waits until each one's process has exited (on
   Kubernetes: until no pod is left, terminating ones included). The collector and everything else
   keep running, so no incoming event is lost (the senders retry only a few seconds; see "New events
   keep coming in").
2. **Drops** `DROP_TABLES` together with those services' migration records (e.g.
   `flyway_schema_history_matcher`). They are moved, unchanged, into schema `replay_old`, where they
   stay until step A11, so **Revert** can put them back exactly. Dropping (not emptying) is what lets
   the services' own migrations build the tables in the shape the deployed release expects, which is
   also what makes an upgrade by replay possible.
3. **Clears CCE's output topics** (`cce.*` except `cce.events.inbound` and the CDC topics). The
   inbound topic's dead-letter topic (`cce.events.inbound.dlq`) is one of them; its records are saved
   to a file first. The inbound topic is left alone until step 7, and topics of other applications on
   the same broker are never touched.
4. **Starts each service once**, in `SCHEMA_ORDER`. Its own migrations create its tables again, then
   it's stopped again. What a service sent to Kafka while it was up is thrown away before the next one
   starts, and after the last.
5. **Empties the rebuilt tables.** While a service was up for its migrations, the consumer already
   read the live events waiting in the inbound topic and wrote rows for them, against empty tables and
   out of order with the history. Those events are all in `inbound_event_log`, so step 7 replays them
   in order; their rows are thrown away here.
6. **Puts the data back** into `RESTORE_TABLES`: configuration and reference data that isn't in any
   event, so the replay can't rebuild it. Ids are kept and the tables' id sequences are moved past
   them, so the services' next inserts don't collide with a restored row.
7. **Takes the cutoff and sends the stored events again** (step A5). Right before sending, it empties
   the inbound topic and records the cutoff; every event received before it goes out, oldest first.
   The cutoff is taken here, not in step 1–6, so that live events that arrived during the preparation
   are sent in order with the history instead of sitting in the topic ahead of it (a patient's new
   visit processed before their enrolment would leave wrong state). The first service in `SERVICES`
   processes them. The others start once it has caught up, so deadlines and alerts are only judged on
   complete data. What the replayed events would make them send out is thrown away before they start.
   Live events that arrive between the cutoff and the end of sending (a few seconds) can land ahead
   of or between replayed ones: see "Live events during the replay: where the order can overlap".

### Example: how stored events are sent again

Three rows in `inbound_event_log` (shortened):

| `received_at` | `status` | `source` | `correlation_id` | `raw_payload` (what the sender sent) |
|---|---|---|---|---|
| 2026-03-01 09:15:04 | `ACCEPTED` | tiberbu | `corr-51e2` | `{"specversion":"1.0","id":"evt-7f3c","source":"tiberbu","type":"org.openphc.cce.encounter","subject":"UPID-10023","time":"2026-03-01T09:15:00Z","datacontenttype":"application/fhir+json","facilityid":"F-104","data":{"resourceType":"Encounter",…}}` |
| 2026-03-05 14:02:11.5 | `ACCEPTED` | openmrs | `corr-9c40` | `{"specversion":"1.0","id":"evt-8a01","source":"openmrs","type":"org.openphc.cce.observation","subject":"UPID-10023","data":{"resourceType":"Observation",…}}` — no `time`, no `correlationid` |
| 2026-03-06 08:00:00 | `REJECTED` (`INVALID_FHIR`) | tiberbu | — | `{"id":"evt-9b77","subject":"UPID-20011",…}` |

`publish` turns them into these Kafka messages on `cce.events.inbound`, sent in this order (the actual
output of the script's query):

| # | Key | Value |
|---|---|---|
| 1 | `UPID-10023` | `{"id": "evt-7f3c", "data": {…}, "time": "2026-03-01T09:15:00Z", "type": "org.openphc.cce.encounter", "source": "tiberbu", "subject": "UPID-10023", "facilityid": "F-104", "specversion": "1.0", "correlationid": "corr-51e2", "datacontenttype": "application/fhir+json"}` |
| 2 | `UPID-10023` | `{"id": "evt-8a01", "data": {…}, "time": "2026-03-05T14:02:11.500000Z", "type": "org.openphc.cce.observation", "source": "openmrs", "subject": "UPID-10023", "specversion": "1.0", "correlationid": "corr-9c40"}` |

What happened, and why:
- **Only `ACCEPTED` rows are sent.** Row 3 was rejected by the collector, so it never reached Kafka
  the first time either; replaying it would process an event CCE never processed.
- **Oldest first:** ordered by `received_at` (then `id`), the order CCE originally received them.
- **Key = the patient (`subject`).** Kafka keeps messages with the same key in one partition, in
  order, so both of patient `UPID-10023`'s events reach Matcher in this order, as the collector's own
  messages did (the collector uses the same key).
- **Value = the stored `raw_payload`, plus what the collector added when it first sent it.**
  `raw_payload` is saved *before* the collector fills in its defaults, so these are put back:
  - `correlationid`: from the row's `correlation_id` column when the sender gave none (both rows here:
    `corr-51e2`, `corr-9c40`);
  - `time`: the receive time (`received_at`, in UTC) when the sender gave none (row 2:
    `2026-03-05T14:02:11.500000Z`);
  - `id`, `source`, `specversion`: from their columns, only when an older collector didn't keep them in
    `raw_payload` (not needed here).
- **Key order inside the JSON differs** from the original message (Postgres stores JSON with its keys
  re-ordered). The services read the JSON by field name, so this makes no difference to them.
- **How it's sent:** each message is one line, `<key><TAB><value>`, piped into Kafka's
  `kafka-console-producer` with `parse.key=true`; it waits for every copy to be written (`acks=all`)
  and keeps messages in order (`enable.idempotence=true`). `publish` then checks that the producer
  reported no send error, that it was handed as many events as were selected, and that the topic grew
  by at least that many.

### Live events during the replay: where the order can overlap

The collector keeps running for the whole replay (it must: the senders retry only a few seconds, so
stopping it would lose events). Its new, live events go into `inbound_event_log` **and** straight
onto `cce.events.inbound`, the same topic the replay is filling. What that means for the order:

| When a live event arrives | What happens to it | Order |
|---|---|---|
| During A4 `prepare` and until A5 takes the cutoff | Waits in the topic; deleted by A5 just before sending, and sent again from `inbound_event_log` with the history | correct (it's part of the replay) |
| **Between the cutoff and the end of sending** (a few seconds) | Lands in the topic **ahead of or between** replayed messages | **may overlap:** see below |
| After A5 has finished sending | Joins the topic behind all the history | correct |

**The overlap, with an example.** A5 is sending patient `UPID-10023`'s history (enrolment on
1 March, visits after it) and a new visit for the same patient arrives at that very moment. If
`UPID-10023`'s older messages have not been written yet, the new visit sits in that patient's queue
**ahead of them**, and Matcher handles it first. Then, for example, a follow-up is seen before the
enrolment, is not matched, and the patient's steps end up wrong. Patients whose history was already
sent, or who have no history, are not affected.

**Events that were on their way through the collector at the cutoff.** The collector records an
event's receive time before it validates and publishes it. An event received just before the cutoff
but published just after the topic's end was noted is therefore both replayed (it was received
before the cutoff) and left in the topic ahead of the history. Matcher keeps the first copy it sees
and skips the second as a duplicate (same `cloudevents_id` and `source`), so the copy that counts is
the early one, ahead of the history. These patients are listed too.

**How big it is:** only live events that arrive between the cutoff and the end of sending, for a
patient who also has history. `publish` does nothing slow in that window (the cutoff is taken, the
old records are deleted, the history is sent: typically 5 seconds plus the sending itself), so this
is usually no one or a handful of patients.

**How it's caught:** after sending, `publish` lists every such patient who also has history, in
`<STATE_DIR>/publish-window-subjects.txt`, and prints a `WARN` if there are any (`OK no live event
arrived for a replayed patient ahead of their history` otherwise). It reads the exact records that
landed in the topic between the cutoff and the start of sending, and adds the patients of events
received while sending. A9 says what to check.

**Why it isn't closed completely:** that would mean pausing the collector during the send, and the
senders would give up on events sent in those seconds (lost for good). A possible wrong order for
a few patients, which can be found and fixed, is the better trade than lost events.

**Fill gaps (C) has the same overlap, larger.** The first service keeps running and processes live
events while the missing older events are sent, so a patient's older (missing) event can be handled
after a newer one. Fill-gaps only sends events that were never processed, so nothing is doubled,
but for a patient with both a gap and new activity the order is not guaranteed.

**Never touched:** every table not in `DROP_TABLES`, and always:
- `inbound_event_log` (the replay's source);
- the collector's migration record (`flyway_schema_history_collector`, or the plain
  `flyway_schema_history` where the collector uses that);
- Keycloak's tables.

A table in `DROP_TABLES` that no service creates again is put back as it was: with its data if it's
in `RESTORE_TABLES`, otherwise empty. The exception is a table tied by a foreign key to an old table
the services did create again. It belongs to the old data model, so it stays in `replay_old` with the
tables it is tied to: **Revert** puts it back with them, A11 deletes it with them. (In the 1.x → 2.0
upgrade that can be `compliance_event_log`, when 1.x `step_instance` points at it; on a database
where it doesn't, `compliance_event_log` comes back empty like the other 1.x-only tables.)

### The settings for each release

| | CCE 2.0 (the values in `replay.env`) | CCE 1.x (the commented 1.x block) | Upgrade 1.x → 2.0 (the commented upgrade block) |
|---|---|---|---|
| `SERVICES` (first one reads `cce.events.inbound`) | Matcher, Step SLA, intelligence | compliance, scheduler | Matcher, **Protocol**, Step SLA, intelligence |
| `SCHEMA_ORDER` | (= `SERVICES`) | (= `SERVICES`) | Protocol, Matcher, intelligence |
| `DROP_TABLES` | `matcher_event_log`, `protocol_instance(_history)`, `step_instance(_history)`, `step_sla_state_transition`, `deviation`, `intelligence_event_log`, `facility`, `receiver_adaptor`, `destination_adaptor_mapping`, `intelligence_delivery(_audit_log)`, `notification_tracker` | `compliance_event_log`, `protocol_definition`, `action_definition`, `trigger_index`, `protocol_instance(_history)`, `step_instance(_history)`, `deviation`, `intelligence_event_log`, `facility`, `audit_log`, `scheduler_lease`, `scheduler_scan_cursor` | the 2.0 list **plus** `protocol_definition`, `action_definition`, `trigger_index` and the 1.x-only `compliance_event_log`, `audit_log`, `scheduler_lease`, `scheduler_scan_cursor` |
| `RESTORE_TABLES` | `facility`, `receiver_adaptor`, `destination_adaptor_mapping`, `notification_tracker` | `protocol_definition`, `action_definition`, `trigger_index`, `facility`, `audit_log` | the 2.0 list **plus** `protocol_definition`, `action_definition`, `trigger_index` |
| `CONSUMER_GROUP` | (found) | (found) | `cce-matcher-service` |

Why these tables are in `RESTORE_TABLES`:
- **`facility`:** facility reference data. It's in `DROP_TABLES` only because the same migration
  creates it (Matcher's in 2.0, compliance's in 1.x).
- **`receiver_adaptor`, `destination_adaptor_mapping`:** where intelligence delivers alerts.
- **`notification_tracker`:** intelligence's alert incidents. Lost, they would be opened and
  alerted again.
- **1.x: the protocol tables and `audit_log`:** 1.x compliance's migrations create them too.

**A deployment without the intelligence service** (none is used on DEV today): leave
`cce-intelligence-service` out of `SERVICES` and `SCHEMA_ORDER`, and its own tables
(`receiver_adaptor`, `destination_adaptor_mapping`, `intelligence_delivery`,
`intelligence_delivery_audit_log`, `notification_tracker`) out of `DROP_TABLES` and `RESTORE_TABLES`.
Keep `intelligence_event_log`: Matcher creates it. Leaving the service in while its tables are
dropped would move the tables out from under it.

`DROP_TABLES` must list **every** table the services' migrations create. A table left out still
exists when the migration runs, so the migration fails with "already exists". `prepare` then stops,
and **Revert** undoes it. Don't list tables of services that keep running, such as the 2.0 protocol
tables in a normal 2.0 replay: they are configuration, Matcher's migrations need them while they
build, and Protocol keeps serving while the replay runs.

List `RESTORE_TABLES` parents first (`protocol_definition` before `trigger_index`,
`receiver_adaptor` before `destination_adaptor_mapping`): rows are put back in that order, and a row
can only be put back after the row it points at.

**Upgrading 1.x → 2.0 by replay** (instead of the database migration): part **U** below. It swaps
the services by hand first (remove 1.x, deploy 2.0 without starting it), then runs A0–A11 with the
upgrade block of `replay.env`.

### Before a rebuild

- **Each service's migrations must be able to build its tables on an empty schema.** For every
  service that creates tables (Protocol, Matcher, intelligence):
  - **Flyway is on.** The 1.x Kubernetes manifests set `SPRING_FLYWAY_ENABLED=false`; manifests
    copied from them create nothing, and `prepare` stops.
  - **Baseline 0:** `CCE_FLYWAY_BASELINE_VERSION=0` (Protocol, Matcher),
    `SPRING_FLYWAY_BASELINE_VERSION=0` (intelligence, the 1.x scheduler). With a baseline above 0 a
    service skips its first migrations and creates nothing; `prepare` detects that and stops.
  - **Baseline on migrate:** `SPRING_FLYWAY_BASELINE_ON_MIGRATE=true`. Matcher's `prod` profile turns
    it off, and the schema is never empty (it holds `inbound_event_log`), so without it Matcher stops
    with "Found non-empty schema(s) … but no schema history table". (DEV already sets it.)
  - **Matcher's V2 fix (`missed_date`).** Without it, `prepare` stops with
    `column s.missed_date does not exist`. As of 2026-09-29 the fix is in neither `release-2.0.0` nor
    `ghcr.io/openphc/cce-matcher-service:latest`: V2 checks for `due_date`, which a fresh 2.0 schema
    also has, where it should check for `missed_date`, which only 1.x has. Deploy a Matcher image with
    that guard fixed before any rebuild, on DEV too.
- **A service may create its tables and still fail to start** because it checks a table a **later**
  service creates (2.0 Protocol checks a sequence only Matcher's V6 sets up). If its own migrations
  all succeeded, `prepare` prints a `WARN` and goes on: its tables are there, and it starts normally
  in `finish` once every table exists. Any other start failure stops `prepare`.
- **How `prepare` knows a service has started:** Spring Boot's `Started … in N seconds` line in its
  log, or the platform's own health signal where the service has one (a Docker healthcheck, a
  Kubernetes readiness probe). A readiness probe must go through the application (e.g.
  `/actuator/health`), not just a TCP port.
- **The replay starts containers as they are.** On Docker Compose it starts the service's existing
  container (`docker start`), not `docker compose up` (and not `docker compose start`, which would
  also start its `depends_on` services), so the service that processes the replay is the same build that built its tables. A
  change to the compose file or `.env` is therefore **not** applied by the replay: apply it first
  (`docker compose up -d <service>`), then run `check`.
- **No open alert incidents** when `notification_tracker` is dropped. The `demo-rw` intelligence
  image checks for alerts the moment it starts, before the rows are back, so an open incident would
  be alerted again. `prepare` refuses, and `plan` warns in advance. (The rw-uat copy of 2026-09-28
  has one `ACTIVE` incident.)
- **Foreign keys.** If a table that stays refers to one being dropped, `prepare` stops before
  changing anything and names both tables.

## Before you start

- **Tell people:** the Insights dashboard shows incomplete numbers from A4 until A8, and is
  unavailable during A8 (it is stopped while ClickHouse is rebuilt, usually a few minutes).
- **Which services stop, and when:**

  | Services | A/B. Rebuild | C. Fill gaps |
  |---|---|---|
  | not in `SERVICES` (collector, …; Protocol except in the upgrade) | keep running | keep running |
  | Insights (`INSIGHTS_SERVICES`) | stopped during A8 only | keep running |
  | the **first** in `SERVICES` | stopped in A4, started again in A5 (`publish`) | keeps running |
  | the **others** in `SERVICES` | stopped in A4, started again in A7 (`finish`) | stopped in C5, started again in C8 |

  A4 also starts each one for about a minute, so its migrations create its tables, and stops it again.
- **New events keep coming in.** The collector keeps accepting events during the replay, and must:
  the senders (emitter adaptors) retry only 3 times over a few seconds, so events sent while it is
  down are lost unless the source system resends them. Events received before the cutoff (recorded
  by A5 `publish`, right before sending) are replayed; later ones are processed live once the first
  service runs again. None are lost, and each patient's events are processed in the order received —
  except, possibly, for a patient whose live event arrives in the few seconds between the cutoff and
  the end of sending. `publish` lists those patients so they can be checked (A9). Details: "Live
  events during the replay: where the order can overlap".
- **No alerts or deliveries come from the replayed events.** The services that send them are stopped
  while the events are processed, and what the replayed events produce for them is thrown away before
  they start. Their own checks (e.g. ingestion-gap alerts) pause while they are stopped. This also
  drops the alerts of live events Matcher processes between A5 and A7: they are in the same topic and
  can't be told apart.
- **Disk.** The backup, the old tables kept in `replay_old`, the rebuilt tables, the replayed events
  in Kafka and the WAL Postgres keeps for the paused CDC connector (from A4 until A8) all take space at
  once. `plan` shows the database size and the free space for the backup; `status` and `wait` show
  the WAL kept for CDC. On a server shared by two deployments (UAT and prod), both feel it.
- **Time:** `status` shows how many events there are; `wait` (step A6) shows progress.

### 1. Log in and find the script

Log in to the server CCE runs on and go to the deploy-scripts folder there (on a Docker Compose
server this is usually `/opt/deployment`):

```bash
cd /opt/deployment
ls upgrade-1x-to-2x/replay/replay-inbound-events.sh upgrade-1x-to-2x/replay/replay.env        # both must exist
```

If `upgrade-1x-to-2x/` is missing, copy it from your laptop (run in the deploy-scripts folder there):

```bash
scp -r upgrade-1x-to-2x <user>@<server>:/opt/deployment/
# e.g. dev:  scp -r -i ~/.ssh/id_ed25519 upgrade-1x-to-2x ubuntu@13.206.132.44:/opt/deployment/
```

The machine that runs the script needs `bash`, GNU core tools, `curl` and `python3` (the ClickHouse
steps use it); `check` says if one is missing.

### 2. Fill in `upgrade-1x-to-2x/replay/replay.env`

Do this once per deployment (`nano upgrade-1x-to-2x/replay/replay.env`). It has three parts:

1. **`DEPLOYMENT_NAME`**: a short name, printed by every step.
2. **How to reach it**:
   - **the services:** `PLATFORM=compose` (+ `COMPOSE_DIR`), `docker` (containers by name) or
     `kubernetes` (+ `KUBECTL`, `K8S_NAMESPACE`). Each name in `SERVICES` is a Compose service, a
     container or a Deployment of that name;
   - **Postgres, Kafka and Kafka Connect:** each through a command prefix that runs a program where
     its tools are, and passes stdin through:

     | Where it runs | Prefix |
     |---|---|
     | a container | `"docker exec -i <container>"` |
     | a pod | `"kubectl -n <namespace> exec -i <pod, e.g. statefulset/postgres> --"` |
     | installed on this server | `"sudo -u postgres"` (Postgres), or `""` to run the tools directly |

     `PG_EXEC` runs `psql`, `pg_dump` and `pg_restore`: they connect as `PG_USER` if set, else as the
     database image's `POSTGRES_USER`, else as the OS user (`PG_HOST`, `PG_PORT` only when not the
     default). `KAFKA_EXEC` runs the `kafka-*` tools: Apache Kafka's end in `.sh` and live in
     `/opt/kafka/bin` (`KAFKA_TOOL_SUFFIX=.sh`, `KAFKA_TOOLS_DIR=/opt/kafka/bin`); `KAFKA_BOOTSTRAP`
     is the broker as seen from there; `KAFKA_CLIENT_CONFIG` is a client properties file (SASL/TLS)
     if the broker needs one. `CONNECT_EXEC` runs `curl` against `CONNECT_URL`, as seen from there;
   - **ClickHouse:** `CH_HTTP`, over HTTP from the server that runs the script (a port-forward if
     ClickHouse runs in a cluster), and where its password comes from;
   - **`DATA_PIPELINE_DIR`:** the deployed release's data-pipeline (default: `data-pipeline/` at the
     deploy-scripts root). `check` and A8 stop if it captures tables the database doesn't have (a 1.x
     pipeline against a 2.0 database);
   - **`STATE_DIR`** (optional): where backups and replay progress go (default
     `~/cce-replay/<DEPLOYMENT_NAME>`). Set it if steps may be run both with and without `sudo`:
     each would otherwise use its own home folder.

   The older settings `PG_ACCESS`, `KAFKA_ACCESS`, `CONNECT_ACCESS` (with `PG_CONTAINER`,
   `KAFKA_CONTAINER`, `CONNECT_CONTAINER`, `PG_LOCAL_PREFIX`, `KAFKA_BIN`, `KAFKA_CONTAINER_BIN`)
   still work.
3. **What the replay does**: `SERVICES`, `DROP_TABLES`, `RESTORE_TABLES` (and `SCHEMA_ORDER`,
   `CONSUMER_GROUP` when needed). The values are for 2.0; for 1.x, or for the 1.x → 2.0 upgrade, use
   the matching commented block. `INSIGHTS_SERVICES=""` for a deployment without Insights.

#### How each connection setting is used, and when to set it

**`PLATFORM` decides only how the CCE services are stopped and started.** Postgres, Kafka, Kafka
Connect and ClickHouse are reached through their own settings, whatever `PLATFORM` is: UAT is
`PLATFORM=kubernetes` with its Postgres and Kafka in Docker, prod is `kubernetes` with them installed
on the server. Each `*_EXEC` says **where** a tool runs; the settings next to it say how that tool
finds the component **from there**.

**The services (`PLATFORM`)**

| | `compose` | `docker` | `kubernetes` |
|---|---|---|---|
| Also set | `COMPOSE_DIR`; `COMPOSE_OPTS` only if needed (below) | — | `KUBECTL`, `K8S_NAMESPACE` |
| A name in `SERVICES` is | a Compose service | a container | a Deployment (an autoscaler, if any, has the same name) |
| Stop | `docker compose stop` | `docker stop` | saves the replica count and the autoscaler (`STATE_DIR/replicas-*`, `hpa-*.yaml`), deletes the autoscaler, scales to 0 |
| Start | `docker start` on the existing container | `docker start` | scales back, re-applies the autoscaler, `rollout status` |

Every step then waits until the process has exited (Kubernetes: no pod left, terminating ones included).

- **`COMPOSE_OPTS`.** The script runs `cd $COMPOSE_DIR && docker compose $COMPOSE_OPTS …`. Compose
  finds a service's containers by the **project name** (the label `com.docker.compose.project` on
  each container) and its compose file(s). The project name is `-p`, else `COMPOSE_PROJECT_NAME` (in
  the shell or the folder's `.env`), else a top-level `name:` in the compose file, else the folder's
  name. Set `COMPOSE_OPTS` when the stack was brought up in a way a plain `docker compose` in
  `COMPOSE_DIR` doesn't repeat:

  | The stack was started with | `COMPOSE_OPTS` |
  |---|---|
  | a file not named `compose.yaml` / `docker-compose.yml` (`-f docker-compose.prod.yml`) | `"-f docker-compose.prod.yml"` |
  | several files (`-f docker-compose.yml -f docker-compose.2x.yml`) | the same `-f` list, in the same order |
  | `-p cce` from a folder with another name, or from another folder | `"-p cce"` |

  To see what is needed: `docker compose ls` shows each project's NAME and CONFIG FILES; `cd
  $COMPOSE_DIR && docker compose ps` must list the CCE services. With the wrong project, the services
  look `absent` (or stopped) to the script although they run. A container's project cannot be changed
  in place: renaming a project means `down` and `up` again, and new named volumes (empty) unless they
  are declared `external`. So point the script at the name the stack has.
- **`KUBECTL`** is the command the script runs for every Kubernetes call, as
  `$KUBECTL -n $K8S_NAMESPACE …` (default `kubectl`). On k3s (UAT, prod) it is `"k3s kubectl"`: k3s
  bundles kubectl, and its credentials (`/etc/rancher/k3s/k3s.yaml`) are readable by root only, hence
  `sudo` in `R`. Use whichever of `sudo k3s kubectl -n <ns> get deploy` or `kubectl -n <ns> get deploy`
  works on the server. `KUBECTL` is for the services only: a component running in a pod is reached
  through its own `*_EXEC`, with the kubectl command written into it.

**Postgres (`PG_EXEC`, `PG_DB`, `PG_USER`, `PG_HOST`, `PG_PORT`)**

The script runs `$PG_EXEC sh -c 'psql -U … -h … -p … -d $PG_DB …'` (also `pg_dump`, `pg_restore`);
each optional setting adds its flag only when set. Inside wherever `PG_EXEC` runs:

| | If unset |
|---|---|
| `PG_DB` | `ccedb` |
| `PG_USER` | `$POSTGRES_USER` there (the official image sets it), else the OS user psql runs as |
| `PG_HOST` | the local Unix socket |
| `PG_PORT` | 5432 (the socket's name depends on the port too) |
| password (no setting) | `$PGPASSWORD` there, else `$POSTGRES_PASSWORD` there, else `~/.pgpass`; none for trust or peer authentication |

| Where Postgres runs | Set | Example |
|---|---|---|
| a container of the official image | `PG_EXEC` only | dev, UAT: `"docker exec -i postgres-uat"`. Inside the container it is always 5432, whatever port the host publishes (UAT's 5433 doesn't matter) |
| a container or pod without `POSTGRES_USER` in its environment (Bitnami, many StatefulSets) | `PG_EXEC` + `PG_USER` | `"kubectl -n data exec -i statefulset/postgres --"`, `PG_USER=postgres`. Without it psql logs in as `root` and fails |
| installed on this server | `PG_EXEC="sudo -u postgres"` (peer authentication as role `postgres`) + `PG_PORT` if not 5432 | prod: `PG_PORT=5432` |
| reached over the network (psql on this host, Postgres elsewhere or in a container with a published port, a managed database) | `PG_EXEC=""` + `PG_HOST` + `PG_PORT` + `PG_USER`, and the password in this host's environment | `PG_HOST=localhost PG_PORT=5433 PG_USER=postgres`; `export PGPASSWORD=…` before running, or `~/.pgpass` of the user the script runs as (`sudo` drops `PGPASSWORD` unless `sudo -E`) |

Any of them: `PG_DB` when the database isn't `ccedb`. The user must be allowed to drop and create
tables and `pg_dump` the database; **Revert** also drops and creates the database and drops
replication slots. In practice: the superuser (`postgres`), not the services' own user.

**Kafka (`KAFKA_EXEC`, `KAFKA_BOOTSTRAP`, `KAFKA_TOOLS_DIR`, `KAFKA_TOOL_SUFFIX`, `KAFKA_CLIENT_CONFIG`)**

The script runs `$KAFKA_EXEC $KAFKA_TOOLS_DIR/<tool>$KAFKA_TOOL_SUFFIX --bootstrap-server
$KAFKA_BOOTSTRAP …` for `kafka-topics`, `kafka-get-offsets`, `kafka-consumer-groups`,
`kafka-delete-records` (its JSON file is written with `mktemp` where the tools run, then removed),
`kafka-console-producer` (the replayed events, through stdin) and `kafka-console-consumer`.

| Kafka | `KAFKA_EXEC` | `KAFKA_TOOLS_DIR` | `KAFKA_TOOL_SUFFIX` |
|---|---|---|---|
| Confluent image (`confluentinc/cp-kafka`) | `"docker exec -i <container>"` | — | — |
| Apache image (`apache/kafka`) | `"docker exec -i <container>"` | `/opt/kafka/bin` | `.sh` |
| Bitnami image | `"docker exec -i <container>"` | — | `.sh` |
| a pod | `"kubectl -n <ns> exec -i <pod> --"` | as for its image | as for its image |
| installed on this server (prod) | `""` | `/opt/kafka/bin` | `.sh` |

`check` reporting the tools as not found means these two are wrong. To see which a container has:
`docker exec <container> sh -c 'command -v kafka-topics kafka-topics.sh; ls /opt/kafka/bin'`.

- **`KAFKA_BOOTSTRAP` is the broker as seen from where the tools run.** A client is redirected to the
  broker's *advertised* listener, so take the listener that resolves there
  (`docker exec <container> env | grep -i LISTENERS`): `kafka:9092` inside the dev Compose network,
  `localhost:9092` in UAT's container and on prod, `kafka-0.kafka-headless:9092` in a pod. A port the
  container publishes to the host (e.g. `localhost:29092`) doesn't exist inside the container.
- **`KAFKA_CLIENT_CONFIG`:** only when the broker needs SASL or TLS. A client properties file **where
  the tools run** (inside the container or pod); it is passed to every tool.

**Kafka Connect (`CONNECT_EXEC`, `CONNECT_URL`, `CONNECT_HOST_URL`)**

The script calls Connect's REST API as `$CONNECT_EXEC curl $CONNECT_URL/connectors/…`: the CDC
connector's status (`check`, `status`), pause and resume during the replay, and in A8 saving its
configuration, removing it and registering it again.

| Connect | `CONNECT_EXEC` | `CONNECT_URL` |
|---|---|---|
| a container (dev, UAT) | `"docker exec -i cce-kafka-connect"` | `http://localhost:8083`: inside the container, whatever port the host publishes |
| a pod | `"kubectl -n <ns> exec -i deploy/kafka-connect --"` | `http://localhost:8083` |
| installed on this server (prod) | `""` | its port: `http://localhost:8086` |
| an image without `curl`, or reached from this host | `""` | the port as published to this host |

**`CONNECT_HOST_URL`** (rarely): A8 registers the connector again from the configuration it saved
before removing it, through `CONNECT_EXEC` / `CONNECT_URL`. Only when there was no connector to save
(a fresh setup, or one removed before the first run) does it run
`data-pipeline/scripts/register-connectors.sh` **on this host**, which then needs Connect's address
as seen from here, and the `CDC_*` credentials. Set it only when that can happen **and** the host
port differs from the container's (the laptop: `8084` on the host for the container's `8083`).

**ClickHouse (`CH_HTTP`, and its credentials)**

ClickHouse has **no `*_EXEC`**: `curl` and `python3` (`apply-schema.py`, the schema/09 backfill) run
**on this host**, against ClickHouse's HTTP interface. So `CH_HTTP` is ClickHouse as seen from this
host, and `python3` must be installed here (`check` says so).

| | Taken from |
|---|---|
| address | `CH_HTTP`, else `http://$CLICKHOUSE_HOST:$CLICKHOUSE_PORT`, else `http://localhost:8123` |
| user | `CH_USER`, else `CLICKHOUSE_USER`, else `cce_pipeline` |
| password | `CH_PASSWORD`, else `CLICKHOUSE_PASSWORD` (A8 stops without one) |
| database | `CH_DB`, else `CLICKHOUSE_DB`, else `cce_analytics` |

| ClickHouse | `CH_HTTP` |
|---|---|
| a container publishing its HTTP port (dev) | `http://localhost:8123` |
| UAT | unset: `CLICKHOUSE_HOST` / `CLICKHOUSE_PORT` come from Infisical |
| installed on this server (prod) | `http://localhost:8124` |
| in a cluster | `http://localhost:8123`, with `kubectl -n <ns> port-forward svc/clickhouse 8123:8123 &` started first and kept running through A8 |
| elsewhere | any URL `curl` reaches from here (`https://…:8443` with TLS) |

The HTTP port, not the native one (9000). A Compose service name (`http://clickhouse:8123`) does not
resolve on the host. The user and password come from the environment (Infisical on UAT and prod) or
from `SECRETS_FILE`, of which only the credentials are read (its URLs and ports never override this
file). ClickHouse's own connection to Kafka (its Kafka tables) is not set here: it is the server-side
named collection `cce_kafka`, which A8 checks exists before it drops anything.

**`DATA_PIPELINE_DIR`** is not a connection but the folder A8 rebuilds ClickHouse from. It reads
`connectors/debezium-postgres-source.json` (the tables captured, and the connector's definition),
`cdc/01-configure-replication.sql` (applied to Postgres again), `schema/01…08` (ClickHouse),
`schema/09-historical-backfill.sql` and `scripts/apply-schema.py` (and `scripts/register-connectors.sh`
as above). It must be the **deployed** release's: `check` warns, and A8 refuses, when it captures
tables the database doesn't have (a 1.x pipeline against 2.0).

| Situation | `DATA_PIPELINE_DIR` |
|---|---|
| `data-pipeline/` sits beside `upgrade-1x-to-2x/` at the deployed version | unset (the default) |
| only `upgrade-1x-to-2x/` was copied to the server | **must** be set: the default doesn't exist |
| the deployed pipeline is elsewhere | its path, e.g. `/opt/deployment/data-pipeline` |
| upgrade 1.x → 2.0 (part U) | the 2.0 pipeline (U1) |
| going back to 1.x | the 1.x pipeline (U1) |

**Checking:** `$R check` (A0) uses exactly these commands and prints, on failure, the prefix and
address it used. The same commands by hand:
```bash
docker exec -i cce-postgres psql -U postgres -d ccedb -c 'select 1'
docker exec -i kafka kafka-topics --bootstrap-server kafka:9092 --list | grep cce.events.inbound
docker exec -i cce-kafka-connect curl -s http://localhost:8083/connectors
curl -s http://localhost:8123/ -H "X-ClickHouse-User: cce_pipeline" -H "X-ClickHouse-Key: $PW" --data-binary 'SELECT 1'
```

#### Examples: the current setups side by side

The three kinds of setup CCE runs on today. Take the column that matches your server, then run
`$R check` (step A0) until every line is `OK`.

| Setting | Dev (Docker Compose) | UAT (Kubernetes, infra in Docker) | Prod (Kubernetes, infra installed on the server) |
|---|---|---|---|
| Server | 13.206.132.44, folder `/opt/deployment` | 41.74.172.80 (shared with prod) | 41.74.172.80 (shared with UAT) |
| `PLATFORM` | `compose` + `COMPOSE_DIR=/opt/deployment` | `kubernetes`, namespace `cce-uat` | `kubernetes`, namespace `cce-prod` |
| `PG_EXEC` | `"docker exec -i cce-postgres"` | `"docker exec -i postgres-uat"` (port 5433 on the server) | `"sudo -u postgres"` + `PG_PORT=5432` |
| `KAFKA_EXEC` / broker | `"docker exec -i kafka"`, `kafka:9092` | `"docker exec -i kafka-uat"`, `localhost:9092` | `""` + `/opt/kafka/bin`, `.sh`, `localhost:9092` |
| `CONNECT_EXEC` / URL | `"docker exec -i cce-kafka-connect"`, port 8083 | `"docker exec -i cce-kafka-connect"`, port 8083 | `""`, port 8086 |
| ClickHouse | port 8123 | port 8123 | port 8124 |
| ClickHouse password | `data-pipeline/.env` | Infisical, via `rw/lib/infisical-run.sh uat` | Infisical, via `rw/lib/infisical-run.sh prod` |
| Release today | 2.0 | 1.x (2.0 once deployed) | 1.x (2.0 once deployed) |
| `sudo` in `R` | no | yes | yes |

The last part of the file (`SERVICES`, `DROP_TABLES`, `RESTORE_TABLES`) depends only on the
release, not the setup: use the 2.0 values in `replay.env` for a 2.0 deployment, the commented
1.x block for a 1.x one, and the commented upgrade block to move a 1.x deployment to 2.0.

**Dev** — `upgrade-1x-to-2x/replay/replay.env`, first two parts (these are the file's own values, so only
`DEPLOYMENT_NAME` changes):
```bash
DEPLOYMENT_NAME=dev
PLATFORM=compose
COMPOSE_DIR=/opt/deployment
PG_EXEC="docker exec -i cce-postgres"
KAFKA_EXEC="docker exec -i kafka"
KAFKA_BOOTSTRAP=kafka:9092
CONNECT_EXEC="docker exec -i cce-kafka-connect"
CONNECT_URL=http://localhost:8083
CH_HTTP=http://localhost:8123
SECRETS_FILE=/opt/deployment/data-pipeline/.env
```
`R="bash upgrade-1x-to-2x/replay/replay-inbound-events.sh"`

**UAT** — `upgrade-1x-to-2x/replay/replay-uat.env`, first two parts:
```bash
DEPLOYMENT_NAME=rw-uat
PLATFORM=kubernetes
KUBECTL="k3s kubectl"
K8S_NAMESPACE=cce-uat
PG_EXEC="docker exec -i postgres-uat"
KAFKA_EXEC="docker exec -i kafka-uat"
KAFKA_BOOTSTRAP=localhost:9092
CONNECT_EXEC="docker exec -i cce-kafka-connect"
CONNECT_URL=http://localhost:8083
STATE_DIR=/root/cce-replay/rw-uat
# no CH_HTTP: ClickHouse's address comes from Infisical (CLICKHOUSE_HOST / CLICKHOUSE_PORT), as for replay-uat.sh
```
`R="sudo -A bash rw/lib/infisical-run.sh uat bash upgrade-1x-to-2x/replay/replay-inbound-events.sh --config upgrade-1x-to-2x/replay/replay-uat.env"`

If `check` says the Kafka tools are not found, the `kafka-uat` image is an Apache one: add
`KAFKA_TOOL_SUFFIX=.sh` and `KAFKA_TOOLS_DIR=/opt/kafka/bin`.

**Prod** — `upgrade-1x-to-2x/replay/replay-prod.env`, first two parts:
```bash
DEPLOYMENT_NAME=rw-prod
PLATFORM=kubernetes
KUBECTL="k3s kubectl"
K8S_NAMESPACE=cce-prod
PG_EXEC="sudo -u postgres"
PG_PORT=5432
KAFKA_EXEC=""
KAFKA_TOOLS_DIR=/opt/kafka/bin
KAFKA_TOOL_SUFFIX=.sh
KAFKA_BOOTSTRAP=localhost:9092
CONNECT_EXEC=""
CONNECT_URL=http://localhost:8086
CH_HTTP=http://localhost:8124
STATE_DIR=/root/cce-replay/rw-prod
```
`R="sudo -A bash rw/lib/infisical-run.sh prod bash upgrade-1x-to-2x/replay/replay-inbound-events.sh --config upgrade-1x-to-2x/replay/replay-prod.env"`

**Postgres, Kafka and Kafka Connect running in the cluster** (not a setup CCE runs on today; shown so
the settings are clear). The prefixes go through `kubectl exec`; ClickHouse is reached through a
port-forward started beforehand (`kubectl -n analytics port-forward svc/clickhouse 8123:8123 &`):
```bash
PLATFORM=kubernetes
KUBECTL=kubectl
K8S_NAMESPACE=cce
PG_EXEC="kubectl -n data exec -i statefulset/postgres --"
PG_USER=postgres
KAFKA_EXEC="kubectl -n kafka exec -i kafka-0 --"
KAFKA_TOOLS_DIR=/opt/kafka/bin
KAFKA_TOOL_SUFFIX=.sh
KAFKA_BOOTSTRAP=kafka-0.kafka-headless:9092
KAFKA_CLIENT_CONFIG=/opt/kafka/config/client.properties    # inside the pod, if the broker needs SASL/TLS
CONNECT_EXEC="kubectl -n analytics exec -i deploy/kafka-connect --"
CONNECT_URL=http://localhost:8083
CH_HTTP=http://localhost:8123
```

#### Complete settings files

Whole files, both parts together, as they are used. Lines starting with `#` are comments.

**Dev, CCE 2.0** (`upgrade-1x-to-2x/replay/replay.env`; also a normal 2.0 replay anywhere, with that server's access
lines):
```bash
DEPLOYMENT_NAME=dev
PLATFORM=compose
COMPOSE_DIR=/opt/deployment
PG_EXEC="docker exec -i cce-postgres"
KAFKA_EXEC="docker exec -i kafka"
KAFKA_BOOTSTRAP=kafka:9092
CONNECT_EXEC="docker exec -i cce-kafka-connect"
CONNECT_URL=http://localhost:8083
CH_HTTP=http://localhost:8123
SECRETS_FILE=/opt/deployment/data-pipeline/.env
INSIGHTS_SERVICES="cce-insights-service cce-insights-ui"

SERVICES="cce-matcher-service cce-step-sla-service cce-intelligence-service"
DROP_TABLES="matcher_event_log protocol_instance protocol_instance_history step_instance
  step_instance_history step_sla_state_transition deviation intelligence_event_log facility
  receiver_adaptor destination_adaptor_mapping intelligence_delivery intelligence_delivery_audit_log
  notification_tracker"
RESTORE_TABLES="facility receiver_adaptor destination_adaptor_mapping intelligence_delivery
  intelligence_delivery_audit_log notification_tracker"
```
Without the intelligence service (see "The settings for each release"):
```bash
SERVICES="cce-matcher-service cce-step-sla-service"
DROP_TABLES="matcher_event_log protocol_instance protocol_instance_history step_instance
  step_instance_history step_sla_state_transition deviation intelligence_event_log facility"
RESTORE_TABLES="facility"
```

**UAT, upgrade 1.x → 2.0** (`upgrade-1x-to-2x/replay/replay-uat-upgrade.env`, for part **U**):
```bash
DEPLOYMENT_NAME=rw-uat
PLATFORM=kubernetes
KUBECTL="k3s kubectl"
K8S_NAMESPACE=cce-uat
PG_EXEC="docker exec -i postgres-uat"
KAFKA_EXEC="docker exec -i kafka-uat"
KAFKA_BOOTSTRAP=localhost:9092
CONNECT_EXEC="docker exec -i cce-kafka-connect"
CONNECT_URL=http://localhost:8083
STATE_DIR=/root/cce-replay/rw-uat
DATA_PIPELINE_DIR=/home/cceadmin/cce-2x/data-pipeline    # the 2.0 data-pipeline (U1)
# ClickHouse address and password: from Infisical (R runs the script under rw/lib/infisical-run.sh uat)
INSIGHTS_SERVICES="cce-insights-service cce-insights-ui"

# the upgrade block
SERVICES="cce-matcher-service cce-protocol-service cce-step-sla-service cce-intelligence-service"
SCHEMA_ORDER="cce-protocol-service cce-matcher-service cce-intelligence-service"
CONSUMER_GROUP=cce-matcher-service
DROP_TABLES="protocol_definition action_definition trigger_index
  matcher_event_log protocol_instance protocol_instance_history step_instance step_instance_history
  step_sla_state_transition deviation intelligence_event_log facility receiver_adaptor
  destination_adaptor_mapping intelligence_delivery intelligence_delivery_audit_log notification_tracker
  compliance_event_log audit_log scheduler_lease scheduler_scan_cursor"
RESTORE_TABLES="protocol_definition action_definition trigger_index facility receiver_adaptor
  destination_adaptor_mapping intelligence_delivery intelligence_delivery_audit_log notification_tracker"
```
`R="sudo -A bash rw/lib/infisical-run.sh uat bash upgrade-1x-to-2x/replay/replay-inbound-events.sh --config upgrade-1x-to-2x/replay/replay-uat-upgrade.env"`

After the upgrade (U6), the UAT file keeps its first part and takes the 2.0 part of the dev file
above: the three lines `SERVICES`, `DROP_TABLES`, `RESTORE_TABLES`, and no `SCHEMA_ORDER` or
`CONSUMER_GROUP`.

**UAT, CCE 1.x** (a replay on 1.x, and step 4 of going back from an upgrade). The first part as
above, then:
```bash
SERVICES="cce-compliance-service cce-scheduler-service"
DROP_TABLES="compliance_event_log protocol_definition action_definition trigger_index protocol_instance
  protocol_instance_history step_instance step_instance_history deviation intelligence_event_log
  facility audit_log scheduler_lease scheduler_scan_cursor"
RESTORE_TABLES="protocol_definition action_definition trigger_index facility audit_log"
# going back from an upgrade only: ClickHouse is rebuilt with the 1.x data-pipeline (U1)
# DATA_PIPELINE_DIR=/home/cceadmin/cce-1x/data-pipeline
```

**A laptop, services started with `docker run`** (a local copy of CCE, 2.0; the ready-made file is
`upgrade-1x-to-2x/replay/replay-local.env`). Kafka is the Apache image, and Kafka Connect is reached
from the host on another port than inside its container. With Docker Compose instead, set
`PLATFORM=compose` and `COMPOSE_DIR` (and `COMPOSE_OPTS` if needed), as the file shows:
```bash
DEPLOYMENT_NAME=local
PLATFORM=docker
PG_EXEC="docker exec -i cce-collector-postgres"
KAFKA_EXEC="docker exec -i cce-collector-kafka"
KAFKA_TOOLS_DIR=/opt/kafka/bin
KAFKA_TOOL_SUFFIX=.sh
KAFKA_BOOTSTRAP=localhost:9092
CONNECT_EXEC="docker exec -i cce-kafka-connect"
CONNECT_URL=http://localhost:8083
CONNECT_HOST_URL=http://localhost:8084
CH_HTTP=http://localhost:8123
SECRETS_FILE=$HOME/.cce-replay-secrets.env          # CH_USER / CH_PASSWORD, mode 600
INSIGHTS_SERVICES="cce-insights-service cce-insights-ui"

SERVICES="cce-matcher-service cce-step-sla-service cce-intelligence-service"
DROP_TABLES="matcher_event_log protocol_instance protocol_instance_history step_instance
  step_instance_history step_sla_state_transition deviation intelligence_event_log facility
  receiver_adaptor destination_adaptor_mapping intelligence_delivery intelligence_delivery_audit_log
  notification_tracker"
RESTORE_TABLES="facility receiver_adaptor destination_adaptor_mapping intelligence_delivery
  intelligence_delivery_audit_log notification_tracker"
```
`R="bash upgrade-1x-to-2x/replay/replay-inbound-events.sh --config upgrade-1x-to-2x/replay/replay-local.env"`

**A laptop, upgrade 1.x → 2.0** (`upgrade-1x-to-2x/replay/replay-local-upgrade.env`, for part **U** against a local
copy of a 1.x database, e.g. a UAT dump). The first part is the laptop file's above; then the
upgrade block (as in the UAT upgrade file). With containers
started by `docker run`, U3 and U4 use the **Docker (containers by name)** commands: `docker stop` /
`docker rm` for 1.x, `docker create` for 2.0; with Compose, the Compose ones.

**Secrets on UAT and prod come from Infisical the same way as for every other rw script**
(`replay-uat.sh`, `replay-prod.sh`, `deploy-all.sh`): `rw/lib/infisical-run.sh <env>` logs in with
the environment's machine identity (credentials in `/home/cceadmin/.cce-infisical/<env>.creds`) and
runs the command with the project's secrets in its environment. The replay reads the ClickHouse user
and password from them (`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`). `infisical-run.sh` passes
`--recursive`, which matters: the secrets sit in per-component folders (`clickhouse`, `kafka-connect`,
…), and without it the ClickHouse ones would be missing. So on those servers, put `upgrade-1x-to-2x/` in
the same folder as `rw/` and `data-pipeline/` and run every command from that folder.

(The settings file can instead name a `k8s/.infisical.<env>` credentials file in
`INFISICAL_CREDENTIALS`; the script then logs in itself, also with `--recursive`. Use that only on a
server without `rw/lib/infisical-run.sh`.)

> **One server, two deployments** (UAT and prod today): the two sit on the same server, and only
> the settings file decides which one a command changes. Keep one file per deployment, as above,
> always pass `--config`, and check that step A0 prints the deployment you meant (`rw-uat` or
> `rw-prod`). The UAT file must never point at the installed Postgres on port 5432: that is prod's.
>
> When UAT moves to its own server laid out like prod, its file becomes the prod example with
> `K8S_NAMESPACE=cce-uat` and the UAT Infisical file.

### 3. Set `R`

Every command below uses `$R`:

```bash
R="bash upgrade-1x-to-2x/replay/replay-inbound-events.sh"
```

Use `R="sudo bash upgrade-1x-to-2x/replay/replay-inbound-events.sh"` if your user cannot run `docker`, `kubectl` or
`sudo -u postgres` directly. On UAT and prod use the `R` from the examples above (`sudo -A` plus
`rw/lib/infisical-run.sh`, for the secrets). Use the **same** `R` for every step: with `sudo`,
backups and progress go to root's home (`/root/cce-replay/`) unless `STATE_DIR` says otherwise, and
a step run the other way would not find them (a step run with `sudo` warns when it also finds state
from a run without).

From here on, every command runs **on the server, in that folder**, with `R` set.

---

## A. Full rebuild (all events)

Each step below has three parts: the command, **Check** (what must be true before you go on) and
**If it goes wrong**. Every step that changes something stops with a **STOP** message on its own when
a check fails; the **Check** lines are what you confirm with your own eyes.

### A0. Check the script can reach everything
```bash
$R check
```
**Check:**
- every line is `OK`, and the last line is `OK all components reachable`;
- the first lines name the deployment you meant and how each part is reached
  (`Postgres via '…', Kafka via '…', Kafka Connect via '…'`);
- `read by consumer group …` names the first service's group;
- `OK no other CCE consumer reads cce.events.inbound`;
- every service in `SERVICES` is listed and `running`. A service with neither a healthcheck nor a
  readiness probe is marked `(… its start is recognised by its log)`: that's fine.

**If it goes wrong:** a `WARN` line says what doesn't match (a setting, or a service that isn't
deployed). Fix it and run `check` again. Nothing has changed yet.
`consumer group(s) … also read cce.events.inbound with running consumers` means a service outside
`SERVICES` reads the inbound topic too (e.g. 1.x compliance left running next to 2.0 Matcher): it
would process the replayed events against its own tables. Stop it or add it to `SERVICES`;
`prepare` and `publish` refuse while it runs.
`the data-pipeline captures tables this database does not have` means `DATA_PIPELINE_DIR` is another
release's data-pipeline: point it at the deployed one.

### A1. Look at the current state
```bash
$R status
```
**Check:**
- every service in `SERVICES` is `running`;
- the consumer group's `lag` is `0`. If it isn't, wait a minute and run `status` again;
- write down `inbound_event_log (accepted)` and `step_instance`: you compare them in A9.

**If it goes wrong:** fix a service that isn't `running` first (`$R service start <name>`,
`$R logs <name>`, e.g. `$R logs cce-step-sla-service`). Nothing has changed yet.

### A2. See what will happen (changes nothing)
```bash
$R plan --mode rebuild
```
**Check:**
- `events to publish` is about the `inbound_event_log (accepted)` count from A1;
- `database size` and the free space for the backup: the backup needs roughly the database's size;
- the stop and start order, the tables to drop (those with `(data restored)` get their data back)
  and the topics to empty are what you expect;
- there's no `WARN`.

**If it goes wrong:** `events to publish 0` means there is nothing to replay: stop here. A `WARN`
about open alert incidents means `prepare` would refuse: wait until they are resolved. Nothing has
changed yet.

### A3. Back up the database
```bash
$R backup
```
**Check:** `OK backup written: <size>  <file>`, e.g.
`OK backup written: 38M  /home/ubuntu/cce-replay/dev/ccedb_before_replay_20260928_091500.dump`.
The size is roughly the database's size (not a few KB). Write down the file name: its time
(`ccedb_before_replay_<YYYYMMDD_HHMMSS>.dump`, UTC; here 28 Sep 2026 09:15:00) is the point a revert
goes back to.

**If it goes wrong:** usually a full disk (`df -h ~`). Free space and run `backup` again. Nothing has
changed yet. The next step refuses to run without a backup less than 6 hours old.

### A4. Prepare: stop services, rebuild the tables, clear Kafka
```bash
$R prepare --mode rebuild --yes
```
This does steps 1–6 of "What a rebuild does": it stops the services, moves `DROP_TABLES` aside, empties
CCE's output topics, has each service create its tables again (in `SCHEMA_ORDER`), empties those
tables and puts the data back into `RESTORE_TABLES`. It also pauses the Debezium connector
(ClickHouse is rebuilt in A8). It does **not** take the cutoff or touch `cce.events.inbound`: A5 does,
right before sending, so events arriving in between are replayed in order.

On Kubernetes, "stop" scales the deployment to 0 and waits until its pods are gone. The script saves
the replica count and any autoscaler (HPA) first, and puts both back when it starts the service
again. Don't re-apply the manifests (`kubectl apply`, `deploy-*.sh`) while a replay runs: that would
start the stopped services again.

**Check:** the step prints:
- `OK moved: …`, with the tables `plan` listed;
- if the dead-letter topic held records: `saved the N record(s) of cce.events.inbound.dlq to …`;
- for each service, `OK <service> started; created: …`, e.g.
  `OK cce-matcher-service started; created: flyway_schema_history_matcher protocol_instance matcher_event_log …`
  (Step SLA creates no tables, so its line is just `OK cce-step-sla-service started`);
- upgrade only: possibly `WARN cce-protocol-service created its tables but did not start …` (expected,
  see "Before a rebuild");
- `OK emptied what the services produced while they were up`;
- `OK emptied the rebuilt tables …`;
- possibly `not created by any of SERVICES, put back as they were: …`. That's expected for a table
  the deployed image doesn't create (e.g. the 1.x-only tables in an upgrade);
- `OK <table>: N rows restored` for each of `RESTORE_TABLES`, where N is the count `plan` listed, e.g.
  `OK facility: 72 rows restored`;
- finally `OK ready to publish. The cutoff is taken by 'publish' …`.

Then `$R status` shows the services `stopped`, the rebuilt tables empty except `RESTORE_TABLES`,
`mode=rebuild cutoff=` (empty until A5) and `old tables kept in schema replay_old`.

If `prepare` stops with `<service> could not create its tables` (e.g.
`cce-matcher-service could not create its tables: it failed to start`), it prints the reason and the
lines of the service's log that explain it (e.g. `column s.missed_date does not exist`: the Matcher
image lacks the V2 fix). Nothing is lost: the old tables are still in `replay_old`. Run **Revert**
(an upgrade: `revert --yes --no-start`), fix the reason ("Before a rebuild" above), and start again
from A3.

**If it goes wrong:** from here on, data has changed. Undo with **Revert** below, fix the cause,
and start again from A3.

### A5. Publish the events and start the first service
```bash
$R publish
```
First it takes the **cutoff**: it notes where `cce.events.inbound` ends, records the time, and
deletes the topic's records up to the noted positions (every one of them was received before the
cutoff, so it is replayed; nothing is lost). Then it sends every accepted event received before the
cutoff, oldest first, exactly as the collector sent it. Envelope fields that older collector versions
kept only in their own columns (`id`, `source`, `specversion`) are filled in from those columns.
Then it lists the patients a live event may have overtaken, and starts the first service.

Why here and not in A4: every live event that arrived since A4 is in `inbound_event_log`, so taking
the cutoff at the last moment sends it in order with the history. Taken earlier, those events would
sit in the topic ahead of the history and be processed first.

**Check:** `OK cutoff = …`, then `OK published N events (topic grew by M; any extra are live events)`,
where N equals `events to publish` from A2 plus events received since, then either
`OK no live event arrived for a replayed patient ahead of their history` or a `WARN` naming a file of
patients to check in A9, then `OK started`.

**If it goes wrong:**
- STOP before `Publishing N events` was printed: nothing was sent (the inbound topic may have been
  emptied, but every event deleted from it is in `inbound_event_log`). Fix the cause and run
  `publish` again: it takes a new cutoff;
- STOP after that (some events may have been sent, e.g. `The producer could not send some events`):
  **Revert**, then start again from A3. The script refuses a second `publish` after the same
  `prepare`, so events are never sent twice. The producer's log is in
  `<STATE_DIR>/publish-producer.log`;
- STOP after `OK published` (only the service failed to start): `$R service start <name>`
  (e.g. `$R service start cce-matcher-service`), then go on with A6.

### A6. Wait for it to finish
```bash
$R wait
```
Prints progress every 15 seconds: `lag=` falls to 0 and the number of processed events climbs to the
published count. It also shows the WAL Postgres keeps for the paused CDC connector, which grows until
A8. Pressing Ctrl-C is safe: run the command again to keep watching.

**Check:** `OK <first service> has caught up (lag 0 for a minute). cce.events.inbound.dlq now holds 0 records.`,
e.g. `OK cce-matcher-service has caught up (lag 0 for a minute). cce.events.inbound.dlq now holds 0 records.`

**If it goes wrong:**
- lag doesn't fall: `$R logs <first service>` (e.g. `$R logs cce-matcher-service`) shows why
  (e.g. the database is unreachable). Once fixed, the service continues where it stopped; run `wait`
  again;
- the dead-letter topic holds records: the service gave up on those events. A few can be looked at
  afterwards (A7 keeps them and saves a copy); many mean something is wrong: **Revert**. Events that
  point at a specific protocol instance (`actionid` + `protocolinstanceid`) end up there after a
  rebuild: the instance they name no longer exists;
- `STOP <service> was started during the replay …`: only the first service may run until A7. A
  deadline service started by hand (or by a re-applied manifest) judges steps whose completing event
  is still in the topic, and records false OVERDUE / MISSED deviations that can't be told apart from
  real ones. **Revert**, then start again from A4. Until A7, don't start, restart or re-deploy any
  CCE service.

### A7. Finish: start the other services
```bash
$R finish --yes
```
Throws away what the replayed events produced for the other services, then starts them. The
dead-letter topic is kept: if it holds records, `finish` prints
`WARN cce.events.inbound.dlq holds N record(s) …` and saves a copy to
`<STATE_DIR>/dlq-after-replay-<time>.txt` (time, headers with the error, key and value of each).

**Check:** `OK started`, and `$R status` shows every service `running`. Within a minute or two the
deviation count climbs: the deadline service's first run judges every deadline that has already
passed, so a burst of OVERDUE / MISSED deviations is expected.

It starts nothing, and stops, while `publish` hasn't finished, while the first service still has lag,
or when one of the other services is already running. Run it only after A6 reports caught up: the
deadline service judges each deadline against the steps as they are when it runs, so a step whose
completing event hasn't been processed yet would get a false OVERDUE / MISSED, with a deviation.

**If it goes wrong:** a service that doesn't start: `$R logs <name>`, then `$R service start <name>`
once fixed (e.g. `$R logs cce-step-sla-service`, then `$R service start cce-step-sla-service`).
`STOP … is running; it may already have acted on what the replayed events produced`: a service was
started by hand (or by a re-applied manifest) during the replay, and its verdicts may be wrong.
**Revert**, then start again from A4.

### A8. Rebuild ClickHouse (Insights data)
```bash
$R rebuild-clickhouse --yes
```
First it checks that `DATA_PIPELINE_DIR` belongs to the deployed release (it stops, changing nothing,
if the pipeline captures tables the database doesn't have). Then it saves the Debezium connector's
configuration, and:
1. **stops Insights** (`INSIGHTS_SERVICES`: `cce-insights-service`, `cce-insights-ui`). Insights reads
   ClickHouse, which is about to be dropped and copied again; left running, the dashboard would show
   errors and then partial numbers while the copy runs;
2. removes the connector and its replication slot;
3. drops the ClickHouse database and empties the `cce.public.*` topics;
4. re-applies the CDC settings;
5. applies the ClickHouse schema from the deployed release's data-pipeline;
6. creates the connector again. Its tables come from the data-pipeline's connector file; its
   connection details come from the saved configuration. The connector then copies the rebuilt
   Postgres data into ClickHouse;
7. **waits for that copy to settle**, **backfills past days of the daily compliance KPIs**
   (`schema/09`, see below), **then starts Insights** (only the Insights services that were running
   in step 1). Settled means: Debezium reports its snapshot done and ClickHouse only grows at the rate
   of live events, or ClickHouse's row count is unchanged for 45 seconds; it waits up to
   `CH_SETTLE_MINUTES` (default 30). Each check prints `rows in ClickHouse: N (snapshot running|done)`.

**Why the backfill (`schema/09`, run on every ClickHouse rebuild):**
- the daily compliance KPIs (`mv_daily_compliance_kpis`) are a snapshot the live view takes of *today*
  only, so a freshly rebuilt ClickHouse has no past days for them. `schema/09` rebuilds every day from
  the first `inbound_event_log` date to today from the records' own clinical and deadline times
  (`enrolled_at`, `completed_at`, the SLA thresholds), not from when rows were written, so past days
  are right after a replay too;
- it also refills the current-state rollups (`rollup_*_current`) that the live view reads: after a
  rebuild the snapshot can miss them, and the live view would then write no row at all.

The other daily KPIs need no backfill: they are computed from the clinical event date and rebuild
themselves.

**Check:** steps `1/7` to `7/7` each end with `OK`, the schema lines show no `ERROR`, the backfill
prints `4 statement(s) sent, 0 failed` (3 rollup refills and the past days) and `OK backfill done`, and
the last line is
`OK Insights started`. A backfill failure is only a `WARN` (Insights still starts): fix the cause and
run `$R backfill-clickhouse`, which is safe to repeat. If it prints `WARN the copy had not settled …`,
the backfill was not run and Insights is left stopped: wait until `verify` (A9) shows `— match`, then
`$R backfill-clickhouse`, `$R service start cce-insights-service` and
`$R service start cce-insights-ui`.

**If it goes wrong:** Postgres is already complete, only Insights is affected. Fix the cause and run
`rebuild-clickhouse --yes` again: it is safe to repeat and keeps the saved connector configuration.

### A9. Verify the end result
Wait about 5 minutes after A8, then:
```bash
$R verify
```

| Line | Must show |
|---|---|
| `accepted events never processed` | `0` (B: the events left out on purpose) |
| `lag of <consumer group>` (e.g. `lag of cce-matcher-service`) | `0` |
| `records in cce.events.inbound.dlq` | `0` |
| `steps (CDC check)` | `— match` (if it says "not yet equal", wait a few minutes and run `verify` again) |
| `CDC connector` | `"state":"RUNNING" "state":"RUNNING"` |
| SERVICES | all `running` |

The row counts of `DROP_TABLES` are printed too. Compare with A1: `inbound_event_log (accepted)` is
the same or higher (new events arrived), and `step_instance` is about the same. A big drop means
events were not matched: look at the DLQ copy and the first service's log before deciding to
**Revert**.

If A5 printed a `WARN` about patients a live event may have overtaken, look at each patient in
`<STATE_DIR>/publish-window-subjects.txt` (their protocol instances and steps). The list is usually
empty; a patient whose state looks wrong can be put right by a new rebuild.

Then open Insights and check that the Dashboard, Compliance and a patient's journey load. A browser
that showed the old data may need a hard refresh (Ctrl+Shift+R).

**If it goes wrong:** **Revert**.

### A10. Write the report to share
```bash
$R report
```
Writes a markdown file comparing the numbers from just before A4 (`prepare` saved them) with now:
events processed, rows per table, enrolments per protocol, steps by status and deadline verdict,
deviations by type, processed events by result (e.g. `ZERO_MATCH`). It adds the likely reason for
each difference and the errors the services logged during the replay. Changes nothing, and can be run again
at any time after A9. Read it before A11: once the old tables are removed, **Revert** can no longer go
back to them.

**Check:** `OK report written: <STATE_DIR>/replay-report-<time>.md`. Paste the file as it is into a
ticket, chat or doc.

### A11. Remove the old tables
Once A9 is good and the A10 report has been read, and not before:
```bash
$R drop-old-tables --yes
```
Deletes schema `replay_old` with the old tables in it.

**Check:** `OK dropped`, and `$R status` no longer mentions `replay_old`.

**If it goes wrong:** nothing to undo. After this step `revert` can no longer go back to the old
tables; only the A3 backup file can (`restore --file`, under **Revert**). A new rebuild refuses to
start while `replay_old` exists, so this step can't be skipped by accident.

---

## B. Rebuild from a date range

Same as A, but only events **received in the range** are replayed. Everything received before
`--from` (or from `--to` on) is **not** rebuilt: those enrolments and steps disappear from the data,
and `verify` counts those events as `never processed`. Use this only when leaving them out is the
intention (e.g. test events sent after a moment, or events before a date known to be bad). The order
is kept as in A (the same seconds of `publish` excepted). Don't use C afterwards to put the left-out events back: they would be processed after
newer ones. To keep everything, run A.

The dates are options of `plan` and `publish`, not settings: the settings file stays the same. Do
A0, A1, A3 and A4 as they are. Then replace A2 and A5 with these (UTC; a time is optional, e.g.
`'2026-09-01 06:00'`; either end can be left out):

```bash
$R plan --mode rebuild --from '2026-09-01' --to '2026-09-15'
```
```bash
$R publish --from '2026-09-01' --to '2026-09-15'
```

Then do A6 to A11 as they are, with the same checks. `--from` is inclusive, `--to` exclusive. In A9,
`accepted events never processed` then counts the events left out on purpose, and the step count is
lower than in A1.

`--to` alone rebuilds from everything received up to a moment, e.g. to leave out test events that
were sent after it.

---

## C. Fill gaps in a date range

For events the collector accepted but that were never processed, for example after a Kafka problem.
**Nothing is dropped**: only events with no record in the first service's processed-events table
(`matcher_event_log` in 2.0, `compliance_event_log` in 1.x) are sent, so an event already processed
is never processed twice. Events outside the range, and everything already processed, are not
touched. The first service keeps running; the others pause. ClickHouse needs no rebuild (normal CDC
carries the changes).

**The order is not kept** for a patient who has a missing event *and* later activity: the missing
(older) event is processed after the newer ones already processed, so, for example, an ORDER_VIOLATION
recorded back then stays. Use C for lost events when that is acceptable; when the order matters for
those patients, run A instead. Because the first service keeps processing live events
while the missing ones are sent, a patient with both a gap and new activity may have their older
(missing) event handled after a newer one: see "Live events during the replay: where the order can
overlap".

Pick the range (UTC): `--from` is inclusive, `--to` exclusive; either can be left out. They are
options of `plan` and `publish`, not settings (the settings file stays the same). Use the **same**
`--from` / `--to` in `plan` and `publish`, e.g. `--from '2026-09-20 06:00'` for a time.

| Step | Command | Check |
|---|---|---|
| C1 | `$R check` | every line `OK`, right deployment |
| C2 | `$R status` | every service `running`, lag `0` |
| C3 | `$R plan --mode fill-gaps --from '2026-09-20' --to '2026-09-27'` | `events to publish` = the missing events; if `0`, stop here |
| C4 | `$R backup` | `OK backup written` |
| C5 | `$R prepare --mode fill-gaps --yes` | `OK ready to publish`; only the other services are stopped |
| C6 | `$R publish --from '2026-09-20' --to '2026-09-27'` | `OK published N events`, N = `events to publish` from C3 (fewer if part of the range is in the last 10 minutes) |
| C7 | `$R wait` | `OK … has caught up … cce.events.inbound.dlq now holds 0 records` |
| C8 | `$R finish --yes` | `OK started`; all services `running` |
| C9 | `$R verify` | `accepted events never processed` dropped by N; lag `0`; DLQ `0` |

Events from the 10 minutes before `prepare` are always left out, because they may still be on their
way. If `publish` says `--from … is not before the cutoff`, wait 10 minutes and run `prepare` again.
To catch those up too, run C3–C9 again 10 minutes later.

**If it goes wrong:** before C6 nothing has changed except the other services being paused:
`$R service start <name>` puts each back (2.0: `$R service start cce-step-sla-service` and
`$R service start cce-intelligence-service`). From C6 on, fix the cause and repeat the step, or
**Revert**.

---

## U. Upgrade 1.x → 2.0 by replay

Moves a 1.x deployment to 2.0 by **deploying 2.0 first, then replaying**: every stored event is
processed again by the 2.0 services, on a fresh 2.0 schema.

- **Kept:** protocol definitions, action definitions, trigger index, facilities, alert receivers,
  incidents and the history of the alerts already sent (`RESTORE_TABLES`).
- **Rebuilt by 2.0:** enrolments, steps, deadlines, deviations. Counts differ from 1.x (see "Good to
  know").
- **Not carried over:** 1.x-only data (`compliance_event_log`, `audit_log`, scheduler state), the
  alerts' links to the steps that raised them (`intelligence_event_log`: the steps get new ids) and
  events that never went through the collector. They stay in the A3 backup.
- **New ids:** every protocol instance and step gets a new id. A system that kept a 1.x id (e.g. from
  an alert payload) and sends it back later in `protocolinstanceid` will not find it.

| Step | What | Services |
|---|---|---|
| U1 | Get ready (before the window) | 1.x running |
| U2 | Remove 1.x | compliance, scheduler removed; collector keeps running |
| U3 | Deploy 2.0, **without starting it** | Protocol, Matcher, Step SLA, intelligence, Insights: created, stopped |
| U4 | `check` | |
| U5 | The replay: **A1–A11** | the replay starts the 2.0 services itself, in order |
| U6 | Finish | Insights, gateway, clean-up |

Why "without starting": started on the 1.x tables, the 2.0 migrations fail ("already exists") and
Matcher would read events against the wrong tables. The replay starts each service at the right
moment (A4 to build its tables, A5 Matcher, A7 the rest).

### U1. Get ready (before the window)
1. **2.0 images built and pullable:** Protocol, Matcher **with the V2 `missed_date` fix** (see "Before
   a rebuild": not yet in `release-2.0.0` or `:latest` on 2026-09-29), Step SLA, intelligence,
   Insights service and UI. Check each one pulls: `docker pull ghcr.io/openphc/cce-matcher-service:<tag>`.
   Matcher and Step SLA from `release-2.0.0` of 2026-09-30 or later count work recorded at the due-date
   instant as on time (Matcher migration V7); Step SLA must run that version before Matcher's V7 rows are
   judged, which the replay's order (Matcher alone until A7) does not break.
2. **Write down the 1.x image tags** in use now. Going back needs them.
3. **The 2.0 data-pipeline on the server**, in its own folder (e.g. `/home/cceadmin/cce-2x/data-pipeline`
   from `cce-data-pipeline` `release-2.0.0`), named in `DATA_PIPELINE_DIR`. The deploy-scripts
   `data-pipeline/` is the 1.x one; A8 refuses it against the 2.0 database.
4. **Settings file** with the upgrade block (examples under "Complete settings files": *UAT, upgrade
   1.x → 2.0* and *A laptop, upgrade 1.x → 2.0*). Set `R` to use it.
5. **A copy of the 1.x data-pipeline**, for going back only:
   `mkdir -p ~/cce-1x && git -C /opt/deployment archive f892c43 data-pipeline | tar -x -C ~/cce-1x`
6. **Gateway permissions for 2.0:** the gateway's `api_permissions` table only has rows for
   `/v1/compliance/**`. Prepare the rows for `/v1/protocol/**` (and any other 2.0 API the UIs call),
   to insert in U6.
7. **No open alert incidents** (`SELECT count(*) FROM notification_tracker WHERE status = 'ACTIVE'`
   must be 0; `plan` also warns).
8. **Protocol definitions ready for 2.0.** The replay restores the stored definitions as they are
   (`RESTORE_TABLES`) and doesn't change them. Any change a protocol needs for 2.0 is made before this
   procedure, outside it.
9. **Tell people:** no events are processed and Insights is down from U2 until A8. The collector keeps
   accepting events, so none are lost.

### U2. Remove the 1.x services
| Setup | Commands |
|---|---|
| Docker Compose | `docker compose stop cce-compliance-service cce-scheduler-service`<br>`docker compose rm -f cce-compliance-service cce-scheduler-service` |
| Docker | `docker stop cce-compliance-service cce-scheduler-service`<br>`docker rm cce-compliance-service cce-scheduler-service` |
| Kubernetes (`K="sudo k3s kubectl -n cce-uat"`) | `$K get deploy/cce-compliance-service deploy/cce-scheduler-service -o yaml > ~/cce-1x-deployments.yaml` (kept for going back)<br>`$K delete hpa cce-compliance-service cce-scheduler-service --ignore-not-found`<br>`$K delete deploy cce-compliance-service cce-scheduler-service` |

**Check:** `docker ps -a` (or `$K get deploy`) no longer lists them.

### U3. Deploy 2.0 without starting it
Every 2.0 service that creates tables needs (see "Before a rebuild"): Flyway on, a **Flyway baseline
of 0** (`CCE_FLYWAY_BASELINE_VERSION=0` for Protocol and Matcher, **not** 1, the migration path's
value; `SPRING_FLYWAY_BASELINE_VERSION=0` for intelligence) and
`SPRING_FLYWAY_BASELINE_ON_MIGRATE=true`. On Kubernetes, each Deployment's readiness probe should go
through the application (`/actuator/health`).

| Setup | Commands |
|---|---|
| Docker Compose | Put the 2.0 `docker-compose.yml` on the server, copying only files git tracks so the server's `.env` is not overwritten (from your deploy-scripts checkout: `git ls-files > /tmp/f.txt; rsync -ac --files-from=/tmp/f.txt ./ <server>:/opt/deployment/`). In `.env`: the 2.0 image of each service below and `CCE_FLYWAY_BASELINE_VERSION=0`. Then:<br>`docker compose pull cce-protocol-service cce-matcher-service cce-step-sla-service cce-intelligence-service cce-insights-service cce-insights-ui`<br>`docker compose up --no-start --no-deps cce-protocol-service cce-matcher-service cce-step-sla-service cce-intelligence-service cce-insights-service cce-insights-ui` |
| Docker | `docker rm -f` the 1.x `cce-intelligence-service`, `cce-insights-service`, `cce-insights-ui`, then create each 2.0 one with your usual `docker run` options but **`docker create`** |
| Kubernetes | `$K scale deploy cce-intelligence-service cce-insights-service cce-insights-ui --replicas=0`<br>`$K apply -f <2.0 manifests with replicas: 0>` (`k8s/` holds only 1.x manifests today) |

`--no-start` / `docker create` / `replicas: 0` all mean: the service exists but does not run.

**Check:** `$R service state cce-matcher-service` (and Protocol, Step SLA, intelligence) says
`stopped`.

### U4. Check
```bash
$R check
```
**Check:** `OK no other CCE consumer reads cce.events.inbound`, the four 2.0 services `stopped`,
`OK data-pipeline folder: <the 2.0 one>`, last line `OK all components reachable`. One `WARN` is
expected: `not in the database … matcher_event_log step_sla_state_transition` (A4 creates them).

**If it goes wrong:** `consumer group(s) cce-compliance-service also read …` means compliance still
runs (U2); `… is not deployed here` means U3 is missing; `the data-pipeline captures tables this
database does not have` means `DATA_PIPELINE_DIR` is not the 2.0 pipeline (U1). `prepare` refuses on
the first two, so nothing can be damaged.

### U5. The replay: A1–A11
Run A1 to A11 as written, with these differences:

| Step | Expect |
|---|---|
| A1 | services `stopped`, lag `-` (Matcher has read nothing yet). Fine |
| A4 | each 2.0 service `started; created: …` (Matcher's list includes `matcher_event_log`); `protocol_definition: N rows restored`; the 1.x-only tables `put back as they were … (emptied: …)`, or `compliance_event_log` `kept with them in replay_old` when 1.x `step_instance` points at it |
| A8 | ends with `Insights not started` (it was created stopped): started in U6 |
| A9 | counts are 2.0's, so they differ from A1 |

If A4 stops, go back with `$R revert --yes --no-start` (a plain `revert` recognises the upgrade and does
the same), fix the cause and start again from A3.

**A10** (`report`) shows what changed between 1.x and 2.0, with the reasons. Run **A11** only once
you're sure you won't go back.

### U6. Finish
1. **Insights:** `$R service start cce-insights-service`, then `$R service start cce-insights-ui`;
   check the Dashboard.
2. **Gateway:** the protocol API moved from compliance (`/v1/compliance/**`) to Protocol
   (`/v1/protocol/**`). Insert the `api_permissions` rows prepared in U1, and restart the gateway with
   the 2.0 configuration: Compose `docker compose up -d --no-deps gateway-service`; Kubernetes: apply
   the 2.0 gateway manifest.
3. **Kubernetes:** apply the 2.0 manifests again with their normal replicas and autoscalers.
4. **Settings file:** switch it to the 2.0 values; later replays are 2.0 replays.
5. **Clean-up, after a stable period:** the emptied 1.x tables and ledgers, and the 1.x Kafka topics
   and groups:
   ```sql
   DROP TABLE IF EXISTS compliance_event_log, audit_log, scheduler_lease, scheduler_scan_cursor,
                        flyway_schema_history_compliance, flyway_schema_history_scheduler;
   ```
   ```bash
   docker exec kafka kafka-topics --bootstrap-server kafka:9092 --delete --topic cce.scheduler.triggers
   docker exec kafka kafka-consumer-groups --bootstrap-server kafka:9092 --delete --group cce-compliance-service
   docker exec kafka kafka-consumer-groups --bootstrap-server kafka:9092 --delete --group cce-scheduler-service
   ```

### Going back to 1.x (before A11)
1. `$R revert --yes --no-start`. It puts the 1.x tables back, with their migration records exactly
   as they were, and starts nothing. (A plain `revert` does the same: it sees that the services created
   tables 1.x never had, says `this replay was an upgrade …`, and leaves `SERVICES` stopped.)
2. Remove the 2.0 services: Compose `docker compose rm -sf cce-protocol-service cce-matcher-service cce-step-sla-service`,
   Kubernetes `$K delete deploy cce-protocol-service cce-matcher-service cce-step-sla-service`.
3. Bring 1.x back with the tags from U1: compliance, scheduler, and the 1.x intelligence and Insights
   (Compose: the 1.x compose file and `.env`, `docker compose up -d --no-deps …`; Kubernetes:
   `$K apply -f ~/cce-1x-deployments.yaml` and the 1.x overlay).
4. Rebuild ClickHouse with the 1.x data-pipeline: a 1.x settings file with
   `DATA_PIPELINE_DIR=~/cce-1x/data-pipeline`, then `rebuild-clickhouse --yes` with it.
5. Catch up with **C. Fill gaps** (1.x settings), `--from` = the backup time step 1 printed.

**After A11** (the old tables are gone): `revert` stops (`… its old tables are gone …`) and changes
nothing, because the 1.x data is only in the A3 backup. Restore the whole database from it instead of
step 1:
```bash
$R restore-database --file <A3 backup file> --yes
```
It stops every CCE service (the collector too), saves the events received since the backup to a file
in `STATE_DIR`, empties CCE's Kafka topics (so 1.x doesn't process again what 2.0 already did), stops
the CDC connector and drops its slot, drops `ccedb` and creates it again from the backup, puts the
saved events back (skipping those the backup has), and starts the collector again. Everything else
stays stopped. The user in `PG_EXEC` must be allowed to drop and create the database.

**Check:** `OK <n> event(s) saved`, `OK ccedb is as it was at <backup time> UTC`, `OK <n> event(s)
added back`. Then steps 2–5 above, with `--from` = the backup time it printed. (A fill-gaps leaves out
the last 10 minutes: for events received just before the restore, run it again 10 minutes later.)

---

## Revert

Revert puts every dropped table back exactly as it was before the rebuild, and rebuilds ClickHouse
from it. Use it when a step cannot be fixed, or when the end result is wrong.

| Where it went wrong | What to do |
|---|---|
| A0–A3 (or C1–C4) | Nothing has changed. Just stop. |
| C5 (fill-gaps prepare) | `$R service start <name>` for each stopped service (2.0: `cce-step-sla-service`, `cce-intelligence-service`) |
| A4–A7, A9 (or C6–C9) | `$R revert --yes`, then catch up (below) |
| A8 only | Postgres is fine: run `$R rebuild-clickhouse --yes` again; `revert` only if it keeps failing |
| any step of **U** (the upgrade) | `$R revert --yes --no-start`, then "Going back to 1.x" in part U. A plain `revert` also leaves the 2.0 services stopped: it recognises an upgrade by the tables the services created |

```bash
$R revert --yes
```

It:
1. stops `SERVICES`;
2. empties the Kafka topics (saving the dead-letter topic's records to a file first), so no replayed
   event or its output is applied to the old data and nothing is sent out;
3. puts the old tables and migration records back from `replay_old`, in **one transaction**: if
   anything fails, nothing changes. After a fill-gaps, or once `replay_old` is gone, it restores the
   rows of `DROP_TABLES` from the backup file instead;
4. starts `SERVICES` again;
5. rebuilds ClickHouse from the restored data (as A8). The `schema/09` backfill in it restores the
   past days of the daily compliance KPIs too, because the restored history has its original dates.

`inbound_event_log` and every table not in `DROP_TABLES` are **not** touched: every event received
during and after the replay stays in `inbound_event_log`.

If the deployed image carries a changed migration file (for example a fix deployed for this replay),
revert records the new file's checksum in the old migration record and says so
(`recording their new checksums`), as `flyway repair` would; otherwise the service would refuse to
start.

**Check:** `OK reverted. Data is as it was at <backup time> UTC`, e.g.
`OK reverted. Data is as it was at 2026-09-28 09:15:00 UTC`. Then `$R verify` shows lag `0`,
DLQ `0`, all services `running` and, after a few minutes, `steps (CDC check) — match`.

**Catch up:** the restored data doesn't include events received after the backup. Ten minutes after
the revert, process them with **C. Fill gaps**, using the `--from` time the revert printed (the
backup's time) and no `--to`. After that, `verify` shows `accepted events never processed 0`. (Run
earlier, fill-gaps leaves out the last 10 minutes; run it again later for those.)

**`--no-start`** (`$R revert --yes --no-start`) puts the tables back the same way but leaves
`SERVICES` stopped, does not rebuild ClickHouse, and leaves the old migration records exactly as they
were (no checksum is changed: the old release comes back and checks them against its own files). It
is for going back from an upgrade (part U), where `SERVICES` are the new release and must not run on
the old tables. `revert` and `restore` switch to it by themselves when the replay was an upgrade: the
services created tables the old data never had (e.g. `matcher_event_log`), and they print
`this replay was an upgrade …`.

**If revert itself stops:** fix what the STOP message says and run `revert --yes` again. Every part
is safe to repeat. To restore from a specific backup file: `$R restore --file <backup file> --yes`,
then `$R rebuild-clickhouse --yes`, e.g.
`$R restore --file ~/cce-replay/dev/ccedb_before_replay_20260928_091500.dump --yes`.

Other commands that help:

| Command | Does |
|---|---|
| `$R logs <service>` (e.g. `$R logs cce-matcher-service`) | the service's recent log (on Kubernetes: every pod's) |
| `$R service state\|start\|stop <service>` (e.g. `$R service state cce-step-sla-service`) | one service, on any platform (`stop` waits until its process has exited) |
| `$R status` | services, row counts, WAL kept for CDC, lag, DLQ, replay progress |
| `$R report` | before/after counts with reasons, as markdown to share (A10) |
| `$R restore-database --file <backup> --yes` | the whole database back from a backup, keeping the events received since (going back after A11 of an upgrade) |
| `$R backfill-clickhouse` | past days of the daily compliance KPIs from the history (`schema/09`); run by A8, safe to repeat |

## Good to know

- **Deadlines are judged at replay time.** Deviations raised by the replay carry the replay's date as
  their "detected" time, and the deadline service's first run judges every old deadline at once.
- **Past days' compliance KPIs follow the clinical dates.** A replay writes every history row and
  deviation on the replay day, but `schema/09` (A8) does not use those write times: it dates each past
  day by the records' own `enrolled_at`, `completed_at` and SLA thresholds, and each deviation by the
  deadline it breached (as the Deviations page does). So the daily compliance history after a replay
  shows the same days it would have shown in live running. One approximation: a step created ahead of
  time for a deadline after day D is counted from that deadline, so past days' `step_not_started`
  reads a little low. The other daily KPIs (events, deviations page, adoption, referrals) are computed
  from the clinical event time and rebuild themselves within a minute. ClickHouse keeps only 90 days of
  event-log rows, as in normal running.
- **The current protocol versions are used.** Old events are matched against the protocols loaded
  today, not the ones in force when the events first arrived. A replay can match events that were
  not matched before (a protocol loaded later), and the other way round. On the rw-uat copy of
  2026-09-28, for example, 1.x enrolled patients only from 15 July, while a replay matches every event
  since June against today's protocol and enrols more patients.
- **Only `inbound_event_log` is replayed.** Anything that reached the services without going through
  the collector (e.g. test events sent straight to Kafka) is not rebuilt.
- **Past deliveries are not sent again.** Their records (`intelligence_delivery` and its audit log) are
  put back as history when they are in `RESTORE_TABLES`, as in the examples; `intelligence_event_log`
  is rebuilt empty, because it points at enrolments and steps that get new ids.
- **Replay progress** (mode, cutoff, published count), backups, the DLQ copies and the list of
  patients to check are kept in `STATE_DIR` (default `~/cce-replay/<DEPLOYMENT_NAME>`, e.g.
  `~/cce-replay/dev/`). `status` shows it.
- **Kubernetes:** the services must exist as Deployments in the namespace under the names in
  `SERVICES`, and an autoscaler, if any, must have the same name as its Deployment. `check` lists
  each one as `running`, `stopped` or `absent`. Don't re-apply manifests while a replay runs.
- **Docker Compose:** a name in `SERVICES` is the Compose service's name; its container may be named
  otherwise. The replay starts existing containers as they are (`docker start` on the service's
  container; `docker compose up -d --no-deps` only for a service that has no container yet).
- **Only CCE's topics and consumer groups are touched:** topics matching `TOPIC_PATTERN` (`^cce\.`)
  and groups matching `GROUP_PATTERN` (`^cce-`). On a server whose Kafka broker other applications
  share, their topics and groups are left alone.
- **Kafka with SASL/TLS:** set `KAFKA_CLIENT_CONFIG` to a client properties file where the tools run;
  every Kafka tool gets it.

## Where each planned step is done

| Planned step | Runbook step |
|---|---|
| 1. Stop Matcher and Step SLA (the services) | A4 `prepare` (stops `SERVICES`, rebuilds their tables) |
| 2. Clean the Kafka topic | A4 `prepare` (CCE's output topics), A5 `publish` (`cce.events.inbound`, right before sending) |
| 3. Insert the data into the Kafka topic | A5 `publish` (takes the cutoff first) |
| 4. Start the Matcher service (the first service) | A5 `publish` |
| 5. Wait for the Kafka lag to clear | A6 `wait` |
| — then | A7 `finish` (the other services), A8 ClickHouse, A9 checks, A10 report, A11 cleanup |

## Tested

On 2026-09-29, on a laptop copy of the rw-uat (1.x) database with the 2.x images, Kafka 3.8,
Debezium 3.0 and ClickHouse 26.3, all on Docker Compose, and live events arriving throughout:
the 1.x → 2.0 upgrade (A0–A11), going back from a failed and from a finished upgrade
(`revert --no-start`), the upgrade again with `publish --to`, a 2.0 rebuild, `revert --yes`, and
`fill-gaps --from`. Kubernetes and installed (non-container) Postgres/Kafka were not part of it: run
UAT before prod.
