#!/usr/bin/env bash
# one-click-installer/lib/apply-image-pins.sh <envcode> — set the CCE service image versions in the env's overlay from the config.
#
# The overlay (k8s/overlays/<OVERLAY_NAME>/kustomization.yaml) has a kustomize `images:` block — one entry per CCE service. For each
# service, a config key IMAGE_<NAME> (name upper-cased, '-' -> '_') selects the version:
#     IMAGE_CCE_COLLECTOR_SERVICE=release-1.2.0          -> newTag: release-1.2.0
#     IMAGE_CCE_EMITTER_ADAPTOR=sha256:0cc8…             -> digest: sha256:0cc8…   (exact build — strongest pin)
# The emitter adaptor differs per implementation (<system>-cce-emitter-adaptor: openhim-, openmrs-, tiberbu-…), so it has one
# generic key, IMAGE_CCE_EMITTER_ADAPTOR, applied to whichever emitter image the overlay contains. Its system-specific key
# (e.g. IMAGE_OPENHIM_CCE_EMITTER_ADAPTOR) still wins if set — needed only when an overlay runs more than one emitter.
# IMAGE_TAG_DEFAULT applies to every service without its own key; IMAGE_REGISTRY replaces the registry/owner part of every
# image name (e.g. a country's own mirror). Services with no setting keep what the template overlay had. Re-run every install, so the
# config file is the single place versions are decided; the resulting overlay is git-tracked, i.e. the deployed versions are recorded.
set -euo pipefail
ENVCODE="${1:?usage: apply-image-pins.sh <envcode>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
K="$REPO/k8s/overlays/${OVERLAY_NAME:-$ENVCODE}/kustomization.yaml"
[ -r "$K" ] || { echo "ERROR: no overlay at $K"; exit 1; }
python3 - "$K" <<'PY'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().split("\n")
try:
    start = next(i for i, l in enumerate(lines) if re.match(r"^images:\s*$", l))
except StopIteration:
    sys.exit("ERROR: overlay has no top-level `images:` block — cannot pin versions")
end = start + 1
while end < len(lines) and (lines[end].startswith(" ") or lines[end].strip() == "" or lines[end].startswith("-")):
    end += 1
# parse entries
entries, cur = [], None
for l in lines[start + 1:end]:
    m = re.match(r"^\s*-\s*name:\s*(\S+)", l)
    if m: cur = {"name": m.group(1)}; entries.append(cur); continue
    m = re.match(r"^\s+(newName|newTag|digest):\s*(\S+)", l)
    if m and cur is not None: cur[m.group(1)] = m.group(2)
registry = os.environ.get("IMAGE_REGISTRY", "").rstrip("/")
default = os.environ.get("IMAGE_TAG_DEFAULT", "")
EMITTER_KEY = "IMAGE_CCE_EMITTER_ADAPTOR"
is_emitter = lambda base: base.endswith("-cce-emitter-adaptor")
emitters = [e["name"].rsplit("/", 1)[-1] for e in entries if is_emitter(e["name"].rsplit("/", 1)[-1])]
if os.environ.get(EMITTER_KEY) and len(emitters) > 1:
    unpinned = [b for b in emitters if not os.environ.get("IMAGE_" + re.sub(r"[^A-Z0-9]", "_", b.upper()))]
    if unpinned:   # a tag/digest is image-specific: one value cannot be right for two different emitters
        sys.exit(f"ERROR: {EMITTER_KEY} is ambiguous — this overlay has {len(emitters)} emitter adaptors ({', '.join(emitters)}). "
                 "Set the per-emitter key for each instead, e.g. " + ", ".join("IMAGE_" + re.sub(r"[^A-Z0-9]", "_", b.upper()) for b in unpinned))
out = ["images:"]
for e in entries:
    base = e["name"].rsplit("/", 1)[-1]
    key = "IMAGE_" + re.sub(r"[^A-Z0-9]", "_", base.upper())
    if not os.environ.get(key) and is_emitter(base) and os.environ.get(EMITTER_KEY):
        key = EMITTER_KEY
    want = os.environ.get(key, "") or default
    new_name = (registry + "/" + base) if registry else e.get("newName", e["name"])
    if want:
        ref = {"digest": want} if want.startswith("sha256:") else {"newTag": want}
        src = key if os.environ.get(key) else "IMAGE_TAG_DEFAULT"
    else:
        ref = {k: e[k] for k in ("digest", "newTag") if k in e}; src = "template"
    out += [f"  - name: {e['name']}", f"    newName: {new_name}"] + [f"    {k}: {v}" for k, v in ref.items()]
    shown = ("@" + ref["digest"]) if "digest" in ref else (":" + ref.get("newTag", "?"))
    print(f"  {base:32} {new_name}{shown:<20}  ({src})")
lines[start:end] = out + [""]
open(path, "w").write("\n".join(lines).rstrip("\n") + "\n")
PY
