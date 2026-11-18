#!/usr/bin/env bash
# one-click-installer/lib/beckn/run.sh --config <file> <script> [args…] — run ONE lib/beckn script by hand, the way
# install-beckn.sh runs it: installer config loaded, Beckn defaults filled, the environment's secrets injected from Infisical.
# The env code is passed to the script as its first argument.
#
#   sudo bash one-click-installer/lib/beckn/run.sh --config one-click-installer/config/<env>.env openhim-setup.sh
#   sudo bash one-click-installer/lib/beckn/run.sh --config one-click-installer/config/<env>.env beckn-deploy.sh openmrs
#   sudo bash one-click-installer/lib/beckn/run.sh --config one-click-installer/config/<env>.env openmrs-import.sh /root/openmrs-export.tgz
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; LIB="$(cd "$HERE/.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (sudo)"; exit 1; }
[ "${1:-}" = "--config" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || { sed -n '2,9p' "$0"; exit 2; }
CONFIG="$2"; SCRIPT="$HERE/$(basename "$3")"; shift 3
[ -r "$SCRIPT" ] || { echo "ERROR: no such script: $SCRIPT  (one of: $(cd "$HERE" && ls *.sh | grep -v -E '^(run|beckn-lib)\.sh$' | tr '\n' ' '))"; exit 2; }
. "$LIB/load-config.sh"; cce_load_config "$CONFIG"
: "${ENVCODE:?the config must set ENVCODE}"; export ENVCODE
. "$HERE/beckn-lib.sh"; beckn_defaults
beckn_validate || { echo "Fix the config above and re-run."; exit 1; }
exec bash "$LIB/infisical-run.sh" "$ENVCODE" bash "$SCRIPT" "$ENVCODE" "$@"
