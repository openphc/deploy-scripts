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
python3 - "$K" "$REPO/k8s/overlays/${OVERLAY_TEMPLATE:-prod}/kustomization.yaml" <<'PY'
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
# The template overlay's own images: entries — what a service gets when the config gives it no version. Read from the template,
# not from this overlay: this overlay holds the LAST pin, so falling back to it meant clearing a key never reverted anything.
tmpl = {}
if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    tl = open(sys.argv[2]).read().split("\n"); cur_t = None
    try:
        ts = next(i for i, l in enumerate(tl) if re.match(r"^images:\s*$", l))
        for l in tl[ts + 1:]:
            if l and not (l.startswith(" ") or l.startswith("-")): break
            m = re.match(r"^\s*-\s*name:\s*(\S+)", l)
            if m: cur_t = {"name": m.group(1)}; tmpl[m.group(1).rsplit("/", 1)[-1]] = cur_t; continue
            m = re.match(r"^\s+(newName|newTag|digest):\s*(\S+)", l)
            if m and cur_t is not None: cur_t[m.group(1)] = m.group(2)
    except StopIteration:
        pass
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
    t_e = tmpl.get(base)   # None for an image the template does not have (e.g. a non-openhim emitter): keep this overlay's
    new_name = (registry + "/" + base) if registry else (t_e.get("newName", t_e["name"]) if t_e else e.get("newName", e["name"]))
    if want:
        ref = {"digest": want} if want.startswith("sha256:") else {"newTag": want}
        src = key if os.environ.get(key) else "IMAGE_TAG_DEFAULT"
    elif t_e:
        ref = {k: t_e[k] for k in ("digest", "newTag") if k in t_e}; src = "template"
    else:
        ref = {}; src = "manifest's own tag (not in the template)"   # e.g. k8s/emitters/<name>/: no pin = what its manifest says
    out += [f"  - name: {e['name']}", f"    newName: {new_name}"] + [f"    {k}: {v}" for k, v in ref.items()]
    shown = ("@" + ref["digest"]) if "digest" in ref else (":" + ref["newTag"]) if "newTag" in ref else " (manifest tag)"
    print(f"  {base:32} {new_name}{shown:<20}  ({src})")
rw = [l.split("newTag:")[1].strip() for l in out if "newTag:" in l and "demo-rw" in l]
if rw:
    print("  NOTE: %d image(s) still use the template's Rwanda build (%s). Pin IMAGE_CCE_INSIGHTS_SERVICE / IMAGE_CCE_INSIGHTS_UI"
          " (and any other) to your implementation's build in the config." % (len(rw), ", ".join(sorted(set(rw)))))
lines[start:end] = out + [""]
open(path, "w").write("\n".join(lines).rstrip("\n") + "\n")
PY
