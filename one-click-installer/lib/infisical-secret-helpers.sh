#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/creds-dir.sh"   # cce_creds_dir
# one-click-installer/lib/infisical-secret-helpers.sh — shared Infisical secret helpers. SOURCE this file
# (not executable on its own); it defines functions, does not run anything.
#
# Used by one-click-installer/lib/native/07-monitoring-exporters.sh and one-click-installer/lib/infisical-seed.sh so there's one
# implementation of "reuse an existing secret, or generate+store a new one" (idempotent — safe to
# re-run; never rotates a value that already exists).
#
# Functions:
#   infisical_login                                          -> sets/exports INFISICAL_TOKEN
#   infisical_get       <path> <key> <projectId> <envSlug>    -> prints value, or empty if unset
#   infisical_set       <path> <key> <projectId> <envSlug> <value>
#   infisical_get_or_generate <path> <key> <projectId> <envSlug> [generator_cmd...] -> prints value
#
# Requires INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET in the environment (as injected by
# one-click-installer/lib/infisical-run.sh) and INFISICAL_DOMAIN (defaults to http://localhost:8080).

: "${INFISICAL_DOMAIN:=http://localhost:8080}"

# Resolve an env code to (PROJECT_ID, INFISICAL_ENV_SLUG) using the SAME logic as
# one-click-installer/lib/infisical-run.sh's case-switch + .meta fallback (kept in sync manually — this is a
# small, stable lookup, not worth a shared-file coupling between the two). Sets the two vars in
# the caller's scope (not a subshell) so callers just do: infisical_resolve_project prod; echo
# "$PROJECT_ID $INFISICAL_ENV_SLUG"
infisical_resolve_project() {
  local envcode="$1" creds_dir="${2:-$(cce_creds_dir)}"
  local meta="$creds_dir/${envcode}.meta"
  [ -r "$meta" ] || { echo "ERROR: no project for env '$envcode' — missing $meta" >&2; return 1; }
  set -a; . "$meta"; set +a
  : "${PROJECT_ID:?$meta must set PROJECT_ID}"
  : "${INFISICAL_ENV_SLUG:?$meta must set INFISICAL_ENV_SLUG}"
  export PROJECT_ID INFISICAL_ENV_SLUG
}

infisical_login() {
  : "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID not set — run this under one-click-installer/lib/infisical-run.sh}"
  : "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET not set}"
  INFISICAL_TOKEN=$(infisical login --method=universal-auth \
    --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
    --plain --silent --domain="$INFISICAL_DOMAIN")
  [ -n "$INFISICAL_TOKEN" ] || { echo "ERROR: Infisical Universal-Auth login failed" >&2; return 1; }
  export INFISICAL_TOKEN
}

infisical_get() {
  local path="$1" key="$2" project_id="$3" env_slug="$4"
  : "${INFISICAL_TOKEN:?call infisical_login first}"
  INFISICAL_TOKEN="$INFISICAL_TOKEN" infisical secrets get "$key" \
    --path="$path" --projectId="$project_id" --env="$env_slug" --domain="$INFISICAL_DOMAIN" \
    --plain 2>/dev/null || true
}

# Folders do NOT auto-vivify — `secrets set --path=/foo` 404s on a fresh project until /foo is
# explicitly created (discovered 2026-07-13 seeding a brand-new project; existing prod/uat
# projects already had their folders, so this never surfaced before). Ensure-once per (project,
# path) using an in-process cache so a seeding run touching the same folder repeatedly doesn't
# reissue the create call every time.
declare -A _INFISICAL_FOLDERS_ENSURED
infisical_ensure_folder() {
  local path="$1" project_id="$2" env_slug="$3"
  [ "$path" = "/" ] && return 0
  local cache_key="${project_id}:${env_slug}:${path}"
  [ -n "${_INFISICAL_FOLDERS_ENSURED[$cache_key]:-}" ] && return 0
  : "${INFISICAL_TOKEN:?call infisical_login first}"
  INFISICAL_TOKEN="$INFISICAL_TOKEN" infisical secrets folders create \
    --name="${path#/}" --path=/ --env="$env_slug" --projectId="$project_id" \
    --domain="$INFISICAL_DOMAIN" >/dev/null 2>&1 || true   # idempotent: ignore "already exists"
  _INFISICAL_FOLDERS_ENSURED[$cache_key]=1
}

infisical_set() {
  local path="$1" key="$2" project_id="$3" env_slug="$4" value="$5"
  : "${INFISICAL_TOKEN:?call infisical_login first}"
  infisical_ensure_folder "$path" "$project_id" "$env_slug"
  INFISICAL_TOKEN="$INFISICAL_TOKEN" infisical secrets set --path="$path" \
    --projectId="$project_id" --env="$env_slug" --domain="$INFISICAL_DOMAIN" "$key=$value" >/dev/null
}

# Default generator: a random 32-char alnum string (openssl rand, filtered).
_infisical_default_generator() { openssl rand -base64 24 | tr -d '=+/' | head -c 32; }

infisical_get_or_generate() {
  local path="$1" key="$2" project_id="$3" env_slug="$4"; shift 4 || true
  local existing
  existing=$(infisical_get "$path" "$key" "$project_id" "$env_slug")
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi
  local value
  if [ "$#" -gt 0 ]; then
    value=$("$@")
  else
    value=$(_infisical_default_generator)
  fi
  infisical_set "$path" "$key" "$project_id" "$env_slug" "$value"
  printf '%s' "$value"
}
