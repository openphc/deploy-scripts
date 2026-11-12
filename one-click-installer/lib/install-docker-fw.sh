#!/usr/bin/env bash
# one-click-installer/lib/install-docker-fw.sh — install the public-NIC block for docker-published ports. Idempotent.
#
#   sudo bash one-click-installer/lib/install-docker-fw.sh
#
# WHY: ports published by Docker bypass UFW (DNAT/FORWARD run ahead of it), so `ufw default deny` does NOT protect the
# docker stack. In 2026-10, on a reference deployment's UAT host, Kafka Connect REST (8083), Postgres, ClickHouse and Kafka were
# open to the internet and an exploit connector (CVE-2025-27817) was planted. This installs cce-docker-fw.sh + its systemd unit,
# which drops NEW connections from the public NIC into any docker bridge.
# install.sh runs it whenever docker is present (a docker runtime was chosen); also after a full host rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not installed on this host — nothing to protect, skipping"; exit 0; }
install -m 755 "$HERE/cce-docker-fw.sh"      /usr/local/sbin/cce-docker-fw.sh
install -m 644 "$HERE/cce-docker-fw.service" /etc/systemd/system/cce-docker-fw.service
systemctl daemon-reload
systemctl enable cce-docker-fw.service >/dev/null 2>&1
systemctl restart cce-docker-fw.service
echo "installed: unit $(systemctl is-enabled cce-docker-fw)/$(systemctl is-active cce-docker-fw), DOCKER-USER rules: $(iptables -S DOCKER-USER | grep -c cce-block)"
echo "verify from OFF-NETWORK:  nmap -Pn <host-ip>   # only 22/80/443 should be open"
