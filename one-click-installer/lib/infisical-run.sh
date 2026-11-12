#!/usr/bin/env bash
# one-click-installer/lib/infisical-run.sh — run a command with a project's secrets injected from Infisical
# (self-hosted). Infisical is the SINGLE SOURCE OF TRUTH for config/secrets; this replaces the
# old k8s/.env, k8s/.env.prod and data-pipeline/.env files.
#
#   Usage:  one-click-installer/lib/infisical-run.sh <prod|uat> <command...>
#   e.g.:   one-click-installer/lib/infisical-run.sh prod  bash rw/prod/install-all.sh
#           one-click-installer/lib/infisical-run.sh prod  bash rw/prod/05-k8s-deploy.sh
#           one-click-installer/lib/infisical-run.sh uat   bash rw/uat/deploy-all.sh
#
# Auth: a per-env Universal Auth machine identity (project-scoped). Its Client ID/Secret live in a
# 0600 creds file OUTSIDE the repo (the bootstrap "secret zero"); nothing else is stored on disk.
#
# Env resolution: "prod"/"uat" are a fast-path (their project IDs are hardcoded below, unchanged
# since before multi-env support — zero regression risk for the two existing live environments).
# Any OTHER env code falls back to a per-env metadata file written once by
# one-click-installer/lib/infisical-bootstrap.sh (one-click-installer/install.sh's project/identity provisioning step):
#   $CREDS_DIR/<env>.meta containing PROJECT_ID=... and INFISICAL_ENV_SLUG=...
# ENVCODE (the CLI arg / namespace suffix, e.g. "dev") and INFISICAL_ENV_SLUG (the environment
# *within* that project, e.g. Infisical's own default slug "prod") are DIFFERENT axes — a new
# project has exactly one real environment, so its internal slug need not equal the operator's
# env code. See one-click-installer/lib/infisical-run.sh's case-switch below vs. the .meta fallback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENVNAME="${1:?usage: infisical-run.sh <env> <cmd...>  (any env code bootstrapped by install.sh)}"; shift || true
DOMAIN="${INFISICAL_DOMAIN:-http://localhost:8080}"
. "$HERE/creds-dir.sh"
CREDS_DIR="$(cce_creds_dir)"
# Generic installer: every environment is resolved from its .meta file — no deployment's project IDs are hardcoded.
META="$CREDS_DIR/${ENVNAME}.meta"
[ -r "$META" ] || {
  echo "ERROR: unknown env '$ENVNAME' — no $META"
  echo "       Bootstrap it first: one-click-installer/install.sh (or one-click-installer/lib/infisical-bootstrap.sh)"
  exit 1
}
set -a; . "$META"; set +a   # provides PROJECT_ID + INFISICAL_ENV_SLUG (written by infisical-bootstrap.sh)
: "${PROJECT_ID:?$META must set PROJECT_ID}"
: "${INFISICAL_ENV_SLUG:?$META must set INFISICAL_ENV_SLUG}"

CREDS="$CREDS_DIR/${ENVNAME}.creds"
[ -r "$CREDS" ] || { echo "ERROR: missing/unreadable Infisical creds: $CREDS"; exit 1; }
set -a; . "$CREDS"; set +a        # provides INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET
: "${INFISICAL_CLIENT_ID:?creds file must set INFISICAL_CLIENT_ID}"
: "${INFISICAL_CLIENT_SECRET:?creds file must set INFISICAL_CLIENT_SECRET}"

TOKEN="$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --plain --silent --domain="$DOMAIN")"
[ -n "$TOKEN" ] || { echo "ERROR: Infisical Universal-Auth login failed for env=$ENVNAME"; exit 1; }

# Secrets are organised into per-component folders (postgres, clickhouse, kafka-connect, keycloak,
# grafana, openhim-emitter-adaptor, cce-collector-service, platform). --recursive flattens every
# folder under / into the env so callers see all keys regardless of folder.
# NOTE: `infisical run --recursive` works on this CLI (0.43.x); `infisical export --recursive` does
# NOT (returns nothing) — for a break-glass dotenv export, loop per-folder instead (see DR docs).
#
# The command is wrapped in host-ip-exec.sh, which runs AFTER Infisical's values are injected and
# fills the IP-dependent variables (VM_HOST_IP, POSTGRES_HOST, KAFKA_BOOTSTRAP_SERVERS, ...) from the
# detected host address ONLY IF Infisical doesn't set them — so the server's IP need not be stored
# (and can't go stale). A stored value that disagrees with the detected IP triggers a warning.
# See one-click-installer/lib/host-ip.sh.
exec env INFISICAL_TOKEN="$TOKEN" \
  infisical run --recursive --path=/ --projectId="$PROJECT_ID" --env="$INFISICAL_ENV_SLUG" --domain="$DOMAIN" -- \
  bash "$HERE/host-ip-exec.sh" "$ENVNAME" "$@"
