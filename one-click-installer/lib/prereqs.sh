#!/usr/bin/env bash
# one-click-installer/lib/prereqs.sh — check and install what one-click-installer/install.sh needs on a FRESH Ubuntu machine.
#
#   sudo bash one-click-installer/lib/prereqs.sh            # check + install what is missing (idempotent)
#   sudo CHECK_ONLY=1 bash one-click-installer/lib/prereqs.sh   # report only, change nothing
#
# The installer provisions PostgreSQL, Kafka, ClickHouse and Kafka Connect itself, but it has always ASSUMED k3s, the
# Infisical CLI and envsubst already exist ("ERROR: no kubectl / k3s found" otherwise). This closes that gap, pinned to
# the versions the reference production environment runs so a new environment starts from the same baseline:
#   K3S_VERSION           default v1.35.4+k3s1   (PROD)
#   INFISICAL_CLI_VERSION default 0.43.93        (PROD)
# An existing install at a DIFFERENT version is reported, never replaced (k3s cannot be downgraded in place) —
# FORCE_K3S_REINSTALL=1 on a machine with an EMPTY cluster uninstalls and reinstalls the pinned version.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/sudo-compat.sh"

K3S_VERSION="${K3S_VERSION:-v1.35.4+k3s1}"
INFISICAL_CLI_VERSION="${INFISICAL_CLI_VERSION:-0.43.93}"
CHECK_ONLY="${CHECK_ONLY:-}"
# PROD today requests ~7.6 vCPU / 12.5 GiB across its pods (measured 2026-10-26); the native Postgres/Kafka/ClickHouse/
# Connect run on the same node. Below these a PROD-sized overlay will leave pods Pending.
REC_VCPU=8; REC_MEM_GIB=24; REC_DISK_GB=40

fail=0; warn=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warn=$((warn+1)); }
sect() { printf '\n── %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

sect "machine"
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = ubuntu ] && command -v apt-get >/dev/null; then ok "OS: ${PRETTY_NAME:-ubuntu} (apt + systemd)"; else bad "OS ${PRETTY_NAME:-unknown}: installer is written for Ubuntu (apt, systemd)"; fi
pidof systemd >/dev/null 2>&1 && ok "systemd is PID 1" || bad "systemd is not running"
sudo_ver="$(sudo --version 2>/dev/null | head -1)"; ok "sudo: ${sudo_ver:-?}$(echo "$sudo_ver" | grep -qi rs && echo ' — sudo-rs: -E unsupported, scripts use `sudo env`/direct root')"
cpu="$(nproc)"; mem="$(awk '/MemTotal/{printf "%d", $2/1048576+0.5}' /proc/meminfo)"; disk="$(df -BG --output=avail / | tail -1 | tr -dc 0-9)"
[ "$cpu"  -ge "$REC_VCPU" ]    && ok "CPU $cpu vCPU (>= $REC_VCPU)"       || note "CPU $cpu vCPU < $REC_VCPU recommended — PROD-sized pods will not all schedule"
[ "$mem"  -ge "$REC_MEM_GIB" ] && ok "RAM ${mem} GiB (>= $REC_MEM_GIB)"   || note "RAM ${mem} GiB < $REC_MEM_GIB recommended"
[ "$disk" -ge "$REC_DISK_GB" ] && ok "free disk ${disk} GB (>= $REC_DISK_GB)" || note "free disk ${disk} GB < $REC_DISK_GB recommended"

sect "outbound access (everything the installer downloads)"
# A site used only to install something that is already in place is not checked: the install steps skip it (k3s is never
# reinstalled without FORCE_K3S_REINSTALL; Kafka when /opt/kafka exists — k8s/infrastructure/setup-prod-infra.sh; ClickHouse when
# clickhouse-server exists — native/02; the Infisical CLI at the pinned version). So a slow or unreachable archive.apache.org
# (seen: 7–8 s per request) cannot stop a re-run. Image registries, github.com and the Ubuntu mirror are always needed.
sites=(https://github.com https://ghcr.io/v2/ https://quay.io/v2/ https://registry-1.docker.io/v2/ https://registry.k8s.io/v2/ http://archive.ubuntu.com/ubuntu/)
skip_site(){ ok "$1 — not needed ($2 already installed)"; }
if command -v k3s >/dev/null 2>&1 && [ -z "${FORCE_K3S_REINSTALL:-}" ]; then skip_site https://get.k3s.io k3s; else sites+=(https://get.k3s.io); fi
# Kafka: needed unless the installed version IS the configured one (a newer KAFKA_VERSION is an in-place upgrade = a download).
kafka_have="$(ls /opt/kafka/libs/kafka_*.jar 2>/dev/null | sed -nE 's#.*/kafka_[0-9.]+-([0-9]+\.[0-9]+\.[0-9]+)\.jar$#\1#p' | head -1)"
if [ -n "$kafka_have" ] && [ "$kafka_have" = "${KAFKA_VERSION:-3.7.0}" ]; then skip_site https://archive.apache.org "Kafka $kafka_have"
else sites+=(https://archive.apache.org); fi
if command -v clickhouse-server >/dev/null 2>&1; then skip_site https://packages.clickhouse.com ClickHouse; else sites+=(https://packages.clickhouse.com); fi
if [ "$(infisical --version 2>/dev/null | awk '{print $3}')" = "${INFISICAL_CLI_VERSION:-0.43.93}" ]; then skip_site https://artifacts-cli.infisical.com "Infisical CLI ${INFISICAL_CLI_VERSION:-0.43.93}"
else sites+=(https://artifacts-cli.infisical.com); fi
for u in "${sites[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --retry 2 --retry-delay 3 "$u" 2>/dev/null || true)"
  case "$code" in 2*|3*|401|403|404) ok "$u ($code)";; *) bad "cannot reach $u (curl: ${code:-none})";; esac
done

sect "tools"
need_pkgs=()
for pair in envsubst:gettext-base curl:curl python3:python3 gpg:gnupg git:git ; do
  cmd="${pair%%:*}"; pkg="${pair##*:}"
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd" || { note "$cmd missing (apt: $pkg)"; need_pkgs+=("$pkg"); }
done
if [ "${#need_pkgs[@]}" -gt 0 ] && [ -z "$CHECK_ONLY" ]; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_pkgs[@]}" >/dev/null && ok "installed: ${need_pkgs[*]}" || bad "apt install failed: ${need_pkgs[*]}"
fi

# Docker is needed only when a docker runtime is chosen: EXPORTER_RUNTIME=docker, or a local Infisical with
# LOCAL_INFISICAL_RUNTIME=docker (NEED_DOCKER=1 forces it, e.g. for a caller that builds images). The defaults run nothing in docker.
NEED_DOCKER="${NEED_DOCKER:-}"
[ "${EXPORTER_RUNTIME:-systemd}" = docker ] && NEED_DOCKER=1
[ "${USE_LOCAL_INFISICAL:-false}" = true ] && [ "${LOCAL_INFISICAL_RUNTIME:-native}" = docker ] && NEED_DOCKER=1
sect "Docker (only for a docker runtime)"
if command -v docker >/dev/null 2>&1; then ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"
elif [ -z "$NEED_DOCKER" ]; then ok "not needed (native exporters/Infisical/Portainer) — not installing"
elif [ -n "$CHECK_ONLY" ]; then note "docker not installed (needed by the docker runtime you chose)"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 \
    && ok "installed docker $(docker --version | awk '{print $3}' | tr -d ,)" || bad "docker install failed"
fi

sect "Infisical CLI ($INFISICAL_CLI_VERSION)"
have="$(infisical --version 2>/dev/null | awk '{print $3}')"
if [ "$have" = "$INFISICAL_CLI_VERSION" ]; then ok "infisical $have"
elif [ -n "$have" ]; then note "infisical $have installed, pinned is $INFISICAL_CLI_VERSION — leaving it"
elif [ -n "$CHECK_ONLY" ]; then note "infisical CLI not installed"
else
  curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | bash >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "infisical=$INFISICAL_CLI_VERSION" >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq infisical >/dev/null 2>&1
  have="$(infisical --version 2>/dev/null | awk '{print $3}')"
  [ -n "$have" ] && { [ "$have" = "$INFISICAL_CLI_VERSION" ] && ok "installed infisical $have" || note "installed infisical $have (pinned $INFISICAL_CLI_VERSION not available)"; } || bad "infisical CLI install failed"
fi

sect "k3s ($K3S_VERSION)"
cur="$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')"
if [ -n "$cur" ] && [ "$cur" != "$K3S_VERSION" ] && [ -n "${FORCE_K3S_REINSTALL:-}" ] && [ -z "$CHECK_ONLY" ]; then
  pods="$(k3s kubectl get pods -A --no-headers 2>/dev/null | awk '$1!="kube-system"' | wc -l)"   # any pod outside kube-system = real workload
  if [ "$pods" -eq 0 ]; then echo "  empty cluster — uninstalling $cur to install $K3S_VERSION"; /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1; cur=""
  else note "FORCE_K3S_REINSTALL refused: cluster has $pods workload pod(s)"; fi
fi
if [ "$cur" = "$K3S_VERSION" ]; then ok "k3s $cur"
elif [ -n "$cur" ]; then note "k3s $cur is installed; pinned (PROD) is $K3S_VERSION — leaving it (set FORCE_K3S_REINSTALL=1 on an EMPTY cluster to align)"
elif [ -n "$CHECK_ONLY" ]; then note "k3s not installed"
else
  curl -sfL https://get.k3s.io | as_root_env "INSTALL_K3S_VERSION=$K3S_VERSION" sh -s - >/tmp/k3s-install.log 2>&1 || true
  cur="$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')"
  if   [ "$cur" = "$K3S_VERSION" ]; then ok "installed k3s $cur"
  elif [ -n "$cur" ];               then bad "k3s pin IGNORED: asked $K3S_VERSION, got $cur (see /tmp/k3s-install.log; sudo -E?)"
  else bad "k3s install failed (see /tmp/k3s-install.log)"; fi
fi
if command -v k3s >/dev/null 2>&1 && [ -z "$CHECK_ONLY" ]; then
  echo "  waiting for the node and Traefik to be Ready…"
  for _ in $(seq 1 60); do
    k3s kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready' && \
    [ "$(k3s kubectl -n kube-system get deploy traefik -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] && { ok "node Ready, Traefik Ready"; break; }
    sleep 5
  done
fi

echo; [ "$fail" -eq 0 ] && echo "prereqs: OK ($warn warning(s))" || echo "prereqs: $fail FAILURE(S), $warn warning(s)"
exit $(( fail > 0 ))
