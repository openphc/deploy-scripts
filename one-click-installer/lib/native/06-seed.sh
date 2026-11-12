#!/usr/bin/env bash
# one-click-installer/lib/native/06-seed.sh <envcode> — gateway api_permissions + Keycloak cce realm
# (+ optional protocol) for the given env. Uses the NATIVE host PostgreSQL (psql) and this env's
# cce-<envcode> keycloak.
set -euo pipefail

ENVCODE="${1:?usage: 06-seed.sh <envcode>}"
NS="cce-${ENVCODE}"
KC_PF_PORT="${KC_PF_PORT:-18080}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found"; exit 1; fi
fi
export PGPASSWORD="${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}"

echo "=== [$ENVCODE 1/3] gateway api_permissions -> ${POSTGRES_DB:-ccedb} (native psql) ==="
psql -h localhost -p 5432 -v ON_ERROR_STOP=1 \
  -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-ccedb}" -f "$REPO/k8s/seeds/api_permissions.sql"

# The gateway loads api_permissions from the DB ONCE on startup. In install-all.sh order it comes
# up before this seed, so restart it now to pick up the permission mappings — otherwise every
# authorized route returns 403 "No permission mappings configured".
echo "  restarting gateway-service to reload permissions..."
$KUBECTL rollout restart deploy/gateway-service -n "$NS" 2>/dev/null || true

echo "=== [$ENVCODE 2/3] Keycloak cce realm import ==="
: "${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"
# Keycloak is the slowest workload to come up on a fresh machine (image pull + realm DB init). Wait for its ROLLOUT, not just
# the port: the old ~40s port poll ran out while the pod was still ContainerCreating, the token call returned an empty body, and
# the install died on a raw JSONDecodeError instead of a message.
echo "  waiting for the keycloak rollout (up to 10 min)..."
$KUBECTL -n "$NS" rollout status deploy/keycloak --timeout=600s || { echo "  ✗ keycloak did not become ready — check: $KUBECTL -n $NS describe pod -l app=keycloak"; exit 1; }
$KUBECTL -n "$NS" port-forward svc/keycloak "${KC_PF_PORT}:8080" >"/tmp/kc-pf-${ENVCODE}.log" 2>&1 &
KCPF=$!; trap 'kill $KCPF 2>/dev/null || true' EXIT
for i in $(seq 1 20); do curl -sf "http://localhost:${KC_PF_PORT}/auth/realms/master" >/dev/null 2>&1 && break; sleep 2; done
KC="http://localhost:${KC_PF_PORT}/auth"
TOK=$(curl -s "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER:-admin}" -d password="$KEYCLOAK_ADMIN_PASSWORD" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")')
[ -n "$TOK" ] || { echo "  ✗ no keycloak admin token"; exit 1; }
if curl -sf -H "Authorization: Bearer $TOK" "$KC/admin/realms/cce" >/dev/null 2>&1; then
  echo "  cce realm already exists — skipping"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -X POST "$KC/admin/realms" \
    --data-binary @"$REPO/k8s/seeds/cce-realm.json")
  echo "  realm import HTTP=$code"
fi
# Select the login theme. cce-realm.json names none, so the mounted theme (05-k8s-deploy.sh: KEYCLOAK_THEME_DIR, mounted as
# "insights-ui-theme") was never used and every fresh install showed Keycloak's stock page. PUT is a partial update — only
# loginTheme changes. Re-run safe.
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -X PUT "$KC/admin/realms/cce" -d '{"loginTheme":"insights-ui-theme"}')
echo "  login theme insights-ui-theme (from ${KEYCLOAK_THEME_DIR:-keycloak-themes/cce-insights-theme/dev}) HTTP=$code"

echo "=== [$ENVCODE 3/3] clinical protocol (optional — PROTOCOL_FILE + PROTOCOL_LOAD_URL in the config) ==="
# The protocol-service endpoint (2.0; /v1/compliance/** in 1.x) expects {"planDefinitionJson": "<stringified PlanDefinition>"},
# NOT the raw PlanDefinition. PROTOCOL_AUTH must be a Bearer token with COMPLIANCE_WRITE
# (e.g. the openhim-emitter-adaptor service account).
# Each implementation brings its own PlanDefinition (FHIR R4 JSON); nothing deployment-specific is bundled here.
if [ -n "${PROTOCOL_LOAD_URL:-}" ] && [ -n "${PROTOCOL_FILE:-}" ]; then
  [ -r "$PROTOCOL_FILE" ] || { echo "  ✗ PROTOCOL_FILE not readable: $PROTOCOL_FILE"; exit 1; }
  python3 -c 'import json,sys;print(json.dumps({"planDefinitionJson":open(sys.argv[1]).read()}))' "$PROTOCOL_FILE" > /tmp/wrapped-pd.json
  curl -s -w '\n  HTTP=%{http_code}\n' -X POST "$PROTOCOL_LOAD_URL" \
    -H 'Content-Type: application/json' ${PROTOCOL_AUTH:+-H "Authorization: $PROTOCOL_AUTH"} \
    --data-binary @/tmp/wrapped-pd.json
  rm -f /tmp/wrapped-pd.json
else
  echo "  skipped (set PROTOCOL_FILE=<PlanDefinition.json>, PROTOCOL_LOAD_URL=https://\${INGRESS_HOST}/v1/protocol/protocol-definitions"
  echo "           and PROTOCOL_AUTH='Bearer <token>' in the config to load your protocol)"
fi
echo "Seed complete."
