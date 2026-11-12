#!/usr/bin/env bash
# one-click-installer/lib/image-changed.sh <namespace> [deployment...]
#
# Print (one per line) the ghcr.io/openphc/* deployments whose RUNNING image digest differs from the
# CURRENT registry digest for their (mutable) tag — i.e. a newer build was pushed that a rollout would
# pull. Used by redeploy.sh's CHANGED_ONLY mode to avoid restarting services that are already current.
#
# openphc images are public, so this resolves the remote digest with an anonymous ghcr bearer token +
# a manifest HEAD (no skopeo/crane needed). If the remote digest can't be resolved (network/private),
# the deployment is skipped rather than falsely flagged.
#
# With no names: checks all ghcr.io/openphc/* deployments. With names: only those.
set -uo pipefail

NS="${1:?usage: image-changed.sh <namespace> [deployment...]}"; shift || true
WANT=" $* "   # " " when empty -> match all

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found" >&2; exit 1; fi
fi

# repo tag -> remote digest (sha256:...) for ghcr.io
ghcr_digest() {
  local repo="$1" tag="$2" tok
  tok="$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" \
         | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  [ -z "$tok" ] && return 0
  curl -sI -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r' | tail -1
}

while IFS=$'\t' read -r name image; do
  [ -z "$name" ] && continue
  [ "$WANT" != "  " ] && case "$WANT" in *" $name "*) : ;; *) continue ;; esac
  case "$image" in *ghcr.io/openphc/*) : ;; *) continue ;; esac
  ref="${image#*ghcr.io/}"                                  # openphc/<repo>:<tag>
  case "${ref##*/}" in
    *:*) repo="${ref%:*}"; tag="${ref##*:}" ;;
    *)   repo="$ref";      tag="latest" ;;
  esac
  remote="$(ghcr_digest "$repo" "$tag")"
  [ -z "$remote" ] && continue                              # unresolved -> skip (don't falsely flag)
  running="$($KUBECTL -n "$NS" get pods -l "app=$name" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].imageID}{"\n"}{end}' 2>/dev/null \
    | grep -o 'sha256:[0-9a-f]\+' | sort -u)"
  # changed if no running pod, or none of the running digests match the current remote digest
  if [ -z "$running" ] || ! printf '%s\n' "$running" | grep -qx "$remote"; then
    echo "$name"
  fi
done < <($KUBECTL -n "$NS" get deploy -o json | python3 -c '
import sys, json
for d in json.load(sys.stdin).get("items", []):
    cs = d["spec"]["template"]["spec"].get("containers", [])
    print("%s\t%s" % (d["metadata"]["name"], cs[0].get("image","") if cs else ""))')
