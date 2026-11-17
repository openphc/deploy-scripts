#!/usr/bin/env bash
# one-click-installer/lib/native/06-seed.sh <envcode> — gateway api_permissions + Keycloak cce realm (+ login theme and the
# emitter's inbound Basic auth) (+ optional protocol) for the given env. Uses the NATIVE host PostgreSQL (psql) and this env's
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
# The seed file grants EMITTER_INBOUND_WRITE on the openhim emitter's path only. Grant it on the path of the emitter this
# overlay actually runs (apply-emitter.sh); a no-op for openhim, whose row the seed already has.
. "$HERE/../emitter-lib.sh"; cce_emitter_from_overlay "$REPO/k8s/overlays/${OVERLAY_NAME:-$ENVCODE}"
psql -h localhost -p 5432 -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-admin}" -d "${POSTGRES_DB:-ccedb}" -Atq -c "
  INSERT INTO api_permissions (permission_name, http_method, uri_pattern, description, resource_category)
  SELECT 'EMITTER_INBOUND_WRITE', 'POST', '/v1/${EMITTER_DEPLOYMENT}/**', 'Post inbound events to the ${EMITTER_NAME} emitter adaptor', 'Emitter'
  WHERE NOT EXISTS (SELECT 1 FROM api_permissions WHERE http_method = 'POST' AND uri_pattern = '/v1/${EMITTER_DEPLOYMENT}/**');"
echo "  emitter ${EMITTER_NAME}: EMITTER_INBOUND_WRITE on POST /v1/${EMITTER_DEPLOYMENT}/**"

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
# Select the login theme: the theme mounted as "insights-ui-theme" (05-k8s-deploy.sh: KEYCLOAK_THEME_DIR). cce-realm.json now
# selects it on import too; this also covers a realm imported before that, which showed Keycloak's stock page. PUT is a
# partial update — only loginTheme changes. Re-run safe.
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -X PUT "$KC/admin/realms/cce" -d '{"loginTheme":"insights-ui-theme"}')
echo "  login theme insights-ui-theme (from ${KEYCLOAK_THEME_DIR:-keycloak-themes/cce-insights-theme/dev}) HTTP=$code"
# The emitter's inbound HTTP Basic auth: client role, the gateway's password-grant client and the inbound user.
bash "$HERE/../keycloak-inbound-basic.sh" "$ENVCODE"

echo "=== [$ENVCODE 3/3] clinical protocol (optional — PROTOCOL_FILE + PROTOCOL_LOAD_URL in the config) ==="
# The protocol-service endpoint (2.0; /v1/compliance/** in 1.x) expects {"planDefinitionJson": "<stringified PlanDefinition>"},
# NOT the raw PlanDefinition. PROTOCOL_AUTH must be a Bearer token with COMPLIANCE_WRITE
# (e.g. the openhim-emitter-adaptor service account).
# Each implementation brings its own PlanDefinition (FHIR R4 JSON); nothing deployment-specific is bundled here.
if [ -n "${PROTOCOL_LOAD_URL:-}" ] && [ -n "${PROTOCOL_FILE:-}" ]; then
  [ -r "$PROTOCOL_FILE" ] || { echo "  ✗ PROTOCOL_FILE not readable: $PROTOCOL_FILE"; exit 1; }
  CANON="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("url","")+"|"+d.get("version",""))' "$PROTOCOL_FILE")"
  # Already loaded (same url|version)? Then do nothing: re-posting it on every re-run only produced a 400 "duplicate".
  LOADED="$(curl -s --max-time 30 ${PROTOCOL_AUTH:+-H "Authorization: $PROTOCOL_AUTH"} "${PROTOCOL_LOAD_URL}?size=500" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); items=d.get("content",d) if isinstance(d,dict) else d
    print("\n".join("%s|%s %s"%(p.get("url"),p.get("version"),p.get("status")) for p in items))
except Exception: pass' || true)"
  if printf '%s\n' "$LOADED" | grep -qF "$CANON "; then
    echo "  protocol $CANON already loaded ($(printf '%s\n' "$LOADED" | grep -F "$CANON " | awk '{print $2}' | head -1)) — not posted again"
  else
    WRAPPED="$(mktemp)"
    python3 -c 'import json,sys;print(json.dumps({"planDefinitionJson":open(sys.argv[1]).read()}))' "$PROTOCOL_FILE" > "$WRAPPED"
    curl -s -w '\n  HTTP=%{http_code}\n' -X POST "$PROTOCOL_LOAD_URL" \
      -H 'Content-Type: application/json' ${PROTOCOL_AUTH:+-H "Authorization: $PROTOCOL_AUTH"} \
      --data-binary @"$WRAPPED"
    rm -f "$WRAPPED"
  fi
else
  echo "  skipped (set PROTOCOL_FILE=<PlanDefinition.json>, PROTOCOL_LOAD_URL=https://\${INGRESS_HOST}/v1/protocol/protocol-definitions"
  echo "           and PROTOCOL_AUTH='Bearer <token>' in the config to load your protocol)"
fi
echo "Seed complete."
