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

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw default allow routed   >/dev/null      # REQUIRED: k3s pod traffic is forwarded; "deny routed" breaks the cluster
for ifc in lo cni0 flannel.1 docker0; do ufw allow in on "$ifc" >/dev/null; done
for src in "$POD_CIDR" "$SVC_CIDR" 172.16.0.0/12; do ufw allow from "$src" >/dev/null; done   # pods, services, docker bridges
if [ -n "${SSH_ALLOWED_CIDR:-}" ]; then ufw allow from "$SSH_ALLOWED_CIDR" to any port 22 proto tcp >/dev/null
else ufw allow 22/tcp >/dev/null; fi
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
IFS=',' read -ra EXTRA <<< "${UFW_EXTRA_ALLOW:-}"
for r in "${EXTRA[@]}"; do r="$(echo "$r" | xargs)"; [ -z "$r" ] && continue
  if [[ "$r" == */* && "$r" =~ ^[0-9.]+/[0-9]+$ ]]; then ufw allow from "$r" >/dev/null; else ufw allow "$r" >/dev/null; fi
done
ufw --force enable >/dev/null

# Still reachable over SSH (we are running over it) -> disarm the dead-man.
if ufw status | grep -qE '^22(/tcp)?\s+ALLOW'; then systemctl stop cce-ufw-deadman.timer 2>/dev/null || true; fi
echo "ufw: $(ufw status | head -1) — default deny incoming; public: 22$( [ -n "${SSH_ALLOWED_CIDR:-}" ] && echo " (from $SSH_ALLOWED_CIDR)")/80/443${UFW_EXTRA_ALLOW:+ + $UFW_EXTRA_ALLOW}; internal: $POD_CIDR $SVC_CIDR 172.16.0.0/12"
