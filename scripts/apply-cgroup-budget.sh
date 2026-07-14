#!/usr/bin/env bash
# apply-cgroup-budget.sh — set MemoryMax/MemoryLow (+ optional
# MemoryHigh/MemorySwapMax) on a systemd unit via systemctl set-property.
#
# Changes apply to the unit's cgroup immediately on daemon-reload and do
# NOT restart running processes. Properties persist across reboots
# (systemd writes a drop-in under /etc/systemd/system.control/).
#
# Usage:
#   sudo apply-cgroup-budget.sh <unit> --max 8G --low 2G [--high 6G] [--swap-max 2G]
#
# At least one of --max / --low / --high / --swap-max is required.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: apply-cgroup-budget.sh <unit.service> [--max SIZE] [--low SIZE] [--high SIZE] [--swap-max SIZE]
  SIZE: systemd size syntax, e.g. 4G, 512M, or "infinity" to clear.
  Requires root (writes /etc/systemd/system.control/).
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

unit="$1"; shift

# Validate unit name early: must exist as a unit file (enabled or not).
if ! systemctl cat "$unit" >/dev/null 2>&1; then
  echo "error: unit '$unit' not found (systemctl cat failed)" >&2
  exit 1
fi

max="" low="" high="" swap_max=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)      max="${2:?--max needs a value}"; shift 2 ;;
    --low)      low="${2:?--low needs a value}"; shift 2 ;;
    --high)     high="${2:?--high needs a value}"; shift 2 ;;
    --swap-max) swap_max="${2:?--swap-max needs a value}"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "error: unknown option '$1'" >&2; usage ;;
  esac
done

if [[ -z "$max$low$high$swap_max" ]]; then
  echo "error: provide at least one of --max/--low/--high/--swap-max" >&2
  usage
fi

# Sanity: warn (don't fail) if low > max — memory.low above memory.max
# is meaningless and usually a typo.
to_bytes() {
  # crude systemd-size parser: number + optional K/M/G/T suffix
  local v="$1" n suffix
  if [[ "$v" == "infinity" ]]; then echo "inf"; return; fi
  n="${v%[KMGT]}"
  suffix="${v: -1}"
  case "$suffix" in
    K) echo $(( n * 1024 )) ;;
    M) echo $(( n * 1024**2 )) ;;
    G) echo $(( n * 1024**3 )) ;;
    T) echo $(( n * 1024**4 )) ;;
    *) echo "$n" ;;
  esac
}
if [[ -n "$max" && -n "$low" && "$max" != "infinity" && "$low" != "infinity" ]]; then
  if (( $(to_bytes "$low") > $(to_bytes "$max") )); then
    echo "warning: MemoryLow ($low) exceeds MemoryMax ($max) — low above max is a no-op" >&2
  fi
fi

props=()
[[ -n "$max" ]]      && props+=("MemoryMax=$max")
[[ -n "$low" ]]      && props+=("MemoryLow=$low")
[[ -n "$high" ]]     && props+=("MemoryHigh=$high")
[[ -n "$swap_max" ]] && props+=("MemorySwapMax=$swap_max")

echo "Applying to $unit: ${props[*]}"
systemctl set-property "$unit" "${props[@]}"

# Show what landed, from the kernel's point of view if the cgroup exists.
systemctl show "$unit" -p MemoryMax -p MemoryLow -p MemoryHigh -p MemorySwapMax
cg="/sys/fs/cgroup/system.slice/${unit}"
if [[ -d "$cg" ]]; then
  echo "live cgroup values:"
  for f in memory.max memory.low memory.high memory.swap.max; do
    [[ -r "$cg/$f" ]] && printf '  %-16s %s\n' "$f" "$(cat "$cg/$f")"
  done
else
  echo "(unit not running — no live cgroup; values apply on next start)" >&2
fi
