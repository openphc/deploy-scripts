#!/usr/bin/env bash
# /usr/local/sbin/cce-docker-fw.sh
# Ports published by Docker bypass UFW (DNAT + FORWARD run ahead of it, and the ruleset needs `allow routed`
# for k3s). Drop NEW connections that arrive on the PUBLIC interface and are forwarded into a docker bridge.
# Unaffected: pods/containers/host (they use cni0/flannel/br-*/lo, never the public NIC), replies to
# connections the containers opened themselves (not NEW), and k3s's 80/443 (forwarded to flannel/cni, not a
# docker bridge). Port-independent on purpose: a newly published port is closed by default.
# Idempotent. Re-run by cce-docker-fw.service after docker (re)starts. Remove with: iptables -D DOCKER-USER <rule>
set -euo pipefail
PUB="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$PUB" ] || { echo "cce-docker-fw: no default-route interface" >&2; exit 1; }
for _ in $(seq 1 30); do iptables -S DOCKER-USER >/dev/null 2>&1 && break; sleep 1; done
iptables -S DOCKER-USER >/dev/null 2>&1 || { echo "cce-docker-fw: DOCKER-USER chain missing" >&2; exit 1; }
for out in docker0 'br-+'; do
  rule=(-i "$PUB" -o "$out" -m conntrack --ctstate NEW -m comment --comment cce-block-public-to-docker -j DROP)
  iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null || iptables -I DOCKER-USER 1 "${rule[@]}"
done
echo "cce-docker-fw: $PUB -> docker bridges: NEW inbound connections dropped"
