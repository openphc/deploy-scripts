#!/usr/bin/env bash
# Deploy CCE UAT environment to k3s
# Usage:
#   ./deploy-uat.sh                      # reads config/secrets from k8s/.env
#   ./deploy-uat-infisical.sh            # pulls config/secrets from Infisical (no .env needed)
#   infisical run --env=uat -- ./deploy-uat.sh
#
# Config/secrets are resolved from the process environment (envsubst). They can be
# supplied either by a local k8s/.env file OR injected by Infisical — if neither is
# present the required-variable checks below will fail loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  # Auto-export every variable defined in .env so envsubst can resolve the
  # ${...} placeholders in the kustomization (config + secrets) and network policy.
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "No $ENV_FILE found — using variables already in the environment (e.g. injected by Infisical)."
fi

: "${VM_HOST_IP:?VM_HOST_IP not set (provide via k8s/.env or Infisical)}"
: "${ACME_EMAIL:?Set ACME_EMAIL (used for Traefik ACME/TLS certs)}"

echo "Deploying CCE UAT with VM_HOST_IP=${VM_HOST_IP}"

# Generate final manifests with variable substitution
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Configure cluster-global Traefik ACME / TLS (kube-system) — applied outside kustomize so its
# namespace is preserved. Triggers a brief Traefik redeploy.
envsubst < "${SCRIPT_DIR}/base/traefik/traefik-helmchartconfig.yaml" > "${TMPDIR}/traefik-helmchartconfig.yaml"
kubectl apply -f "${TMPDIR}/traefik-helmchartconfig.yaml"

# Substitute variables in kustomization overlay
envsubst < "${SCRIPT_DIR}/overlays/uat/kustomization.yaml" > "${TMPDIR}/kustomization.yaml"
cp "${TMPDIR}/kustomization.yaml" "${SCRIPT_DIR}/overlays/uat/kustomization.yaml.rendered"

# Substitute variables in network policy
envsubst < "${SCRIPT_DIR}/base/network-policy.yaml" > "${TMPDIR}/network-policy.yaml"
cp "${TMPDIR}/network-policy.yaml" "${SCRIPT_DIR}/base/network-policy.yaml.rendered"

# Apply using kustomize with rendered files
# First apply the network policy directly (it has the IP substitution)
kubectl apply -f "${TMPDIR}/network-policy.yaml" -n cce-uat

# For kustomize, we need to temporarily swap in the rendered file
cp "${SCRIPT_DIR}/overlays/uat/kustomization.yaml" "${SCRIPT_DIR}/overlays/uat/kustomization.yaml.tpl"
cp "${TMPDIR}/kustomization.yaml" "${SCRIPT_DIR}/overlays/uat/kustomization.yaml"

kubectl apply -k "${SCRIPT_DIR}/overlays/uat"

# Restore template
mv "${SCRIPT_DIR}/overlays/uat/kustomization.yaml.tpl" "${SCRIPT_DIR}/overlays/uat/kustomization.yaml"

# Clean up rendered files
rm -f "${SCRIPT_DIR}/overlays/uat/kustomization.yaml.rendered"
rm -f "${SCRIPT_DIR}/base/network-policy.yaml.rendered"

echo "Deployment complete. Check pods: kubectl -n cce-uat get pods"
