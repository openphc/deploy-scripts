#!/usr/bin/env bash
# one-click-installer/lib/grafana-redeploy.sh <uat|prod>
#
# Redeploy Grafana dashboard updates: rebuild the `grafana-dashboards` ConfigMap from
# grafana/dashboards/*.json (+ the data-pipeline pipeline-health dashboard), rewriting the dangling
# `${DS_PROMETHEUS}` input to the provisioned datasource uid "prometheus", then rollout-restart
# Grafana so it re-provisions them.
#
# Dashboards are STATIC JSON, so (unlike redeploy.sh) this needs NO Infisical secrets — just kubectl.
# It globs ALL dashboards under grafana/dashboards/, so dropping a new .json there and re-running is
# all it takes to ship it (matches what 03/05-k8s-deploy.sh's [5/5] step does).
#
#   sudo bash rw/<env>/grafana-redeploy.sh                 # rebuild dashboards configmap + restart grafana
#   sudo DRY_RUN=1 bash rw/<env>/grafana-redeploy.sh       # list dashboards that would deploy, change nothing
# NOTE: env vars MUST come AFTER `sudo` (sudo resets the environment — `VAR=1 sudo bash …` is dropped).
#
# Datasources (Prometheus/ClickHouse/PostgreSQL) are provisioned separately by the grafana-datasources
# ConfigMap in k8s/base/monitoring/grafana.yaml — this script does not touch them.
set -euo pipefail

ENVNAME="${1:?usage: grafana-redeploy.sh <envcode>}"; shift || true
NS="cce-${ENVNAME}"
DRY_RUN="${DRY_RUN:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found"; exit 1; fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GDASH="$TMP/gdash"; mkdir -p "$GDASH"
python3 - "$REPO" "$GDASH" <<'PY'
import sys, os, glob
repo, out = sys.argv[1], sys.argv[2]
# Every grafana/dashboards/*.json — rewrite the dangling ${DS_PROMETHEUS} input -> uid "prometheus"
# (harmless for dashboards that reference datasources by name/uid, e.g. ClickHouse/PostgreSQL).
for p in sorted(glob.glob(os.path.join(repo, 'grafana', 'dashboards', '*.json'))):
    open(os.path.join(out, os.path.basename(p)), 'w').write(
        open(p).read().replace('${DS_PROMETHEUS}', 'prometheus'))
# data-pipeline pipeline-health dashboard (references datasources by NAME).
dp = os.path.join(repo, 'data-pipeline', 'infra', 'grafana', 'provisioning',
                  'dashboards', 'json', 'pipeline-health.json')
if os.path.exists(dp):
    open(os.path.join(out, 'pipeline-health.json'), 'w').write(open(dp).read())
PY

echo "== grafana-redeploy ($ENVNAME, ns=$NS) — dashboards =="
ls -1 "$GDASH" | sed 's/^/  /'
BYTES=$(cat "$GDASH"/* | wc -c)
echo "  total: $BYTES bytes (ConfigMap limit ~1048576)"
if [ "$BYTES" -ge 1000000 ]; then echo "  !! near the 1MB ConfigMap limit — trim dashboards"; fi

if [ -n "$DRY_RUN" ]; then
  echo "  DRY_RUN: would recreate ConfigMap/grafana-dashboards in $NS and rollout-restart deploy/grafana."
  exit 0
fi

# Server-side apply: the dashboards JSON exceeds the 256KB client-side `last-applied-configuration`
# annotation limit, so use --server-side (no client annotation) + --force-conflicts to take ownership.
$KUBECTL create configmap grafana-dashboards -n "$NS" --from-file="$GDASH" \
  --dry-run=client -o yaml | $KUBECTL apply --server-side --force-conflicts -f -
$KUBECTL rollout restart deploy/grafana -n "$NS"
$KUBECTL rollout status  deploy/grafana -n "$NS" --timeout="$ROLLOUT_TIMEOUT" || {
  echo "  !! grafana rollout did not complete in $ROLLOUT_TIMEOUT — check: $KUBECTL -n $NS get pods -l app=grafana"; exit 1; }
echo "grafana-redeploy: done."
