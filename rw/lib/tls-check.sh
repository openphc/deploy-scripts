#!/usr/bin/env bash
# rw/lib/tls-check.sh <ingress-host> — make sure Traefik serves a real Let's Encrypt certificate for the host, once it can.
#
#   sudo bash rw/lib/tls-check.sh cceuat.moh.gov.rw        # run by rw/one-click-install.sh; also by hand after a DNS change
#
# Let's Encrypt validates over HTTP on the address PUBLIC DNS gives. Before the DNS points at this machine every attempt fails,
# and after a few failures Traefik stops retrying — it does not notice the DNS switch by itself (seen on the .20 → .21 move: the
# default certificate stayed until Traefik was restarted). So:
#   - DNS does not point here yet  -> say so and do nothing (nothing can work until it does)
#   - DNS points here, real cert   -> nothing to do
#   - DNS points here, still Traefik's default certificate -> restart Traefik (it requests the certificate on start) and wait for it
# Exit 0 in every case but "DNS points here and no certificate after the restart" (exit 1). Idempotent.
set -euo pipefail
HOST="${1:?usage: tls-check.sh <ingress-host>}"
KUBECTL="${KUBECTL:-k3s kubectl}"
WAIT_SECS="${TLS_WAIT_SECS:-180}"

issuer() { echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//'; }

# Public resolution (what Let's Encrypt sees), not /etc/hosts or a split-horizon resolver.
if command -v dig >/dev/null; then
  PUB="$( (dig +short "$HOST" @8.8.8.8 2>/dev/null; dig +short "$HOST" @1.1.1.1 2>/dev/null) | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ')"
else   # no dnsutils: the system resolver (on RW hosts that is 8.8.8.8/8.8.4.4 anyway)
  PUB="$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi
MINE=" $(hostname -I) "
HERE=0; for ip in $PUB; do case "$MINE" in *" $ip "*) HERE=1;; esac; done

CUR="$(issuer)"
if [ "$HERE" = 0 ]; then
  echo "  TLS: $HOST resolves to ${PUB:-nothing} publicly, not to this machine — the certificate can only be issued after the DNS"
  echo "       points here. Then run: sudo bash $0 $HOST   (serving now: ${CUR:-nothing})"
  exit 0
fi
case "$CUR" in
  *"Let's Encrypt"*) echo "  TLS: $HOST -> Let's Encrypt certificate in place ($CUR)"; exit 0;;
esac
echo "  TLS: $HOST points here but Traefik serves '${CUR:-nothing}' — restarting Traefik so it requests the certificate now"
$KUBECTL -n kube-system rollout restart deploy/traefik >/dev/null
$KUBECTL -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null
for _ in $(seq 1 $((WAIT_SECS / 10))); do
  sleep 10; CUR="$(issuer)"
  case "$CUR" in *"Let's Encrypt"*) echo "  TLS: certificate issued ($CUR)"; exit 0;; esac
done
echo "  ✗ TLS: still '${CUR:-nothing}' after ${WAIT_SECS}s. Check: $KUBECTL -n kube-system logs deploy/traefik | grep -i acme"
echo "    (port 80 must be reachable from the internet for the HTTP challenge; Let's Encrypt allows 5 failed validations per hour)"
exit 1
