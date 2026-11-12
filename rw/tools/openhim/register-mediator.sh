#!/usr/bin/env bash
# Register the CCE emitter mediator with an OpenHIM Core instance using OpenHIM's native
# token (challenge-response) auth, and OPTIONALLY add the "CCE Emitter Adaptor" route
# (secondary) to an existing channel. Works over plain-HTTP or HTTPS. python3 stdlib only.
#
# Usage:
#   ./register-mediator.sh <host_or_ip> <api_port> <http|https> <username> <password> [channel_name]
#   ./register-mediator.sh <host_or_ip> <api_port> <http|https> <username> <password> --list
#
# Examples:
#   # register the mediator only
#   ./register-mediator.sh <openhim-host> 8080 http <openhim-admin-user> '<password>'
#   # list channel names (to find the one to attach to)
#   ./register-mediator.sh <openhim-host> 8080 http <openhim-admin-user> '<password>' --list
#   # register the mediator AND add the CCE route (secondary) to a named channel
#   ./register-mediator.sh <openhim-host> 8080 http <openhim-admin-user> '<password>' "OpenMRS to SHR channel"
#
# The CCE endpoint the route forwards to (override via env if needed):
#   CCE_ENDPOINT_HOST (default cce.moh.gov.rw)   CCE_ENDPOINT_PATH (default /v1/openhim-emitter-adaptor/inbound)
#   CCE_ENDPOINT_PORT (default 443)   CCE_BASIC_USER (default openhim-emitter-inbound)
#   CCE_BASIC_PASS (required to add the route: that user's password; no default)
set -euo pipefail
HOST="${1:?usage: register-mediator.sh <host> <port> <http|https> <user> <pass> [channel_name|--list]}"
PORT="${2:?port}"; SCHEME="${3:?http|https}"; USER="${4:?username}"; PASS="${5:?password}"
CHANNEL="${6:-}"
# Adding the route needs the OpenHIM inbound user's password (Infisical OPENHIM_INBOUND_PASSWORD); it is never defaulted.
if [ -n "$CHANNEL" ] && [ "$CHANNEL" != "--list" ] && [ -z "${CCE_BASIC_PASS:-}" ]; then
  echo "ERROR: set CCE_BASIC_PASS (the password of ${CCE_BASIC_USER:-openhim-emitter-inbound}) to add the CCE route" >&2; exit 2
fi

python3 - "$HOST" "$PORT" "$SCHEME" "$USER" "$PASS" "$CHANNEL" \
  "${CCE_ENDPOINT_HOST:-cce.moh.gov.rw}" "${CCE_ENDPOINT_PATH:-/v1/openhim-emitter-adaptor/inbound}" \
  "${CCE_ENDPOINT_PORT:-443}" "${CCE_BASIC_USER:-openhim-emitter-inbound}" "${CCE_BASIC_PASS:-}" <<'PY'
import sys, hashlib, datetime, uuid, json, ssl, urllib.request, urllib.parse, urllib.error
host, port, scheme, user, pw, channel, chost, cpath, cport, cuser, cpass = sys.argv[1:12]
base = f"{scheme}://{host}:{port}"
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

# --- OpenHIM token auth: fetch the user's salt once, mint fresh headers per request ---
try:
    salt = json.loads(urllib.request.urlopen(
        urllib.request.Request(f"{base}/authenticate/" + urllib.parse.quote(user)),
        timeout=15, context=ctx).read())["salt"]
except Exception as e:
    print(f"AUTH FAILED: no salt from {base}/authenticate/{user} -> {e}"); sys.exit(2)
pwhash = hashlib.sha512((salt + pw).encode()).hexdigest()

def auth_headers():
    rsalt = str(uuid.uuid4())
    rts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
    token = hashlib.sha512((pwhash + rsalt + rts).encode()).hexdigest()
    return {"auth-username": user, "auth-ts": rts, "auth-salt": rsalt, "auth-token": token}

def call(method, path, payload=None):
    h = auth_headers()
    data = None
    if payload is not None:
        h["Content-Type"] = "application/json"; data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=h)
    return urllib.request.urlopen(req, timeout=20, context=ctx)

CCE_ROUTE = {"name": "CCE Emitter Adaptor", "status": "enabled", "type": "http", "secured": True,
             "host": chost, "port": int(cport), "path": cpath, "primary": False,
             "username": cuser, "password": cpass, "forwardAuthHeader": False}

# --- --list: just print channel names, then exit ---
if channel == "--list":
    chans = json.loads(call("GET", "/channels").read())
    print("CHANNELS:")
    for c in chans:
        print(f"  - {c.get('name')}  (routes: {', '.join(r.get('name','?') for r in c.get('routes', []))})")
    sys.exit(0)

# --- 1) register the mediator (idempotent upsert by urn) ---
mediator = {"urn": "urn:mediator:cce-emitter-adaptor", "version": "1.0.0", "name": "CCE Emitter Adaptor",
            "description": "Wraps FHIR R4 resources into CloudEvents for CCE Collector",
            "defaultChannelConfig": [], "endpoints": [dict(CCE_ROUTE, primary=True)]}
try:
    r = call("POST", "/mediators", mediator)
    print(f"MEDIATOR: HTTP {r.status} — registered '{mediator['urn']}' at {base}")
except urllib.error.HTTPError as e:
    print(f"MEDIATOR FAILED: HTTP {e.code} -> {e.read()[:300].decode(errors='replace')}"); sys.exit(1)

# --- 2) optionally attach the CCE route (secondary) to a named channel ---
if channel:
    chans = json.loads(call("GET", "/channels").read())
    ch = next((c for c in chans if c.get("name") == channel), None)
    if ch is None:
        print(f"CHANNEL NOT FOUND: '{channel}'. Run with --list to see names."); sys.exit(3)
    routes = ch.get("routes", [])
    if any(r.get("name") == CCE_ROUTE["name"] or (r.get("host") == chost and r.get("path") == cpath) for r in routes):
        print(f"ROUTE: already present on channel '{channel}' — no change.")
    else:
        cid = ch["_id"]
        for k in ("_id", "__v"):
            ch.pop(k, None)
        ch["routes"] = routes + [CCE_ROUTE]
        try:
            r = call("PUT", f"/channels/{cid}", ch)
            print(f"ROUTE: HTTP {r.status} — added 'CCE Emitter Adaptor' (secondary) to channel '{channel}'.")
        except urllib.error.HTTPError as e:
            print(f"ROUTE FAILED: HTTP {e.code} -> {e.read()[:300].decode(errors='replace')}"); sys.exit(1)
PY
