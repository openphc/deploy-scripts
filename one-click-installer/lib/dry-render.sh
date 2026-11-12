#!/usr/bin/env bash
# one-click-installer/lib/dry-render.sh <envcode> — render the env's overlay exactly as the deploy will, WITHOUT applying anything
# and without touching the real overlay (it renders a throwaway copy of k8s/). Run under infisical-run.sh so values are injected.
set -euo pipefail
ENVCODE="${1:?usage: dry-render.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
NAME="${OVERLAY_NAME:-$ENVCODE}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp -r "$REPO/k8s" "$T/k8s"
export VM_HOST_CIDR="${VM_HOST_CIDR:-${VM_HOST_IP}/32}"
envsubst < "$T/k8s/overlays/$NAME/kustomization.yaml" > "$T/k.yaml" && mv "$T/k.yaml" "$T/k8s/overlays/$NAME/kustomization.yaml"
KUBECTL="kubectl"; command -v kubectl >/dev/null 2>&1 || KUBECTL="k3s kubectl"
$KUBECTL kustomize "$T/k8s/overlays/$NAME" > "$T/render.yaml" 2>"$T/err" || { echo "  !! render FAILED:"; cat "$T/err"; exit 1; }
# NB: do not treat leftover ${...} in the render as errors — Grafana provisioning and some container commands contain ${VAR}
# references that are resolved INSIDE the pod at runtime, on purpose. Overlay variables without a value are caught earlier,
# by overlay-vars-check.sh.
echo "  render OK: $(grep -c '^kind:' "$T/render.yaml") resources"
