#!/usr/bin/env python3
"""Step-load report of replay-perf-test.sh 'suite': how the replay scales with the number of events.

Usage (by replay-perf-test.sh): suite-report.py <suite .runs file> <perf dir> "<sizes to estimate>" <deployment>
Each line of the .runs file is "size|repeat|run stamp"; each run has run-<stamp>/steps.tsv and
perf-report-<stamp>.md in the perf dir.
"""
import os
import re
import statistics as st
import sys

from step_names import STEPS, legend, name

runs_file, perf_dir, project, deployment = sys.argv[1:5]
STEP_KEYS = ["A4 prepare", "A5 publish", "A6 wait (first service)", "A7+ deadline sweep", "A8 rebuild-clickhouse"]


def hms(seconds):
    s = int(float(seconds) + .5)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


def load_run(size, repeat, stamp):
    run_dir = os.path.join(perf_dir, f"run-{stamp}")
    steps = {}
    for line in open(os.path.join(run_dir, "steps.tsv")):
        if line.strip():
            label, secs, _ = line.rstrip("\n").split("|")
            steps[label] = float(secs)
    report = open(os.path.join(perf_dir, f"perf-report-{stamp}.md")).read()
    events = int(re.search(r"\*\*([\d,]+) accepted events\*\*", report).group(1).replace(",", ""))
    rate = re.search(r"\*\*([\d,]+) events/s\*\*", report)
    never = re.search(r"accepted events never processed: (\S+)", report)
    dlq = re.search(r"records in the inbound DLQ: (\S+)", report)
    cdc = re.search(r"steps Postgres / ClickHouse: (.+)", report)
    peaks = {m.group(1): (float(m.group(2)), m.group(3).strip())
             for m in re.finditer(r"\| (cce-[\w-]+) \| (\d+) % \| \d+ % \| ([^|]+) \|", report)}
    return dict(size=int(size), repeat=int(repeat), stamp=stamp, events=events, steps=steps,
                total=sum(steps.values()), rate=int(rate.group(1).replace(",", "")) if rate else 0,
                never=never.group(1) if never else "?", dlq=dlq.group(1) if dlq else "?",
                cdc_match=bool(cdc and "match" in cdc.group(1)), peaks=peaks)


runs = [load_run(*line.strip().split("|")) for line in open(runs_file) if line.strip()]
totals_by_events = {}
for run in runs:
    totals_by_events.setdefault(run["events"], []).append(run["total"])
sizes = sorted(totals_by_events)
out = print

out(f"# Replay step-load test: {deployment}")
out()
out(f"The same full rebuild (runbook part A, A0–A11) at {len(sizes)} size(s). The synthetic events are copies of")
out("the stored ones, each copy a new set of patients and ids, so every size has the same mix of event types.")
out()
out("## The steps")
out()
out("Each step of the replay, in the order it runs. The runbook step code is in brackets.")
out()
timed = [key for key in STEPS if any(key in run["steps"] for run in runs)]
legend(timed, out)
out()
out("## Results per size")
out()
out("Total and each step in h:mm:ss. Steps not shown (check, plan, backup, verify, report, delete the old")
out("tables) take a few seconds each.")
out()
out("| Events | Run | Total | " + " | ".join(name(key) for key in STEP_KEYS) + " | Matcher events/s | Checks |")
out("|---:|---:|---:|" + "---:|" * len(STEP_KEYS) + "---:|---|")
for run in runs:
    s = run["steps"]
    checks = ("OK" if run["never"] == "0" and run["dlq"] == "0" and run["cdc_match"]
              else f"never processed {run['never']}, DLQ {run['dlq']}, CDC {'match' if run['cdc_match'] else 'NOT equal'}")
    out(f"| {run['events']:,} | {run['repeat']} | {hms(run['total'])} | "
        + " | ".join(hms(s.get(key, 0)) for key in STEP_KEYS) + f" | {run['rate']:,} | {checks} |")
out()

if any(len(v) > 1 for v in totals_by_events.values()):
    out("## Variation between runs of the same size")
    out()
    out("| Events | Runs | Mean total | Spread (max − min) |")
    out("|---:|---:|---:|---:|")
    for events, totals in sorted(totals_by_events.items()):
        spread = max(totals) - min(totals)
        out(f"| {events:,} | {len(totals)} | {hms(st.mean(totals))} | {hms(spread)} ({spread / st.mean(totals) * 100:.0f} %) |")
    out()


def mean_step(events, key):
    return st.mean(run["steps"].get(key, 0) for run in runs if run["events"] == events)


out("## How each step scales (seconds per 1 000 events)")
out()
out("**This table is not the time each step took** (that is the table above). It divides each step's time")
out("by the number of events, in thousands, to show whether a step costs the same per event at every size.")
out()
total_of = {e: st.mean(totals_by_events[e]) for e in sizes}
small, large = sizes[0], sizes[-1]
example = next((key for key in STEP_KEYS if any(key in run["steps"] for run in runs)), None)
out("**How a number is calculated:** the step's time in seconds ÷ (events ÷ 1 000).")
if example and len(sizes) > 1:
    a, b = mean_step(small, example), mean_step(large, example)
    out(f"For example, {name(example)} took {a:,.0f} s at {small:,} events: {a:,.0f} ÷ {small / 1000:,.2f} = "
        f"**{a / small * 1000:.2f}**. At {large:,} events it took {b:,.0f} s: {b:,.0f} ÷ {large / 1000:,.2f} = "
        f"**{b / large * 1000:.2f}**. About the same time both runs, so the cost per event falls as the same "
        f"time is shared by {large / small:,.0f}× more events.")
out()
out("**How to read a row:**")
out()
out("- **falling** (high at the left, low at the right): a fixed cost, about the same time at every size,")
out("  such as starting the services or a one-minute check. It matters for small runs only;")
out("- **flat**: real work per event; the step's time grows in step with the data (linear);")
out("- **rising**: the step slows down as the data grows; look there first.")
out()
if len(sizes) > 1:
    out(f"**The last row, whole replay,** does the same with the total time of the run (every step, including")
    out(f"the short ones not listed here, so it is more than the rows above added up): "
        f"{total_of[small]:,.0f} s ÷ {small / 1000:,.2f} = **{total_of[small] / small * 1000:.2f}** at {small:,} events, "
        f"{total_of[large]:,.0f} s ÷ {large / 1000:,.2f} = **{total_of[large] / large * 1000:.2f}** at {large:,}. "
        f"A higher number does not mean a slower run: the {small:,}-event run took {hms(total_of[small])} in all, "
        f"the {large:,}-event run {hms(total_of[large])}.")
    out()
out("| Step | " + " | ".join(f"{e:,}" for e in sizes) + " |")
out("|---|" + "---:|" * len(sizes))
for key in STEP_KEYS + ["total"]:
    per_k = [(total_of[e] if key == "total" else mean_step(e, key)) / e * 1000 for e in sizes]
    label = "**whole replay** (total time ÷ events)" if key == "total" else name(key)
    out(f"| {label} | " + " | ".join(f"{v:.2f}" for v in per_k) + " |")
out()
out("Total time of each run, for comparison (h:mm:ss): "
    + ", ".join(f"{e:,} events {hms(total_of[e])}" for e in sizes) + ".")
out()

xs = [run["events"] for run in runs]
ys = [run["total"] for run in runs]
if len(set(xs)) >= 2:
    mean_x, mean_y = st.mean(xs), st.mean(ys)
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / sum((x - mean_x) ** 2 for x in xs)
    fixed = mean_y - slope * mean_x
    ss_total = sum((y - mean_y) ** 2 for y in ys)
    ss_residual = sum((y - (fixed + slope * x)) ** 2 for x, y in zip(xs, ys))
    r_squared = 1 - ss_residual / ss_total if ss_total else 1.0
    out("## Fit and estimates")
    out()
    out(f"Total time ≈ **{hms(max(fixed, 0))} fixed + {slope * 1000:.2f} s per 1 000 events** (R² = {r_squared:.3f}: close")
    out("to 1 means the line describes the runs well; well below 1 means the replay does not grow linearly, and")
    out("the estimates below are rough).")
    out()
    def round2(n):   # two significant digits: 403 272 -> 400 000
        digits = len(str(int(n))) - 2
        return int(round(n, -digits)) if digits > 0 else int(n)
    targets = sorted({int(t) for t in project.split()} | {round2(max(xs) * 4), round2(max(xs) * 10)})
    out("| Events | Estimated total |")
    out("|---:|---:|")
    for target in targets:
        out(f"| {target:,} | {hms(fixed + slope * target)} |")
    out()
    out("For this machine only. Beyond about 4× the largest size run it is an extrapolation: run the suite with")
    out("a size near the target to be sure.")
    out()
else:
    out("Only one size was run, so there is no fit: run the suite with at least two sizes.")
    out()

largest = max(sizes)
last_largest = [run for run in runs if run["events"] == largest][-1]
out(f"## Where the time goes at {largest:,} events")
out()
out("| Step | Time | Share |")
out("|---|---:|---:|")
for key, secs in sorted(last_largest["steps"].items(), key=lambda kv: -kv[1]):
    if secs >= 1:
        out(f"| {name(key)} | {hms(secs)} | {secs / last_largest['total'] * 100:.0f} % |")
out()
if last_largest["peaks"]:
    busiest = sorted(last_largest["peaks"].items(), key=lambda kv: -kv[1][0])[:4]
    out("Busiest containers (CPU peak, 100 % = one core): "
        + ", ".join(f"{name} {cpu:.0f} % ({mem})" for name, (cpu, mem) in busiest) + ".")
    out()
out("Per-run reports: " + ", ".join(f"`perf-report-{run['stamp']}.md`" for run in runs) + f", in `{perf_dir}`.")
