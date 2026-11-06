#!/usr/bin/env bash
# rw/lib/overlay-tweaks.sh <overlay-dir> — this machine's deviations from PROD's sizing, applied to the generated overlay (which is
# otherwise a verbatim clone of k8s/overlays/prod). Idempotent; run by rw/one-click-install.sh and rw/redeploy-from-source.sh before
# every deploy, so the config file stays the one place they are decided.
#   HPA_REPLICAS=<n>          every HPA in cce-hpas.yaml gets minReplicas = maxReplicas = n (empty = keep PROD's)
#   CPU_LIMIT_OVERRIDES=<deployment>=<cpu>[,…]   container CPU limit per deployment, e.g. cce-protocol-service=800m
set -euo pipefail
OVERLAY="${1:?usage: overlay-tweaks.sh <overlay-dir>}"
[ -r "$OVERLAY/kustomization.yaml" ] || { echo "ERROR: no overlay at $OVERLAY"; exit 1; }
python3 - "$OVERLAY" <<'PY'
import os, re, sys
ov = sys.argv[1]

n = os.environ.get("HPA_REPLICAS", "").strip()
hpas = os.path.join(ov, "cce-hpas.yaml")
if n and os.path.exists(hpas):
    if not n.isdigit() or int(n) < 1: sys.exit(f"ERROR: HPA_REPLICAS must be a positive integer (got {n!r})")
    t = open(hpas).read()
    t2 = re.sub(r"^(\s*)(minReplicas|maxReplicas):\s*\d+", lambda m: f"{m.group(1)}{m.group(2)}: {n}", t, flags=re.M)
    open(hpas, "w").write(t2)
    print(f"  HPAs: min = max = {n} replicas ({len(re.findall(r'^kind: HorizontalPodAutoscaler', t2, re.M))} HPAs)")

k = os.path.join(ov, "kustomization.yaml")
text = open(k).read()
for item in filter(None, (x.strip() for x in os.environ.get("CPU_LIMIT_OVERRIDES", "").split(","))):
    dep, _, cpu = item.partition("=")
    dep, cpu = dep.strip(), cpu.strip()
    if not re.fullmatch(r"[a-z0-9-]+", dep) or not re.fullmatch(r"\d+(\.\d+)?m?", cpu):
        sys.exit(f"ERROR: CPU_LIMIT_OVERRIDES entry {item!r} — expected <deployment>=<cpu>, e.g. cce-protocol-service=800m")
    line = f'      - {{op: replace, path: /spec/template/spec/containers/0/resources/limits/cpu, value: "{cpu}"}}\n'
    # The deployment's patch block in the cloned PROD overlay: "- target: { kind: Deployment, name: X }" or the multi-line form.
    m = re.search(r"(  - target:\s*\n\s+kind: Deployment\s*\n\s+name: " + re.escape(dep) + r"\s*\n\s+patch: \|\n)((?:      .*\n)*)", text)
    if m:
        body = re.sub(r"      - \{op: replace, path: /spec/template/spec/containers/0/resources/limits/cpu, value: [^}]*\}\n", "", m.group(2))
        text = text[:m.start()] + m.group(1) + body + line + text[m.end():]
    else:
        block = f"  - target:\n      kind: Deployment\n      name: {dep}\n    patch: |\n{line}"
        if "\npatches:\n" not in text: sys.exit("ERROR: overlay has no top-level 'patches:' block")
        text = text.replace("\npatches:\n", "\npatches:\n" + block, 1)
    print(f"  {dep}: CPU limit {cpu}")
open(k, "w").write(text)
PY
