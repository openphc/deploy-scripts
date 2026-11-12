#!/usr/bin/env bash
# one-click-installer/lib/redeploy.sh — one command to roll out config AND/OR image changes for the CCE k8s services.
#
# Use it after EITHER (or both):
#   - an env-variable value changed in Infisical, and/or
#   - a new CCE service image was pushed to GHCR (mutable :latest / :demo-rw-latest tag).
#
# What it does:
#   1. (REFRESH_ENV=1, default) re-pull config/secrets from Infisical — re-render the overlay and
#      apply the cce-config ConfigMap + cce-secrets Secret, so the latest env values are in-cluster.
#   2. rollout-restart the target deployment(s). The overlays pin MUTABLE tags with
#      imagePullPolicy: Always, so `kubectl apply` alone won't redeploy an unchanged tag (same spec =
#      no rollout = no pull); the restart recreates the pods, which pull the current image AND re-read
#      the refreshed ConfigMap/Secret. (Secrets/ConfigMaps use disableNameSuffixHash, so applying them
#      does not by itself roll pods — the restart in step 2 is what makes the new values take effect.)
#
# Since redeploy normally runs directly (not under infisical-run), step 1 re-execs the script with the
# project's secrets injected. Set REFRESH_ENV=0 to skip step 1 (image-only rollout).
#
#   one-click-installer/lib/redeploy.sh <namespace> [deployment...]
#     - with no names: ALL CCE app deployments (those whose image is ghcr.io/openphc/*)
#     - with names:    just those deployments
#   DRY_RUN=1     -> print what would be refreshed/restarted, change nothing
#   REFRESH_ENV=0 -> skip the Infisical config refresh (image-only rollout)
#   CHANGED_ONLY=1 -> restart ONLY deployments that actually changed: an env value they consume
#                     (via rollout-changed.sh) OR a newer image digest for their tag (image-changed.sh).
#                     Skips services that are already current — handy for "redeploy whatever changed".
#   IMAGE_TAG=<tag>           -> pin the (single) target deployment to <repo>:<tag> via
#                                `kubectl set image` instead of a rollout restart. <repo> is read from
#                                the deployment's CURRENT image, so only the tag changes. Requires
#                                exactly one target deployment (ambiguous otherwise: different
#                                services use different repos) — for multiple deployments at once,
#                                each with its own version, use ASK_VERSION=1 instead.
#   IMAGE_DIGEST=<sha256:...> -> same, but pins to <repo>@sha256:... (an exact digest). Wins over
#                                IMAGE_TAG if both are set. Use this to guarantee a specific build is
#                                deployed regardless of what a mutable tag currently resolves to in
#                                the registry — e.g. re-deploying a known-good digest mid-incident
#                                without risking a newer (possibly untested) push to that tag.
#   ASK_VERSION=1             -> interactively prompt for a tag/digest PER target deployment (each
#                                service needs its own version — a single IMAGE_TAG/IMAGE_DIGEST
#                                would be wrong applied uniformly across different services). Blank
#                                answer keeps that deployment on a plain rollout restart (current
#                                behavior, unpinned). Requires a TTY; not for non-interactive/CI use
#                                (use per-deployment IMAGE_TAG/IMAGE_DIGEST calls instead there).
#   ROLLOUT_TIMEOUT=180s, WAIT_DELETE_TIMEOUT=90s  -> tunable waits
#
# Run as root on the host (e.g. `sudo bash rw/uat/redeploy.sh ...`) so kubectl can reach k3s.
set -euo pipefail

NS="${1:?usage: redeploy.sh <namespace> [deployment...]}"; shift || true
DRY_RUN="${DRY_RUN:-}"
REFRESH_ENV="${REFRESH_ENV:-1}"   # 1 = re-pull cce-config/cce-secrets from Infisical before rolling
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_DIGEST="${IMAGE_DIGEST:-}"
ASK_VERSION="${ASK_VERSION:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
WAIT_DELETE_TIMEOUT="${WAIT_DELETE_TIMEOUT:-90s}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# Namespace cce-<env> maps to Infisical env <env> when that env was bootstrapped (it has a .meta); otherwise the config
# refresh is skipped and only the image roll happens.
. "$HERE/creds-dir.sh"
IENV="${NS#cce-}"; [ -r "$(cce_creds_dir)/${IENV}.meta" ] || IENV=""

# To pull the latest config/secrets, re-exec under infisical-run so the project's secrets are in the
# env for the render below — unless they're already injected (VM_HOST_IP set, e.g. called from
# deploy-all.sh --pull-images), this is already the re-exec (marker set), or REFRESH_ENV=0.
if [ "$REFRESH_ENV" != "0" ] && [ -z "${__CCE_REDEPLOY_REEXEC:-}" ] && [ -n "$IENV" ] && [ -z "${VM_HOST_IP:-}" ]; then
  export __CCE_REDEPLOY_REEXEC=1
  echo "redeploy: pulling latest config from Infisical ($IENV) — re-exec under infisical-run…"
  exec bash "$HERE/infisical-run.sh" "$IENV" bash "$0" "$NS" "$@"
fi

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found"; exit 1; fi
fi

# Re-render the overlay from the (Infisical-injected) env and apply ONLY the cce-config ConfigMap +
# cce-secrets Secret, so the rollout below brings pods back with the latest env values. No-op when
# REFRESH_ENV=0 or the namespace isn't mapped to an Infisical project.
refresh_env() {
  if [ "$REFRESH_ENV" = "0" ]; then echo "  REFRESH_ENV=0 — skipping config refresh (image-only)."; return 0; fi
  [ -z "$IENV" ] && { echo "  ns=$NS not mapped to an Infisical project — skipping config refresh."; return 0; }
  local overlay="$REPO/k8s/overlays/${OVERLAY_NAME:-$IENV}"
  if [ -n "$DRY_RUN" ]; then
    echo "  DRY_RUN: would render $overlay from Infisical ($IENV) and apply ConfigMap/cce-config + Secret/cce-secrets to $NS."
    return 0
  fi
  echo "== refresh config: regenerate cce-config + cce-secrets from Infisical ($IENV) =="
  : "${VM_HOST_IP:?VM_HOST_IP missing — Infisical env not injected (set REFRESH_ENV=0 to skip the refresh)}"
  export VM_HOST_CIDR="${VM_HOST_CIDR:-${VM_HOST_IP}/32}"
  local tmp; tmp="$(mktemp -d)"
  cp "$overlay/kustomization.yaml" "$overlay/kustomization.yaml.bak"
  envsubst < "$overlay/kustomization.yaml.bak" > "$overlay/kustomization.yaml"
  if $KUBECTL kustomize "$overlay" > "$tmp/render.yaml"; then
    mv "$overlay/kustomization.yaml.bak" "$overlay/kustomization.yaml"
  else
    mv "$overlay/kustomization.yaml.bak" "$overlay/kustomization.yaml"
    rm -rf "$tmp"; echo "  !! kustomize render failed"; return 1
  fi
  python3 - "$tmp/render.yaml" > "$tmp/env.yaml" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
keep = []
for doc in re.split(r'(?m)^---\s*$', txt):
    is_cm  = re.search(r'(?m)^kind:\s*ConfigMap\s*$', doc) and re.search(r'(?m)^\s{2}name:\s*cce-config\s*$', doc)
    is_sec = re.search(r'(?m)^kind:\s*Secret\s*$', doc)    and re.search(r'(?m)^\s{2}name:\s*cce-secrets\s*$', doc)
    if is_cm or is_sec:
        keep.append(doc.strip())
if not keep:
    sys.exit("ERROR: cce-config / cce-secrets not found in rendered overlay")
sys.stdout.write("\n---\n".join(keep) + "\n")
PY
  $KUBECTL apply -n "$NS" -f "$tmp/env.yaml"
  rm -rf "$tmp"
}

# Candidate deployments: the named ones, else ALL ghcr.io/openphc/* app deployments.
CANDIDATES=("$@")
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  mapfile -t CANDIDATES < <($KUBECTL -n "$NS" get deploy -o json | python3 -c '
import sys, json
for d in json.load(sys.stdin).get("items", []):
    imgs = [c.get("image", "") for c in d["spec"]["template"]["spec"].get("containers", [])]
    if any("ghcr.io/openphc/" in i for i in imgs):
        print(d["metadata"]["name"])')
fi
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "redeploy: no target deployments in $NS (no ghcr.io/openphc/* images?)"; exit 0
fi

# IMAGE_TAG/IMAGE_DIGEST pin a specific image ref instead of rollout-restarting onto whatever a
# mutable tag currently resolves to — only unambiguous with exactly one target deployment, since
# different services use different image repos. For multiple deployments each needing their own
# version, use ASK_VERSION=1 instead (prompts per-deployment).
if [ -n "$IMAGE_TAG$IMAGE_DIGEST" ] && [ "${#CANDIDATES[@]}" -ne 1 ]; then
  echo "ERROR: IMAGE_TAG/IMAGE_DIGEST requires exactly one target deployment (got: ${CANDIDATES[*]}) — use ASK_VERSION=1 for multiple"
  exit 1
fi
if [ -n "$ASK_VERSION" ] && [ ! -t 0 ]; then
  echo "ERROR: ASK_VERSION=1 requires an interactive terminal (stdin is not a TTY)"
  exit 1
fi

# CHANGED_ONLY: snapshot env BEFORE the config refresh so we can tell which deployments actually
# changed (env or image), and restart only those.
CHANGED_ONLY="${CHANGED_ONLY:-}"
SNAP=""
if [ -n "$CHANGED_ONLY" ]; then
  SNAP="$(mktemp)"
  KUBECTL="$KUBECTL" bash "$HERE/rollout-changed.sh" "$NS" "$SNAP" capture
fi

# Step 1: refresh config/secrets from Infisical so the restart picks up new env values + new image.
refresh_env

# Decide what to roll.
if [ -n "$CHANGED_ONLY" ]; then
  ENV_CHANGED="$(KUBECTL="$KUBECTL" bash "$HERE/rollout-changed.sh" "$NS" "$SNAP" list)"
  IMG_CHANGED="$(KUBECTL="$KUBECTL" bash "$HERE/image-changed.sh" "$NS" "${CANDIDATES[@]}")"
  rm -f "$SNAP"
  # union(env, image) intersected with CANDIDATES, preserving membership
  mapfile -t TARGETS < <(
    { printf '%s\n' "$ENV_CHANGED"; printf '%s\n' "$IMG_CHANGED"; } | sed '/^$/d' | sort -u |
    grep -xF -f <(printf '%s\n' "${CANDIDATES[@]}") )
  echo "redeploy (ns=$NS, CHANGED_ONLY): env-changed=[$(echo $ENV_CHANGED)] image-changed=[$(echo $IMG_CHANGED)]"
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "redeploy: nothing changed (env + image up to date) — nothing to redeploy."; exit 0
  fi
else
  TARGETS=("${CANDIDATES[@]}")
fi

echo "redeploy (ns=$NS): ${TARGETS[*]}"

if [ -n "$DRY_RUN" ]; then
  if [ -n "$ASK_VERSION" ]; then
    echo "  DRY_RUN=1 — would prompt for a version per deployment above, pinning each answer via 'kubectl set image' (no changes made)."
  elif [ -n "$IMAGE_DIGEST" ]; then
    echo "  DRY_RUN=1 — would 'kubectl set image' ${TARGETS[0]} to <repo>@$IMAGE_DIGEST (no changes made)."
  elif [ -n "$IMAGE_TAG" ]; then
    echo "  DRY_RUN=1 — would 'kubectl set image' ${TARGETS[0]} to <repo>:$IMAGE_TAG (no changes made)."
  else
    echo "  DRY_RUN=1 — would 'rollout restart' each of the above (no changes made)."
  fi
  exit 0
fi

# Is a deployment managed by an HPA? (then don't scale it to 0 in the fallback — it'd fight the HPA)
hpa_managed() {
  $KUBECTL -n "$NS" get hpa -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.name}{"\n"}{end}' 2>/dev/null \
    | grep -qx "$1"
}

# Resolves a tag-or-digest answer (from IMAGE_TAG/IMAGE_DIGEST or an ASK_VERSION prompt) against
# $dep's CURRENT repo and pins it via `kubectl set image`. A value starting with "sha256:" is
# treated as a digest (@sha256:...); anything else as a tag (:tag). Container name matches
# deployment name by convention across every CCE service.
pin_image() {
  local dep="$1" answer="$2" current repo new_image
  current=$($KUBECTL -n "$NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}')
  repo="${current%%[:@]*}"
  case "$answer" in
    sha256:*) new_image="${repo}@${answer}" ;;
    *)        new_image="${repo}:${answer}" ;;
  esac
  echo "  pinning to $new_image (no mutable-tag rollout restart)"
  $KUBECTL -n "$NS" set image "deploy/$dep" "$dep=$new_image"
}

rc=0
for dep in "${TARGETS[@]}"; do
  echo "== $dep =="
  if ! $KUBECTL -n "$NS" get "deploy/$dep" >/dev/null 2>&1; then
    echo "  !! no such deployment — skipping"; rc=1; continue
  fi
  if [ -n "$ASK_VERSION" ]; then
    read -r -p "  version for $dep (tag, or sha256:<digest>; blank = plain rollout restart): " ANSWER
    if [ -n "$ANSWER" ]; then
      pin_image "$dep" "$ANSWER"
    else
      $KUBECTL -n "$NS" rollout restart "deploy/$dep"
    fi
  elif [ -n "$IMAGE_DIGEST" ]; then
    pin_image "$dep" "$IMAGE_DIGEST"
  elif [ -n "$IMAGE_TAG" ]; then
    pin_image "$dep" "$IMAGE_TAG"
  else
    $KUBECTL -n "$NS" rollout restart "deploy/$dep"
  fi
  if $KUBECTL -n "$NS" rollout status "deploy/$dep" --timeout="$ROLLOUT_TIMEOUT"; then
    continue
  fi
  echo "  rollout did not complete in $ROLLOUT_TIMEOUT."
  if hpa_managed "$dep"; then
    echo "  $dep is HPA-managed — not scaling to 0 (would fight the HPA). Check quota/scheduling manually."
    rc=1; continue
  fi
  # Fallback for the UAT CPU-quota surge: rolling update needs room for old+new; scale 0->1 avoids it.
  echo "  fallback: scale $dep 0 -> 1 (avoids the rolling-update surge / quota clash)..."
  $KUBECTL -n "$NS" scale "deploy/$dep" --replicas=0
  $KUBECTL -n "$NS" wait --for=delete pod -l "app=$dep" --timeout="$WAIT_DELETE_TIMEOUT" 2>/dev/null || true
  $KUBECTL -n "$NS" scale "deploy/$dep" --replicas=1
  $KUBECTL -n "$NS" rollout status "deploy/$dep" --timeout="$ROLLOUT_TIMEOUT" || { echo "  !! still not ready"; rc=1; }
done

echo "redeploy: done (rc=$rc)."
exit $rc
