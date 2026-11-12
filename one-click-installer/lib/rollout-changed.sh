#!/usr/bin/env bash
# one-click-installer/lib/rollout-changed.sh — rollout-restart ONLY the k8s deployments whose env actually changed.
#
# Why this exists: the kustomize generators use `disableNameSuffixHash: true`, so the `cce-secrets`
# Secret and `cce-config` ConfigMap keep STABLE names. `kubectl apply` updates their contents but
# does NOT roll the Deployments — and env vars (secretKeyRef/configMapKeyRef/envFrom) are read only
# at pod startup. So after an Infisical value change + redeploy, running pods keep the OLD value
# until restarted. This helper restarts exactly the affected deployments, nothing more.
#
# Usage (bracket the k8s apply step):
#   one-click-installer/lib/rollout-changed.sh <namespace> <snapshot-file> capture   # BEFORE the apply
#   <run your kubectl apply / deploy step>
#   one-click-installer/lib/rollout-changed.sh <namespace> <snapshot-file> restart   # AFTER the apply
#
# On a fresh install (no prior Secret) capture writes an empty snapshot and restart is a no-op
# (the pods are brand new, so they already have the latest values).
set -euo pipefail

NS="${1:?usage: rollout-changed.sh <namespace> <snapshot-file> <capture|restart>}"
SNAP="${2:?snapshot file path}"
MODE="${3:?capture|restart}"

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
  elif command -v k3s >/dev/null 2>&1; then KUBECTL="sudo k3s kubectl"
  else echo "ERROR: no kubectl / k3s found"; exit 1; fi
fi

# Emit "KEY<TAB>sha256" for every key in cce-secrets + cce-config (sorted). Empty if neither exists.
snapshot() {
  for kn in "secret cce-secrets" "configmap cce-config"; do
    # shellcheck disable=SC2086
    $KUBECTL -n "$NS" get $kn -o json 2>/dev/null | python3 -c '
import sys, json, hashlib
try: it = json.load(sys.stdin)
except Exception: sys.exit(0)
for k, v in (it.get("data", {}) or {}).items():
    print("%s\t%s" % (k, hashlib.sha256((v or "").encode()).hexdigest()))
'
  done | sort
}

# Print the deployments that consume a cce-secrets/cce-config key whose value changed since $SNAP.
# (Prints nothing if there's no prior snapshot or no consumed key changed.)
compute_changed() {
  [ ! -s "$SNAP" ] && return 0
  local NEW; NEW="$(mktemp)"
  snapshot > "$NEW"
  comm -3 "$SNAP" "$NEW" | awk -F'\t' '{print $1}' | sed '/^$/d' | sort -u > "$NEW.keys"
  if [ -s "$NEW.keys" ]; then
    # map changed keys -> deployments that consume them (secretKeyRef/configMapKeyRef/envFrom)
    $KUBECTL -n "$NS" get deploy -o json | python3 -c '
import sys, json
changed = set(open(sys.argv[1]).read().split())
GEN = {"cce-secrets", "cce-config"}
out = []
for d in json.load(sys.stdin).get("items", []):
    name = d["metadata"]["name"]
    consumed, envfrom_all = set(), False
    for c in d["spec"]["template"]["spec"].get("containers", []):
        for e in c.get("env", []):
            vf = e.get("valueFrom") or {}
            for ref in ("secretKeyRef", "configMapKeyRef"):
                r = vf.get(ref)
                if r and r.get("name") in GEN and r.get("key"):
                    consumed.add(r["key"])
        for ef in c.get("envFrom", []):
            for ref in ("secretRef", "configMapRef"):
                r = ef.get(ref)
                if r and r.get("name") in GEN:
                    envfrom_all = True
    if (envfrom_all and changed) or (consumed & changed):
        out.append(name)
print("\n".join(sorted(set(out))))
' "$NEW.keys"
  fi
  rm -f "$NEW" "$NEW.keys"
}

case "$MODE" in
  capture)
    snapshot > "$SNAP" || true
    ;;

  list)
    # Print changed deployment names only (for programmatic use, e.g. redeploy.sh CHANGED_ONLY).
    compute_changed
    ;;

  restart)
    if [ ! -s "$SNAP" ]; then
      echo "  rollout-changed: no prior snapshot (fresh deploy) — nothing to restart."
      exit 0
    fi
    DEPLOYS="$(compute_changed)"
    if [ -z "$DEPLOYS" ]; then
      echo "  rollout-changed: no changed env consumed by any deployment — nothing to restart."
      exit 0
    fi
    echo "  rollout-changed: restarting -> $(echo "$DEPLOYS" | tr '\n' ' ')"
    for dep in $DEPLOYS; do
      echo "  rollout restart deploy/$dep (-n $NS)"
      $KUBECTL -n "$NS" rollout restart "deploy/$dep"
    done
    ;;

  *)
    echo "ERROR: mode must be 'capture', 'restart', or 'list'"; exit 1 ;;
esac
