#!/usr/bin/env bash
# one-click-installer/lib/keycloak-inbound-basic.sh <envcode> — the Keycloak side of the emitter's inbound HTTP Basic auth.
# Run under infisical-run.sh, after the cce realm exists (06-seed.sh calls it). k8s/seeds/cce-realm.json has none of this.
#
# The source system (OpenHIM, tibERbu, ...) calls POST https://<host>/v1/<emitter-deployment>/inbound with
# "Authorization: Basic <user:password>". The gateway (BASIC_AUTH_ENABLED=true) exchanges that for a token with a password
# grant through the client BASIC_AUTH_CLIENT_ID + BASIC_AUTH_CLIENT_SECRET, and api_permissions lets EMITTER_INBOUND_WRITE
# (a gateway-service client role) through. Ensures:
#   - client role gateway-service:EMITTER_INBOUND_WRITE
#   - client <BASIC_AUTH_CLIENT_ID> (confidential, password grant only), its secret = Infisical's BASIC_AUTH_CLIENT_SECRET
#     (the gateway is that secret's only consumer, so Keycloak follows Infisical)
#   - user EMITTER_INBOUND_USER holding the role, created with EMITTER_INBOUND_PASSWORD. An EXISTING user's password is never
#     changed: it is the source system's credential, so it has to stay the one that system is configured with.
# Idempotent; a no-op when BASIC_AUTH_ENABLED is not true.
set -euo pipefail
ENVCODE="${1:?usage: keycloak-inbound-basic.sh <envcode>}"
NS="cce-${ENVCODE}"
[ "${BASIC_AUTH_ENABLED:-false}" = true ] || { echo "  BASIC_AUTH_ENABLED is not true — skipping (inbound Basic auth not used)"; exit 0; }
: "${BASIC_AUTH_CLIENT_ID:?BASIC_AUTH_CLIENT_ID not set}" "${BASIC_AUTH_CLIENT_SECRET:?BASIC_AUTH_CLIENT_SECRET not set}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD not set}"
INBOUND_USER="${EMITTER_INBOUND_USER:?EMITTER_INBOUND_USER not set}"
ROLE=EMITTER_INBOUND_WRITE
if [ -z "${KUBECTL:-}" ]; then command -v kubectl >/dev/null 2>&1 && KUBECTL=kubectl || KUBECTL="sudo k3s kubectl"; fi
PORT="${KC_INBOUND_PF_PORT:-18082}"   # not 06-seed.sh's 18080: its port-forward is still open when this runs

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
    call("POST", f"{R}/clients/{gw['id']}/roles", {"name": role, "description": "Post inbound events to the emitter adaptor"}, T)
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
# A service account, so the profile fields are placeholders; .invalid is a reserved TLD (RFC 2606) — nothing is ever mailed.
PROFILE = {"firstName": user, "lastName": "inbound", "email": f"{user}@cce.invalid", "emailVerified": True}
st, us = call("GET", f"{R}/users?username={urllib.parse.quote(user)}&exact=true", token=T)
u = us[0] if us else None
if not u:
    pw = E.get("EMITTER_INBOUND_PASSWORD", "")
    if not pw:
        print(f"  ! user {user} does not exist and EMITTER_INBOUND_PASSWORD is not set — inbound calls will get 401 until it is"
              " created (set it in Infisical and re-run)")
        sys.exit(0)
    st, _ = call("POST", f"{R}/users", {"username": user, "enabled": True, **PROFILE,
                 "credentials": [{"type": "password", "value": pw, "temporary": False}]}, T)
    print(f"  created user {user} HTTP={st}")
    u = call("GET", f"{R}/users?username={urllib.parse.quote(user)}&exact=true", token=T)[1][0]
# Keycloak 26's default user profile requires first name, last name and e-mail: without them the password grant fails with
# "invalid_grant: Account is not fully set up", so every inbound call got 401. Complete a user that lacks them (or has pending
# required actions); its password is not touched.
if any(not u.get(k) for k in ("firstName", "lastName", "email")) or u.get("requiredActions"):
    full = call("GET", f"{R}/users/{u['id']}", token=T)[1] or u
    full.update({k: full.get(k) or v for k, v in PROFILE.items()}); full["requiredActions"] = []
    st, _ = call("PUT", f"{R}/users/{u['id']}", full, T)
    print(f"  user {user}: profile completed (name, e-mail, no required actions) HTTP={st}")
st, have = call("GET", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", token=T)
if any(r["name"] == role for r in (have or [])):
    print(f"  user {user}: has {role}")
else:
    r = call("GET", f"{R}/clients/{gw['id']}/roles/{role}", token=T)[1]
    st, _ = call("POST", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", [r], T)
    print(f"  user {user}: granted {role} HTTP={st}")
PY
