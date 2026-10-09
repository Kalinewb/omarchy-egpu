#!/bin/bash

# common.sh — shared by every engine module.
#
# Paths, JSON output, config, PCI/sysfs readers, backend loading and enclosure
# profiles. Sourced, never run. Each module (status.sh, health.sh, ...) sources
# this and nothing else from lib/ except the backend it loads.
#
# Every system location is read through a variable so the test suite can point
# the engine at a fixture tree (plan-engine.md §4.1). External tools are called
# by bare name, so tests put tests/fakes/bin first on PATH. Nothing here writes
# outside $EGPU_RUN and $EGPU_STATE.

# shellcheck disable=SC2034  # many of these are read by the modules, not here

EGPU_LIB="${EGPU_LIB:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
EGPU_ROOT="${EGPU_ROOT:-$(cd -- "$EGPU_LIB/.." && pwd)}"

EGPU_SYS="${EGPU_SYS:-/sys}"
EGPU_DEV="${EGPU_DEV:-/dev}"
EGPU_PROC="${EGPU_PROC:-/proc}"
EGPU_ETC="${EGPU_ETC:-/etc}"
EGPU_USRLIB="${EGPU_USRLIB:-/usr/lib}"
# Not in the plan's list: /boot is needed for the initramfs row, and the tests
# need to point it at a fixture like every other root.
EGPU_BOOT="${EGPU_BOOT:-/boot}"
EGPU_RUN="${EGPU_RUN:-${XDG_RUNTIME_DIR:-/run/user/$UID}/omarchy-egpu}"
EGPU_STATE="${EGPU_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-egpu}"
EGPU_CONFIG="${EGPU_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-egpu/config.json}"
# The root half (§10). Only checked for presence and version here; never run
# with privileges by the engine's read-only verbs.
EGPU_ADMIN="${EGPU_ADMIN:-/usr/local/bin/omarchy-egpu-admin}"
EGPU_POLICY="${EGPU_POLICY:-/usr/share/polkit-1/actions/no.kalinewb.egpu.policy}"

EGPU_PCI="$EGPU_SYS/bus/pci/devices"

# Backends in detection order. A backend file defines the be_* functions of
# plan-engine.md §4.2 and sets BE_STATUS=implemented|stub.
EGPU_BACKENDS=(nvidia amdgpu intel)
EGPU_BACKEND=''
BE_STATUS=stub

# ---------------------------------------------------------------- output

# Milliseconds since the epoch, without forking date.
now_ms() {
  local t=${EPOCHREALTIME/./}
  printf '%s\n' "${t:0:13}"
}

# json_error <code> [extra-json-object]
# Prints {"error":code,...extra} on stdout. The caller decides the exit code
# (1 for refused/failed, 3 for busy; plan-engine.md §1.1).
json_error() {
  local code=$1 extra=${2:-'{}'}
  jq -cn --arg e "$code" --argjson x "$extra" '{error: $e} + $x'
}

# Prose goes to stderr, JSON to stdout.
say() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------- files

# read_attr <file>: the file's first line, or nothing (and status 1) when it is
# missing or unreadable. sysfs attributes are one line.
read_attr() {
  local line
  [[ -r $1 ]] || return 1
  IFS= read -r line <"$1" 2>/dev/null || [[ -n $line ]] || return 1
  printf '%s\n' "$line"
}

# Atomic write: temp file in the same directory, then rename.
write_atomic() {
  local dest=$1 tmp
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  tmp=$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").XXXXXX") || return 1
  if cat >"$tmp" && mv -f -- "$tmp" "$dest"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

# ---------------------------------------------------------------- config

# config_get <key> <default-json>: prints the effective value as compact JSON.
# Keys are dotted paths ("device.match"); a literal dotted key also matches.
config_get() {
  local key=$1 def=$2
  if [[ -r $EGPU_CONFIG ]]; then
    jq -c --arg k "$key" --argjson d "$def" '
      if has($k) then .[$k]
      else (getpath($k | split(".")) // $d) end' "$EGPU_CONFIG" 2>/dev/null && return 0
  fi
  printf '%s\n' "$def"
}

# config_str <key> <default>: the same, as a raw string.
config_str() {
  config_get "$1" "$(jq -cn --arg d "$2" '$d')" | jq -r '.'
}

plugin_version() {
  jq -r '.version // "0.0.0"' "$EGPU_ROOT/manifest.json" 2>/dev/null || echo 0.0.0
}

# ---------------------------------------------------------------- PCI

pci_attr() { read_attr "$EGPU_PCI/$1/$2"; }

# The driver bound to a function, or nothing.
pci_driver() {
  local link
  link=$(readlink -- "$EGPU_PCI/$1/driver" 2>/dev/null) || return 1
  printf '%s\n' "${link##*/}"
}

pci_is_display() { [[ $(pci_attr "$1" class) == 0x03* ]]; }
pci_is_removable() { [[ $(pci_attr "$1" removable) == removable ]]; }
pci_is_boot_vga() { [[ $(pci_attr "$1" boot_vga) == 1 ]]; }

# Every display-class function.
pci_display_functions() {
  local d
  for d in "$EGPU_PCI"/*; do
    [[ -e $d/class ]] || continue
    pci_is_display "${d##*/}" && printf '%s\n' "${d##*/}"
  done
}

# The candidate eGPU functions: display class, behind a removable port, not the
# boot VGA device. `removable` is the discriminator recorded at E0 (§10.1).
# `device.match` in config narrows it to one vendor/device.
pci_egpu_candidates() {
  local bdf match vendor device
  match=$(config_get device.match '"auto"')
  vendor=$(jq -r 'if type == "object" then .vendor // "" else "" end' <<<"$match")
  device=$(jq -r 'if type == "object" then .device // "" else "" end' <<<"$match")
  while IFS= read -r bdf; do
    [[ -n $bdf ]] || continue
    pci_is_removable "$bdf" || continue
    pci_is_boot_vga "$bdf" && continue
    [[ -z $vendor || $(pci_attr "$bdf" vendor) == "$vendor" ]] || continue
    [[ -z $device || $(pci_attr "$bdf" device) == "$device" ]] || continue
    printf '%s\n' "$bdf"
  done < <(pci_display_functions)
}

# The primary display device: config primary.bypath, else the boot VGA one.
pci_primary() {
  local bypath bdf
  bypath=$(config_str primary.bypath "")
  if [[ $bypath =~ ^pci-([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])-card$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  while IFS= read -r bdf; do
    [[ -n $bdf ]] && pci_is_boot_vga "$bdf" && { printf '%s\n' "$bdf"; return 0; }
  done < <(pci_display_functions)
  return 1
}

# All functions in the same slot (GPU + HDMI audio).
pci_slot_functions() {
  local slot=${1%.*} d
  for d in "$EGPU_PCI/$slot".[0-7]; do
    [[ -e $d ]] && printf '%s\n' "${d##*/}"
  done
}

# The DRM card name (card1) of a PCI function, from its drm/ subdirectory.
pci_drm_card() {
  local c
  for c in "$EGPU_PCI/$1"/drm/card[0-9]*; do
    [[ -d $c ]] && { printf '%s\n' "${c##*/}"; return 0; }
  done
  return 1
}

# The by-path name of a card node, if udev made one.
drm_bypath_for() {
  local bdf=$1 name="pci-$1-card"
  [[ -e $EGPU_DEV/dri/by-path/$name || -L $EGPU_DEV/dri/by-path/$name ]] || return 1
  printf '%s\n' "$name"
}

# The by-path name a cardN node is reachable by, or nothing.
drm_bypath_of_card() {
  local card=$1 l
  for l in "$EGPU_DEV"/dri/by-path/*-card; do
    [[ -L $l ]] || continue
    [[ $(readlink -- "$l") == */"$card" || $(readlink -- "$l") == "$card" ]] && { printf '%s\n' "${l##*/}"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- modules

module_loaded() {
  [[ -d $EGPU_SYS/module/$1 ]] || return 1
  local st
  st=$(read_attr "$EGPU_SYS/module/$1/initstate") || return 0
  [[ $st == live ]]
}

# Module names are compared with '-' and '_' treated alike, as the kernel does.
module_norm() { printf '%s\n' "${1//-/_}"; }

# ---------------------------------------------------------------- processes

# pids of the user's own processes with this exact name.
user_pids() { pgrep -u "$UID" -x "$1" 2>/dev/null; }

compositor_pid() { user_pids Hyprland | head -n1; }

# The DRM nodes (card*, renderD*) a process has open, one per line, unique.
proc_open_dri() {
  local fd t
  for fd in "$EGPU_PROC/$1"/fd/*; do
    t=$(readlink -- "$fd" 2>/dev/null) || continue
    [[ $t == /dev/dri/* ]] && printf '%s\n' "${t#/dev/dri/}"
  done | sort -u
}

# State letter from /proc/<pid>/stat (field 3; comm may contain spaces).
proc_state() {
  local stat rest
  stat=$(read_attr "$EGPU_PROC/$1/stat") || return 1
  rest=${stat##*) }
  printf '%s\n' "${rest%% *}"
}

# ---------------------------------------------------------------- backends

# backend_load <name>: source a backend, replacing the be_* functions of the
# previous one. Returns 1 for an unknown name.
backend_load() {
  local f="$EGPU_LIB/backends/$1.sh"
  [[ $1 =~ ^[a-z0-9]+$ && -r $f ]] || return 1
  unset -f be_name be_detect be_kms_modules be_unload_modules be_dev_nodes \
    be_verify be_offload_env be_steam_extras be_health be_kms_params be_flatpak_gl_ext
  BE_STATUS=stub
  # shellcheck source=/dev/null
  source "$f"
}

# backend_select <bdf>: load the backend that drives this function, honouring
# the `backend` config key, and set EGPU_BACKEND to its name. Runs in the
# caller's shell (not in $(...)) so the be_* functions stay loaded.
backend_select() {
  local want b
  EGPU_BACKEND=''
  want=$(config_str backend auto)
  if [[ $want != auto ]]; then
    backend_load "$want" && be_detect "$1" && { EGPU_BACKEND=$want; return 0; }
    return 1
  fi
  for b in "${EGPU_BACKENDS[@]}"; do
    backend_load "$b" || continue
    be_detect "$1" && { EGPU_BACKEND=$b; return 0; }
  done
  return 1
}

# Backends that support unloading (non-empty be_unload_modules). Their KMS
# modules are the ones that must never load at boot or without a card.
backends_unloadable() {
  local b mods
  for b in "${EGPU_BACKENDS[@]}"; do
    backend_load "$b" || continue
    mods=$(be_unload_modules 2>/dev/null) || continue
    [[ -n $mods ]] && printf '%s\n' "$b"
  done
}

# ---------------------------------------------------------------- bolt

# bolt_devices: every device boltctl knows, as a JSON array of
#   {uuid,name,vendor,status,generation,stored,policy}
# Exit 1 when boltctl is missing or boltd does not answer.
bolt_devices() {
  command -v boltctl >/dev/null 2>&1 || return 1
  local out
  out=$(timeout 5 boltctl list 2>/dev/null) || return 1
  awk '
    function flush() {
      if (uuid != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", uuid, name, vendor, status, gen, stored, policy
      uuid = name = vendor = status = gen = stored = policy = ""
    }
    /^ [^ |`]/ { flush(); next }
    {
      line = $0
      if (!match(line, /[|`]- [a-z][a-z ]*: */)) next
      key = substr(line, RSTART + 3, RLENGTH - 3); sub(/: *$/, "", key)
      val = substr(line, RSTART + RLENGTH)
      if (key == "uuid") uuid = val
      else if (key == "name") name = val
      else if (key == "vendor") vendor = val
      else if (key == "status") { split(val, w, " "); status = w[1] }
      else if (key == "generation") gen = val
      else if (key == "stored") stored = (val == "no" ? "no" : "yes")
      else if (key == "policy") policy = val
    }
    END { flush() }' <<<"$out" |
    jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t") |
        {uuid: .[0], name: .[1], vendor: .[2], status: .[3],
         generation: (if .[4] == "" then null else .[4] end),
         stored: (.[5] == "yes"),
         policy: (if .[6] == "" then null else .[6] end)})'
}

bolt_connected_status() {
  case $1 in
    connecting | connected | authorizing | authorized | auth-error) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- profiles

# profile_match <bolt_vendor> <bolt_name>: prints the matching profile id
# (exact strings only, §4.3). The `profile` config key wins when it names one.
# Falls back to "generic".
profile_match() {
  local want f id
  want=$(config_str profile auto)
  if [[ $want != auto && -r $EGPU_ROOT/profiles/$want.json ]]; then
    printf '%s\n' "$want"
    return 0
  fi
  for f in "$EGPU_ROOT"/profiles/*.json; do
    id=$(jq -r --arg v "$1" --arg n "$2" '
      select(.match != null and .match.bolt_vendor == $v and .match.bolt_name == $n) | .id' "$f" 2>/dev/null)
    [[ -n $id ]] && { printf '%s\n' "$id"; return 0; }
  done
  printf '%s\n' generic
}

profile_json() {
  local f="$EGPU_ROOT/profiles/${1:-generic}.json"
  [[ -r $f ]] || f="$EGPU_ROOT/profiles/generic.json"
  jq -c . "$f" 2>/dev/null || echo '{}'
}

# Enclosures the engine has seen with an eGPU behind them, by bolt uuid. An
# authorized Thunderbolt device without a GPU only counts as "the eGPU without
# its PCI device" if it matches a profile or is remembered here; otherwise any
# dock would read as a broken eGPU.
enclosure_known() {
  [[ -r $EGPU_STATE/enclosures ]] && grep -qxF -- "$1" "$EGPU_STATE/enclosures"
}

enclosure_remember() {
  [[ -n $1 ]] || return 0
  enclosure_known "$1" && return 0
  mkdir -p -- "$EGPU_STATE" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$EGPU_STATE/enclosures"
}

# ---------------------------------------------------------------- health rows

# health_row <id> <group> <level> <title> <detail> [fix_kind] [fix_label] [value]
# One row of the §9 format, compact, on one line.
health_row() {
  jq -cn --arg id "$1" --arg g "$2" --arg l "$3" --arg t "$4" --arg d "$5" \
    --arg fk "${6:-none}" --arg fl "${7:-}" --arg v "${8-}" --arg hv "${8+1}" '
    {id: $id, group: $g, level: $l, title: $t, detail: $d,
     fix: {kind: $fk, label: $fl}}
    + (if $hv == "1" then {value: $v} else {} end)'
}
