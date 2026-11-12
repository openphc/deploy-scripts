#!/usr/bin/env bash
# one-click-installer/lib/emitter-lib.sh — SOURCE me. Which emitter adaptor an environment runs.
#
# Every implementation runs ONE emitter adaptor, the one for its source system. openhim is built into k8s/base
# (k8s/base/services/openhim-emitter-adaptor.yaml); any other lives in k8s/emitters/<name>/ (a kustomization plus
# emitter.conf) and is swapped in by apply-emitter.sh. After that the overlay is the record: scripts that run later
# (deploy, seed, day-2) read the choice back from it with cce_emitter_from_overlay, not from the config file.
#
#   cce_emitter_conf <name>              -> EMITTER_NAME EMITTER_DEPLOYMENT EMITTER_PORT EMITTER_IMAGE EMITTER_SOURCE
#   cce_emitter_from_overlay <overlay>   -> the same, for the emitter that overlay deploys
#   cce_emitter_known                    -> names that can be chosen
# Inbound URL for every emitter: https://<host>/v1/<EMITTER_DEPLOYMENT>/inbound (gateway route 3, HTTP Basic).

_EMITTER_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cce_emitter_known() {
  local d; echo openhim
  for d in "$_EMITTER_REPO"/k8s/emitters/*/emitter.conf; do [ -r "$d" ] && basename "$(dirname "$d")"; done
}

cce_emitter_conf() {
  local name="${1:-openhim}" conf
  EMITTER_NAME="$name"
  if [ "$name" = openhim ]; then
    EMITTER_DEPLOYMENT=openhim-emitter-adaptor; EMITTER_PORT=8082
    EMITTER_IMAGE=ghcr.io/openphc/openhim-cce-emitter-adaptor; EMITTER_SOURCE=openhim
    return 0
  fi
  conf="$_EMITTER_REPO/k8s/emitters/$name/emitter.conf"
  [ -r "$conf" ] || { echo "ERROR: unknown emitter adaptor '$name' — choose one of: $(cce_emitter_known | tr '\n' ' ')" >&2; return 1; }
  EMITTER_DEPLOYMENT="$(sed -n 's/^DEPLOYMENT=//p' "$conf")"; EMITTER_PORT="$(sed -n 's/^PORT=//p' "$conf")"
  EMITTER_IMAGE="$(sed -n 's/^IMAGE=//p' "$conf")";           EMITTER_SOURCE="$(sed -n 's/^SOURCE=//p' "$conf")"
  [ -n "$EMITTER_DEPLOYMENT" ] && [ -n "$EMITTER_PORT" ] && [ -n "$EMITTER_IMAGE" ] \
    || { echo "ERROR: $conf must set DEPLOYMENT, PORT and IMAGE" >&2; return 1; }
}

cce_emitter_from_overlay() {
  local k="$1/kustomization.yaml" name
  name="$(sed -n 's#^  - \.\./\.\./emitters/\([a-z0-9-]*\)/*$#\1#p' "$k" 2>/dev/null | head -1)"
  cce_emitter_conf "${name:-openhim}"
}
