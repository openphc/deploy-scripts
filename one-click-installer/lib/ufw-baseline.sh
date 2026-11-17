#!/usr/bin/env bash
# one-click-installer/lib/ufw-baseline.sh — host firewall for an ON-PREM / bare-metal / VM-without-security-groups install.
#
#   sudo bash one-click-installer/lib/ufw-baseline.sh
#
# Run by install.sh when IS_CLOUD_DEPLOYMENT=false. On a cloud VM the provider's security group / firewall is the perimeter, so
# the installer skips this (it is still safe to run there). The host firewall is then the ONLY perimeter, so: default-deny
# inbound; only SSH + HTTP(S) public; every database / broker / k3s API / exporter reachable only from the node's own pod,
# service and docker networks. Ruleset = the reference production environment's, parameterised. Idempotent.
#
# Config (env / config file):  SSH_ALLOWED_CIDR (default: any)  UFW_EXTRA_ALLOW (e.g. "8443/tcp,10.0.0.0/8")
#                              K3S_CLUSTER_CIDR (10.42.0.0/16)  K3S_SERVICE_CIDR (10.43.0.0/16)
# NOTE: UFW does NOT see ports published by Docker (DNAT runs first) — install-docker-fw.sh covers those; install.sh runs both.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0"; exit 1; }
command -v ufw >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null; }
POD_CIDR="${K3S_CLUSTER_CIDR:-10.42.0.0/16}"; SVC_CIDR="${K3S_SERVICE_CIDR:-10.43.0.0/16}"

# Dead-man switch: if anything below locks us out, the firewall disables itself in 10 minutes.
systemctl stop cce-ufw-deadman.timer 2>/dev/null || true
systemd-run --quiet --on-active=600 --unit=cce-ufw-deadman /usr/sbin/ufw --force disable >/dev/null 2>&1 || true

# ufw rewrites ALL its iptables/ip6tables chains on every rule change. If that collides with k3s rewriting its own rules
# (pods being created or restarted), the reload can fail halfway and leave ufw's ip6tables chains missing: then every ufw
# command fails ("Could not load logging rules" / "problem running ip6tables") — seen on a re-run. A reload rebuilds them,
# so each call is retried after one. The dead-man timer above stays armed throughout.
u() {
  local i
  for i in 1 2 3; do
    ufw "$@" >/dev/null 2>&1 && return 0
    echo "  ufw $* failed (attempt $i) — reloading ufw and retrying" >&2; ufw reload >/dev/null 2>&1 || true; sleep 3
  done
  ufw "$@"   # last try, with its error shown
}

u default deny incoming
u default allow outgoing
u default allow routed        # REQUIRED: k3s pod traffic is forwarded; "deny routed" breaks the cluster
for ifc in lo cni0 flannel.1 docker0; do u allow in on "$ifc"; done
for src in "$POD_CIDR" "$SVC_CIDR" 172.16.0.0/12; do u allow from "$src"; done   # pods, services, docker bridges
if [ -n "${SSH_ALLOWED_CIDR:-}" ]; then
  u allow from "$SSH_ALLOWED_CIDR" to any port 22 proto tcp
  # Narrowing SSH must also REMOVE an earlier allow-from-anywhere rule (rules only ever accumulated, so setting
  # SSH_ALLOWED_CIDR on a re-run changed nothing). The dead-man below stays armed unless this session is still allowed.
  ufw status | grep -qE '^22/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere[[:space:]]*$' && u delete allow 22/tcp   # ufw pads lines with spaces
else
  u allow 22/tcp
fi
u allow 80/tcp
u allow 443/tcp
IFS=',' read -ra EXTRA <<< "${UFW_EXTRA_ALLOW:-}"
for r in "${EXTRA[@]}"; do r="$(echo "$r" | xargs)"; [ -z "$r" ] && continue
  if [[ "$r" == */* && "$r" =~ ^[0-9.]+/[0-9]+$ ]]; then u allow from "$r"; else u allow "$r"; fi
done
u --force enable

# Disarm the dead-man only if SSH is still open to the people running this. With SSH_ALLOWED_CIDR, that means at least one
# CURRENT SSH connection comes from inside it: otherwise an admin outside the range would be locked out with no automatic undo.
ssh_ok=0
if ufw status | grep -qE '^22(/tcp)?[[:space:]]+ALLOW'; then
  if [ -z "${SSH_ALLOWED_CIDR:-}" ]; then ssh_ok=1
  else
    peers="$(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $NF}' | sed -E 's/^\[?([^]]*)\]?:[0-9]+$/\1/' | sort -u)"
    if [ -z "$peers" ] || python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1],strict=False); sys.exit(0 if any(ipaddress.ip_address(p) in n for p in sys.argv[2:]) else 1)' "$SSH_ALLOWED_CIDR" $peers 2>/dev/null; then
      ssh_ok=1   # no SSH session (console/automation), or one from inside the range
    else
      echo "ufw: WARNING — no current SSH connection comes from SSH_ALLOWED_CIDR=$SSH_ALLOWED_CIDR (peers: $(echo $peers)). The dead-man"
      echo "     timer stays ARMED: UFW is disabled again in 10 minutes unless you fix the range and re-run (or: systemctl stop cce-ufw-deadman.timer)."
    fi
  fi
fi
[ "$ssh_ok" = 1 ] && { systemctl stop cce-ufw-deadman.timer 2>/dev/null || true; }
echo "ufw: $(ufw status | head -1) — default deny incoming; public: 22$( [ -n "${SSH_ALLOWED_CIDR:-}" ] && echo " (from $SSH_ALLOWED_CIDR)")/80/443${UFW_EXTRA_ALLOW:+ + $UFW_EXTRA_ALLOW}; internal: $POD_CIDR $SVC_CIDR 172.16.0.0/12"
