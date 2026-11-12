#!/usr/bin/env python3
"""one-click-installer/tools/env-parity.py <reference.fp> <candidate.fp> [--ignore REGEX]... — how closely does one environment match another?

Both files come from one-click-installer/tools/env-fingerprint.sh (one fact per line:  section | subject | detail).
Typical use: reference = the reference production environment, candidate = a new environment from one-click-installer/install.sh.

  MISSING    fact exists in the reference but not the candidate   (candidate lacks something PROD has)
  EXTRA      fact exists in the candidate but not the reference
  DIFFERENT  same section+subject, different detail

--ignore REGEX  drop any fact whose "section | subject" matches (repeatable) — for differences you have judged legitimate.
Exit status: 0 = identical after ignores, 1 = differences.
"""
import re, sys
from collections import defaultdict

def load(path):
    facts = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        parts = [p.strip() for p in line.split(" | ", 2)]
        if len(parts) < 3 or not parts[0]: continue
        facts[(parts[0], parts[1])] = parts[2]
    return facts

args = sys.argv[1:]
ignores = []
while "--ignore" in args:
    i = args.index("--ignore"); ignores.append(re.compile(args[i + 1])); del args[i:i + 2]
if len(args) != 2: sys.exit(__doc__)
ref, cand = load(args[0]), load(args[1])
keep = lambda k: not any(r.search("%s | %s" % k) for r in ignores)
keys = sorted(k for k in set(ref) | set(cand) if keep(k))

missing = [k for k in keys if k in ref and k not in cand]
extra   = [k for k in keys if k in cand and k not in ref]
diff    = [k for k in keys if k in ref and k in cand and ref[k] != cand[k]]
same    = [k for k in keys if k in ref and k in cand and ref[k] == cand[k]]

def by_section(ks):
    d = defaultdict(list)
    for k in ks: d[k[0]].append(k)
    return d

print("PARITY  reference=%s (%d facts)  candidate=%s (%d facts)" % (args[0], len(ref), args[1], len(cand)))
print("        identical=%d  DIFFERENT=%d  MISSING=%d  EXTRA=%d  (ignored: %d)\n" % (
      len(same), len(diff), len(missing), len(extra), len(set(ref) | set(cand)) - len(keys)))
for title, ks, fmt in (
    ("DIFFERENT — same thing, different value", diff, lambda k: "  %-46s\n        ref : %s\n        cand: %s" % ("%s | %s" % k, ref[k], cand[k])),
    ("MISSING — in the reference, absent from the candidate", missing, lambda k: "  %-46s ref: %s" % ("%s | %s" % k, ref[k])),
    ("EXTRA — in the candidate only", extra, lambda k: "  %-46s cand: %s" % ("%s | %s" % k, cand[k])),
):
    if not ks: continue
    print("══ %s  (%d)" % (title, len(ks)))
    for sec, items in sorted(by_section(ks).items()):
        print("── %s (%d)" % (sec, len(items)))
        for k in items: print(fmt(k))
    print()
sys.exit(1 if (diff or missing or extra) else 0)
