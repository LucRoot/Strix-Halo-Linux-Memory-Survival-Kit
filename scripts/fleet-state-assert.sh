#!/usr/bin/env bash
# fleet-state-assert.sh — boot-time sanity assertions for a fleet of
# systemd inference services.
#
# Born from a reboot incident: after 12 days of uptime a box came back
# with (a) one service missing its enable symlink — it silently never
# started — and (b) one service whose User= account could not traverse
# its own home directory, so the unit failed instantly on every start.
# Both bugs were invisible while the machine stayed up. This script
# makes both loud on every boot.
#
# Usage:
#   fleet-state-assert.sh <unit1.service> [unit2.service ...]
#   fleet-state-assert.sh --all 'llama-*.service'
#
# Checks per unit:
#   1. enable symlink present (unit is enabled for at least one target)
#   2. if the unit sets User=<u> and HOME=/path or the account's home is
#      known: every directory component of that home is traversable
#      (execute/search permission) by <u>
#
# Exit: 0 if all checks pass, 1 otherwise. Failures go to stderr so they
# show up in `systemctl status` / the journal.
set -uo pipefail

units=()
if [[ $# -ge 2 && "$1" == "--all" ]]; then
  # expand a glob against enabled unit symlinks
  shopt -s nullglob globstar
  for d in /etc/systemd/system/multi-user.target.wants /etc/systemd/system/graphical.target.wants; do
    for f in "$d"/$2; do
      [[ -e "$f" ]] && units+=("$(basename "$f")")
    done
  done
elif [[ $# -ge 1 ]]; then
  units=("$@")
else
  echo "usage: fleet-state-assert.sh <unit.service> [...] | --all '<glob>'" >&2
  exit 2
fi

if [[ ${#units[@]} -eq 0 ]]; then
  echo "fleet-state-assert: no units matched — nothing to check" >&2
  exit 1
fi

fail=0

check_enabled() {
  local unit="$1"
  # systemctl is-enabled returns 0 for "enabled"; "static"/"disabled" fail.
  local state
  state=$(systemctl is-enabled "$unit" 2>/dev/null) || state="missing"
  if [[ "$state" != "enabled" ]]; then
    echo "FAIL: $unit is not enabled (state: $state) — it will not start on boot" >&2
    fail=1
  else
    echo "ok:   $unit enabled"
  fi
}

check_home_traversable() {
  local unit="$1" user home
  # User= from the effective unit config; skip units running as root.
  user=$(systemctl show "$unit" -p User --value 2>/dev/null)
  [[ -z "$user" || "$user" == "root" ]] && return 0

  # Prefer explicit HOME= environment from the unit, else the passwd entry.
  home=$(systemctl show "$unit" -p Environment --value 2>/dev/null \
           | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1)
  if [[ -z "$home" ]]; then
    home=$(getent passwd "$user" | cut -d: -f6)
  fi
  if [[ -z "$home" || ! -d "$home" ]]; then
    echo "FAIL: $unit: cannot determine home dir for user '$user'" >&2
    fail=1
    return 0
  fi

  # Walk every component of the path; each must be searchable (x) by user.
  local path=""
  local IFS='/'
  read -ra parts <<< "$home"
  unset IFS
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    path="$path/$part"
    if ! sudo -u "$user" test -x "$path" 2>/dev/null; then
      echo "FAIL: $unit: user '$user' cannot traverse '$path' (on the way to $home)" >&2
      fail=1
      return 0
    fi
  done
  echo "ok:   $unit: home $home traversable by $user"
}

for unit in "${units[@]}"; do
  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    echo "FAIL: $unit does not exist" >&2
    fail=1
    continue
  fi
  check_enabled "$unit"
  check_home_traversable "$unit"
done

if [[ $fail -ne 0 ]]; then
  echo "fleet-state-assert: FAILURES present — fleet is not boot-safe" >&2
  exit 1
fi
echo "fleet-state-assert: all ${#units[@]} units OK"
exit 0
