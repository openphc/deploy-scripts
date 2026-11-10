#!/usr/bin/env bash
# one-click-installer/tools/show-credentials.sh <envcode> [--reveal] — every login of an installed environment, in one place.
#
#   sudo bash one-click-installer/tools/show-credentials.sh <envcode>            # URLs + user names; passwords masked
#   sudo bash one-click-installer/tools/show-credentials.sh <envcode> --reveal   # also print the passwords
#   OVERLAY_NAME=<name> ...   the overlay the env was installed with, if not <envcode> (only used to name the emitter)
#
# WHY: the installer generates every password into Infisical and writes no plain-text credentials file — this prints them on
# demand instead, read live from Infisical (the source of truth), so nothing goes stale and nothing extra is left on disk.
# Read-only: changes nothing. Root is needed because the Infisical creds files and admin.env are 0600 root.
set -euo pipefail
ENVN="${1:?usage: show-credentials.sh <envcode> [--reveal]}"; shift || true
REVEAL=0; for a in "$@"; do [ "$a" = "--reveal" ] && REVEAL=1; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$HERE/../lib"; REPO="$(cd "$HERE/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (sudo) — the Infisical creds files are readable only by root"; exit 1; }

if [ -z "${CCE_SHOWCREDS_WRAPPED:-}" ]; then   # self-wrap: get every Infisical key of the env injected
  export CCE_SHOWCREDS_WRAPPED=1
  exec bash "$LIB/infisical-run.sh" "$ENVN" bash "$0" "$ENVN" "$@"
fi

. "$LIB/creds-dir.sh"
. "$LIB/emitter-lib.sh"
cce_emitter_from_overlay "$REPO/k8s/overlays/${OVERLAY_NAME:-$ENVN}" 2>/dev/null || cce_emitter_conf openhim
INF_STATE="${CCE_LOCAL_INFISICAL_DIR:-/opt/cce-local-infisical}"
if [ -r "$INF_STATE/admin.env" ]; then
  INF_ADMIN_EMAIL="$(sed -n 's/^INFISICAL_ADMIN_EMAIL=//p' "$INF_STATE/admin.env")"
  INF_ADMIN_PASSWORD="$(sed -n 's/^INFISICAL_ADMIN_PASSWORD=//p' "$INF_STATE/admin.env")"
fi
export ENVN REVEAL EMITTER_NAME EMITTER_DEPLOYMENT INF_STATE INF_ADMIN_EMAIL INF_ADMIN_PASSWORD CREDS_DIR="$(cce_creds_dir)" \
       PORTAINER_UP="$(systemctl is-active cce-portainer 2>/dev/null || true)"

python3 - <<'PY'
import os
E = os.environ.get
reveal = E("REVEAL") == "1"
def pw(key=None, value=None):
    v = E(key, "") if key else (value or "")
    if not v: return "(not set)"
    return v if reveal else "********"
def val(key, default="(not set)"): return E(key) or default
url = E("CCE_PUBLIC_URL", "http://<this-host>").rstrip("/")
env = E("ENVN")

print(f"== Credentials for environment '{env}'" + ("" if reveal else "   (passwords masked — add --reveal to show)") + " ==")
print(f"   Source: Infisical project for '{env}' (every value below is read live from it), plus the local files listed at the end.\n")

rows = []  # (what, where, user, password, infisical location)
if E("INF_ADMIN_EMAIL"):
    rows.append(("Infisical (holds all of the below)", "ssh -L 8080:localhost:8080 <host>; http://localhost:8080",
                 E("INF_ADMIN_EMAIL"), pw(value=E("INF_ADMIN_PASSWORD")), f"file {E('INF_STATE')}/admin.env"))
else:
    rows.append(("Infisical (holds all of the below)", E("INFISICAL_DOMAIN", "remote Infisical"),
                 "(org admin; not stored on this host)", "-", "-"))
rows += [
    ("Insights UI", f"{url}/insights/", "users of Keycloak realm 'cce' (none are created by the installer)", "-", "-"),
    ("Keycloak admin console", f"{url}/auth/admin/", val("KEYCLOAK_ADMIN_USER"), pw("KEYCLOAK_ADMIN_PASSWORD"),
     "/keycloak KEYCLOAK_ADMIN_*"),
    ("Grafana", f"{url}/grafana/", val("GRAFANA_ADMIN_USER"), pw("GRAFANA_ADMIN_PASSWORD"), "/grafana GRAFANA_ADMIN_*"),
]
if E("PORTAINER_UP") == "active" or E("PORTAINER_ADMIN_PASSWORD"):
    rows.append(("Portainer", "ssh -L 9443:localhost:9443 <host>; https://localhost:9443", "admin",
                 pw("PORTAINER_ADMIN_PASSWORD"), "/portainer PORTAINER_ADMIN_PASSWORD"))
rows += [
    ("PostgreSQL (owner)", f"localhost:{val('POSTGRES_PORT','5432')} db {val('POSTGRES_DATABASE','ccedb')}",
     val("POSTGRES_USER"), pw("POSTGRES_PASSWORD"), "/postgres POSTGRES_USER/PASSWORD"),
    ("PostgreSQL (CDC, read-only)", "same", val("POSTGRES_READ_ONLY_USER"), pw("POSTGRES_READ_ONLY_PASSWORD"),
     "/postgres POSTGRES_READ_ONLY_*"),
    ("PostgreSQL (superuser)", "on the host: sudo -u postgres psql", "postgres", "none (local peer auth)", "-"),
    ("ClickHouse", f"http://localhost:{val('CLICKHOUSE_PORT','8123')} db {val('CLICKHOUSE_DB','cce_analytics')}",
     val("CLICKHOUSE_USER"), pw("CLICKHOUSE_PASSWORD"), "/clickhouse CLICKHOUSE_USER/PASSWORD"),
    ("ClickHouse (default user)", "on the host only: clickhouse-client", "default", "none (loopback only)", "-"),
    (f"Emitter inbound ({E('EMITTER_NAME')}) — give to the source system", f"{url}/v1/{E('EMITTER_DEPLOYMENT')}/inbound  (HTTP Basic)",
     val("EMITTER_INBOUND_USER"), pw("EMITTER_INBOUND_PASSWORD"), "/keycloak EMITTER_INBOUND_*"),
]
for what, where, user, p, loc in rows:
    print(f"-- {what}\n   where:     {where}\n   user:      {user}\n   password:  {p}" + (f"\n   stored in: {loc if loc.startswith('file ') else 'Infisical ' + loc}" if loc != "-" else ""))

print("\n-- Service-to-service secrets (used by the services themselves; you rarely need them)")
for k, label in [("BASIC_AUTH_CLIENT_SECRET", f"gateway Basic-auth client '{val('BASIC_AUTH_CLIENT_ID')}' (/keycloak)"),
                 ("CCE_COLLECTOR_AUTH_TOKEN", "emitter -> collector token (/platform)"),
                 ("CCE_INTELLIGENCE_SMTP_PASSWORD", f"SMTP login '{val('CCE_INTELLIGENCE_SMTP_USERNAME')}' at {val('CCE_INTELLIGENCE_SMTP_HOST')} (/platform)"),
                 ("OPENHIM_PASSWORD", f"OpenHIM login '{val('OPENHIM_USERNAME')}' (/openhim-emitter-adaptor)")]:
    print(f"   {k:<32} {pw(k):<20} {label}")
print("   Kafka (9092) and Kafka Connect (127.0.0.1:8083) have no login; keep 9092 closed to the outside (UFW, or the cloud security group).")

cd = E("CREDS_DIR"); st = E("INF_STATE")
print(f"""
-- Files on this host (0600, root) — BACK THESE UP OFF THE MACHINE; without them Infisical, and so every password above, is lost
   {st}/admin.env      Infisical admin login
   {st}/.env           Infisical's encryption key, auth secret and database password (needed to decrypt its data)
   {cd}/{env}.creds / {env}.meta   machine identity + project id the scripts use to read Infisical

-- Changing a password: Keycloak, Grafana and Portainer keep their admin password in their own database after the first start,
   so editing Infisical alone changes nothing. Grafana + Portainer: sudo bash one-click-installer/lib/set-admin-passwords.sh {env}
   Keycloak admin: change it in the admin console, then update /keycloak KEYCLOAK_ADMIN_PASSWORD in Infisical to match.""")
if reveal:
    print("\n   (Passwords were printed: clear the terminal scrollback if this screen is shared or recorded.)")
PY
