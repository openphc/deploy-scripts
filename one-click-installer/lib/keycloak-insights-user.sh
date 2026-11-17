#!/usr/bin/env bash
# one-click-installer/lib/keycloak-insights-user.sh <envcode> — the default Insights sign-in user, so a new environment can be
# opened at <CCE_PUBLIC_URL>/insights/ straight after the install. Run under infisical-run.sh, after the cce realm exists
# (06-seed.sh calls it). tools/show-credentials.sh prints the login.
#
# Ensures, in realm cce:
#   - user INSIGHTS_USER (default "insights"), created with password INSIGHTS_PASSWORD (generated into Infisical /keycloak)
#   - the gateway-service client roles the Insights UI's API calls need: INSIGHTS_READ (/v1/insights/**) and
#     COMPLIANCE_READ (protocol reads)
# An EXISTING user's password is never changed, so a password changed in Keycloak survives a re-run (update Infisical too,
# or show-credentials.sh shows the old one). INSIGHTS_USER=none skips the step. Idempotent.
set -euo pipefail
ENVCODE="${1:?usage: keycloak-insights-user.sh <envcode>}"
NS="cce-${ENVCODE}"
INSIGHTS_USER="${INSIGHTS_USER:-insights}"
[ "$INSIGHTS_USER" != none ] || { echo "  INSIGHTS_USER=none — no default Insights user"; exit 0; }
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD not set}"
if [ -z "${KUBECTL:-}" ]; then command -v kubectl >/dev/null 2>&1 && KUBECTL=kubectl || KUBECTL="sudo k3s kubectl"; fi
PORT="${KC_INSIGHTS_PF_PORT:-18083}"   # 06-seed.sh's own port-forward (18080) is still open when this runs

$KUBECTL -n "$NS" rollout status deploy/keycloak --timeout=600s >/dev/null
$KUBECTL -n "$NS" port-forward svc/keycloak "${PORT}:8080" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
KC="http://localhost:${PORT}/auth"
for _ in $(seq 1 20); do curl -sf "$KC/realms/master" >/dev/null 2>&1 && break; sleep 2; done

KC="$KC" INSIGHTS_USER="$INSIGHTS_USER" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.parse, urllib.error
KC, E = os.environ["KC"], os.environ
ROLES = ("INSIGHTS_READ", "COMPLIANCE_READ")
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

st, cs = call("GET", f"{R}/clients?clientId=gateway-service", token=T)
gw = (cs or [None])[0] or sys.exit("  ✗ client gateway-service missing from the cce realm")

user = E["INSIGHTS_USER"]
# Keycloak 26's default user profile requires first name, last name and e-mail; without them the first sign-in stops at
# "Update account information". .invalid is a reserved TLD (RFC 2606) — nothing is ever mailed.
PROFILE = {"firstName": "Insights", "lastName": "User", "email": f"{user}@cce.invalid", "emailVerified": True}
q = f"{R}/users?username={urllib.parse.quote(user)}&exact=true"
u = (call("GET", q, token=T)[1] or [None])[0]
if not u:
    pw = E.get("INSIGHTS_PASSWORD", "")
    if not pw:
        print(f"  ! user {user} does not exist and INSIGHTS_PASSWORD is not set — set it in Infisical /keycloak and re-run")
        sys.exit(0)
    st, _ = call("POST", f"{R}/users", {"username": user, "enabled": True, **PROFILE, "requiredActions": [],
                 "credentials": [{"type": "password", "value": pw, "temporary": False}]}, T)
    if st != 201: sys.exit(f"  ✗ could not create user {user} (HTTP {st})")
    print(f"  created user {user} HTTP={st}")
    u = call("GET", q, token=T)[1][0]
else:
    print(f"  user {user}: present (password not changed)")
if any(not u.get(k) for k in ("firstName", "lastName", "email")) or u.get("requiredActions"):
    full = call("GET", f"{R}/users/{u['id']}", token=T)[1] or u
    full.update({k: full.get(k) or v for k, v in PROFILE.items()}); full["requiredActions"] = []
    st, _ = call("PUT", f"{R}/users/{u['id']}", full, T)
    print(f"  user {user}: profile completed (name, e-mail, no required actions) HTTP={st}")
have = {r["name"] for r in (call("GET", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", token=T)[1] or [])}
missing = []
for name in ROLES:
    if name in have: continue
    st, r = call("GET", f"{R}/clients/{gw['id']}/roles/{name}", token=T)
    if st != 200: sys.exit(f"  ✗ client role gateway-service:{name} missing from the cce realm (HTTP {st})")
    missing.append(r)
if missing:
    st, _ = call("POST", f"{R}/users/{u['id']}/role-mappings/clients/{gw['id']}", missing, T)
    print(f"  user {user}: granted {', '.join(r['name'] for r in missing)} HTTP={st}")
else:
    print(f"  user {user}: has {', '.join(ROLES)}")
PY
