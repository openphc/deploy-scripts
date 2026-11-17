#!/usr/bin/env bash
# one-click-installer/lib/sudo-compat.sh — SOURCE me. Privilege helpers that work on BOTH classic sudo and sudo-rs.
#
# WHY: Ubuntu 26.04 ships sudo-rs, which does NOT support `sudo -E` — it prints
#   "sudo: preserving the entire environment is not supported, '-E' is ignored"
# and silently drops every variable. `FOO=x sudo -E cmd` therefore runs `cmd` WITHOUT FOO. (That is how a pinned
# INSTALL_K3S_VERSION was ignored and the latest k3s got installed instead, 2026-10-27.) Never use `sudo -E` or
# `sudo VAR=x cmd` in these scripts.
#
#   as_root cmd args…               run as root. If we already are root (the installers require it) just exec —
#                                   the environment is inherited untouched. Otherwise `sudo cmd`.
#   as_root_env VAR=x VAR2=y -- cmd run as root WITH those variables, portably: `sudo env VAR=x cmd`.
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}
as_root_env() {
  local -a vars=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift || true
  if [ "$(id -u)" = 0 ]; then env "${vars[@]}" "$@"; else sudo env "${vars[@]}" "$@"; fi
}
