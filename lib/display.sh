#!/bin/bash

# display.sh — module: Hyprland, the eGPU's monitors and the toggle file.
# plan-engine.md §7.1–7.3 and §11, with the 2026-10-10 decisions in scope.md
# (display.policy, what the toggle file contains).
#
#   omarchy-egpu display list                        {policy, primary, monitors[], persisted[]}
#   omarchy-egpu display enable|disable <monitor>    live through hyprctl eval, then persisted
#   omarchy-egpu display set <monitor> <json>        {mode, position, scale, mirror, vrr}
#   omarchy-egpu display off                         every eGPU monitor off now (< 1 s), persisted
#   omarchy-egpu display move-workspaces <monitor>   its workspaces to the primary panel
#   omarchy-egpu display policy [get]                {policy, origin}
#   omarchy-egpu display policy set igpu|egpu-hdmi   config + toggle file; takes effect at login
#   omarchy-egpu display render                      the toggle file as it should be, on stdout
#   omarchy-egpu display apply                       write it if it differs, reload, validate
#
# <monitor> is a description ("desc:" optional), a Hyprland monitor name or a
# connector. Only monitors on the eGPU qualify. hyprctl has no GPU field, so
# they are matched to the eGPU card's connectors by name, and by EDID where a
# connector name exists on two GPUs (§7.1).
#
# Policies (display.policy, default igpu):
#   igpu       Monitors go on the laptop's own ports; the eGPU is for offload
#              only. AQ_DRM_DEVICES, when the udev links exist, lists the primary
#              alone, so the compositor never opens the eGPU.
#   egpu-hdmi  The eGPU's own outputs, driven by Hyprland. Needs the eGPU at
#              login (E1b); a mid-session plug-in sets status.display.needs_relogin.
#              AQ_DRM_DEVICES lists the primary, then the eGPU when its link
#              exists at login. A monitor seen on the eGPU gets a rule: extend at
#              display.position, vrr = display.vrr (§11.5).
#
# The toggle file ${XDG_STATE_HOME:-~/.local/state}/omarchy/toggles/hypr/zz-omarchy-egpu.lua
# is written by _dsp_commit and nowhere else. It is rendered from the primary
# and eGPU backends (be_primary_session, be_session_needs, ...), config and
# $EGPU_STATE/display.json (per-monitor settings), written atomically after a
# backup to $EGPU_STATE/backups/toggle/ (newest 20 kept). After a write the
# engine runs `hyprctl reload` and `hyprctl configerrors`; an error that was
# not there before puts the previous file and display.json back (§7.2).
#
# Errors beyond §1.1's display codes (unsafe_name, hdmi_still_active):
# no_compositor, monitor_not_found, invalid_value, config_errors,
# config_invalid, enable_failed, move_failed, write_failed, backup_failed;
# busy (exit 3).

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

DSP_TOGGLE="${EGPU_TOGGLE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr/zz-omarchy-egpu.lua}"
DSP_STATEFILE="$EGPU_STATE/display.json"
DSP_BACKUPS="$EGPU_STATE/backups/toggle"
DSP_KEEP_BACKUPS=20
DSP_POLICIES=(igpu egpu-hdmi)
# The udev links of §10.3 (system half). Paths as Hyprland sees them; tested
# under $EGPU_DEV.
DSP_LINK_PRIMARY=/dev/dri/omarchy-egpu-primary
DSP_LINK_EXTERNAL=/dev/dri/omarchy-egpu-external
# Names and descriptions that may go into Lua or hyprctl eval (§7.1, as
# omarchy-hyprland-monitor-clamshell refuses others).
DSP_SAFE_RE='^[A-Za-z0-9 ._()/+-]+$'
# Values that may go into hl.env / hl.config: driver names and paths.
DSP_VALUE_RE='^[A-Za-z0-9_./:-]+$'
DSP_WAIT_MS=3000

# ---------------------------------------------------------------- backends

# Display roles beyond the §4.2 table. backend_load does not know them, so
# they are unset before each load: one backend's must never answer for the next.
_DSP_ROLE_FNS=(be_primary_match be_primary_session be_session_needs be_session_note be_hypr_config)
_dsp_backend_load() {
  unset -f "${_DSP_ROLE_FNS[@]}"
  backend_load "$1"
}

# For be_primary_session: is this VA-API driver (iHD, radeonsi, ...) installed?
va_driver_installed() {
  [[ -e $EGPU_USRLIB/dri/$1_drv_video.so ]] || compgen -G "$EGPU_USRLIB/*/dri/$1_drv_video.so" >/dev/null
}

# The eGPU's backend: the attached card's, else the `backend` config key, else
# the first implemented one. The file is parsed at every login, so it must be
# right for a login with the card attached even when it is not attached now.
_dsp_secondary_backend() {
  local bdf want b
  bdf=$(pci_egpu_candidates | head -n1)
  if [[ -n $bdf ]] && backend_select "$bdf"; then
    printf '%s\n' "$EGPU_BACKEND"
    return
  fi
  want=$(config_str backend auto)
  if [[ $want != auto ]]; then
    backend_load "$want" && printf '%s\n' "$want"
    return
  fi
  for b in "${EGPU_BACKENDS[@]}"; do
    backend_load "$b" && [[ $BE_STATUS == implemented ]] && { printf '%s\n' "$b"; return; }
  done
}

# ---------------------------------------------------------------- config

_dsp_policy_valid() {
  local p
  for p in "${DSP_POLICIES[@]}"; do [[ $1 == "$p" ]] && return 0; done
  return 1
}

# The effective policy (an invalid value in the file reads as the default).
_dsp_policy() {
  local p
  p=$(config_str display.policy igpu)
  _dsp_policy_valid "$p" || p=igpu
  printf '%s\n' "$p"
}

# _dsp_config_set <dotted key> <json>: the one key changed in config.json,
# atomically; every other key kept as it is. A literal dotted key wins, as in
# config_get.
_dsp_config_set() {
  local cur='{}'
  if [[ -e $EGPU_CONFIG ]]; then
    cur=$(jq -c 'if type == "object" then . else error("not an object") end' "$EGPU_CONFIG" 2>/dev/null) || {
      json_error config_invalid "$(jq -cn --arg f "$EGPU_CONFIG" '{file: $f, detail: "config.json is not a JSON object; nothing was changed"}')"
      return 1
    }
  fi
  jq --arg k "$1" --argjson v "$2" 'if has($k) then .[$k] = $v else setpath($k | split("."); $v) end' <<<"$cur" |
    write_atomic "$EGPU_CONFIG" || { json_error write_failed '{"detail":"config.json"}'; return 1; }
}

# ---------------------------------------------------------------- state

# display.json: {"monitors": {"<description>": {enabled, mode, position, at,
# scale, mirror, mirror_of, vrr}}}. `position` is what the user chose
# (left|right|above|below|x,y), `at` the Hyprland position computed from it.
_dsp_state() {
  jq -c 'if type == "object" then {monitors: (.monitors // {})} else error("bad") end' "$DSP_STATEFILE" 2>/dev/null ||
    echo '{"monitors":{}}'
}

# ---------------------------------------------------------------- model

# _dsp_model: everything the toggle file depends on, in DSP_* globals.
_dsp_model() {
  local b k v n
  DSP_POLICY=$(_dsp_policy)
  DSP_VRR=$(config_get display.vrr false)
  DSP_NOEXPLICIT=$(config_get display.mgpu_no_explicit false)
  DSP_POSITION=$(config_str display.position right)

  # The primary GPU's session values (label, glx, va, egl, qt_decode, decode_label).
  DSP_P_BDF=$(pci_primary)
  declare -gA DSP_P=()
  if [[ -n $DSP_P_BDF ]]; then
    for b in "${EGPU_BACKENDS[@]}"; do
      _dsp_backend_load "$b" || continue
      declare -F be_primary_match >/dev/null && be_primary_match "$DSP_P_BDF" || continue
      while IFS='=' read -r k v; do
        [[ -n $k ]] && DSP_P[$k]=$v
      done < <(be_primary_session 2>/dev/null)
      break
    done
  fi

  # What the eGPU's backend needs from the session, with its notes.
  DSP_S_BACKEND=$(_dsp_secondary_backend)
  DSP_S_NEEDS=()
  DSP_S_CONFIG=()
  declare -gA DSP_S_NOTES=()
  if [[ -n $DSP_S_BACKEND ]] && _dsp_backend_load "$DSP_S_BACKEND"; then
    declare -F be_session_needs >/dev/null && mapfile -t DSP_S_NEEDS < <(be_session_needs 2>/dev/null)
    declare -F be_hypr_config >/dev/null && mapfile -t DSP_S_CONFIG < <(be_hypr_config 2>/dev/null)
    if declare -F be_session_note >/dev/null; then
      for n in header "${DSP_S_NEEDS[@]}"; do
        DSP_S_NOTES[$n]=$(be_session_note "$n" 2>/dev/null)
      done
    fi
  fi
}

# The session variables the toggle file sets (what hypr.session_env checks),
# as KEY=VALUE lines. Needs _dsp_model.
_dsp_session_env() {
  local need
  for need in "${DSP_S_NEEDS[@]}"; do
    case $need in
      glx_va)
        [[ -n ${DSP_P[glx]:-} ]] && echo "__GLX_VENDOR_LIBRARY_NAME=${DSP_P[glx]}"
        [[ -n ${DSP_P[va]:-} ]] && echo "LIBVA_DRIVER_NAME=${DSP_P[va]}"
        ;;
      egl_vendor) [[ -n ${DSP_P[egl]:-} ]] && echo "__EGL_VENDOR_LIBRARY_FILENAMES=${DSP_P[egl]}" ;;
      qt_decode) [[ -n ${DSP_P[qt_decode]:-} ]] && echo "QT_FFMPEG_DECODING_HW_DEVICE_TYPES=${DSP_P[qt_decode]}" ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------- render

_dsp_comment() {
  local l
  while IFS= read -r l; do printf -- '-- %s\n' "$l"; done <<<"$1"
}

_dsp_note() {
  local t=${DSP_S_NOTES[$1]:-}
  t=${t//@PRIMARY@/${DSP_P[label]:-the primary GPU}}
  t=${t//@DECODE@/${DSP_P[decode_label]:-decoder}}
  printf '%s' "$t"
}

_dsp_lua_env() {
  [[ -n $2 && $2 =~ $DSP_VALUE_RE ]] || return 0
  printf 'hl.env("%s", "%s")\n' "$1" "$2"
}

# a.b=v → hl.config({ a = { b = v } }). Numbers and booleans bare, else quoted.
_dsp_lua_config() {
  local key=${1%%=*} val=${1#*=} parts i
  [[ $key =~ ^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*$ ]] || return 0
  if [[ ! $val =~ ^(-?[0-9]+(\.[0-9]+)?|true|false)$ ]]; then
    [[ $val =~ $DSP_VALUE_RE ]] || return 0
    val="\"$val\""
  fi
  IFS=. read -r -a parts <<<"$key"
  for ((i = ${#parts[@]} - 1; i >= 0; i--)); do val="{ ${parts[i]} = $val }"; done
  printf 'hl.config(%s)\n' "$val"
}

_dsp_need_body() {
  local c
  case $1 in
    glx_va)
      _dsp_lua_env __GLX_VENDOR_LIBRARY_NAME "${DSP_P[glx]:-}"
      _dsp_lua_env LIBVA_DRIVER_NAME "${DSP_P[va]:-}"
      ;;
    hypr_config) for c in "${DSP_S_CONFIG[@]}"; do _dsp_lua_config "$c"; done ;;
    egl_vendor) _dsp_lua_env __EGL_VENDOR_LIBRARY_FILENAMES "${DSP_P[egl]:-}" ;;
    qt_decode) _dsp_lua_env QT_FFMPEG_DECODING_HW_DEVICE_TYPES "${DSP_P[qt_decode]:-}" ;;
  esac
}

# The Lua of one monitor rule, from a display.json entry. Shared by the
# toggle file and hyprctl eval, so what is applied live is what persists.
# shellcheck disable=SC2016  # jq program
DSP_JQ_RULE='
  def safe: type == "string" and test($safe);
  def rule($d; $m; $vrr):
    if ($m.enabled == false) then "hl.monitor({ output = \"desc:\($d)\", disabled = true })"
    else
      (if ($m.mode | type == "string") and ($m.mode | test("^([0-9]+x[0-9]+(@[0-9]+(\\.[0-9]+)?)?|preferred|highres|highrr)$"))
       then $m.mode else "preferred" end) as $mode
      | (if ($m.at | type == "string") and ($m.at | test("^-?[0-9]+x-?[0-9]+$")) then $m.at else "auto" end) as $at
      | (if ($m.scale | type == "number") and $m.scale > 0 then ($m.scale | tostring) else "\"auto\"" end) as $scale
      | "hl.monitor({ output = \"desc:\($d)\", mode = \"\($mode)\", position = \"\($at)\", scale = \($scale), vrr = \(if ($m.vrr // $vrr) == true then 1 else 0 end)"
        + (if $m.mirror == true and ($m.mirror_of | safe) then ", mirror = \"\($m.mirror_of)\"" else "" end)
        + " })"
    end;'

_dsp_render_rules() {
  _dsp_state | jq -r --arg safe "$DSP_SAFE_RE" --argjson vrr "$DSP_VRR" "$DSP_JQ_RULE"'
    .monitors | to_entries | sort_by(.key)[] | select(.key | safe) | rule(.key; .value; $vrr)'
}

# _dsp_render: the toggle file on stdout. Needs _dsp_model.
#
# Layout: the managed line and the eGPU backend's header note, then one block
# per need, each after a blank line with its note (the first block follows the
# header, which is its note). Then, only when they apply: the GPU order
# (AQ_DRM_DEVICES, when the udev links exist), the eGPU monitor rules, and
# AQ_MGPU_NO_EXPLICIT. For this laptop with the igpu policy and no links that
# is byte for byte the hand-written file of 2026-10-10 (tests/fixtures/display).
_dsp_render() {
  local need body note n=0 rules
  echo "-- Managed by omarchy-egpu. Delete this file to undo."
  [[ -n ${DSP_S_NOTES[header]:-} ]] && _dsp_comment "$(_dsp_note header)"
  for need in "${DSP_S_NEEDS[@]}"; do
    body=$(_dsp_need_body "$need")
    [[ -n $body ]] || continue
    (( n++ )) && echo
    note=$(_dsp_note "$need")
    [[ -n $note && $need != glx_va ]] && _dsp_comment "$note"
    printf '%s\n' "$body"
  done

  if [[ -e $EGPU_DEV${DSP_LINK_PRIMARY#/dev} || -L $EGPU_DEV${DSP_LINK_PRIMARY#/dev} ]]; then
    echo
    _dsp_comment "GPU order, read by the compositor once at login. The links come from the system
half's udev rule; cardN numbers change with hotplug, and by-path names contain colons."
    if [[ $DSP_POLICY == egpu-hdmi ]]; then
      _dsp_comment "Policy egpu-hdmi: the laptop GPU first, then the eGPU when it is attached at login."
    else
      _dsp_comment "Policy igpu: the laptop GPU only, so the compositor never opens the eGPU."
    fi
    cat <<EOF
do
  local function present(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
  end
  if present("$DSP_LINK_PRIMARY") then
EOF
    if [[ $DSP_POLICY == egpu-hdmi ]]; then
      cat <<EOF
    local devices = "$DSP_LINK_PRIMARY"
    if present("$DSP_LINK_EXTERNAL") then
      devices = devices .. ":$DSP_LINK_EXTERNAL"
    end
    hl.env("AQ_DRM_DEVICES", devices)
EOF
    else
      echo "    hl.env(\"AQ_DRM_DEVICES\", \"$DSP_LINK_PRIMARY\")"
    fi
    printf '  end\nend\n'
  fi

  rules=$(_dsp_render_rules)
  if [[ -n $rules ]]; then
    echo
    _dsp_comment "Monitors on the eGPU, set with \`omarchy-egpu display\`. Keyed by description,
because connector names can repeat across GPUs."
    printf '%s\n' "$rules"
  fi

  if [[ $DSP_NOEXPLICIT == true ]]; then
    echo
    _dsp_comment "display.mgpu_no_explicit: no explicit sync between the GPUs, a workaround for
artifacts on the eGPU's monitors (plan-engine.md §11.4). Read at login."
    echo 'hl.env("AQ_MGPU_NO_EXPLICIT", "1")'
  fi
}

# ---------------------------------------------------------------- write

_dsp_utc() { date -u +%Y%m%dT%H%M%S.%3NZ; }

_dsp_prune_backups() {
  local old f
  mapfile -t old < <(find "$DSP_BACKUPS" -maxdepth 1 -name 'zz-omarchy-egpu-*.lua' -printf '%f\n' 2>/dev/null |
    sort | head -n -"$DSP_KEEP_BACKUPS")
  for f in "${old[@]}"; do rm -f -- "${DSP_BACKUPS:?}/$f"; done
}

# Hyprland's config errors as a JSON array of non-empty strings. `-j` prints
# [""] when there are none (Hyprland 0.56.2).
_dsp_configerrors() {
  local out
  out=$(timeout 3 hyprctl -j configerrors 2>/dev/null)
  if jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    jq -c 'map(select(type == "string" and length > 0))' <<<"$out"
  else
    printf '%s\n' "$out" | jq -R -s -c 'split("\n") | map(select(length > 0))'
  fi
}

# _dsp_commit [--no-reload]: render the toggle file and put it in place. The
# only code that writes it. Prints a JSON result. With Hyprland running (and
# without --no-reload) it reloads and checks configerrors; errors that were
# not there before the write put the previous file back (or remove a new one)
# and reload again: exit 1 with config_errors.
_dsp_commit() {
  local reload=1 tmp prev='' backup='' before='[]' after new_errs relogin=true reloaded=false
  [[ ${1:-} == --no-reload ]] && reload=0
  mkdir -p -- "$EGPU_RUN" || { json_error write_failed '{"detail":"runtime dir"}'; return 1; }
  tmp=$(mktemp "$EGPU_RUN/.toggle.XXXXXX") || { json_error write_failed '{"detail":"temp file"}'; return 1; }
  _dsp_model
  _dsp_render >"$tmp"
  if [[ -f $DSP_TOGGLE ]] && cmp -s -- "$tmp" "$DSP_TOGGLE"; then
    rm -f -- "$tmp"
    jq -cn --arg f "$DSP_TOGGLE" --arg p "$DSP_POLICY" '{changed: false, file: $f, policy: $p, backup: null, reloaded: false, relogin_required: false}'
    return 0
  fi
  if [[ -f $DSP_TOGGLE ]]; then
    prev=$(mktemp "$EGPU_RUN/.toggle-prev.XXXXXX") && cp -- "$DSP_TOGGLE" "$prev" || {
      rm -f -- "$tmp" "$prev"
      json_error backup_failed "$(jq -cn --arg f "$DSP_TOGGLE" '{file: $f}')"
      return 1
    }
    backup="$DSP_BACKUPS/zz-omarchy-egpu-$(_dsp_utc).lua"
    if ! { mkdir -p -- "$DSP_BACKUPS" && cp -- "$DSP_TOGGLE" "$backup"; }; then
      rm -f -- "$tmp" "$prev"
      json_error backup_failed "$(jq -cn --arg b "$backup" '{backup: $b}')"
      return 1
    fi
    _dsp_prune_backups
    # Monitor rules apply on reload; anything else (env, GPU order) only in
    # the next session.
    cmp -s <(grep -v '^hl\.monitor(' "$prev") <(grep -v '^hl\.monitor(' "$tmp") && relogin=false
  fi
  (( reload )) && _dsp_hypr_up || reload=0
  (( reload )) && before=$(_dsp_configerrors)
  if ! write_atomic "$DSP_TOGGLE" <"$tmp"; then
    rm -f -- "$tmp" "$prev"
    json_error write_failed "$(jq -cn --arg f "$DSP_TOGGLE" '{file: $f}')"
    return 1
  fi
  chmod 644 -- "$DSP_TOGGLE" 2>/dev/null
  rm -f -- "$tmp"
  if (( reload )); then
    timeout 5 hyprctl reload >/dev/null 2>&1
    reloaded=true
    after=$(_dsp_configerrors)
    new_errs=$(jq -cn --argjson a "$after" --argjson b "$before" '$a - $b')
    if [[ $new_errs != '[]' ]]; then
      if [[ -n $prev ]]; then
        write_atomic "$DSP_TOGGLE" <"$prev" && chmod 644 -- "$DSP_TOGGLE" 2>/dev/null
      else
        rm -f -- "$DSP_TOGGLE"
      fi
      rm -f -- "$prev"
      timeout 5 hyprctl reload >/dev/null 2>&1
      json_error config_errors "$(jq -cn --argjson e "$new_errs" --arg f "$DSP_TOGGLE" --arg b "$backup" \
        '{errors: $e, file: $f, restored: true, backup: (if $b == "" then null else $b end)}')"
      return 1
    fi
  fi
  rm -f -- "$prev"
  jq -cn --arg f "$DSP_TOGGLE" --arg p "$DSP_POLICY" --arg b "$backup" --argjson r "$reloaded" --argjson rl "$relogin" \
    '{changed: true, file: $f, policy: $p, backup: (if $b == "" then null else $b end), reloaded: $r, relogin_required: $rl}'
}

# _dsp_persist <state json> [--no-reload]: display.json, then the toggle file.
# When the toggle file is refused, display.json goes back too.
_dsp_persist() {
  local new=$1 prev_state='' had=0 out rc
  [[ -f $DSP_STATEFILE ]] && { prev_state=$(cat -- "$DSP_STATEFILE"); had=1; }
  if ! jq -c . <<<"$new" | write_atomic "$DSP_STATEFILE"; then
    json_error write_failed "$(jq -cn --arg f "$DSP_STATEFILE" '{file: $f}')"
    return 1
  fi
  out=$(_dsp_commit "${2:-}")
  rc=$?
  if (( rc != 0 )); then
    if (( had )); then printf '%s\n' "$prev_state" | write_atomic "$DSP_STATEFILE"; else rm -f -- "$DSP_STATEFILE"; fi
  fi
  printf '%s\n' "$out"
  return "$rc"
}

# One display job at a time (separate from device.sh's lock, so eject can run
# `display off` while it holds its own).
_dsp_lock() {
  mkdir -p -- "$EGPU_RUN" 2>/dev/null
  exec {DSP_LOCK_FD}>"$EGPU_RUN/display.lock" || return 1
  flock -w "${EGPU_DISPLAY_LOCK_WAIT:-2}" "$DSP_LOCK_FD"
}

_dsp_busy() { json_error busy '{"detail":"another display change is running"}'; return 3; }

# ---------------------------------------------------------------- Hyprland

_dsp_hypr_up() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null 2>&1 && [[ -n $(compositor_pid) ]]
}

_dsp_monitors() {
  local out
  out=$(timeout 3 hyprctl monitors all -j 2>/dev/null) || return 1
  jq -c 'if type == "array" then . else error("not an array") end' <<<"$out" 2>/dev/null
}

_dsp_workspaces() {
  local out
  out=$(timeout 3 hyprctl workspaces -j 2>/dev/null)
  jq -c 'if type == "array" then . else error("x") end' <<<"$out" 2>/dev/null || echo '[]'
}

_dsp_eval() { timeout 3 hyprctl eval "$1" >/dev/null 2>&1; }
_dsp_dispatch() { timeout 3 hyprctl dispatch "$1" >/dev/null 2>&1; }

# _dsp_wait <timeout ms> <jq predicate over the monitor list> [jq args...]
_dsp_wait() {
  local deadline=$(( $(now_ms) + $1 )) pred=$2 mons
  shift 2
  while :; do
    mons=$(_dsp_monitors) && jq -e "$@" "$pred" <<<"$mons" >/dev/null 2>&1 && return 0
    (( $(now_ms) >= deadline )) && return 1
    sleep 0.05
  done
}

# EDID → "model<TAB>serial" as Hyprland (libdisplay-info) reports them: the
# monitor-name descriptor or the product code as 0x%04X; the serial descriptor
# or the serial number as 0x%08X (empty when 0).
# shellcheck disable=SC2016
DSP_EDID_PY='
import sys
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
if len(d) < 128 or d[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
    sys.exit(1)
prod = d[10] | d[11] << 8
num = d[12] | d[13] << 8 | d[14] << 16 | d[15] << 24
name = sname = ""
for o in (54, 72, 90, 108):
    b = d[o:o + 18]
    if b[0] == 0 and b[1] == 0 and b[3] in (0xFC, 0xFF):
        t = b[5:18].split(b"\n")[0].decode("cp437").strip()
        if b[3] == 0xFC:
            name = t
        else:
            sname = t
print((name or "0x%04X" % prod) + "\t" + (sname or ("0x%08X" % num if num else "")))
'

# _dsp_egpu_match <monitors json>: {card, monitors: [eGPU monitors + connector,
# matched_by], ambiguous: [names]}. A monitor is the eGPU's when its name is a
# connected connector on the eGPU card that no other GPU has, or when its
# make/serial match exactly one connected eGPU connector's EDID. A name on
# both GPUs that EDID cannot settle is ambiguous and never treated as the
# eGPU's (§7.1: Hyprland's handling of the collision is unverified).
_dsp_egpu_match() {
  local mons=$1 bdf card='' d c n others='' rows=() names st edid ids
  bdf=$(pci_egpu_candidates | head -n1)
  [[ -n $bdf ]] && card=$(pci_drm_card "$bdf")
  if [[ -z $card || ! -d $EGPU_PCI/$bdf/drm/$card ]]; then
    echo '{"card":null,"monitors":[],"ambiguous":[]}'
    return 0
  fi
  for d in "$EGPU_PCI"/*/drm/card[0-9]*; do
    [[ -d $d && $d != "$EGPU_PCI/$bdf/"* ]] || continue
    for c in "$d/${d##*/}"-*; do
      [[ -e $c ]] || continue
      n=${c##*/}
      others+="${n#"${d##*/}"-}"$'\n'
    done
  done
  names=$(jq -r '.[].name' <<<"$mons")
  for c in "$EGPU_PCI/$bdf/drm/$card/$card"-*; do
    [[ -r $c/status ]] || continue
    n=${c##*/}
    n=${n#"$card"-}
    st=$(read_attr "$c/status")
    edid=''
    # EDID only where the name cannot decide: it collides, or Hyprland lists
    # no monitor by that name. Keeps `display off` fast in the normal case.
    if [[ $st == connected ]] && { grep -qxF -- "$n" <<<"$others" || ! grep -qxF -- "$n" <<<"$names"; }; then
      ids=$(python3 -c "$DSP_EDID_PY" "$c/edid" 2>/dev/null) && edid=$ids
    fi
    rows+=("$(jq -cn --arg c "$n" --arg s "$st" --arg e "$edid" --argjson col "$(grep -qxF -- "$n" <<<"$others" && echo true || echo false)" '
      {connector: $c, status: $s, collides: $col,
       edid: (if $e == "" then null else ($e | split("\t") | {model: .[0], serial: .[1]}) end)}')")
  done
  printf '%s\n' "${rows[@]}" | jq -s -c --arg card "$card" --argjson m "$mons" '
    . as $conns
    | [$m[] as $mon
       | ([$conns[] | select(.status == "connected" and .connector == $mon.name and (.collides | not))][0]) as $byname
       | ([$conns[] | select(.status == "connected" and .edid != null and .edid.model != ""
                             and .edid.model == $mon.model and .edid.serial == $mon.serial)][0]) as $byedid
       | ([$m[] | select(.model == $mon.model and .serial == $mon.serial)] | length) as $same
       | if $byname then $mon + {connector: $byname.connector, matched_by: "name"}
         elif $byedid and $same == 1 then $mon + {connector: $byedid.connector, matched_by: "edid"}
         else empty end] as $eg
    | {card: $card, monitors: $eg,
       ambiguous: [$m[] | select(.name as $n | [$conns[] | select(.status == "connected" and .collides and .connector == $n)] | length > 0)
                   | select(.description as $d | [$eg[] | select(.description == $d)] | length == 0) | .name]}'
}

# _dsp_primary <monitors json> <egpu monitors json>: the primary panel, the
# laptop's own (eDP/LVDS/DSI) if enabled, else the first enabled monitor not
# on the eGPU; with its logical size (lw, lh) for positions (§7.3).
_dsp_primary() {
  jq -c --argjson eg "$2" '
    ($eg | map(.description)) as $egd
    | [.[] | select((.disabled | not) and (.description as $d | $egd | index($d) | not))] as $c
    | ([$c[] | select(.name | test("^(eDP|LVDS|DSI)-"))][0] // $c[0] // null)
    | if . == null then null else
        (if .scale > 0 then .scale else 1 end) as $s
        | ((.width / $s) | round) as $w | ((.height / $s) | round) as $h
        | {name, description, x, y, scale,
           lw: (if (.transform % 2) == 1 then $h else $w end),
           lh: (if (.transform % 2) == 1 then $w else $h end)} end' <<<"$1"
}

# shellcheck disable=SC2016
DSP_JQ_GEOM='
  # Mode "WxH@R" → [W, H]; preferred/highres/highrr → the current size.
  def msize($mon; $mode):
    if ($mode | type == "string") and ($mode | test("^[0-9]+x[0-9]+")) then
      ($mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)") | [(.w | tonumber), (.h | tonumber)])
    else [$mon.width, $mon.height] end;
  # The Hyprland position ("XxY") of a monitor next to the primary panel.
  def at($p; $mon; $m):
    msize($mon; $m.mode) as $sz
    | (if ($m.scale | type == "number") and $m.scale > 0 then $m.scale
       elif ($mon.scale // 0) > 0 then $mon.scale else 1 end) as $s
    | (($sz[0] / $s) | round) as $tw | (($sz[1] / $s) | round) as $th
    | ($m.position // "right") as $pos
    | if $p == null then "auto"
      elif $pos == "right" then "\($p.x + $p.lw)x\($p.y)"
      elif $pos == "left" then "\($p.x - $tw)x\($p.y)"
      elif $pos == "above" then "\($p.x)x\($p.y - $th)"
      elif $pos == "below" then "\($p.x)x\($p.y + $p.lh)"
      elif ($pos | test("^-?[0-9]+,-?[0-9]+$")) then ($pos | split(",") | "\(.[0])x\(.[1])")
      else "auto" end;
  def modestr: (.refreshRate * 100 | round) as $r
    | "\(.width)x\(.height)@\($r / 100 | floor).\($r % 100 | tostring | if length == 1 then "0" + . else . end)";'

# _dsp_entry <monitor json> <primary json> <state entry or null> <overrides json>:
# the display.json entry to apply, with `at` recomputed from `position` (the
# primary may have changed since).
_dsp_entry() {
  jq -cn --argjson mon "$1" --argjson p "$2" --argjson cur "$3" --argjson o "$4" \
    --arg pos "$DSP_POSITION" --argjson vrr "$DSP_VRR" "$DSP_JQ_GEOM"'
    ({enabled: true, mode: "preferred", position: $pos,
      scale: (if ($mon.scale // 0) > 0 then $mon.scale else "auto" end),
      mirror: false, vrr: $vrr} + ($cur // {}) + $o) as $m
    | $m + {at: at($p; $mon; $m),
            mirror_of: (if $m.mirror == true and $p != null then $p.name else null end)}'
}

# _dsp_rule <description> <entry json>: the hl.monitor Lua for hyprctl eval.
_dsp_rule() {
  jq -rn --arg safe "$DSP_SAFE_RE" --arg d "$1" --argjson m "$2" --argjson vrr "$DSP_VRR" \
    "$DSP_JQ_RULE"'rule($d; $m; $vrr)'
}

# _dsp_ws_on <workspaces json> <monitor json>: ids of its regular workspaces,
# by monitor id (two monitors can share a name, §7.1).
_dsp_ws_on() {
  jq -r --argjson mon "$2" '.[] | select(.id > 0 and (if has("monitorID") then .monitorID == $mon.id else .monitor == $mon.name end)) | .id' <<<"$1"
}

# _dsp_move_ws <monitor json> <primary name>: move its workspaces to the
# primary. hl.dsp.workspace.move with a workspace id is tried first; whether
# Hyprland honours the id is unverified (§7.3), so any that did not move are
# focused and moved as the active workspace. Prints {moved, failed, method}.
_dsp_move_ws() {
  local mon=$1 to=$2 ws ids=() id left=() method=direct
  [[ $to =~ $DSP_SAFE_RE ]] || { echo '{"moved":[],"failed":[],"method":null,"error":"unsafe_name"}'; return 1; }
  ws=$(_dsp_workspaces)
  mapfile -t ids < <(_dsp_ws_on "$ws" "$mon")
  if (( ${#ids[@]} == 0 )); then echo '{"moved":[],"failed":[],"method":null}'; return 0; fi
  for id in "${ids[@]}"; do
    [[ $id =~ ^[0-9]+$ ]] || continue
    _dsp_dispatch "hl.dsp.workspace.move({ workspace = \"$id\", monitor = \"$to\" })"
  done
  ws=$(_dsp_workspaces)
  mapfile -t left < <(_dsp_ws_on "$ws" "$mon")
  if (( ${#left[@]} )); then
    method=focus
    for id in "${left[@]}"; do
      [[ $id =~ ^[0-9]+$ ]] || continue
      _dsp_dispatch "hl.dsp.focus({ workspace = \"$id\" })"
      _dsp_dispatch "hl.dsp.workspace.move({ monitor = \"$to\" })"
    done
    ws=$(_dsp_workspaces)
    mapfile -t left < <(_dsp_ws_on "$ws" "$mon")
  fi
  jq -cn --arg m "$method" --arg all "${ids[*]}" --arg left "${left[*]:-}" '
    ($all | split(" ") | map(select(length > 0) | tonumber)) as $a
    | ($left | split(" ") | map(select(length > 0) | tonumber)) as $l
    | {moved: ($a - $l), failed: $l, method: $m}'
  (( ${#left[@]} == 0 ))
}

# _dsp_arg <arg>: true when the description or name (without "desc:") is safe.
_dsp_arg() {
  local a=${1#desc:}
  [[ -n $a && $a =~ $DSP_SAFE_RE ]]
}

_dsp_find() {
  jq -c --arg a "$2" '($a | ltrimstr("desc:")) as $d
    | ([.[] | select(.description == $d)] + [.[] | select(.name == $a or .connector == $a)]) | .[0] // empty' <<<"$1"
}

# ---------------------------------------------------------------- verbs

display_list() {
  local policy state mons match ws primary
  policy=$(_dsp_policy)
  state=$(_dsp_state)
  if ! _dsp_hypr_up || ! mons=$(_dsp_monitors); then
    jq -cn --arg p "$policy" --argjson s "$state" \
      '{policy: $p, compositor: false, primary: null, monitors: [], ambiguous: [],
        persisted: ($s.monitors | to_entries | map({description: .key} + .value))}'
    return 0
  fi
  match=$(_dsp_egpu_match "$mons")
  ws=$(_dsp_workspaces)
  primary=$(_dsp_primary "$mons" "$(jq -c .monitors <<<"$match")")
  jq -cn --arg p "$policy" --argjson s "$state" --argjson match "$match" --argjson ws "$ws" \
    --argjson primary "$primary" "$DSP_JQ_GEOM"'
    {policy: $p, compositor: true,
     primary: (if $primary == null then null else $primary | {name, description} end),
     card: $match.card,
     monitors: [$match.monitors[] as $m
       | {name: $m.name, description: $m.description, connector: $m.connector, card: $match.card,
          matched_by: $m.matched_by, enabled: ($m.disabled | not),
          mode: (if ($m.disabled | not) then ($m | modestr) else null end),
          modes: (($m.availableModes // []) | map(sub("Hz$"; "")) | unique),
          position: {x: $m.x, y: $m.y}, scale: $m.scale, vrr: $m.vrr,
          mirror_of: (if ($m.mirrorOf // "none") == "none" then null else $m.mirrorOf end),
          workspaces: [$ws[] | select(.id > 0 and (if has("monitorID") then .monitorID == $m.id else .monitor == $m.name end)) | {id, name}],
          rule: ($s.monitors[$m.description] // null)}],
     ambiguous: $match.ambiguous,
     persisted: ($s.monitors | to_entries | map({description: .key} + .value))}'
}

# The eGPU monitors and the primary, or an error document. Sets D_MONS,
# D_MATCH, D_EG, D_PRIMARY.
_dsp_live() {
  if ! _dsp_hypr_up || ! D_MONS=$(_dsp_monitors); then
    json_error no_compositor '{"detail":"Hyprland is not running or hyprctl does not answer"}'
    return 1
  fi
  D_MATCH=$(_dsp_egpu_match "$D_MONS")
  D_EG=$(jq -c .monitors <<<"$D_MATCH")
  D_PRIMARY=$(_dsp_primary "$D_MONS" "$D_EG")
}

display_enable_disable() {
  local verb=$1 arg=${2:-} state cur mon desc entry rule moved='null' out rc
  if [[ -z $arg ]]; then
    json_error usage "$(jq -cn --arg v "$verb" '{detail: "display \($v) <monitor>"}')"
    return 1
  fi
  _dsp_arg "$arg" || { json_error unsafe_name "$(jq -cn --arg n "$arg" '{name: $n}')"; return 1; }
  _dsp_lock || { _dsp_busy; return 3; }
  _dsp_model
  state=$(_dsp_state)
  mon=''
  if _dsp_hypr_up && D_MONS=$(_dsp_monitors); then
    D_MATCH=$(_dsp_egpu_match "$D_MONS")
    D_EG=$(jq -c .monitors <<<"$D_MATCH")
    D_PRIMARY=$(_dsp_primary "$D_MONS" "$D_EG")
    mon=$(_dsp_find "$D_EG" "$arg")
  fi

  if [[ -z $mon ]]; then
    # Not on screen: only a remembered monitor can be switched, in the file.
    desc=${arg#desc:}
    cur=$(jq -c --arg d "$desc" '.monitors[$d] // empty' <<<"$state")
    if [[ -z $cur ]]; then
      json_error monitor_not_found "$(jq -cn --arg n "$arg" '{name: $n, detail: "no monitor by that name on the eGPU"}')"
      return 1
    fi
    state=$(jq -c --arg d "$desc" --argjson e "$([[ $verb == enable ]] && echo true || echo false)" \
      '.monitors[$d].enabled = $e' <<<"$state")
    out=$(_dsp_persist "$state")
    rc=$?
    (( rc == 0 )) || { printf '%s\n' "$out"; return "$rc"; }
    jq -cn --arg d "$desc" --argjson e "$([[ $verb == enable ]] && echo true || echo false)" --argjson f "$out" \
      '{monitor: {name: null, description: $d}, enabled: $e, live: false, toggle: $f}'
    return 0
  fi

  desc=$(jq -r .description <<<"$mon")
  [[ $desc =~ $DSP_SAFE_RE ]] || { json_error unsafe_name "$(jq -cn --arg n "$desc" '{name: $n}')"; return 1; }
  cur=$(jq -c --arg d "$desc" '.monitors[$d] // null' <<<"$state")
  if [[ $verb == disable ]]; then
    if [[ $D_PRIMARY != null ]]; then
      moved=$(_dsp_move_ws "$mon" "$(jq -r .name <<<"$D_PRIMARY")")
    fi
    _dsp_eval "hl.monitor({ output = \"desc:$desc\", disabled = true })"
    if ! _dsp_wait "$DSP_WAIT_MS" 'all(.[] | select(.description == $d); .disabled == true)' --arg d "$desc"; then
      json_error hdmi_still_active "$(jq -cn --arg d "$desc" '{monitors: [$d]}')"
      return 1
    fi
    entry=$(jq -c '(. // {}) + {enabled: false}' <<<"$cur")
  else
    entry=$(_dsp_entry "$mon" "$D_PRIMARY" "$cur" '{"enabled":true}')
    rule=$(_dsp_rule "$desc" "$entry")
    _dsp_eval "$rule"
    if ! _dsp_wait "$DSP_WAIT_MS" 'any(.[] | select(.description == $d); .disabled == false)' --arg d "$desc"; then
      json_error enable_failed "$(jq -cn --arg d "$desc" --arg r "$rule" '{monitor: $d, rule: $r}')"
      return 1
    fi
  fi
  state=$(jq -c --arg d "$desc" --argjson e "$entry" '.monitors[$d] = $e' <<<"$state")
  out=$(_dsp_persist "$state")
  rc=$?
  (( rc == 0 )) || { printf '%s\n' "$out"; return "$rc"; }
  jq -cn --argjson mon "$mon" --argjson e "$entry" --argjson moved "$moved" --argjson f "$out" \
    '{monitor: {name: $mon.name, description: $mon.description, connector: $mon.connector},
      enabled: ($e.enabled != false), live: true, workspaces: $moved, rule: $e, toggle: $f}'
}

display_set() {
  local arg=${1:-} json=${2:-} state mon desc cur o entry rule out rc
  if [[ -z $arg || -z $json ]]; then
    json_error usage '{"detail":"display set <monitor> {\"mode\":…, \"position\":\"left|right|above|below|x,y\", \"scale\":…, \"mirror\":bool, \"vrr\":bool}"}'
    return 1
  fi
  _dsp_arg "$arg" || { json_error unsafe_name "$(jq -cn --arg n "$arg" '{name: $n}')"; return 1; }
  _dsp_lock || { _dsp_busy; return 3; }
  _dsp_model
  _dsp_live || return 1
  mon=$(_dsp_find "$D_EG" "$arg")
  [[ -n $mon ]] || { json_error monitor_not_found "$(jq -cn --arg n "$arg" '{name: $n}')"; return 1; }
  desc=$(jq -r .description <<<"$mon")
  [[ $desc =~ $DSP_SAFE_RE ]] || { json_error unsafe_name "$(jq -cn --arg n "$desc" '{name: $n}')"; return 1; }

  # Validate and normalise: unknown keys, a mode the monitor does not list, a
  # position or scale outside the forms Hyprland takes.
  o=$(jq -c --argjson mon "$mon" '
    def fail($m): {error: $m};
    if type != "object" then fail("not a JSON object")
    elif (keys - ["mode", "position", "scale", "mirror", "vrr"]) != [] then fail("unknown key: \(keys - ["mode", "position", "scale", "mirror", "vrr"] | join(", "))")
    elif has("mode") and (.mode | type != "string") then fail("mode must be a string")
    elif has("mode") and (.mode | IN("preferred", "highres", "highrr") | not) and
      ((.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)(@(?<r>[0-9]+(\\.[0-9]+)?))?$")?) as $want
       | if $want == null then true
         else [($mon.availableModes // [])[] | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)")
               | select(.w == $want.w and .h == $want.h and
                        ($want.r == null or ((.r | tonumber) - ($want.r | tonumber) | fabs) < 0.05))] | length == 0 end)
      then fail("mode \(.mode) is not one the monitor lists")
    elif has("position") and ((.position | type == "string" and test("^(left|right|above|below|-?[0-9]+,-?[0-9]+)$")) | not)
      then fail("position must be left, right, above, below or x,y")
    elif has("scale") and (((.scale == "auto") or (.scale | type == "number" and . >= 0.25 and . <= 10)) | not)
      then fail("scale must be a number from 0.25 to 10, or \"auto\"")
    elif has("mirror") and (.mirror | type != "boolean") then fail("mirror must be true or false")
    elif has("vrr") and (.vrr | type != "boolean") then fail("vrr must be true or false")
    else
      (if has("mode") and (.mode | test("^[0-9]")) then
         (.mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)(@(?<r>[0-9.]+))?")) as $want
         | .mode = ([($mon.availableModes // [])[] | sub("Hz$"; "") | select(test("^\($want.w)x\($want.h)@"))
                     | select($want.r == null or ((capture("@(?<r>[0-9.]+)").r | tonumber) - ($want.r | tonumber) | fabs) < 0.05)][0])
       else . end)
    end' <<<"$json" 2>/dev/null) || { json_error invalid_value '{"detail":"not valid JSON"}'; return 1; }
  if jq -e 'has("error")' <<<"$o" >/dev/null; then
    json_error invalid_value "$(jq -c '{detail: .error}' <<<"$o")"
    return 1
  fi
  state=$(_dsp_state)
  cur=$(jq -c --arg d "$desc" '.monitors[$d] // null' <<<"$state")
  entry=$(_dsp_entry "$mon" "$D_PRIMARY" "$cur" "$(jq -c '. + {enabled: true}' <<<"$o")")
  if jq -e '.mirror == true and .mirror_of == null' <<<"$entry" >/dev/null; then
    json_error invalid_value '{"detail":"no primary monitor to mirror"}'
    return 1
  fi
  rule=$(_dsp_rule "$desc" "$entry")
  _dsp_eval "$rule"
  if ! _dsp_wait "$DSP_WAIT_MS" 'any(.[] | select(.description == $d); .disabled == false)' --arg d "$desc"; then
    json_error enable_failed "$(jq -cn --arg d "$desc" --arg r "$rule" '{monitor: $d, rule: $r}')"
    return 1
  fi
  state=$(jq -c --arg d "$desc" --argjson e "$entry" '.monitors[$d] = $e' <<<"$state")
  out=$(_dsp_persist "$state")
  rc=$?
  (( rc == 0 )) || { printf '%s\n' "$out"; return "$rc"; }
  jq -cn --argjson mon "$mon" --argjson e "$entry" --arg r "$rule" --argjson f "$out" \
    '{monitor: {name: $mon.name, description: $mon.description, connector: $mon.connector},
      rule: $e, lua: $r, toggle: $f}'
}

# The kill switch (§7.3, §11.6). One hyprctl eval per enabled eGPU monitor,
# no reload; Hyprland moves their workspaces itself. Then the file, without a
# reload, so the next reload or login keeps them off. elapsed_ms is the time
# until hyprctl showed them all disabled.
display_off() {
  local t0 targets n i mon desc name key keys=() offd=() unsafe=() state out rc=0 t_off err=''
  t0=$(now_ms)
  _dsp_lock || { _dsp_busy; return 3; }
  if ! _dsp_hypr_up || ! D_MONS=$(_dsp_monitors); then
    jq -cn '{disabled: [], compositor: false, elapsed_ms: 0, persisted: false}'
    return 0
  fi
  D_MATCH=$(_dsp_egpu_match "$D_MONS")
  targets=$(jq -c '[.monitors[] | select(.disabled | not)]' <<<"$D_MATCH")
  n=$(jq 'length' <<<"$targets")
  for ((i = 0; i < n; i++)); do
    mon=$(jq -c ".[$i]" <<<"$targets")
    desc=$(jq -r .description <<<"$mon")
    name=$(jq -r .name <<<"$mon")
    if [[ $desc =~ $DSP_SAFE_RE ]]; then
      key="desc:$desc"
    elif [[ $name =~ ^[A-Za-z0-9._-]+$ ]]; then
      key=$name
      unsafe+=("$name")
    else
      unsafe+=("$name")
      continue
    fi
    _dsp_eval "hl.monitor({ output = \"$key\", disabled = true })"
    keys+=("$desc")
    offd+=("$(jq -c '{name, description, connector}' <<<"$mon")")
  done
  if (( ${#keys[@]} )) &&
    ! _dsp_wait "$DSP_WAIT_MS" 'all(.[] | select(.description as $d | $want | index($d)); .disabled == true)' \
      --argjson want "$(printf '%s\n' "${keys[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"; then
    err=hdmi_still_active
  fi
  t_off=$(( $(now_ms) - t0 ))

  # Persist every eGPU monitor that is off now, including ones that were
  # already, so a reload does not bring them back.
  state=$(_dsp_state)
  state=$(jq -c --argjson eg "$(jq -c .monitors <<<"$D_MATCH")" --argjson keys "$(printf '%s\n' "${keys[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" --arg safe "$DSP_SAFE_RE" '
    reduce ($eg[] | select(.description | test($safe)) | select((.disabled == true) or (.description as $d | $keys | index($d))) | .description) as $d
      (.; .monitors[$d] = ((.monitors[$d] // {}) + {enabled: false}))' <<<"$state")
  out=$(_dsp_persist "$state" --no-reload)
  rc=$?
  local doc
  doc=$(jq -cn --argjson offd "$(printf '%s\n' "${offd[@]}" | jq -s -c '.')" \
    --argjson unsafe "$(printf '%s\n' "${unsafe[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson t "$t_off" --argjson total "$(( $(now_ms) - t0 ))" --argjson f "$out" --argjson ok "$([[ $rc == 0 ]] && echo true || echo false)" '
    {disabled: $offd, compositor: true, elapsed_ms: $t, total_ms: $total, persisted: $ok,
     not_persisted: $unsafe, toggle: $f}')
  if [[ -n $err ]]; then
    json_error "$err" "$doc"
    return 1
  fi
  printf '%s\n' "$doc"
  (( rc == 0 ))
}

display_move_workspaces() {
  local arg=${1:-} mon res
  [[ -n $arg ]] || { json_error usage '{"detail":"display move-workspaces <monitor>"}'; return 1; }
  _dsp_arg "$arg" || { json_error unsafe_name "$(jq -cn --arg n "$arg" '{name: $n}')"; return 1; }
  _dsp_lock || { _dsp_busy; return 3; }
  _dsp_live || return 1
  mon=$(_dsp_find "$D_EG" "$arg")
  [[ -n $mon ]] || { json_error monitor_not_found "$(jq -cn --arg n "$arg" '{name: $n}')"; return 1; }
  [[ $D_PRIMARY != null ]] || { json_error monitor_not_found '{"detail":"no primary monitor to move to"}'; return 1; }
  res=$(_dsp_move_ws "$mon" "$(jq -r .name <<<"$D_PRIMARY")")
  if jq -e '.failed | length > 0' <<<"$res" >/dev/null; then
    json_error move_failed "$(jq -c --argjson p "$D_PRIMARY" '. + {to: $p.name}' <<<"$res")"
    return 1
  fi
  jq -c --argjson p "$D_PRIMARY" '. + {to: $p.name}' <<<"$res"
}

# egpu-hdmi: eGPU monitors on screen that have no rule yet get the default
# one (extend at display.position). Prints the new state.
_dsp_record_present() {
  local state=$1 n i mon desc entry
  _dsp_live >/dev/null || { printf '%s\n' "$state"; return 0; }
  n=$(jq 'length' <<<"$D_EG")
  for ((i = 0; i < n; i++)); do
    mon=$(jq -c ".[$i]" <<<"$D_EG")
    desc=$(jq -r .description <<<"$mon")
    [[ $desc =~ $DSP_SAFE_RE ]] || continue
    jq -e --arg d "$desc" '.monitors | has($d)' <<<"$state" >/dev/null && continue
    entry=$(_dsp_entry "$mon" "$D_PRIMARY" null '{}')
    entry=$(jq -c --argjson on "$(jq '.disabled | not' <<<"$mon")" '.enabled = $on' <<<"$entry")
    state=$(jq -c --arg d "$desc" --argjson e "$entry" '.monitors[$d] = $e' <<<"$state")
  done
  printf '%s\n' "$state"
}

display_apply() {
  local state
  _dsp_lock || { _dsp_busy; return 3; }
  _dsp_model
  state=$(_dsp_state)
  if [[ $DSP_POLICY == egpu-hdmi ]]; then
    state=$(_dsp_record_present "$state")
    if [[ $state != "$(_dsp_state)" ]]; then
      _dsp_persist "$state"
      return
    fi
  fi
  _dsp_commit
}

display_policy() {
  local sub=${1:-get} want prev origin=default out rc state
  case $sub in
    get)
      [[ -r $EGPU_CONFIG ]] && jq -e 'has("display.policy") or (.display.policy? != null)' "$EGPU_CONFIG" >/dev/null 2>&1 && origin='file'
      jq -cn --arg p "$(_dsp_policy)" --arg o "$origin" --args '{policy: $p, origin: $o, policies: $ARGS.positional}' "${DSP_POLICIES[@]}"
      ;;
    set)
      want=${2:-}
      if ! _dsp_policy_valid "$want"; then
        json_error invalid_value "$(jq -cn --arg v "$want" --args '{detail: "policy must be one of \($ARGS.positional | join(", "))", got: $v}' "${DSP_POLICIES[@]}")"
        return 1
      fi
      _dsp_lock || { _dsp_busy; return 3; }
      prev=$(_dsp_policy)
      _dsp_config_set display.policy "$(jq -cn --arg v "$want" '$v')" || return 1
      _dsp_model
      state=$(_dsp_state)
      [[ $want == egpu-hdmi ]] && state=$(_dsp_record_present "$state")
      out=$(_dsp_persist "$state")
      rc=$?
      if (( rc != 0 )); then
        _dsp_config_set display.policy "$(jq -cn --arg v "$prev" '$v')" >/dev/null
        printf '%s\n' "$out"
        return "$rc"
      fi
      # The GPU order and the eGPU's outputs are fixed when the session starts.
      jq -cn --arg p "$want" --arg prev "$prev" --argjson f "$out" \
        '{policy: $p, previous: $prev, relogin_required: ($p != $prev), toggle: $f}'
      ;;
    *)
      json_error usage '{"detail":"display policy [get] | display policy set igpu|egpu-hdmi"}'
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------- health

# hypr.links (§10.3). Under igpu the links only pin the primary; missing
# links are information, not a warning.
display_health_links() {
  local policy primary pcard bdf ecard plink elink miss=warn
  policy=$(_dsp_policy)
  [[ $policy == igpu ]] && miss=info
  primary=$(pci_primary)
  pcard=$( [[ -n $primary ]] && pci_drm_card "$primary")
  plink="$EGPU_DEV${DSP_LINK_PRIMARY#/dev}"
  elink="$EGPU_DEV${DSP_LINK_EXTERNAL#/dev}"
  bdf=$(pci_egpu_candidates | head -n1)
  ecard=$( [[ -n $bdf ]] && pci_drm_card "$bdf")
  if [[ ! -L $plink && ! -e $plink ]]; then
    health_row hypr.links display "$miss" "GPU links are not installed" \
      "/dev/dri/omarchy-egpu-primary and -external pin the GPU order without cardN numbers (${primary:+primary is pci-$primary-card}). They come with the udev rule.$([[ $policy == igpu ]] && echo " Optional with the igpu policy: the laptop GPU is primary by itself.")" \
      system "$SYSTEM_FIX"
  elif [[ -n $pcard && $(readlink -- "$plink") != *"$pcard" ]]; then
    health_row hypr.links display error "omarchy-egpu-primary points at the wrong card" \
      "It points at $(readlink -- "$plink"); the primary (pci-$primary-card) is $pcard." system "$SYSTEM_FIX"
  elif [[ -n $ecard && ! -e $elink && ! -L $elink ]]; then
    health_row hypr.links display "$miss" "omarchy-egpu-external is missing" \
      "The eGPU ($ecard, pci-$bdf-card) is present but has no link.$([[ $policy == igpu ]] && echo " The igpu policy does not use it.")" system "$SYSTEM_FIX"
  else
    health_row hypr.links display ok "GPU links installed" "primary → ${pcard:-?}${ecard:+, external → $ecard}"
  fi
}

# hypr.order: what aquamarine logged at start, against the policy. A wrong
# primary is an error under any policy. Under igpu, an unpinned order is
# information unless the toggle file would pin it (then the session predates
# it: log out and in); a device list that includes the eGPU is a warning.
display_health_order() {
  local policy sig log explicit at_primary primary pcard plink pinned=0
  policy=$(_dsp_policy)
  primary=$(pci_primary)
  pcard=$( [[ -n $primary ]] && pci_drm_card "$primary")
  plink="$EGPU_DEV${DSP_LINK_PRIMARY#/dev}"
  [[ -e $plink || -L $plink ]] && pinned=1
  sig=${HYPRLAND_INSTANCE_SIGNATURE:-}
  log="${XDG_RUNTIME_DIR:-}/hypr/$sig/hyprland.log"
  if [[ -z $sig || ! -r $log ]]; then
    health_row hypr.order display skipped "Compositor GPU order" "Hyprland's log is not readable." none ""
    return
  fi
  explicit=$(grep -m1 -oE 'drm: Explicit device list .*' "$log")
  at_primary=$(grep -m1 -oE 'drm: gpu /dev/dri/[^ ]+ becomes primary' "$log" | awk '{print $3}')
  at_primary=${at_primary#/dev/dri/}
  if [[ -n $pcard && -n $at_primary && $at_primary != "$pcard" ]]; then
    health_row hypr.order display error "The compositor's primary GPU is not the laptop's" \
      "Hyprland made /dev/dri/$at_primary primary; the boot GPU is $pcard (pci-$primary-card). Pin the order, then log out and in." \
      user "Write the GPU order, then log out"
  elif [[ -n $explicit && $policy == igpu && $explicit == *omarchy-egpu-external* ]]; then
    health_row hypr.order display warn "The compositor was started with the eGPU" \
      "${explicit#drm: }. The igpu policy keeps the eGPU out of the compositor from the next login on." \
      user "Log out and in"
  elif [[ -n $explicit ]]; then
    health_row hypr.order display ok "GPU order pinned" "${explicit#drm: }; primary /dev/dri/${at_primary:-?}."
  elif (( pinned )); then
    health_row hypr.order display warn "GPU order not applied yet" \
      "The toggle file pins AQ_DRM_DEVICES, but this session started without it. Log out and in." \
      user "Log out and in"
  elif [[ $policy == igpu && -n $at_primary ]]; then
    health_row hypr.order display info "GPU order: laptop GPU primary" \
      "Hyprland chose /dev/dri/$at_primary (pci-$primary-card) by itself. Not pinned (no udev links); the igpu policy does not need the eGPU in the compositor."
  elif [[ -n $at_primary ]]; then
    health_row hypr.order display warn "GPU order not pinned" \
      "Hyprland chose /dev/dri/$at_primary (pci-$primary-card) by itself. That is right now, but nothing keeps an eGPU attached at login from being picked. AQ_DRM_DEVICES is not set." \
      user "Write the GPU order, then log out"
  else
    health_row hypr.order display skipped "Compositor GPU order" "No 'becomes primary' line in Hyprland's log." none ""
  fi
}

# hypr.session_env: the toggle file against what the engine generates now,
# then the running session's environment against the file's values.
# display_health_session_env <compositor pid or empty>
display_health_session_env() {
  local pid=${1:-} tmp want env k v have bad=() fix="Write the toggle file (omarchy-egpu display apply)"
  _dsp_model
  tmp=$(mktemp "${TMPDIR:-/tmp}/omarchy-egpu-toggle.XXXXXX") || return 0
  _dsp_render >"$tmp"
  if [[ ! -f $DSP_TOGGLE ]]; then
    rm -f -- "$tmp"
    health_row hypr.session_env display warn "The toggle file is missing" \
      "$DSP_TOGGLE keeps the session's GL, EGL and video decode on the ${DSP_P[label]:-primary} GPU while the eGPU is attached (policy $DSP_POLICY)." \
      user "$fix"
    return
  fi
  if ! cmp -s -- "$tmp" "$DSP_TOGGLE"; then
    rm -f -- "$tmp"
    health_row hypr.session_env display warn "The toggle file is out of date" \
      "$DSP_TOGGLE differs from what the engine generates now (policy $DSP_POLICY). Writing it keeps a backup." \
      user "$fix"
    return
  fi
  rm -f -- "$tmp"
  want=$(_dsp_session_env)
  if [[ -z $pid ]]; then
    health_row hypr.session_env display ok "The toggle file is up to date" \
      "Hyprland is not running; the session's variables are checked once it is."
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1 || ! env=$(timeout 3 systemctl --user show-environment 2>/dev/null); then
    health_row hypr.session_env display skipped "Session GPU vendor" \
      "The toggle file is up to date; systemctl --user show-environment is not available." none ""
    return
  fi
  while IFS='=' read -r k v; do
    [[ -n $k ]] || continue
    have=$(sed -n "s|^$k=||p" <<<"$env" | tail -n1)
    [[ $have == "$v" ]] || bad+=("$k=${have:-unset} (file: $v)")
  done <<<"$want"
  if (( ${#bad[@]} )); then
    health_row hypr.session_env display warn "The session does not have the toggle file's values" \
      "$(printf '%s; ' "${bad[@]}" | sed 's/; $//'). Apps launched now may use the eGPU's drivers. Log out and in." \
      user "Log out and in"
  else
    health_row hypr.session_env display ok "Session GPU vendor matches the primary" \
      "$(if [[ -n $want ]]; then paste -sd' ' <<<"$want" | sed 's/ /, /g'; else echo "Nothing to override for this GPU pair."; fi)"
  fi
}

# ---------------------------------------------------------------- main

display_main() {
  local verb=${1:-list}
  [[ $# -gt 0 ]] && shift
  case $verb in
    list) display_list ;;
    enable | disable) display_enable_disable "$verb" "$@" ;;
    set) display_set "$@" ;;
    off) display_off ;;
    move-workspaces) display_move_workspaces "$@" ;;
    policy) display_policy "$@" ;;
    render) _dsp_model && _dsp_render ;;
    apply) display_apply ;;
    *)
      json_error usage "$(jq -cn --arg v "$verb" '{detail: "display list|enable|disable|set|off|move-workspaces|policy|render|apply", got: $v}')"
      return 1
      ;;
  esac
}
