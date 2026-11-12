#!/usr/bin/env bash
# one-click-installer/lib/native/install-all.sh <envcode> — stand up the full CCE stack end to end for <envcode>.
#
# Native host services (PostgreSQL, Kafka KRaft, ClickHouse, Kafka Connect/Debezium)
# + the cce-<envcode> k3s namespace.
#
# Config/secrets come from Infisical — the single source of truth. This script re-execs itself
# under one-click-installer/lib/infisical-run.sh so every sub-step gets the secrets injected.
#
# Flags:
#   --pull-images   also force a rollout-restart of the CCE services so the latest GHCR :latest
#                   builds are pulled (apply alone won't redeploy an unchanged image tag).
#   --skip-seed     skip step 7 (gateway api_permissions + Keycloak realm). Seeding defaults to ON
#                   here (unlike rw/prod/install-all.sh, which defaults it off for re-runs against
#                   an already-seeded live PROD) — a brand-new env has no api_permissions/realm yet.
set -euo pipefail

ENVCODE="${1:?usage: install-all.sh <envcode> [--pull-images] [--skip-seed]}"; shift || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap: ensure Infisical secrets are injected (re-exec under the wrapper once).
if [ -z "${CCE_INFISICAL_WRAPPED:-}" ]; then
  export CCE_INFISICAL_WRAPPED=1
  exec bash "$HERE/../infisical-run.sh" "$ENVCODE" bash "$0" "$ENVCODE" "$@"   # `bash`, not a direct exec: zipped/rsynced trees lose the exec bit
fi

PULL_IMAGES=0; SKIP_SEED=0
for a in "$@"; do
  [ "$a" = "--pull-images" ] && PULL_IMAGES=1
  [ "$a" = "--skip-seed" ] && SKIP_SEED=1
done
NS="cce-${ENVCODE}"

echo "########## 1. PostgreSQL + Kafka (native, systemd) ##########"
bash "$HERE/01-install-postgres-kafka.sh" "$ENVCODE"

echo "########## 2. ClickHouse (native) ##########"
bash "$HERE/02-install-clickhouse.sh" "$ENVCODE"

echo "########## 3. Kafka Connect + Debezium (native) ##########"
bash "$HERE/03-install-kafka-connect.sh" "$ENVCODE"

echo "########## 3b. Monitoring exporters for native Postgres/Kafka ##########"
bash "$HERE/07-monitoring-exporters.sh" "$ENVCODE"

echo "########## 4. Kubernetes services ($NS namespace) ##########"
SECRET_SNAP="$(mktemp)"
bash "$HERE/../rollout-changed.sh" "$NS" "$SECRET_SNAP" capture
bash "$HERE/05-k8s-deploy.sh" "$ENVCODE"

echo "########## 4b. Restart deployments whose env (cce-secrets/cce-config) changed ##########"
bash "$HERE/../rollout-changed.sh" "$NS" "$SECRET_SNAP" restart
rm -f "$SECRET_SNAP"

if [ "$PULL_IMAGES" = 1 ]; then
  echo "########## 4c. Pull latest CCE images (--pull-images) ##########"
  bash "$HERE/../redeploy.sh" "$NS"
fi

echo "########## 5. ccedb schema: created by the CCE services — 04-data-pipeline.sh waits for every CDC table ##########"

echo "########## 6. Data pipeline: ClickHouse schema + CDC + Debezium connector ##########"
bash "$HERE/04-data-pipeline.sh" "$ENVCODE"

if [ "$SKIP_SEED" = 0 ]; then
  echo "########## 7. Seeds: api_permissions + Keycloak cce realm ##########"
  bash "$HERE/06-seed.sh" "$ENVCODE"
else
  echo "########## 7. Seeds skipped (--skip-seed) ##########"
fi

echo ""
echo "Done. Verify:  ${KUBECTL:-sudo k3s kubectl} get pods -n $NS"
