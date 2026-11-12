#!/usr/bin/env bash
# one-click-installer/lib/creds-dir.sh — SOURCE me. Where the per-env Infisical machine-identity creds live (<env>.creds / <env>.meta, 0600).
#
# Used to be hardcoded to /home/cceadmin/.cce-infisical, which only existed on the first reference VM — on any other machine (the
# one-click installer's whole purpose) bootstrap wrote creds into a directory belonging to a user that does not exist.
#
# Resolution order:
#   1. $CCE_INFISICAL_CREDS_DIR                 explicit override always wins
#   2. <home of the invoking user>/.cce-infisical   SUDO_USER (we run under sudo as root) → logname → $HOME
cce_creds_dir() {
  if [ -n "${CCE_INFISICAL_CREDS_DIR:-}" ]; then printf '%s' "$CCE_INFISICAL_CREDS_DIR"; return; fi
  local u="${SUDO_USER:-}" h=""
  { [ -n "$u" ] && [ "$u" != root ]; } || u="$(logname 2>/dev/null || true)"
  [ -n "$u" ] && h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  [ -n "$h" ] || h="${HOME:-/root}"
  printf '%s/.cce-infisical' "$h"
}
