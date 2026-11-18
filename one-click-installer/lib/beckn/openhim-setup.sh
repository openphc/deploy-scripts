#!/usr/bin/env bash
# one-click-installer/lib/beckn/openhim-setup.sh <envcode> — configure a running OpenHIM Core through its API. Run under
# infisical-run.sh (install-beckn.sh does, after beckn-deploy.sh openhim). Safe to re-run.
#
#   1. root password   A new OpenHIM has root@openhim.org with the published default password. It is changed to
#                      OPENHIM_ROOT_PASSWORD (Infisical /beckn). An existing password is never changed: if neither the stored
#                      nor the default one logs in, the script stops and says so.
#   2. clients         every client in k8s/beckn/openhim/openhim-metadata.json, created or updated by clientID, with the
#                      password OPENHIM_CLIENT_PASSWORD_<CLIENTID> (Basic auth on the channels)
#   3. channels        every channel in that file, created or updated by name
# The emitter adaptor is restarted when the root password or its own client changed (it signs in with both at start).
set -euo pipefail
ENVCODE="${1:?usage: openhim-setup.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$(cd "$HERE/.." && pwd)"; REPO="$(cd "$LIB/../.." && pwd)"
. "$HERE/beckn-lib.sh"
export ENVCODE
beckn_defaults
beckn_kubectl
NS="$(beckn_component_ns openhim)"
: "${OPENHIM_ROOT_PASSWORD:?OPENHIM_ROOT_PASSWORD not set — run beckn-seed.sh (Infisical /beckn)}"
PORT="${OPENHIM_PF_PORT:-18480}"

$KUBECTL -n "$NS" rollout status deploy/openhim-core --timeout=600s >/dev/null
$KUBECTL -n "$NS" port-forward svc/openhim-core "${PORT}:8080" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -skf "https://localhost:${PORT}/heartbeat" >/dev/null 2>&1 && break; sleep 2; done

CHANGED="$(mktemp)"; trap 'kill $PF 2>/dev/null || true; rm -f "$CHANGED"' EXIT
API="https://localhost:${PORT}" METADATA="$REPO/k8s/beckn/openhim/openhim-metadata.json" CHANGED="$CHANGED" python3 - <<'PY'
import base64, hashlib, json, os, re, secrets, ssl, sys, urllib.error, urllib.request
E = os.environ
API, USER, PW = E["API"], E.get("OPENHIM_ROOT_USER", "root@openhim.org"), E["OPENHIM_ROOT_PASSWORD"]
DEFAULT_PW = "openhim-password"                      # what a new OpenHIM Core creates root@openhim.org with
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE   # Core's certificate is self-signed
changed = []

def call(method, path, body=None, pw=None):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{USER}:{pw or PW}".encode()).decode())
    if body is not None: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
            raw = r.read().decode()
            try: return r.status, json.loads(raw) if raw else None
            except ValueError: return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]

# ── 1. root password ──
st, _ = call("GET", "/users")
if st == 200:
    print(f"  root user {USER}: stored password works")
else:
    st, me = call("GET", f"/users/{USER}", pw=DEFAULT_PW)
    if st != 200:
        sys.exit(f"  ✗ cannot sign in to OpenHIM as {USER}: neither OPENHIM_ROOT_PASSWORD (Infisical /beckn) nor the default "
                 f"password works (HTTP {st}). Put the current password into Infisical, or reset the user in OpenHIM.")
    body = {k: v for k, v in (me if isinstance(me, dict) else {}).items() if k in ("email", "firstname", "surname", "groups")}
    body.setdefault("email", USER); body["password"] = PW
    st, out = call("PUT", f"/users/{USER}", body, pw=DEFAULT_PW)
    ok, _ = call("GET", "/users")
    if ok != 200:      # older Core versions take the hashed form instead of "password"
        salt = secrets.token_hex(16)
        body.pop("password")
        body.update(passwordAlgorithm="sha512", passwordSalt=salt, passwordHash=hashlib.sha512((salt + PW).encode()).hexdigest())
        st, out = call("PUT", f"/users/{USER}", body, pw=DEFAULT_PW)
        ok, _ = call("GET", "/users")
    if ok != 200:
        sys.exit(f"  ✗ could not change the root password (HTTP {st}: {out})")
    print(f"  root user {USER}: default password replaced with OPENHIM_ROOT_PASSWORD")
    changed.append("root")

meta = json.load(open(E["METADATA"]))

# ── 2. clients ──
st, existing = call("GET", "/clients")
if st != 200: sys.exit(f"  ✗ GET /clients: HTTP {st} {existing}")
by_id = {c["clientID"]: c for c in existing}
for c in meta["clients"]:
    key = "OPENHIM_CLIENT_PASSWORD_" + re.sub(r"[^A-Z0-9]", "_", c["clientID"].upper())
    pw = E.get(key, "")
    if not pw: sys.exit(f"  ✗ {key} is not in Infisical /beckn — run beckn-seed.sh")
    cur = by_id.get(c["clientID"])
    # OpenHIM checks Basic auth as sha512(password + salt). Keep the stored salt/hash when the password still matches,
    # so a re-run changes nothing.
    if cur and cur.get("passwordAlgorithm") == "sha512" and cur.get("passwordSalt") and \
       hashlib.sha512((pw + cur["passwordSalt"]).encode()).hexdigest() == cur.get("passwordHash"):
        salt, digest = cur["passwordSalt"], cur["passwordHash"]
    else:
        salt = secrets.token_hex(16); digest = hashlib.sha512((pw + salt).encode()).hexdigest()
    want = {"clientID": c["clientID"], "name": c["name"], "roles": c["roles"],
            "passwordAlgorithm": "sha512", "passwordSalt": salt, "passwordHash": digest}
    if cur is None:
        st, out = call("POST", "/clients", want); verb = "created"
    elif any(cur.get(k) != v for k, v in want.items()):
        st, out = call("PUT", f"/clients/{cur['_id']}", want); verb = "updated"
    else:
        print(f"  client {c['clientID']}: unchanged"); continue
    if st not in (200, 201): sys.exit(f"  ✗ client {c['clientID']}: HTTP {st} {out}")
    print(f"  client {c['clientID']}: {verb}  (password: Infisical /beckn {key})")
    changed.append("client:" + c["clientID"])

# ── 3. channels ──
st, existing = call("GET", "/channels")
if st != 200: sys.exit(f"  ✗ GET /channels: HTTP {st} {existing}")
by_name = {c["name"]: c for c in existing}
def same(want, cur):          # compare only what the file sets (Core adds ids and defaults of its own)
    if isinstance(want, dict): return isinstance(cur, dict) and all(same(v, cur.get(k)) for k, v in want.items())
    if isinstance(want, list): return isinstance(cur, list) and len(want) == len(cur) and all(same(a, b) for a, b in zip(want, cur))
    return want == cur
for ch in meta["channels"]:
    cur = by_name.get(ch["name"])
    if cur is None:
        st, out = call("POST", "/channels", ch); verb = "created"
    elif not same(ch, cur):
        st, out = call("PUT", f"/channels/{cur['_id']}", ch); verb = "updated"
    else:
        print(f"  channel '{ch['name']}': unchanged"); continue
    if st not in (200, 201): sys.exit(f"  ✗ channel '{ch['name']}': HTTP {st} {out}")
    print(f"  channel '{ch['name']}' ({ch['urlPattern']}): {verb}")

open(E["CHANGED"], "w").write("\n".join(changed))
PY

# The adaptor registers as a mediator with the root login and posts to /cce-beckn with its client: both are read at start.
if grep -q -E '^(root|client:cce-beckn-endpoint)$' "$CHANGED" && $KUBECTL -n "$NS" get deploy openhim-cce-emitter-adaptor >/dev/null 2>&1; then
  echo "  restarting openhim-cce-emitter-adaptor (its OpenHIM logins changed)"
  $KUBECTL -n "$NS" rollout restart deploy/openhim-cce-emitter-adaptor >/dev/null
fi
