#!/usr/bin/env bash
# rw/lib/keycloak-openhim-basic.sh <envcode> — the Keycloak side of OpenHIM's Basic auth, which RW PROD/UAT have but
# k8s/seeds/cce-realm.json does not (it was added by hand on .20). Run under the Infisical wrapper, after the realm exists.
#
# OpenHIM calls POST /v1/openhim-emitter-adaptor/inbound with "Authorization: Basic <user:password>". The gateway
# (BASIC_AUTH_ENABLED=true) exchanges that for a token with a password grant through the client BASIC_AUTH_CLIENT_ID +
# BASIC_AUTH_CLIENT_SECRET, and api_permissions lets EMITTER_INBOUND_WRITE (a gateway-service client role) through. Ensures:
#   - client role gateway-service:EMITTER_INBOUND_WRITE
#   - client <BASIC_AUTH_CLIENT_ID> (confidential, password grant only), its secret = Infisical's BASIC_AUTH_CLIENT_SECRET
#     (the gateway is that secret's only consumer, so Keycloak follows Infisical)
#   - user EMITTER_INBOUND_USER (default openhim-emitter-inbound) holding the role. A missing user is created only when
#     EMITTER_INBOUND_PASSWORD is set — it is OpenHIM's credential, so it has to be the one OpenHIM is configured with.
#     (RW's older names OPENHIM_INBOUND_USER/OPENHIM_INBOUND_PASSWORD are still read when the new ones are absent.)
# Idempotent; a no-op when BASIC_AUTH_ENABLED is not true.
# Since the 2026-11 generic installer, one-click-installer/lib/keycloak-inbound-basic.sh (06-seed.sh) does all of this first,
# with the same names; this step only re-checks it, and stays for an installer copy that predates that.
set -euo pipefail
ENVCODE="${1:?usage: keycloak-openhim-basic.sh <envcode>}"
NS="cce-${ENVCODE}"
[ "${BASIC_AUTH_ENABLED:-false}" = true ] || { echo "  BASIC_AUTH_ENABLED is not true — skipping (OpenHIM Basic auth not used)"; exit 0; }
: "${BASIC_AUTH_CLIENT_ID:?BASIC_AUTH_CLIENT_ID not set}" "${BASIC_AUTH_CLIENT_SECRET:?BASIC_AUTH_CLIENT_SECRET not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD not set}"
INBOUND_USER="${EMITTER_INBOUND_USER:-${OPENHIM_INBOUND_USER:-openhim-emitter-inbound}}"
ROLE=EMITTER_INBOUND_WRITE
KUBECTL="${KUBECTL:-k3s kubectl}"
PORT="${KC_PF_PORT:-18081}"

$KUBECTL -n "$NS" rollout status deploy/keycloak --timeout=600s >/dev/null
$KUBECTL -n "$NS" port-forward svc/keycloak "${PORT}:8080" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
KC="http://localhost:${PORT}/auth"
for _ in $(seq 1 20); do curl -sf "$KC/realms/master" >/dev/null 2>&1 && break; sleep 2; done

# Everything else is the admin REST API; python keeps the JSON handling honest and the secrets out of argv.
KC="$KC" INBOUND_USER="$INBOUND_USER" ROLE="$ROLE" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.parse, urllib.error
KC, E = os.environ["KC"], os.environ
def call(method, path, body=None, token=None, form=None):
    data = urllib.parse.urlencode(form).encode() if form else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(KC + path, data=data, method=method)
    if token: req.add_header("Authorization", "Bearer " + token)
    if body is not None: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None
st, tok = call("POST", "/realms/master/protocol/openid-connect/token",
               form={"grant_type": "password", "client_id": "admin-cli",
                     "username": E.get("KEYCLOAK_ADMIN_USER", "admin"), "password": E["KEYCLOAK_ADMIN_PASSWORD"]})
if st != 200: sys.exit(f"  ✗ Keycloak admin login failed (HTTP {st}) — KEYCLOAK_ADMIN_USER/PASSWORD in Infisical must match the master realm")
T = tok["access_token"]; R = "/admin/realms/cce"

def client(cid):
    st, cs = call("GET", f"{R}/clients?clientId={urllib.parse.quote(cid)}", token=T)
    return cs[0] if st == 200 and cs else None

gw = client("gateway-service") or sys.exit("  ✗ client gateway-service missing from the cce realm")
role = E["ROLE"]
if call("GET", f"{R}/clients/{gw['id']}/roles/{role}", token=T)[0] == 404:
    call("POST", f"{R}/clients/{gw['id']}/roles", {"name": role, "description": "Post inbound events to the OpenHIM emitter adaptor"}, T)
    print(f"  created role gateway-service:{role}")
else:
    print(f"  role gateway-service:{role}: present")

cid, secret = E["BASIC_AUTH_CLIENT_ID"], E["BASIC_AUTH_CLIENT_SECRET"]
c = client(cid)
if not c:
    rep = {"clientId": cid, "enabled": True, "publicClient": False, "clientAuthenticatorType": "client-secret", "secret": secret,
           "standardFlowEnabled": False, "implicitFlowEnabled": False, "directAccessGrantsEnabled": True,
           "serviceAccountsEnabled": False, "fullScopeAllowed": True, "protocol": "openid-connect"}
    st, _ = call("POST", f"{R}/clients", rep, T)
    print(f"  created client {cid} (password grant) HTTP={st}")
else:
    st, cur = call("GET", f"{R}/clients/{c['id']}/client-secret", token=T)
    if (cur or {}).get("value") == secret and c.get("directAccessGrantsEnabled"):
        print(f"  client {cid}: present, secret matches Infisical")
    else:
        c.update({"secret": secret, "directAccessGrantsEnabled": True})
        st, _ = call("PUT", f"{R}/clients/{c['id']}", c, T)
        print(f"  client {cid}: secret/password grant aligned to Infisical HTTP={st}")

user = E["INBOUND_USER"]
st, us = call("GET", f"{R}/users?username={urllib.parse.quote(user)}&exact=true", token=T)
u = us[0] if us else None
if not u:
    pw = E.get("EMITTER_INBOUND_PASSWORD", "") or E.get("OPENHIM_INBOUND_PASSWORD", "")
    if not pw:
        print(f"  ! user {user} does not exist and EMITTER_INBOUND_PASSWORD is not set — OpenHIM calls will get 401 until it is"
              " created with the password OpenHIM is configured with (set it in Infisical and re-run)")
        sys.exit(0)
    st, _ = call("POST", f"{R}/users", {"username": user, "enabled": True, "emailVerified": True,
                 "credentials": [{"type": "password", "value": pw, "temporary": False}]}, T)
    print(f"  created user {user} HTTP={st}")
    u = call("GET", f"{R}/users?username={urllib.parse.quote(user)}&exact=true", token=T)[1][0]
st, have = call("GET", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", token=T)
if any(r["name"] == role for r in (have or [])):
    print(f"  user {user}: has {role}")
else:
    r = call("GET", f"{R}/clients/{gw['id']}/roles/{role}", token=T)[1]
    st, _ = call("POST", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", [r], T)
    print(f"  user {user}: granted {role} HTTP={st}")
PY
