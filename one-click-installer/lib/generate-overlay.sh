#!/usr/bin/env bash
# one-click-installer/lib/generate-overlay.sh <envcode>
# Generate k8s/overlays/<envcode>/ by cloning k8s/overlays/prod/ and substituting env identifiers —
# "replicate PROD" applied literally to the k8s side: same resource sizing/HPAs/scheduler tuning,
# cloned verbatim, only naming and the shared-host port-shift workarounds change.
#
# Substitutions applied across every copied file:
#   - cce-prod                 -> cce-<envcode>   (namespace, KAFKA_UI_CLUSTER_NAME, ratelimit
#                                                   middleware refs — all literal "cce-prod" text)
#   - prod-resource-quota       -> <envcode>-resource-quota   (namespace.yaml ResourceQuota name)
#   - prod-limit-range          -> <envcode>-limit-range      (namespace.yaml LimitRange name)
#   - environment: prod         -> environment: <envcode>     (commonLabels + namespace.yaml label)
#   - CLICKHOUSE_PORT=8124      -> CLICKHOUSE_PORT=8123        (PROD's shifted port -> standard;
#                                                   this is a LITERAL value, not a ${VAR}, so a
#                                                   plain name-substitution pass won't catch it)
# And removed entirely (dedicated machine -> no shared-host port collision to work around):
#   - the node-exporter DaemonSet/Service :9101 patch blocks (reverts to base's default :9100)
#
# Everything else — HPAs (cce-hpas.yaml), resource request/limit patches, rate limits — is cloned
# byte-for-byte.
#
# k8s/overlays/<envcode>/ is git-tracked (matches the existing k8s/ convention) — commit it after
# reviewing.
set -euo pipefail

ENVCODE="${1:?usage: generate-overlay.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# OVERLAY_TEMPLATE = the overlay cloned as the starting point (the reference PROD sizing/HPAs/patches);
# OVERLAY_NAME     = the directory to create (defaults to the env code). They must differ.
TEMPLATE="${OVERLAY_TEMPLATE:-prod}"
NAME="${OVERLAY_NAME:-$ENVCODE}"
SRC="$REPO/k8s/overlays/$TEMPLATE"
DST="$REPO/k8s/overlays/$NAME"
[ -d "$SRC" ] || { echo "ERROR: template overlay $SRC not found (OVERLAY_TEMPLATE)"; exit 1; }
[ "$NAME" = "$TEMPLATE" ] && { echo "ERROR: overlay name '$NAME' is the template itself — set OVERLAY_NAME to something else (e.g. ${ENVCODE}-site)"; exit 1; }
[ -d "$DST" ] && { echo "ERROR: $DST already exists — remove it first if you want to regenerate"; exit 1; }

echo "[generate-overlay] cloning $SRC -> $DST"
cp -r "$SRC" "$DST"
rm -f "$DST/kustomization.yaml.bak"   # stray backup file, if a prior render left one

echo "[generate-overlay] substituting env identifiers across all copied files"
for f in "$DST"/*.yaml; do
  sed -i \
    -e "s/cce-${TEMPLATE}/cce-${ENVCODE}/g" \
    -e "s/${TEMPLATE}-resource-quota/${ENVCODE}-resource-quota/g" \
    -e "s/${TEMPLATE}-limit-range/${ENVCODE}-limit-range/g" \
    -e "s/environment: ${TEMPLATE}/environment: ${ENVCODE}/g" \
    -e "s/CLICKHOUSE_PORT=8124/CLICKHOUSE_PORT=8123/" \
    "$f"
done
# Fix the now-stale comment directly above CLICKHOUSE_PORT (it still describes PROD's shifted-port
# rationale even though the value above was just corrected to the standard port).
python3 - "$DST/kustomization.yaml" "$ENVCODE" <<'PY'
import sys
path, envcode = sys.argv[1], sys.argv[2]
text = open(path).read()
old = ("      # PROD ClickHouse is installed natively on the host with shifted ports (UAT's docker\n"
       "      # ClickHouse already holds 8123/9009/9363 on this shared VM): HTTP 8124, metrics 9364.\n")
new = (f"      # ClickHouse is installed natively on this dedicated host, standard ports\n"
       f"      # (no shared-host collision to shift around, unlike PROD's historical setup).\n")
if old in text:
    open(path, "w").write(text.replace(old, new))
PY

echo "[generate-overlay] removing node-exporter port-shift patches (dedicated machine, no collision)"
python3 - "$DST/kustomization.yaml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
# The two node-exporter patch blocks (DaemonSet + Service), plus their leading explanatory
# comment, sit as consecutive top-level (2-space-indented) "- target:" list items just before
# "images:". Remove from the comment through the end of the Service patch block.
pattern = re.compile(
    r"  # PROD node-exporter shares.*?"
    r"- target:\n      kind: Service\n      name: node-exporter\n    patch: \|\n"
    r"      - \{op: replace, path: /spec/ports/0/targetPort, value: 9101\}\n",
    re.DOTALL,
)
new_text, n = pattern.subn("", text)
if n != 1:
    print(f"WARNING: expected to remove exactly 1 node-exporter patch block, removed {n} — "
          f"check {path} manually", file=sys.stderr)
else:
    open(path, "w").write(new_text)
    print("  removed node-exporter patch block")
PY

echo "[generate-overlay] collector: let Flyway baseline a non-empty schema (fresh installs)"
python3 - "$DST/kustomization.yaml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
# Every 2.0 service migrates the SAME ccedb public schema. Protocol/Matcher/intelligence set baseline-on-migrate, the collector's
# manifest does not (its image defaults to false). On a fresh database whichever service migrates first wins, and when it is not
# the collector it crash-loops forever: "Found non-empty schema(s) "public" but no schema history table". Upgraded environments
# never see this (their history table already exists, where these settings are inert). Baseline 0 = still run V1/V2.
# docker-compose.yml sets the same for dev.
patch = (
    "  # Fresh-install fix (one-click-installer): see generate-overlay.sh.\n"
    "  - target: { kind: Deployment, name: cce-collector-service }\n"
    "    patch: |\n"
    "      - {op: add, path: /spec/template/spec/containers/0/env/-, value: {name: SPRING_FLYWAY_BASELINE_ON_MIGRATE, value: \"true\"}}\n"
    "      - {op: add, path: /spec/template/spec/containers/0/env/-, value: {name: SPRING_FLYWAY_BASELINE_VERSION, value: \"0\"}}\n"
)
if "SPRING_FLYWAY_BASELINE_ON_MIGRATE" in text:
    print("  already present")
elif "\npatches:\n" in text:
    open(path, "w").write(text.replace("\npatches:\n", "\npatches:\n" + patch, 1))
    print("  added collector Flyway baseline patch")
else:
    print("WARNING: no top-level 'patches:' in %s — collector Flyway patch NOT added" % path, file=sys.stderr)
PY

echo ""
echo "[generate-overlay] done. Review with:"
echo "  diff -u $SRC/kustomization.yaml $DST/kustomization.yaml"
echo "Then render (dry-run, no apply) to sanity-check:"
echo "  cd $DST && kubectl kustomize . | grep -c "cce-${TEMPLATE}"   # should be 0"
echo "Commit $DST to git when satisfied (k8s/overlays is tracked)."
