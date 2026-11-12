#!/usr/bin/env bash
# one-click-installer/lib/host-ip-exec.sh <env> <command...> — fill IP-derived defaults, then exec the command.
# Runs INSIDE `infisical run`, i.e. after Infisical's values are injected, so Infisical values win.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/host-ip.sh"
cce_fill_host_defaults "${1:?env name required}"; shift
exec "$@"
