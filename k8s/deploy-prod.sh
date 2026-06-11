#!/usr/bin/env bash
# Deploy CCE PROD environment to k3s
# Usage: ./deploy-prod.sh
#
# Requires: .env.prod file in k8s/ directory (copy from .env.example)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.prod"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example to .env.prod and fill in PROD values."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${ACME_EMAIL:?Set ACME_EMAIL in .env.prod (used for Traefik ACME/TLS certs)}"
export VM_HOST_IP VM_HOST_CIDR INGRESS_HOST ACME_EMAIL

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
