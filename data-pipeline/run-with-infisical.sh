#!/usr/bin/env bash
# Run the data-pipeline docker-compose with config/secrets injected from Infisical
# (project cce-uat, env uat) instead of a local data-pipeline/.env file.
#
#   ./run-with-infisical.sh up -d        # any docker-compose arguments
#   ./run-with-infisical.sh down
#
# docker-compose's ${VAR} substitution prefers the process environment that
# `infisical run` populates, so no .env file is required. Reads the same gitignored
# machine-identity credentials as the k8s deploy (k8s/.infisical.uat).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED="${DIR}/../k8s/.infisical.uat"

[[ -f "$CRED" ]] || { echo "ERROR: $CRED not found. Copy k8s/.infisical.example to k8s/.infisical.uat and fill it in."; exit 1; }
# shellcheck disable=SC1090
source "$CRED"
: "${INFISICAL_API_URL:?}" "${INFISICAL_PROJECT_ID:?}" "${INFISICAL_ENV:?}" "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"

command -v infisical >/dev/null || { echo "ERROR: infisical CLI not installed."; exit 1; }

INFISICAL_TOKEN="$(infisical login --method=universal-auth \
  --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
  --domain="$INFISICAL_API_URL" --silent --plain)"
export INFISICAL_TOKEN

cd "$DIR"
exec infisical run --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV" \
  --domain="$INFISICAL_API_URL" -- docker-compose "$@"
