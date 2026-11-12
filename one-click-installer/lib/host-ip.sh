#!/usr/bin/env bash
# one-click-installer/lib/host-ip.sh — SOURCE this. Stops the server's IP having to be stored (and go stale).
#
# The VM's address is not configuration, it is a fact about the machine. Storing it in Infisical
# meant that when the IP changed (as happened to the reference deployment, 2026-10) every copy had to be
# found and edited by hand, and any one left behind was silently re-applied by the next
# `redeploy.sh` (which re-renders cce-config from Infisical).
#
# This detects the primary address from the routing table and fills the IP-DEPENDENT variables
# ONLY WHEN INFISICAL DOES NOT PROVIDE THEM:
#
#     VM_HOST_IP  VM_HOST_CIDR  POSTGRES_HOST  KAFKA_BOOTSTRAP_SERVERS  CLICKHOUSE_HOST
#
# A value that IS set in Infisical always wins (it stays the authority, and a deliberate override
# keeps working) — but if it disagrees with the detected address a loud warning is printed, since
# that is exactly the stale-IP situation. To adopt this fully, delete those keys from Infisical.
#
# Deliberately NOT derived: GATEWAY_ALLOWED_ORIGINS (a CORS policy choice, not topology), and
# anything that must already be a hostname. The default ports mirror the documented topology:
# UAT Kafka :9093 (shared VM, shifted); UAT ClickHouse is the docker bridge gateway, never the public IP.
# PROD and every OTHER env code (one-click-installer/install.sh = dedicated machine, standard ports) use Kafka :9092
# and ClickHouse on the host IP — exactly what infisical-seed.sh used to store, now computed instead.

cce_detect_host_ip() {
  # Source address the kernel would use to reach the outside world. Same address k3s reports as
  # the node InternalIP, which is what pods must use to reach host data services.
  ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
}

# usage: cce_fill_host_defaults <env-name>
cce_fill_host_defaults() {
  local env="${1:-}" ip filled=""
  ip="$(cce_detect_host_ip)"
  if [ -z "$ip" ]; then
    echo "host-ip: WARNING could not detect this host's IP; leaving IP variables as provided" >&2
    return 0
  fi

  # stale-value check on what Infisical DID provide
  if [ -n "${VM_HOST_IP:-}" ] && [ "$VM_HOST_IP" != "$ip" ]; then
    echo "host-ip: WARNING VM_HOST_IP=$VM_HOST_IP (from Infisical) != detected $ip — the stored IP looks STALE." >&2
    echo "host-ip:          Fix: delete VM_HOST_IP/VM_HOST_CIDR/POSTGRES_HOST/KAFKA_BOOTSTRAP_SERVERS/CLICKHOUSE_HOST from Infisical (they are derived), or correct them." >&2
  fi

  _cce_default() {  # name value — set+export only if currently empty
    local name="$1" val="$2"
    if [ -z "${!name:-}" ]; then export "$name=$val"; filled="$filled $name"; fi
  }
  _cce_default VM_HOST_IP   "$ip"
  _cce_default VM_HOST_CIDR "${VM_HOST_IP}/32"
  _cce_default POSTGRES_HOST "$VM_HOST_IP"
  # One-click installs are dedicated machines with the standard ports (KAFKA_PORT overridable via the config file).
  _cce_default KAFKA_BOOTSTRAP_SERVERS "${VM_HOST_IP}:${KAFKA_PORT:-9092}"
  _cce_default CLICKHOUSE_HOST "$VM_HOST_IP"
  [ -z "$filled" ] || echo "host-ip: [$env] derived from this host ($ip):$filled" >&2
}
