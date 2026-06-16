#!/usr/bin/env bash
# Deploy CCE UAT, pulling ALL config/secrets from the self-hosted Infisical
# (project cce-uat, environment "uat") instead of a local k8s/.env file.
#
# Machine-identity credentials are read from k8s/.infisical.uat — a gitignored,
# server-only file (copy k8s/.infisical.example and fill it in). No secrets live
# in the repo; this wrapper only contains the plumbing.
#
# Requires the Infisical CLI: https://infisical.com/docs/cli/overview
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED="${DIR}/.infisical.uat"

[[ -f "$CRED" ]] || { echo "ERROR: $CRED not found. Copy k8s/.infisical.example to k8s/.infisical.uat and fill in the machine-identity credentials."; exit 1; }
# shellcheck disable=SC1090
source "$CRED"
: "${INFISICAL_API_URL:?}" "${INFISICAL_PROJECT_ID:?}" "${INFISICAL_ENV:?}" "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"

command -v infisical >/dev/null || { echo "ERROR: infisical CLI not installed."; exit 1; }

echo "Authenticating to Infisical ($INFISICAL_API_URL) as machine identity…"
INFISICAL_TOKEN="$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_API_URL" --silent --plain)"
export INFISICAL_TOKEN

# Inject every secret in the environment as a process env var, then run the
# normal deploy — its envsubst step resolves the ${...} placeholders from them.
exec infisical run --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" \
  --domain="$INFISICAL_API_URL" -- "${DIR}/deploy-uat.sh"
