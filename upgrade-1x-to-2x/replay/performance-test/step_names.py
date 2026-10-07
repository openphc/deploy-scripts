"""Plain-language names for the replay steps, shared by both perf reports.

The keys are the labels replay-perf-test.sh writes to each run's steps.tsv and to history.tsv (the
runbook's step codes). They stay as they are, so new reports still compare with earlier runs; only
what the reports print changes. "Matcher" is the first service in SERVICES (Matcher in CCE 2.0), the
one that re-processes the events.
"""

# key: (name shown in the reports, what the step does, what its time depends on)
STEPS = {
    "A0 check": (
        "Check access",
        "Confirms the script can reach Postgres, Kafka, Kafka Connect, ClickHouse and every service. "
        "Changes nothing.",
        "fixed: a few seconds"),
    "A2 plan": (
        "Plan (dry run)",
        "Counts the events to replay and lists the tables, topics and services it will touch. "
        "Changes nothing.",
        "fixed: a few seconds"),
    "A3 backup": (
        "Back up the database",
        "Dumps the whole CCE database to a file: the restore point if the replay is undone.",
        "the database size"),
    "A4 prepare": (
        "Prepare empty tables",
        "Stops Matcher, Step SLA and intelligence; moves the tables they build aside; starts each "
        "service once so its migrations create the tables again, empty; puts protocol definitions and "
        "facilities back; empties the services' output topics.",
        "mostly fixed: starting and stopping each service (1-2 minutes in total)"),
    "A5 publish": (
        "Re-send stored events to the inbound topic",
        "Takes the cutoff, empties cce.events.inbound up to it, sends every accepted event from "
        "inbound_event_log back onto it, oldest first, sets Matcher to read it from the start and "
        "starts Matcher.",
        "the number of events (sending is fast), plus a fixed setup"),
    "A6 wait (first service)": (
        "Matcher re-processes the events",
        "Matcher reads every replayed event and rebuilds enrolments, steps and deadlines. Ends once "
        "Matcher has had nothing left to read for one minute.",
        "the number of events: the main cost per event; plus that one-minute check"),
    "A7 finish": (
        "Start Step SLA and intelligence",
        "Throws away what the replayed events produced for the other services (so no alert is sent "
        "again), then starts Step SLA and intelligence.",
        "fixed: a few seconds"),
    "A7+ deadline sweep": (
        "Step SLA judges every past deadline",
        "Step SLA's first run: every deadline already past gets its verdict (met, overdue, missed) and "
        "any deviation. Timed until no deadline is left to judge.",
        "the number of steps with a deadline"),
    "A8 rebuild-clickhouse": (
        "Rebuild the Insights data (ClickHouse)",
        "Stops Insights, drops its ClickHouse database, applies the schema again, copies all Postgres "
        "data across again (a fresh CDC snapshot), fills in the past daily figures, starts Insights.",
        "mostly fixed (schema, connector, a 45-second settle check), plus the rows to copy"),
    "A9 verify": (
        "Verify the result",
        "Checks every event was processed, nothing is in the dead-letter topic, and Postgres and "
        "ClickHouse hold the same steps.",
        "fixed: a few seconds"),
    "A10 report": (
        "Write the before/after report",
        "Writes the comparison of the numbers before and after the replay.",
        "fixed: a few seconds"),
    "A11 drop-old-tables": (
        "Delete the old tables",
        "Deletes the tables set aside in 'Prepare empty tables' (after this the replay can't be undone "
        "from them).",
        "the size of the old tables"),
}


def name(key):
    """The plain-language name, with the runbook step code in brackets, e.g.
    'Matcher re-processes the events (A6)'."""
    entry = STEPS.get(key)
    return f"{entry[0]} ({key.split()[0]})" if entry else key


def legend(keys, out=print):
    """A table explaining each step in keys, for readers who don't know the runbook."""
    out("| Step | What it does | Its time depends on |")
    out("|---|---|---|")
    for key in keys:
        if key in STEPS:
            title, what, time = STEPS[key]
            out(f"| {name(key)} | {what} | {time} |")
