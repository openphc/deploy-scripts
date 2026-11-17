#!/usr/bin/env bash
# one-click-installer/lib/apply-emitter.sh <envcode> — make the env's overlay deploy the emitter adaptor EMITTER_ADAPTOR
# (default openhim). Runs on every install (phase 4, before the image pins), and switching is just a re-run with a different value.
#
# Every emitter lives in k8s/emitters/<name>/ (none in k8s/base). It:
#   - keeps exactly one ../../emitters/<name> entry in the overlay's resources, right after ../../base
#   - renames the emitter's HPA and its sizing/pull-policy patch, and the images: entry (so IMAGE_CCE_EMITTER_ADAPTOR pins it)
#   - for an emitter other than openhim, points gateway route 3 (the emitter inbound route, whose base default is openhim's)
#     at it: /v1/<deployment>/** -> http://<deployment>:<port>, in a patch between "# >>> emitter" and "# <<< emitter"
#     markers that is rewritten each run — don't edit it.
# It also removes what the old layout (openhim in k8s/base) needed: the emitter-delete-openhim-*.yaml "$patch: delete" files.
# Prometheus, api_permissions and the Keycloak inbound user follow from the overlay (05-k8s-deploy.sh / 06-seed.sh read it
# back via emitter-lib.sh).
set -euo pipefail
ENVCODE="${1:?usage: apply-emitter.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/emitter-lib.sh"
OVERLAY="$REPO/k8s/overlays/${OVERLAY_NAME:-$ENVCODE}"
[ -r "$OVERLAY/kustomization.yaml" ] || { echo "ERROR: no overlay at $OVERLAY"; exit 1; }

# every emitter's names, so whichever one the overlay holds now can be renamed to the chosen one
ALL=""
for n in $(cce_emitter_known); do cce_emitter_conf "$n"; ALL="$ALL $n:$EMITTER_DEPLOYMENT:$EMITTER_IMAGE"; done
cce_emitter_conf "${EMITTER_ADAPTOR:-openhim}"

TARGET="$EMITTER_NAME:$EMITTER_DEPLOYMENT:$EMITTER_PORT:$EMITTER_IMAGE" ALL="$ALL" python3 - "$OVERLAY" <<'PY'
import os, re, sys
ov = sys.argv[1]
name, dep, port, image = os.environ["TARGET"].split(":", 3)
others = [x.split(":", 2) for x in os.environ["ALL"].split()]
kpath, hpath = f"{ov}/kustomization.yaml", f"{ov}/cce-hpas.yaml"
k = open(kpath).read()

# 1. drop the previous managed block (re-added last, so the renames below never touch it)
k = re.sub(r"\n  # >>> emitter.*?# <<< emitter\n", "\n", k, flags=re.S)

# 2. resources: exactly one emitters/<name> entry, right after ../../base (comment lines between them are kept)
k = re.sub(r"\n  - \.\./\.\./emitters/[a-z0-9-]+/?(?=\n)", "", k)
k, n = re.subn(r"(\nresources:\n  - \.\./\.\./base\n(?:  #[^\n]*\n)*)", rf"\1  - ../../emitters/{name}\n", k, count=1)
if n != 1:
    sys.exit(f"ERROR: could not add ../../emitters/{name} to resources in {kpath} (expected '  - ../../base' first)")

# 3. rename the emitter in patch targets, the images: entry and the HPA
for oname, odep, oimg in others:
    if odep != dep:
        k = re.sub(rf"(\n\s+name: ){re.escape(odep)}\n", rf"\g<1>{dep}\n", k)
    if oimg != image:
        k = re.sub(rf"(\n  - name: ){re.escape(oimg)}\n(    newName: ){re.escape(oimg)}\n", rf"\g<1>{image}\n\g<2>{image}\n", k)
        k = re.sub(rf"(\n  - name: ){re.escape(oimg)}\n", rf"\g<1>{image}\n", k)
# 4. the old layout's "$patch: delete" files for the base openhim (its path entries went with the block in step 1)
for f in ("emitter-delete-openhim-deployment.yaml", "emitter-delete-openhim-service.yaml"):
    if os.path.exists(f"{ov}/{f}"): os.remove(f"{ov}/{f}")
# 5. managed gateway patch, right after "patches:" (openhim is the gateway's base default: no patch)
if name != "openhim":
    env = [("ID", dep), ("URI", f"http://{dep}:{port}"), ("PREDICATES_0", f"Path=/v1/{dep}/**")]
    block = (
        "  # >>> emitter (lib/apply-emitter.sh — rewritten on every install, do not edit)\n"
        + "  - patch: |-\n      apiVersion: apps/v1\n      kind: Deployment\n      metadata:\n        name: gateway-service\n"
          "      spec:\n        template:\n          spec:\n            containers:\n              - name: gateway-service\n"
          "                env:\n"
        + "".join(f'                  - {{name: SPRING_CLOUD_GATEWAY_SERVER_WEBFLUX_ROUTES_3_{s}, value: "{v}"}}\n' for s, v in env)
        + "  # <<< emitter\n")
    if "\npatches:\n" not in k:
        sys.exit(f"ERROR: {kpath} has no top-level 'patches:' list")
    k = k.replace("\npatches:\n", "\npatches:\n" + block, 1)

open(kpath, "w").write(k)
if os.path.exists(hpath):
    h = open(hpath).read()
    for oname, odep, oimg in others:
        if odep != dep:
            h = re.sub(rf"\b{re.escape(odep)}\b", dep, h)
    open(hpath, "w").write(h)
print(f"  emitter adaptor: {name} — Deployment/Service {dep}:{port}, image {image}, inbound /v1/{dep}/inbound")
PY
