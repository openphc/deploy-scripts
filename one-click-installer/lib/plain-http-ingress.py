#!/usr/bin/env python3
# Rewrite a rendered kustomize manifest stream so the cce-ingress is served over plain HTTP.
# A deployment without a public DNS name, so Traefik ACME/TLS (the default overlay behaviour) is dropped:
#   - router.entrypoints websecure -> web
#   - drop router.tls / router.tls.certresolver annotations
#   - drop the spec.tls block (key + its list items, which kustomize emits at the same indent)
# An empty `host: ""` left by a blank INGRESS_HOST is left as-is (k8s treats it as a catch-all).
# Reads the full multi-doc render on stdin, writes the rewritten render to stdout.
import sys
import re

KEY_RE = re.compile(r'[\w.\-/]+:')   # a mapping key like `rules:` (NOT a `- item`)

docs = sys.stdin.read().split('\n---\n')
out = []
for d in docs:
    if 'kind: Ingress' not in d:
        out.append(d)
        continue
    res = []
    skip_tls = False
    tls_indent = 0
    for ln in d.split('\n'):
        s = ln.strip()
        indent = len(ln) - len(ln.lstrip())
        if skip_tls:
            if s == '':
                continue
            is_key = KEY_RE.match(s) is not None
            if is_key and indent <= tls_indent:
                skip_tls = False          # end of the tls block — process this line normally
            else:
                continue                  # tls list item / nested line — drop
        if 'router.entrypoints' in ln:
            res.append(' ' * indent + 'traefik.ingress.kubernetes.io/router.entrypoints: web')
            continue
        if 'router.tls' in ln:            # router.tls and router.tls.certresolver
            continue
        if s == 'tls:':                    # spec.tls block start
            skip_tls = True
            tls_indent = indent
            continue
        res.append(ln)
    out.append('\n'.join(res))
sys.stdout.write('\n---\n'.join(out))
