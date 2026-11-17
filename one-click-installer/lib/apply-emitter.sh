#!/usr/bin/env bash
# one-click-installer/lib/apply-emitter.sh <envcode> — make the env's overlay deploy the emitter adaptor EMITTER_ADAPTOR
# (default openhim). Runs on every install (phase 4, before the image pins), and switching is just a re-run with a different value.
#
# For a non-openhim emitter (k8s/emitters/<name>/) it:
#   - adds ../../emitters/<name> to resources, and deletes the base openhim Deployment + Service ($patch: delete)
#   - points gateway route 3 (the emitter inbound route) at it: /v1/<deployment>/** -> http://<deployment>:<port>
#   - renames the emitter's HPA and its sizing/pull-policy patch, and the images: entry (so IMAGE_CCE_EMITTER_ADAPTOR pins it)
# The patches it adds sit between "# >>> emitter" and "# <<< emitter" markers (plus two emitter-delete-openhim-*.yaml files)
# and are rewritten each run — don't edit them.
# openhim removes that block and restores the openhim names. Prometheus, api_permissions and the Keycloak inbound user
# follow from the overlay (05-k8s-deploy.sh / 06-seed.sh read it back via emitter-lib.sh).
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

# 2. resources: exactly one emitters/<name> entry (none for openhim)
k = re.sub(r"\n  - \.\./\.\./emitters/[a-z0-9-]+/?(?=\n)", "", k)
if name != "openhim":
    k = re.sub(r"(\nresources:\n  - \.\./\.\./base\n)", rf"\1  - ../../emitters/{name}\n", k, count=1)
    if f"../../emitters/{name}" not in k:
        sys.exit(f"ERROR: could not add ../../emitters/{name} to resources in {kpath} (expected '  - ../../base' first)")

# 3. rename the emitter in patch targets, the images: entry and the HPA
for oname, odep, oimg in others:
    if odep != dep:
        k = re.sub(rf"(\n\s+name: ){re.escape(odep)}\n", rf"\g<1>{dep}\n", k)
    if oimg != image:
        k = re.sub(rf"(\n  - name: ){re.escape(oimg)}\n(    newName: ){re.escape(oimg)}\n", rf"\g<1>{image}\n\g<2>{image}\n", k)
        k = re.sub(rf"(\n  - name: ){re.escape(oimg)}\n", rf"\g<1>{image}\n", k)
# 4. managed patch block, right after "patches:". The deletes live in their own files: the installer runs envsubst over
#    kustomization.yaml, which would turn "$patch: delete" written inline into ": delete".
DELETE_FILES = {"emitter-delete-openhim-deployment.yaml": ("apps/v1", "Deployment"),
                "emitter-delete-openhim-service.yaml": ("v1", "Service")}
for f, (api, kind) in DELETE_FILES.items():
    fp = f"{ov}/{f}"
    if name == "openhim":
        if os.path.exists(fp): os.remove(fp)
    else:
        open(fp, "w").write(f"# Written by one-click-installer/lib/apply-emitter.sh: this environment runs the {name} emitter, not openhim.\n"
                            f"$patch: delete\napiVersion: {api}\nkind: {kind}\nmetadata:\n  name: openhim-emitter-adaptor\n")
if name != "openhim":
    env = [("ID", dep), ("URI", f"http://{dep}:{port}"), ("PREDICATES_0", f"Path=/v1/{dep}/**")]
    block = (
        "  # >>> emitter (lib/apply-emitter.sh — rewritten on every install, do not edit)\n"
        + "".join(f"  - path: {f}\n" for f in DELETE_FILES)
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
