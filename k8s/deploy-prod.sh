#!/usr/bin/env bash
# Deploy CCE PROD environment to k3s
# Usage: ./deploy-prod.sh
#
# Config/secrets are resolved from the process environment (envsubst). Supply them either via a
# local k8s/.env.prod file OR by running under Infisical (rw/lib/infisical-run.sh prod -- ...),
# which injects them — if neither is present the required-variable checks below fail loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.prod"

if [[ -f "$ENV_FILE" ]]; then
  # Auto-export every variable defined in .env.prod so envsubst can resolve the
  # ${...} placeholders in the kustomization (config + secrets) and network policy.
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "No $ENV_FILE found — using variables already in the environment (e.g. injected by Infisical)."
fi

: "${VM_HOST_IP:?VM_HOST_IP not set (provide via k8s/.env.prod or Infisical)}"

: "${ACME_EMAIL:?Set ACME_EMAIL in .env.prod (used for Traefik ACME/TLS certs)}"

echo "Deploying CCE PROD with VM_HOST_IP=${VM_HOST_IP}, INGRESS_HOST=${INGRESS_HOST}"

# Generate final manifests with variable substitution
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Configure cluster-global Traefik ACME / TLS (kube-system) — applied outside kustomize so its
# namespace is preserved. Triggers a brief Traefik redeploy.
envsubst < "${SCRIPT_DIR}/base/traefik/traefik-helmchartconfig.yaml" > "${TMPDIR}/traefik-helmchartconfig.yaml"
kubectl apply -f "${TMPDIR}/traefik-helmchartconfig.yaml"

# Substitute variables in kustomization overlay
envsubst < "${SCRIPT_DIR}/overlays/prod/kustomization.yaml" > "${TMPDIR}/kustomization.yaml"

# Substitute variables in network policy
envsubst < "${SCRIPT_DIR}/base/network-policy.yaml" > "${TMPDIR}/network-policy.yaml"

# Apply network policy
kubectl apply -f "${TMPDIR}/network-policy.yaml" -n cce-prod

# Swap in rendered kustomization for kustomize build
cp "${SCRIPT_DIR}/overlays/prod/kustomization.yaml" "${SCRIPT_DIR}/overlays/prod/kustomization.yaml.tpl"
cp "${TMPDIR}/kustomization.yaml" "${SCRIPT_DIR}/overlays/prod/kustomization.yaml"

kubectl apply -k "${SCRIPT_DIR}/overlays/prod"

# Restore template
mv "${SCRIPT_DIR}/overlays/prod/kustomization.yaml.tpl" "${SCRIPT_DIR}/overlays/prod/kustomization.yaml"

echo "PROD deployment complete. Check pods: kubectl -n cce-prod get pods"
