#!/usr/bin/env bash
# one-click-installer/lib/set-admin-passwords.sh <envcode> — set the Grafana and Portainer admin passwords of an environment installed
# by one-click-installer/install.sh, e.g. to the values an older environment used. Prompts for each (blank = leave unchanged).
#
#   sudo [SEED_ENV_FILE=/path/seed.env] bash one-click-installer/lib/set-admin-passwords.sh <envcode>
#
# Grafana and Portainer keep their admin password in their OWN databases after the first start, so changing Infisical alone does
# nothing. This updates all three places, in this order:
#   Grafana:   Infisical /grafana GRAFANA_ADMIN_PASSWORD + the seed file (SEED_ENV_FILE, if given, so re-runs keep it)
#              + `grafana cli admin reset-admin-password` in the pod
#   Portainer: the Portainer API (logs in with the current Infisical value) + Infisical /portainer PORTAINER_ADMIN_PASSWORD
set -euo pipefail
ENVCODE="${1:?usage: set-admin-passwords.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (sudo)"; exit 1; }
SEED_ENV_FILE="${SEED_ENV_FILE:-}"   # optional: also record the Grafana value there, so re-runs keep it

if [ -z "${CCE_INFISICAL_WRAPPED_PW:-}" ]; then
  read -r -s -p "New Grafana admin password (blank = keep): " G; echo
  read -r -s -p "New Portainer admin password (min 12 chars, blank = keep): " P; echo
  [ -z "$P" ] || [ "${#P}" -ge 12 ] || { echo "ERROR: Portainer needs at least 12 characters"; exit 1; }
  if [ -n "$G" ] && [ -n "$SEED_ENV_FILE" ] && [ -w "$SEED_ENV_FILE" ]; then
    G="$G" python3 - "$SEED_ENV_FILE" <<'PY'
import os, sys
f = sys.argv[1]; lines = [l for l in open(f) if not l.startswith("GRAFANA_ADMIN_PASSWORD=")]
lines.append("GRAFANA_ADMIN_PASSWORD=" + os.environ["G"] + "\n"); open(f, "w").writelines(lines)
PY
    echo "  seed file $SEED_ENV_FILE: GRAFANA_ADMIN_PASSWORD set"
  fi
  export NEW_G="$G" NEW_P="$P" CCE_INFISICAL_WRAPPED_PW=1
  exec bash "$REPO/one-click-installer/lib/infisical-run.sh" "$ENVCODE" bash "$0" "$ENVCODE"
fi

# --- under the Infisical wrapper from here: the CURRENT values are in the environment
. "$REPO/one-click-installer/lib/infisical-secret-helpers.sh"
infisical_resolve_project "$ENVCODE"; infisical_login
KUBECTL="${KUBECTL:-k3s kubectl}"; NS="cce-${ENVCODE}"

if [ -n "${NEW_G:-}" ]; then
  infisical_set /grafana GRAFANA_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$NEW_G"
  echo "  Infisical /grafana GRAFANA_ADMIN_PASSWORD: updated"
  POD="$($KUBECTL -n "$NS" get pod -l app=grafana -o name | head -1)"
  $KUBECTL -n "$NS" exec "$POD" -- grafana cli --homepath /usr/share/grafana admin reset-admin-password "$NEW_G" >/dev/null 2>&1 \
    && echo "  Grafana: admin password reset" || { echo "  ✗ Grafana reset failed — see: $KUBECTL -n $NS logs $POD"; exit 1; }
fi

if [ -n "${NEW_P:-}" ]; then
  OLD_P="${PORTAINER_ADMIN_PASSWORD:?no PORTAINER_ADMIN_PASSWORD in Infisical — install Portainer first (one-click-installer/lib/portainer.sh)}" python3 - <<'PY'
import json, os, ssl, sys, urllib.request, urllib.error
ctx = ssl._create_unverified_context(); API = "https://127.0.0.1:9443/api"
def call(m, p, b, t=None):
    r = urllib.request.Request(API + p, data=json.dumps(b).encode(), method=m,
                               headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + t} if t else {})})
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=30) as x: raw = x.read(); return x.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e: return e.code, None
st, a = call("POST", "/auth", {"Username": "admin", "Password": os.environ["OLD_P"]})
if st != 200: sys.exit(f"  ✗ Portainer: cannot log in with the current Infisical password (HTTP {st})")
st, _ = call("PUT", "/users/1/passwd", {"password": os.environ["OLD_P"], "newPassword": os.environ["NEW_P"]}, a["jwt"])
if st not in (200, 204): sys.exit(f"  ✗ Portainer: password change failed (HTTP {st})")
print("  Portainer: admin password changed")
PY
  infisical_set /portainer PORTAINER_ADMIN_PASSWORD "$PROJECT_ID" "$INFISICAL_ENV_SLUG" "$NEW_P"
  echo "  Infisical /portainer PORTAINER_ADMIN_PASSWORD: updated"
fi
echo "Done."
