#!/usr/bin/env bash
# one-click-installer/lib/infisical-bootstrap.sh <envcode> [--manual]
# Provision a brand-new Infisical project + Universal Auth machine identity for <envcode>, and
# write the creds/.meta files one-click-installer/lib/infisical-run.sh needs to run anything against it.
#
# BACKGROUND: no script in this repo had ever done this before (every existing prod/uat project +
# identity was created by hand in the Infisical UI — see k8s/.infisical.example). The REST call
# sequence below was reverse-engineered and VERIFIED LIVE against the real self-hosted instance on
# 2026-07-13 (full round-trip: created a throwaway project+identity, logged in AS that identity,
# confirmed project access) — this is not a guess. Two things to know:
#   1. A plain `POST /api/v3/auth/login` (email+password) returns a token with NO organization
#      context — every subsequent org-scoped call 401s with "no organization found in request",
#      even GET /api/v2/users/me. The fix: pass --organization-id to the CLI's own
#      `infisical login --method=user`, which performs whatever extra handshake mints a token with
#      organizationId actually embedded in the JWT. Do NOT try to hand-roll this multi-step login
#      via raw curl — use the CLI for this one step.
#   2. DELETE endpoints (/api/v1/projects/{id}, /api/v1/identities/{id}, project
#      identity-memberships) were FLAKY during testing — the first two delete attempts on a
#      freshly-created project/identity both 500'd; retrying the identical calls minutes later
#      against different test projects succeeded cleanly both times (confirmed via an empty
#      workspace list afterward). Root cause not identified (maybe a brief post-creation race).
#      This script does NOT attempt automatic rollback/cleanup on a partial failure — it prints the
#      created project/identity IDs so a human can delete them (retry if the first attempt 500s).
#
# New projects auto-create three environments with FIXED slugs (dev/staging/prod) — verified live.
# This script always uses the "prod" slug (single real environment per project in our model; see
# one-click-installer/lib/infisical-run.sh's envcode-vs-slug distinction).
#
#   one-click-installer/lib/infisical-bootstrap.sh dev              # attempt automation, fall back to manual on any failure
#   one-click-installer/lib/infisical-bootstrap.sh dev --manual      # skip straight to the guided manual flow
#
# Org-admin credentials: read from INFISICAL_ADMIN_EMAIL/INFISICAL_ADMIN_PASSWORD if set, else
# prompted interactively. NOT the project-scoped machine-identity creds used elsewhere in this
# repo — this needs a real user account with org-admin rights (structurally, a project-scoped
# identity cannot create another project).
set -euo pipefail

ENVCODE="${1:?usage: infisical-bootstrap.sh <envcode> [--manual]}"; shift || true
FORCE_MANUAL=0
[ "${1:-}" = "--manual" ] && FORCE_MANUAL=1

: "${INFISICAL_DOMAIN:=http://localhost:8080}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/creds-dir.sh"
CREDS_DIR="$(cce_creds_dir)"
PROJECT_NAME="cce-${ENVCODE}"
IDENTITY_NAME="cce-${ENVCODE}-identity"
ENV_SLUG="prod"   # every new project's fixed internal slug we standardize on (see header)

mkdir -p "$CREDS_DIR"
CREDS_FILE="$CREDS_DIR/${ENVCODE}.creds"
META_FILE="$CREDS_DIR/${ENVCODE}.meta"
[ -e "$CREDS_FILE" ] && { echo "ERROR: $CREDS_FILE already exists — this env is already bootstrapped"; exit 1; }

log(){ echo "[infisical-bootstrap $ENVCODE] $*"; }

print_manual_instructions() {
  cat <<EOF

============================================================
MANUAL SETUP REQUIRED — do this in the Infisical UI, then come back here.
============================================================
  1. Open Infisical (e.g. ssh -L 8080:localhost:8080 ... then http://localhost:8080) and log in
     as an org admin.
  2. Create a new project named exactly:  ${PROJECT_NAME}
  3. Note its Project ID (Project Settings -> General, or the URL's project id segment).
  4. Organization Settings -> Access Control -> Machine Identities -> Create identity
       Name: ${IDENTITY_NAME}     Org role: No Access (project access is granted separately)
  5. Open that identity -> Add Auth Method -> Universal Auth -> Create Client Secret
     (defaults are fine: trusted IPs 0.0.0.0/0, no TTL/use limit).
     Note the Client ID and the Client Secret NOW — the secret is shown only once.
  6. Back in the ${PROJECT_NAME} project -> Access Control -> Machine Identities -> Add identity
       Select ${IDENTITY_NAME}, role: Admin (or a custom role with secret read/write).
============================================================

EOF
}

# ============================================================ automated attempt
automated_bootstrap() {
  : "${INFISICAL_ADMIN_EMAIL:=}"; : "${INFISICAL_ADMIN_PASSWORD:=}"
  if [ -z "$INFISICAL_ADMIN_EMAIL" ]; then
    read -r -p "Infisical org-admin email: " INFISICAL_ADMIN_EMAIL
  fi
  if [ -z "$INFISICAL_ADMIN_PASSWORD" ]; then
    read -r -s -p "Infisical org-admin password: " INFISICAL_ADMIN_PASSWORD; echo
  fi

  # NOTE: the CLI's `login --method=user` ALWAYS requires --organization-id (errors otherwise) —
  # there's no CLI-level "org-less" login. But the raw REST endpoint it calls under the hood
  # (POST /api/v3/auth/login, undocumented in the public OpenAPI spec but verified live) DOES
  # accept email+password with no org context, returning a token good enough for one thing: GET
  # /api/v1/organization to discover which org(s) this admin belongs to. So this discovery step
  # must be a raw curl call, not the CLI — only the second, org-scoped login (below) uses the CLI.
  log "logging in (org-less, to discover organization)..."
  local probe_token org_json org_id
  probe_token=$(curl -sf -X POST "$INFISICAL_DOMAIN/api/v3/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${INFISICAL_ADMIN_EMAIL}\",\"password\":\"${INFISICAL_ADMIN_PASSWORD}\",\"providerAuthToken\":null}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))') || return 1
  [ -n "$probe_token" ] || return 1

  org_json=$(curl -sf "$INFISICAL_DOMAIN/api/v1/organization" -H "Authorization: Bearer $probe_token") || return 1
  org_id=$(printf '%s' "$org_json" | python3 -c 'import json,sys
orgs = json.load(sys.stdin).get("organizations", [])
print(orgs[0]["id"] if len(orgs) == 1 else "")')
  if [ -z "$org_id" ]; then
    log "  could not auto-select a single organization (0 or >1 found) — falling back to manual"
    return 1
  fi
  log "  organization: $org_id"

  log "logging in (org-scoped)..."
  local token
  token=$(infisical login --method=user --email="$INFISICAL_ADMIN_EMAIL" \
    --password="$INFISICAL_ADMIN_PASSWORD" --organization-id="$org_id" \
    --plain --silent --domain="$INFISICAL_DOMAIN" 2>/dev/null) || return 1
  [ -n "$token" ] || return 1

  api() { # method path json_body
    curl -sf -X "$1" "$INFISICAL_DOMAIN/api$2" -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" -d "$3"
  }

  log "creating project '$PROJECT_NAME'..."
  local proj_json project_id
  proj_json=$(api POST /v1/projects "{\"projectName\":\"${PROJECT_NAME}\"}") || return 1
  project_id=$(printf '%s' "$proj_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["project"]["id"])') || return 1
  log "  project_id=$project_id"

  log "creating identity '$IDENTITY_NAME'..."
  local id_json identity_id
  id_json=$(api POST /v1/identities "{\"name\":\"${IDENTITY_NAME}\",\"organizationId\":\"${org_id}\",\"role\":\"no-access\"}") || {
    log "  !! FAILED after creating project $project_id — clean it up via the UI (or DELETE"
    log "     /api/v1/projects/$project_id) if this run isn't retried; deletion has been flaky here."
    return 1
  }
  identity_id=$(printf '%s' "$id_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["identity"]["id"])') || return 1
  log "  identity_id=$identity_id"

  log "configuring Universal Auth..."
  local ua_json client_id
  ua_json=$(api POST "/v1/auth/universal-auth/identities/${identity_id}" '{}') || {
    log "  !! FAILED — orphaned: project=$project_id identity=$identity_id"; return 1; }
  client_id=$(printf '%s' "$ua_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["identityUniversalAuth"]["clientId"])') || return 1

  log "creating client secret..."
  local cs_json client_secret
  cs_json=$(api POST "/v1/auth/universal-auth/identities/${identity_id}/client-secrets" \
    "{\"description\":\"one-click-installer ${ENVCODE}\"}") || {
    log "  !! FAILED — orphaned: project=$project_id identity=$identity_id"; return 1; }
  client_secret=$(printf '%s' "$cs_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientSecret"])') || return 1

  log "granting the identity admin access on the project..."
  api POST "/v1/projects/${project_id}/identity-memberships/${identity_id}" '{"role":"admin"}' >/dev/null || {
    log "  !! FAILED — orphaned: project=$project_id identity=$identity_id (client secret was issued but"
    log "     never granted project access — the creds below won't work until this is fixed manually)."
    return 1
  }

  log "verifying the new identity can actually authenticate..."
  local verify
  verify=$(curl -sf -X POST "$INFISICAL_DOMAIN/api/v1/auth/universal-auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\":\"${client_id}\",\"clientSecret\":\"${client_secret}\"}") || return 1
  printf '%s' "$verify" | python3 -c 'import json,sys;json.load(sys.stdin)["accessToken"]' >/dev/null 2>&1 || return 1

  echo "INFISICAL_CLIENT_ID=${client_id}" > "$CREDS_FILE"
  echo "INFISICAL_CLIENT_SECRET=${client_secret}" >> "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  echo "PROJECT_ID=${project_id}" > "$META_FILE"
  echo "INFISICAL_ENV_SLUG=${ENV_SLUG}" >> "$META_FILE"
  chmod 600 "$META_FILE"
  log "SUCCESS — project=$project_id identity=$identity_id"
  log "  wrote $CREDS_FILE and $META_FILE"
  return 0
}

# ============================================================ manual fallback
manual_bootstrap() {
  print_manual_instructions
  local project_id client_id client_secret
  read -r -p "Project ID: " project_id
  read -r -p "Client ID: " client_id
  read -r -s -p "Client Secret: " client_secret; echo

  echo "INFISICAL_CLIENT_ID=${client_id}" > "$CREDS_FILE"
  echo "INFISICAL_CLIENT_SECRET=${client_secret}" >> "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  echo "PROJECT_ID=${project_id}" > "$META_FILE"
  echo "INFISICAL_ENV_SLUG=${ENV_SLUG}" >> "$META_FILE"
  chmod 600 "$META_FILE"

  log "verifying the identity can authenticate..."
  set -a; . "$CREDS_FILE"; set +a
  local verify
  verify=$(curl -sf -X POST "$INFISICAL_DOMAIN/api/v1/auth/universal-auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\":\"${INFISICAL_CLIENT_ID}\",\"clientSecret\":\"${INFISICAL_CLIENT_SECRET}\"}") || {
    echo "ERROR: could not authenticate with the provided Client ID/Secret"; rm -f "$CREDS_FILE" "$META_FILE"; exit 1; }
  printf '%s' "$verify" | python3 -c 'import json,sys;json.load(sys.stdin)["accessToken"]' >/dev/null 2>&1 || {
    echo "ERROR: login succeeded but no accessToken in response — check manually"; exit 1; }
  log "SUCCESS — wrote $CREDS_FILE and $META_FILE"
}

# ============================================================ main
if [ "$FORCE_MANUAL" = 1 ]; then
  manual_bootstrap
else
  log "attempting automated bootstrap..."
  if automated_bootstrap; then
    exit 0
  fi
  log "automated bootstrap did not complete — falling back to manual"
  manual_bootstrap
fi
