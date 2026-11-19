# RW CCE: loading and managing care protocols

How to load a care protocol (a FHIR PlanDefinition) into CCE, check that it is in use, and retire, delete or replace it. The
same steps work on UAT and PROD; only the namespace differs.

| | UAT | PROD |
|---|---|---|
| Machine | 102.215.10.21 | 102.215.10.20 |
| Namespace | `cce-uat` | `cce-prod` |

Every command runs on the machine, in `~/deploy-scripts`.

## What a protocol is, and where it lives

A protocol says which clinical events enrol a patient and which steps are expected afterwards, with their deadlines. CCE
measures every patient against the protocols that are **ACTIVE**. Without an active protocol, events are stored but nothing is
matched: no journeys, no steps, no deviations, and the Insights compliance pages stay empty.

| Item | Value |
|---|---|
| The Rwanda protocol | [`rw/protocols/emr-service-protocol.json`](../protocols/emr-service-protocol.json) |
| Its identity | "Rwanda Health Center Patient Journey", url `http://openphc.org/PlanDefinition/emr-service-protocol`, version `1.0.0` |
| Where it is loaded | UAT since 2026-11-11. PROD: at install ([`prod/INSTALL-GUIDE.md`](prod/INSTALL-GUIDE.md), step 10) |
| Service that loads it | `cce-protocol-service`. It checks the definition, stores it and builds the **trigger index** (10 rows for this protocol) |
| Service that uses it | `cce-matcher-service`. It re-reads the active protocols **every 60 seconds** (`CCE_PROTOCOL_REFRESH_INTERVAL_MS`), so no restart is needed |

Keep the file in `rw/protocols/` identical to what is loaded, so that UAT and PROD run the same definition.

A protocol applies only to events the matcher sees **after** it is loaded. Load it before OpenHIM starts sending events. To
apply a new protocol to events already received, see [Replace a protocol](#replace-a-protocol).

## How to reach the protocol API

The API is `/v1/protocol/protocol-definitions` on `cce-protocol-service`. Inside the cluster it needs no token, and the machine
itself can reach the service's cluster address, so every box below starts by looking that address up:

```sh
NS=cce-prod                                       # cce-uat on UAT
B=http://$(sudo k3s kubectl -n $NS get svc cce-protocol-service -o jsonpath='{.spec.clusterIP}'):8080/v1/protocol/protocol-definitions
```

Through the public gateway (`https://<host>/v1/protocol/...`) the same API needs a token with the `COMPLIANCE_WRITE` role, which
no user has today. Use the cluster address.

## Load a protocol

**1. Load it.** Set `NS` to the environment's namespace, then paste the whole box:

```sh
cd ~/deploy-scripts
NS=cce-prod                                       # cce-uat on UAT
FILE=rw/protocols/emr-service-protocol.json
B=http://$(sudo k3s kubectl -n $NS get svc cce-protocol-service -o jsonpath='{.spec.clusterIP}'):8080/v1/protocol/protocol-definitions
python3 -c 'import json,sys; print(json.dumps({"planDefinitionJson": open(sys.argv[1]).read()}))' "$FILE" \
  | curl -s -o /tmp/pd-load.json -w 'HTTP %{http_code}\n' -X POST -H 'Content-Type: application/json' --data-binary @- "$B"
python3 -c 'import json; d=json.load(open("/tmp/pd-load.json")); print(d.get("canonical"), d.get("status"), d.get("id")) if "id" in d else print(d)'
rm -f /tmp/pd-load.json
```

**You should see:**

```
HTTP 201
http://openphc.org/PlanDefinition/emr-service-protocol|1.0.0 ACTIVE <id>
```

Note the `<id>`: retiring or deleting the protocol later needs it.

| If you see | It means | Do |
|---|---|---|
| `HTTP 400` and `Protocol definition already exists for url=…, version=…` | this url and version are already loaded. Nothing was changed | nothing, if it is the same file. To load a changed definition, raise its `version` first |
| `HTTP 400` or `HTTP 422` with another message | the definition was rejected (for example a trigger that can never match). Nothing was stored | fix the file; the message names the problem |
| `HTTP 000` | the service is not running, or `NS` is wrong | `sudo k3s kubectl -n $NS get pods \| grep protocol`, then paste the box again |

**2. Check the trigger index.**

```sh
sudo -u postgres psql -tA -d ccedb -c "select count(*) || ' trigger index rows' from trigger_index"
```

**You should see** `10 trigger index rows` for the Rwanda protocol, if it is the only one loaded. `0` means the index was not
built: [rebuild it](#other-operations).

**3. Check the matcher has picked it up.** Wait about a minute, then:

```sh
sudo k3s kubectl -n $NS logs deploy/cce-matcher-service --since=5m | grep 'Protocol cache refresh' | tail -1
```

**You should see** `Protocol cache refresh: 1 definition(s) loaded or reloaded, 0 dropped, 1 active`. If nothing is printed,
wait another minute and run it again. To force it, restart the matcher:
`sudo k3s kubectl -n $NS rollout restart deploy/cce-matcher-service`.

## List the loaded protocols

```sh
NS=cce-prod                                       # cce-uat on UAT
B=http://$(sudo k3s kubectl -n $NS get svc cce-protocol-service -o jsonpath='{.spec.clusterIP}'):8080/v1/protocol/protocol-definitions
curl -s "$B" | python3 -c '
import json,sys
for p in json.load(sys.stdin)["content"]: print(p["status"], p["canonical"], p["id"], p["loadedAt"])'
```

One line per protocol: status, `url|version`, id, and when it was loaded.

## Other operations

Set `NS` and `B` as in [How to reach the protocol API](#how-to-reach-the-protocol-api), then:

| To… | Command | Result |
|---|---|---|
| see one protocol | `curl -s $B/<id>` | the protocol, with its full definition |
| find by url (all versions) | `curl -s -G $B/by-url --data-urlencode url=<url>` | a list |
| find by url and version | `curl -s -G $B/by-url-version --data-urlencode url=<url> --data-urlencode version=<version>` | one protocol, or 404 |
| **retire** it: stop new enrolments, keep the history | `curl -s -X POST $B/<id>/retire` | status `RETIRED`; 409 if it already was |
| rebuild its trigger index | `curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/<id>/rebuild-index` | `200` |
| **delete** it, with its trigger index | `curl -s -o /dev/null -w '%{http_code}\n' -X DELETE $B/<id>` | `204`; **409** while any patient is enrolled in it |

The matcher drops a retired or deleted protocol at its next refresh, within a minute.

**Retire, don't delete,** a protocol that patients are enrolled in: retiring keeps their journeys and deviations. Delete only a
protocol nobody is enrolled in, or as part of [Replace a protocol](#replace-a-protocol), which empties the enrolments first.

Intelligence actions (FHIR ActivityDefinitions) have the same kind of API at `/v1/protocol/action-definitions`. The Rwanda
protocol uses none.

## Replace a protocol

There are two ways, depending on what should happen to the events already received.

- **Only new events follow the new protocol.** Give the new definition a new `version`, load it, then retire the old one.
  Patients already enrolled keep their old journeys.
- **Re-evaluate every event against the new protocol.** Empty what the matcher derived, delete the old protocol, load the new
  one and replay `cce.events.inbound` through the matcher. Kafka keeps events for 7 days only, so check first that the topic
  still holds all of them. The full procedure, done on UAT on 2026-11-11, is in
  [`uat/OPERATIONS-RUNBOOK.md`](uat/OPERATIONS-RUNBOOK.md) §12, "Replace the protocol and re-run every event through the
  matcher". During a replay, keep `cce-step-sla-service` stopped until the matcher has caught up
  ([`ARCHITECTURE.md`](ARCHITECTURE.md) §8.4, "Event Replay").

After either, copy the new file into `rw/protocols/` and commit it, so the other environment can be given the same definition.
