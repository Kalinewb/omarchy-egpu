#!/bin/bash

# apps.sh — module: "Run on eGPU" for installed desktop apps.
#
#   omarchy-egpu apps list                 {apps: [{id, name, icon, comment, state, game, terminal}], on, run}
#   omarchy-egpu apps set <id> on|off      {id, state}
#   omarchy-egpu apps set-all off          {removed: [id…]}
#   omarchy-egpu apps status               {on, run}
#
# state: off | on | manual (the user's own override of the same entry; left alone).
#
# An app turned on gets a copy of its entry in the user's applications
# directory whose Exec lines start with `egpu-run --quiet --` (bin/egpu-run),
# so every launcher starts it on the eGPU, and on the laptop GPU when the eGPU
# is not there. Turning it off deletes that copy, nothing else. Only files
# carrying the marker line `X-Omarchy-eGPU=managed` are ever changed. Steam
# games are not here: they have their own switches (omarchy-egpu steam), and
# Flatpak apps are not listed (a sandbox does not see the variables).
#
# Test seams: EGPU_APPS_DIRS (colon-separated system directories, default
# XDG_DATA_DIRS/applications), XDG_DATA_HOME (the user's).

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

APPS_PY="$EGPU_LIB/apps.py"

_apps_user_dir() { printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/applications"; }

_apps_sys_dirs() {
  if [[ -n ${EGPU_APPS_DIRS:-} ]]; then
    printf '%s\n' "$EGPU_APPS_DIRS"
    return
  fi
  local d out=() IFS=:
  for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    [[ -n $d && $d != */flatpak/exports/share ]] && out+=("${d%/}/applications")
  done
  printf '%s\n' "${out[*]}"
}

# The wrapper the entries call. A stable path inside the plugin folder.
_apps_run_path() {
  local p
  p=$(config_str apps.run_path '')
  [[ -n $p ]] || p="$(cd -- "$EGPU_LIB/.." && pwd)/bin/egpu-run"
  printf '%s\n' "$p"
}

_apps_py() {
  local verb=$1
  shift
  python3 -I "$APPS_PY" "$verb" "$@" --user-dir "$(_apps_user_dir)"
}

apps_list() {
  local out
  out=$(_apps_py list --sys-dirs "$(_apps_sys_dirs)" --run "$(_apps_run_path)") || { printf '%s\n' "$out"; return 1; }
  printf '%s\n' "$out"
}

apps_status() {
  apps_list | jq -c 'if .error then . else {on, run} end'
}

apps_set() {
  local id=${1:-} want=${2:-} out rc
  if [[ -z $id || ($want != on && $want != off) ]]; then
    json_error usage '{"detail":"apps set <id> on|off"}'
    return 1
  fi
  if [[ $want == on ]]; then
    out=$(_apps_py enable "$id" --sys-dirs "$(_apps_sys_dirs)" --run "$(_apps_run_path)")
  else
    out=$(_apps_py disable "$id")
  fi
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

apps_set_all() {
  if [[ ${1:-} != off ]]; then
    json_error usage '{"detail":"apps set-all off"}'
    return 1
  fi
  _apps_py disable-all
}

apps_main() {
  local verb=${1:-}
  [[ $# -gt 0 ]] && shift
  case $verb in
    list) apps_list ;;
    set) apps_set "$@" ;;
    set-all) apps_set_all "$@" ;;
    status) apps_status ;;
    *)
      json_error usage '{"detail":"apps list|set|set-all|status"}'
      return 1
      ;;
  esac
}
