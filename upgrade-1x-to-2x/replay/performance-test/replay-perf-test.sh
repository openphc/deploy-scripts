#!/usr/bin/env bash
# =================================================================================================
# replay-perf-test.sh — performance test of replay-inbound-events.sh, on a LOCAL copy only
# =================================================================================================
# Fills inbound_event_log with synthetic events (copies of the stored ones, each copy a new set of
# patients and ids), runs a full rebuild with the replay script exactly as the runbook's part A does,
# times every step, samples throughput and container resources, and writes a report that it compares
# with the previous run. Re-run it after every change to the replay script.
#
#   replay-perf-test.sh seed    --events N --yes   make inbound_event_log hold about N accepted events
#   replay-perf-test.sh run     --yes              full rebuild, timed; writes perf-report-<time>.md
#   replay-perf-test.sh cleanup --yes              delete the synthetic events (then 'run' or a rebuild
#                                                  removes what they produced)
#   replay-perf-test.sh status                     how many synthetic events there are, previous runs
#   replay-perf-test.sh suite   --yes [--sizes "10000 50000 100000"] [--repeat 1] [--project "1000000"]
#                                                  step-load test: seed up to each size (ascending), run at
#                                                  each, then one report on how the replay scales
#
#   every command takes --config <file>: the replay settings file of the local deployment
#   (DEPLOYMENT_NAME must start with 'local': this script changes data and never runs elsewhere).
#   run: --keep-old-tables (skip drop-old-tables at the end), --keep-backup (keep the run's backup file)
# =================================================================================================
set -euo pipefail
PERF_DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLAY="$(cd "$PERF_DIR_SCRIPT/.." && pwd)/replay-inbound-events.sh"

log()  { printf '[perf %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31mSTOP\033[0m %s\n\n' "$*" >&2; exit 1; }

CONFIG_FILE=""; COMMAND=""; YES=""; EVENTS=""; KEEP_OLD=""; KEEP_BACKUP=""; SIZES="10000 50000 100000"; REPEAT=1; PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2;;
    --events) EVENTS="${2:-}"; shift 2;;
    --yes) YES=1; shift;;
    --keep-old-tables) KEEP_OLD=1; shift;;
    --keep-backup) KEEP_BACKUP=1; shift;;
    --sizes) SIZES="${2:-}"; shift 2;;
    --repeat) REPEAT="${2:-}"; shift 2;;
    --project) PROJECT="${2:-}"; shift 2;;
    -*) die "Unknown option: $1";;
    *) [ -z "$COMMAND" ] && COMMAND="$1" || die "One command at a time."; shift;;
  esac
done
[ -n "$COMMAND" ] || { awk 'NR == 1 {next} /^[^#]/ {exit} {print}' "$0"; exit 1; }
[ -f "$CONFIG_FILE" ] || die "Give the replay settings file of the local deployment: --config <file>."
[ -f "$REPLAY" ] || die "No replay script at $REPLAY."

# The settings file is the replay script's own: read it the same way ($SCRIPT_DIR = the replay folder).
SCRIPT_DIR="$(dirname "$REPLAY")"
# shellcheck disable=SC1090
. "$CONFIG_FILE"
case "${DEPLOYMENT_NAME:-}" in local*) ;; *) die "DEPLOYMENT_NAME is '${DEPLOYMENT_NAME:-}': this test adds up to millions of events and rebuilds everything, so it only runs on a deployment whose name starts with 'local'.";; esac
: "${PG_EXEC:?PG_EXEC must be set in $CONFIG_FILE (the perf test reads Postgres the same way as the replay)}"
PG_DB="${PG_DB:-ccedb}"; PG_USER="${PG_USER:-}"
PERF_DIR="$HOME/cce-replay/$DEPLOYMENT_NAME-perf"; mkdir -p "$PERF_DIR"
R=(bash "$REPLAY" --config "$CONFIG_FILE")
MARK="-perf-"          # every synthetic id and patient carries it: '<original>-perf-<copy>'

psql_q() {   # SQL on stdin, rows out as a|b|c
  local user; if [ -n "$PG_USER" ]; then user="-U '$PG_USER'"; else user='${POSTGRES_USER:+-U "$POSTGRES_USER"}'; fi
  # No parallel workers for this script's own queries: in a Postgres container with Docker's default
  # 64 MB /dev/shm they fail on large tables ('could not resize shared memory segment').
  $PG_EXEC sh -c "export PGOPTIONS='-c client_min_messages=warning -c max_parallel_workers_per_gather=0'; exec psql $user -d '$PG_DB' -v ON_ERROR_STOP=1 -X -q -At -F '|'"
}
sql() { printf '%s\n' "$1" | psql_q; }
secs() { date +%s.%N; }
dur() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
hms() { awk -v s="$1" 'BEGIN { s = int(s + 0.5); printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 }'; }
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---- seed ----------------------------------------------------------------------------------------
cmd_seed() {
  [ -n "$YES" ] || die "Add --yes: this adds synthetic events to inbound_event_log."
  [[ "$EVENTS" =~ ^[0-9]+$ ]] && [ "$EVENTS" -gt 0 ] || die "Give the number of events wanted: --events 1000000."
  local templates total copies first last batch k n t0 t1
  templates=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED' AND cloudevents_id NOT LIKE '%$MARK%'")
  [ "$templates" -gt 0 ] || die "inbound_event_log holds no real accepted events to copy."
  total=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")
  last=$(sql "SELECT coalesce(max(split_part(cloudevents_id, '$MARK', 2)::int), 0) FROM inbound_event_log WHERE cloudevents_id LIKE '%$MARK%'")
  if [ "$total" -ge "$EVENTS" ]; then ok "inbound_event_log already holds $total accepted events (asked: $EVENTS): nothing to add"; return; fi
  copies=$(( (EVENTS - total + templates - 1) / templates ))
  log "Adding $copies cop$( [ "$copies" = 1 ] && echo y || echo ies) of the $templates real events (copies $((last + 1))..$((last + copies))): about $((copies * templates)) events"
  log "Each copy: new patients ('<patient>$MARK<copy>'), new ids ('<uuid>$MARK<copy>'), received <copy> seconds after the original"
  t0=$(secs); first=$((last + 1)); batch=10
  for ((k = first; k <= last + copies; k += batch)); do
    n=$(( k + batch - 1 )); [ "$n" -le $((last + copies)) ] || n=$((last + copies))
    sql "INSERT INTO inbound_event_log (id, cloudevents_id, source, correlation_id, raw_payload, status, rejection_reason,
                                        error_details, received_at, updated_at, event_time)
         SELECT gen_random_uuid(), i.cloudevents_id || '$MARK' || c, i.source, i.correlation_id,
                jsonb_set(regexp_replace(replace(i.raw_payload::text, i.raw_payload->>'subject', (i.raw_payload->>'subject') || '$MARK' || c),
                               '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', '\\1$MARK' || c, 'g')::jsonb,
                          '{id}', to_jsonb(i.cloudevents_id || '$MARK' || c)),
                i.status, i.rejection_reason, i.error_details,
                i.received_at + make_interval(secs => c), i.updated_at, i.event_time
         FROM inbound_event_log i CROSS JOIN generate_series($k, $n) c
         WHERE i.status = 'ACCEPTED' AND i.cloudevents_id NOT LIKE '%$MARK%'" >/dev/null
    printf '  copies %s-%s done  (%s events so far, %ss)\n' "$k" "$n" "$(sql "SELECT count(*) FROM inbound_event_log")" "$(dur "$t0" "$(secs)")"
  done
  sql "VACUUM ANALYZE inbound_event_log" >/dev/null
  t1=$(secs)
  ok "seeded in $(hms "$(dur "$t0" "$t1")"): $(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'") accepted events, $(sql "SELECT count(DISTINCT raw_payload->>'subject') FROM inbound_event_log WHERE status = 'ACCEPTED'") patients, inbound_event_log $(sql "SELECT pg_size_pretty(pg_total_relation_size('inbound_event_log'))")"
}

# ---- cleanup -------------------------------------------------------------------------------------
cmd_cleanup() {
  [ -n "$YES" ] || die "Add --yes: this deletes the synthetic events from inbound_event_log."
  local n; n=$(sql "WITH d AS (DELETE FROM inbound_event_log WHERE cloudevents_id LIKE '%$MARK%' RETURNING 1) SELECT count(*) FROM d")
  sql "VACUUM ANALYZE inbound_event_log" >/dev/null
  ok "$n synthetic event(s) deleted. What they produced (enrolments, steps, ClickHouse) goes with the next rebuild: 'run --yes' or the replay's part A."
}

# ---- status --------------------------------------------------------------------------------------
cmd_status() {
  log "inbound_event_log: $(sql "SELECT count(*) FILTER (WHERE status = 'ACCEPTED') || ' accepted (' || count(*) FILTER (WHERE cloudevents_id LIKE '%$MARK%') || ' synthetic), ' || pg_size_pretty(pg_total_relation_size('inbound_event_log')) FROM inbound_event_log")"
  if [ -f "$PERF_DIR/history.tsv" ]; then log "Previous runs ($PERF_DIR/history.tsv):"; column -t -s $'\t' "$PERF_DIR/history.tsv" | sed 's/^/  /'
  else log "No run yet."; fi
}

# ---- run -----------------------------------------------------------------------------------------
SAMPLER_PID=""
start_sampler() {   # every 10 s: container CPU and memory (Docker only), database size
  local out="$1"
  ( while :; do
      local now; now=$(date -u +%s)
      if command -v docker >/dev/null; then
        docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null | grep -E '^cce-' \
          | awk -F'|' -v t="$now" '{ gsub(/%/, "", $2); split($3, m, " / "); print t "|" $1 "|" $2 "|" m[1] }' >> "$out" || true
      fi
      printf '%s|db|%s|%s\n' "$now" "0" "$(sql "SELECT pg_database_size(current_database())" 2>/dev/null || echo 0)" >> "$out"
      sleep 10
    done ) &
  SAMPLER_PID=$!
}
stop_sampler() { [ -z "$SAMPLER_PID" ] || { kill "$SAMPLER_PID" 2>/dev/null || true; wait "$SAMPLER_PID" 2>/dev/null || true; SAMPLER_PID=""; }; }
trap stop_sampler EXIT

cmd_run() {
  [ -n "$YES" ] || die "Add --yes: this runs a full rebuild of '$DEPLOYMENT_NAME' (every derived table is rebuilt)."
  local stamp run_dir logf samples steps_tsv step t0 t1 rc published events patients db_before db_after
  stamp=$(date -u +%Y%m%d_%H%M%S); run_dir="$PERF_DIR/run-$stamp"; mkdir -p "$run_dir"
  logf="$run_dir/replay.log"; samples="$run_dir/samples.psv"; steps_tsv="$run_dir/steps.tsv"; : > "$steps_tsv"
  events=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")
  patients=$(sql "SELECT count(DISTINCT raw_payload->>'subject') FROM inbound_event_log WHERE status = 'ACCEPTED'")
  db_before=$(sql "SELECT pg_database_size(current_database())")
  log "Run $stamp on '$DEPLOYMENT_NAME': $events accepted events, $patients patients; log in $logf"
  start_sampler "$samples"

  run_step() {   # $1 = label, rest = replay command; appends "label|seconds|exit" to steps.tsv
    local label="$1"; shift
    log "$label: ${*}"
    t0=$(secs); set +e
    { printf '\n===== %s: %s\n' "$label" "$*"; "${R[@]}" "$@" 2>&1; } | plain | tee -a "$logf" | grep -E 'OK|WARN|STOP' | sed 's/^/    /'
    rc=${PIPESTATUS[0]}; set -e
    t1=$(secs); printf '%s|%s|%s\n' "$label" "$(dur "$t0" "$t1")" "$rc" >> "$steps_tsv"
    [ "$rc" = 0 ] || { stop_sampler; write_report "$run_dir" "$stamp" "$events" "$patients" "$db_before" "" "failed at $label"; die "$label failed (exit $rc); see $logf. The report so far is in $run_dir."; }
  }

  run_step "A0 check" check
  run_step "A2 plan" plan --mode rebuild
  run_step "A3 backup" backup
  run_step "A4 prepare" prepare --mode rebuild --yes
  run_step "A5 publish" publish
  run_step "A6 wait (first service)" wait
  run_step "A7 finish" finish --yes

  # The deadline service's first sweep: every deadline already past is judged now. Timed until no due
  # transition is left (the replay itself does not wait for it).
  log "A7+ deadline sweep: until no due transition is left"
  t0=$(secs); local due=1 left
  if [ "$(sql "SELECT to_regclass('public.step_sla_state_transition') IS NOT NULL")" = t ]; then
    while :; do
      left=$(sql "SELECT count(*) FROM step_sla_state_transition WHERE NOT is_processed AND process_by <= now()")
      printf '%s|%s\n' "$(date -u +%s)" "$left" >> "$run_dir/sla-sweep.psv"
      [ "$left" = 0 ] && break
      due=$((due + 1)); [ "$due" -le 1440 ] || { warn "still $left due after 4 h; stopped waiting"; break; }
      sleep 10
    done
  fi
  t1=$(secs); printf '%s|%s|%s\n' "A7+ deadline sweep" "$(dur "$t0" "$t1")" 0 >> "$steps_tsv"

  run_step "A8 rebuild-clickhouse" rebuild-clickhouse --yes
  run_step "A9 verify" verify
  run_step "A10 report" report
  if [ -z "$KEEP_OLD" ]; then run_step "A11 drop-old-tables" drop-old-tables --yes; fi
  stop_sampler
  db_after=$(sql "SELECT pg_database_size(current_database())")
  if [ -z "$KEEP_BACKUP" ]; then
    local b; b=$(grep -oE 'backup written: [^ ]+ +[^ ]+' "$logf" | tail -1 | awk '{print $NF}')
    [ -n "$b" ] && [ -f "$b" ] && { rm -f "$b"; log "removed this run's backup file ($b; --keep-backup keeps it)"; }
  fi
  write_report "$run_dir" "$stamp" "$events" "$patients" "$db_before" "$db_after" ""
}

write_report() {   # $1 run dir, $2 stamp, $3 events, $4 patients, $5 db size before, $6 after, $7 failure note
  local run_dir="$1" stamp="$2" events="$3" patients="$4" db_before="$5" db_after="$6" failed="$7"
  local out="$PERF_DIR/perf-report-$stamp.md" commit dirty prev
  commit=$(git -C "$(dirname "$REPLAY")" log -1 --format='%h %cs' -- "$(basename "$REPLAY")" 2>/dev/null || echo "not in git")
  dirty=$(git -C "$(dirname "$REPLAY")" status --porcelain -- "$(basename "$REPLAY")" 2>/dev/null | head -1)
  # The run to compare with: the latest earlier run of about the same size (within 5 %), from history.tsv.
  # Runs of other sizes are not comparable, so without one the report has no comparison.
  prev=$(awk -F'\t' -v n="$events" 'NR > 1 && ($3 - n) <= n * 0.05 && (n - $3) <= n * 0.05 {s = $1} END {print s}' "$PERF_DIR/history.tsv" 2>/dev/null || true)
  [ -z "$prev" ] || prev="$PERF_DIR/run-$prev/steps.tsv"
  STEP_NAMES_DIR="$PERF_DIR_SCRIPT" python3 - "$run_dir" "$stamp" "$events" "$patients" "$db_before" "${db_after:-}" "$failed" "$commit${dirty:+ + uncommitted changes}" \
            "${prev:-}" "$DEPLOYMENT_NAME" "$PERF_DIR/history.tsv" > "$out" <<'PY'
import sys, os, re, datetime, statistics as st
sys.path.insert(0, os.environ["STEP_NAMES_DIR"]); from step_names import legend, name
run_dir, stamp, events, patients, db_b, db_a, failed, commit, prev, dep, hist = sys.argv[1:12]
events, patients = int(events), int(patients)
def size(b):
    b = float(b or 0)
    for u in ("B", "kB", "MB", "GB", "TB"):
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
def hms(s):
    s = int(float(s) + .5); return f"{s//3600}:{s%3600//60:02d}:{s%60:02d}"
steps = [l.rstrip("\n").split("|") for l in open(os.path.join(run_dir, "steps.tsv")) if l.strip()]
prev_steps = {}
if prev and os.path.exists(prev):
    prev_steps = {l.split("|")[0]: float(l.split("|")[1]) for l in open(prev) if l.strip()}
log = open(os.path.join(run_dir, "replay.log")).read()

# Throughput of the first service, from 'wait' lines: "[replay HH:MM:SS]   lag=N   recorded ... began=M"
pts = [(h, int(m)) for h, m in re.findall(r"\[replay (\d\d:\d\d:\d\d)\]\s+lag=\S+\s+recorded in \S+ since publishing began=(\d+)", log)]
rates = []
def tsec(h): hh, mm, ss = map(int, h.split(":")); return hh * 3600 + mm * 60 + ss
for (h1, m1), (h2, m2) in zip(pts, pts[1:]):
    dt = (tsec(h2) - tsec(h1)) % 86400
    if dt > 0 and m2 > m1: rates.append((m2 - m1) / dt)
pub = re.search(r"published (\d+) events", log); published = int(pub.group(1)) if pub else events
top = max((m for h, m in pts), default=0)
done_at = next((h for h, m in pts if m >= top), None) if top else None
proc_secs = (tsec(done_at) - tsec(pts[0][0])) % 86400 if pts and done_at and done_at != pts[0][0] else None

# Deadline sweep
sweep = [tuple(map(int, l.split("|"))) for l in open(os.path.join(run_dir, "sla-sweep.psv"))] if os.path.exists(os.path.join(run_dir, "sla-sweep.psv")) else []

# Resources
peaks = {}
samples = os.path.join(run_dir, "samples.psv")
def mem_bytes(s):
    m = re.match(r"([\d.]+)\s*([KMGT]?i?B)", s.strip())
    if not m: return 0
    f = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4, "kB": 1e3, "MB": 1e6, "GB": 1e9}.get(m.group(2), 1)
    return float(m.group(1)) * f
db_peak = 0
if os.path.exists(samples):
    for l in open(samples):
        p = l.rstrip("\n").split("|")
        if len(p) < 4: continue
        if p[1] == "db": db_peak = max(db_peak, float(p[3] or 0)); continue
        c = peaks.setdefault(p[1], [0.0, 0.0, []])
        try:
            cpu = float(p[2]); c[0] = max(c[0], cpu); c[2].append(cpu)
        except ValueError: pass
        c[1] = max(c[1], mem_bytes(p[3]))

def grab(pattern, text=None):
    m = re.search(pattern, log if text is None else text); return m.group(1).strip() if m else "?"
total = sum(float(s[1]) for s in steps)
w = print
w(f"# Replay performance report: {dep}, {stamp}")
w()
w(f"- Replay script: `{commit}`")
ram = f"{int(open('/proc/meminfo').readline().split()[1]) // 1024 // 1024} GB RAM" if os.path.exists("/proc/meminfo") else "RAM unknown"
w(f"- Machine: {os.cpu_count()} CPUs, {ram}")
w(f"- Data: **{events:,} accepted events**, {patients:,} patients; database {size(db_b)} before" + (f", {size(db_a)} after (peak {size(db_peak)})" if db_a else ""))
if failed: w(f"- **Result: FAILED** ({failed}); the numbers below stop there")
w()
w("## Steps")
w()
w(("Compared with the previous run of about the same size: `" + os.path.basename(os.path.dirname(prev)) + "`.\n") if prev_steps else "No earlier run of about this size to compare with.\n")
w("| Step | Time | " + ("Previous run | Change |" if prev_steps else "") + " Exit |")
w("|---|---:|" + ("---:|---:|" if prev_steps else "") + "---:|")
for label, secs, rc in steps:
    s = float(secs); row = f"| {name(label)} | {hms(s)} |"
    if prev_steps:
        p = prev_steps.get(label)
        row += (f" {hms(p)} | {'+' if s >= p else '−'}{abs(s - p) / p * 100:.0f} % |" if p else " — | — |")
    w(row + f" {rc} |")
w(f"| **total** | **{hms(total)}** |" + (f" {hms(sum(prev_steps.values()))} | |" if prev_steps else "") + " |")
w()
w("What each step does, and what its time depends on (the runbook step code is in brackets):")
w()
legend([s[0] for s in steps], w)
w()
w("## Throughput")
w()
if rates:
    w(f"- First service: {top:,} of {published:,} published events recorded" + (f" in {hms(proc_secs)}: **{top / proc_secs:,.0f} events/s** on average" if proc_secs else "")
      + ("" if top >= published else f" — **{published - top} never recorded**"))
    w(f"- Per 15 s interval: median {st.median(rates):,.0f}, lowest {min(rates):,.0f}, highest {max(rates):,.0f} events/s")
else:
    w("- No 'wait' progress lines found.")
pt = next((float(s[1]) for s in steps if s[0] == "A5 publish"), None)
if pt: w(f"- Publish: {published:,} events sent in {hms(pt)} ({published / pt:,.0f} events/s, including the cutoff and checks)")
if len(sweep) > 1:
    first, last = sweep[0], sweep[-1]
    judged = first[1] - last[1]; dt = last[0] - first[0]
    w(f"- Deadline sweep: {first[1]:,} due transitions judged in {hms(dt)}" + (f" ({judged / dt:,.0f}/s)" if dt else ""))
elif sweep: w(f"- Deadline sweep: {sweep[0][1]:,} due when checked")
ch_rows = grab(r"rows in ClickHouse: (\d+) \(snapshot done\)")
w(f"- ClickHouse copy: {ch_rows} rows after the snapshot")
w()
w("## Result checks (from verify)")
w()
vm = re.search(r"===== A9 verify.*?(?======|\Z)", log, re.S); vtext = vm.group(0) if vm else ""
for label, pat in [("accepted events never processed", r"accepted events never processed\s+(\S+)"),
                   ("records in the inbound DLQ", r"records in \S+\.dlq\s+(\S+)"),
                   ("steps Postgres / ClickHouse", r"steps \(CDC check\)\s+(.+)"),
                   ("enrolments (protocol_instance)", r"\n  protocol_instance\s+(\d+)"),
                   ("steps (step_instance)", r"\n  step_instance\s+(\d+)"),
                   ("deviations", r"\n  deviation\s+(\d+)")]:
    w(f"- {label}: {grab(pat, vtext)}")
w()
if peaks:
    w("## Container peaks (sampled every 10 s)")
    w()
    w("100 % CPU = one core fully used.")
    w()
    w("| Container | CPU peak | CPU median | Memory peak |")
    w("|---|---:|---:|---:|")
    for name, (cpu, mem, cpus) in sorted(peaks.items(), key=lambda x: -x[1][0]):
        w(f"| {name} | {cpu:.0f} % | {st.median(cpus):.0f} % | {size(mem)} |")
    w()
w("Files: `replay.log` (every step's output), `samples.psv` (resources), `steps.tsv`, in " + f"`{run_dir}`.")

# One line of history per completed run, for 'status' and the next comparison
if not failed:
    new = not os.path.exists(hist)
    with open(hist, "a") as h:
        if new: h.write("run\tscript\tevents\ttotal\tpublish\twait\tsweep\tclickhouse\tevents/s\n")
        g = {s[0]: float(s[1]) for s in steps}
        h.write(f"{stamp}\t{commit.split()[0]}\t{events}\t{hms(total)}\t{hms(g.get('A5 publish', 0))}\t{hms(g.get('A6 wait (first service)', 0))}\t"
                f"{hms(g.get('A7+ deadline sweep', 0))}\t{hms(g.get('A8 rebuild-clickhouse', 0))}\t{(top / proc_secs) if proc_secs else 0:.0f}\n")
PY
  ok "report written: $out"
}

# ---- suite: step-load test -----------------------------------------------------------------------
# The same full rebuild at increasing sizes: how each step's time grows with the data, where the time
# goes, which container works hardest, and (a linear fit: fixed part + part per event) an estimate for
# sizes not run (--project). --repeat runs each size more than once, to show how much runs vary.
cmd_suite() {
  [ -n "$YES" ] || die "Add --yes: this seeds synthetic events and runs a full rebuild of '$DEPLOYMENT_NAME' at each size."
  [[ "$REPEAT" =~ ^[1-9][0-9]*$ ]] || die "--repeat must be a number of 1 or more."
  local sizes size r now list
  sizes=$(printf '%s\n' $SIZES | sort -n | uniq | tr '\n' ' ')
  for size in $sizes; do [[ "$size" =~ ^[0-9]+$ ]] || die "--sizes takes numbers, e.g. --sizes \"10000 50000 100000\"."; done
  list="$PERF_DIR/suite-$(date -u +%Y%m%d_%H%M%S).runs"
  local copy_size
  copy_size=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED' AND cloudevents_id NOT LIKE '%$MARK%'")
  now=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")
  log "Step-load test on '$DEPLOYMENT_NAME': sizes $sizes(each run $REPEAT time(s)); $now accepted events now"
  for size in $sizes; do
    # 'seed' adds whole copies, so it overshoots by up to one copy: a size is reached within that.
    if [ "$now" -ge $((size + copy_size)) ]; then warn "size $size is well below the $now events already there: skipped ('cleanup --yes' starts lower)"; continue; fi
    # Each size in a subshell: a failure stops the suite, but the sizes already run are still reported.
    ( EVENTS=$size; cmd_seed ) || { warn "seeding $size failed (above): the suite stops here"; break; }
    now=$(sql "SELECT count(*) FROM inbound_event_log WHERE status = 'ACCEPTED'")
    local failed=""
    for ((r = 1; r <= REPEAT; r++)); do
      log "===== size $size, run $r of $REPEAT"
      if ( cmd_run ); then
        printf '%s|%s|%s\n' "$size" "$r" "$(ls -1d "$PERF_DIR"/run-* | tail -1 | sed 's#.*/run-##')" >> "$list"
      else failed=1; warn "the run at $size failed (above; its partial report is in $PERF_DIR): the suite stops here"; break; fi
    done
    [ -z "$failed" ] || break
  done
  [ -s "$list" ] || die "No size completed: nothing to report."
  python3 "$PERF_DIR_SCRIPT/suite-report.py" "$list" "$PERF_DIR" "$PROJECT" "$DEPLOYMENT_NAME" > "${list%.runs}-report.md"
  ok "step-load report written: ${list%.runs}-report.md"
}

case "$COMMAND" in
  seed) cmd_seed;; run) cmd_run;; cleanup) cmd_cleanup;; status) cmd_status;; suite) cmd_suite;;
  *) awk 'NR == 1 {next} /^[^#]/ {exit} {print}' "$0"; exit 1;;
esac
