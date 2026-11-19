#!/bin/sh
# /docker-entrypoint.d/45-patch-core-esms.sh
#
# Fixes bugs in the official frontend image's bundles at container boot, until an upstream release
# carries the fix. Each patch replaces one exact piece of minified code; when the image no longer
# has it (fixed upstream, or a different version), the patch does nothing and says so.
#
# Safe-fail: an error is logged and nginx still starts.

set -u

LOG_PREFIX="[45-patch-core-esms]"
HTML_DIR="/usr/share/nginx/html"

log() { echo "$LOG_PREFIX $*"; }

# patch <name> <file glob> <sed expression> <text that must be present>
patch() {
  name=$1; glob=$2; expr=$3; needle=$4
  hits=0
  for f in $HTML_DIR/$glob; do
    [ -f "$f" ] || continue
    grep -qF "$needle" "$f" || continue
    if sed -i "$expr" "$f"; then
      hits=$((hits + 1))
    else
      log "WARN: $name: could not patch $f"
    fi
  done
  if [ "$hits" -gt 0 ]; then
    log "$name: patched $hits file(s)"
  else
    log "$name: nothing to patch (already fixed or another version)"
  fi
}

# Laboratory app "Add lab results" fails with "Cannot read properties of null (reading 'uuid')" when
# the order's encounter also holds obs with no order, e.g. a test ordered from a form: the results
# form reads obs.order.uuid on every obs of the encounter (useCompletedLabResultsArray,
# esm-patient-orders-app). Made null-safe: an obs with no order is simply not a result of the order.
patch "lab-results-obs-without-order" \
  "openmrs-esm-patient-orders-app-*/*.js" \
  's/(null==n?void 0:n\.order\.uuid)/(null==n||null==n.order?void 0:n.order.uuid)/g' \
  '(null==n?void 0:n.order.uuid)'

exit 0
