# shellcheck shell=bash
# tests/display.sh — gate E4 of plan-engine.md §12, the parts a fake can
# settle: lib/display.sh and the toggle file. Sourced by tests/run.sh;
# `tests/run.sh display` runs only these.
#
# Every test builds a fresh scenario (fixtures/display/machine: this laptop,
# Intel primary, Hyprland running, no udev links). The toggle file lands under
# the scenario's $HOME (the runner unsets XDG_STATE_HOME) and hyprctl is
# tests/fakes/bin/hyprctl; a guard stops a test whose toggle path or hyprctl
# is not the test's own. The real ~/.local/state/omarchy/toggles and the
# running Hyprland are never touched.
#
#   fixtures/display/golden-igpu-nvidia-intel.lua   the user's hand-written
#       toggle file of 2026-10-10, copied verbatim: the generator must
#       reproduce it byte for byte (scope.md, DECISIONS 2026-10-10)

DSP_GOLDEN="$TESTS/fixtures/display/golden-igpu-nvidia-intel.lua"
# Resolved here, before any scenario narrows PATH. Used to parse and run the
# rendered Lua against a stub `hl`.
DSP_LUA=$(type -P lua5.4 || type -P lua || true)
DSP_LUAC=$(type -P luac5.4 || type -P luac || true)
DSP_TV="LG Electronics LG TV SSCR2 0x01010101"

# dsp_new <name>: a fresh scenario in the current (sub)shell.
dsp_new() {
  setup_scenario "display-$1" "$TESTS/fixtures/display/machine" || exit 1
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  DSP_FILE="$HOME/.local/state/omarchy/toggles/hypr/zz-omarchy-egpu.lua"
  if [[ $(realpath -m -- "$DSP_FILE") != "$(realpath -- "$WORK")"/* || $(type -P hyprctl) != "$T/bin/hyprctl" ]]; then
    bad "display-$1: toggle file or hyprctl outside the test dir; refusing to run"
    exit 1
  fi
  mkdir -p -- "$EGPU_RUN"
}

# dsp <args>: `omarchy-egpu display <args>`; output in $T/out.json, exit in DSP_RC.
dsp() {
  "$ENGINE" display "$@" >"$T/out.json" 2>"$T/err"
  DSP_RC=$?
}

dsp_check() {
  local label=$1
  shift
  if jq -e "$@" "$T/out.json" >/dev/null 2>&1; then ok "$label"; else bad "$label: rc=$DSP_RC $(head -c 400 "$T/out.json") $(head -c 200 "$T/err")"; fi
}

# dsp_error <label> <code> [exit]
dsp_error() {
  if (( DSP_RC == ${3:-1} )) && jq -e --arg c "$2" '.error == $c' "$T/out.json" >/dev/null 2>&1; then
    ok "$1: refused with $2"
  else
    bad "$1: expected $2 (exit ${3:-1}), got exit $DSP_RC: $(head -c 300 "$T/out.json")"
  fi
}

dsp_true() { # <label> <bash condition...>
  local label=$1
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

dsp_has() { grep -qF -- "$2" "$1"; }

# dsp_config <json>: config.json
dsp_config() { printf '%s\n' "$1" >"$EGPU_CONFIG"; }

# dsp_mon <id> <name> <make> <model> <serial> <WxH@R> <x> <y> <scale> [disabled]
# One `hyprctl monitors all -j` entry, shaped like Hyprland 0.56.2's.
dsp_mon() {
  jq -cn --argjson id "$1" --arg n "$2" --arg make "$3" --arg model "$4" --arg serial "$5" --arg mode "$6" \
    --argjson x "$7" --argjson y "$8" --argjson s "$9" --argjson dis "${10:-false}" '
    ($mode | capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)")) as $c
    | {id: $id, name: $n, description: ([$make, $model, $serial] | map(select(. != "")) | join(" ")),
       make: $make, model: $model, serial: $serial,
       width: ($c.w | tonumber), height: ($c.h | tonumber), refreshRate: ($c.r | tonumber),
       x: $x, y: $y, scale: $s, transform: 0, vrr: false, disabled: $dis, mirrorOf: "none",
       activeWorkspace: {id: 1, name: "1"},
       availableModes: ["\($c.w)x\($c.h)@\($c.r)Hz", "1920x1080@60.00Hz", "1920x1080@50.00Hz"]}'
}

dsp_monitors() { printf '%s\n' "$@" | jq -s -c . >"$EGPU_FAKE_DIR/hypr/monitors.json"; }

# dsp_workspaces <id:monitor:monitorID ...>
dsp_workspaces() {
  local w i m mid
  for w in "$@"; do
    IFS=: read -r i m mid <<<"$w"
    jq -cn --argjson i "$i" --arg m "$m" --argjson mid "$mid" '{id: $i, name: ($i | tostring), monitor: $m, monitorID: $mid}'
  done | jq -s -c . >"$EGPU_FAKE_DIR/hypr/workspaces.json"
}

dsp_ws_monitor() { jq -r --argjson i "$1" '.[] | select(.id == $i) | .monitor' "$EGPU_FAKE_DIR/hypr/workspaces.json"; }
dsp_mon_field() { jq -r --arg d "$1" ".[] | select(.description == \$d) | $2" "$EGPU_FAKE_DIR/hypr/monitors.json"; }

# The eGPU attached and bound, Hyprland holding its card.
dsp_egpu() {
  fx_deg2 authorized true
  fx_egpu_nvidia nvidia "${1:-disconnected:disabled}"
  fx_nvidia_modules
  ln -sfn /dev/dri/card1 "$FX_ROOT/proc/1217/fd/20"
}

# The LG TV on the eGPU's HDMI-A-2, lit by Hyprland (eGPU present at login,
# E1b): workspace 1 on the laptop, 2 and 3 on the TV.
dsp_world_hdmi() {
  dsp_egpu connected:enabled
  dsp_monitors "$(dsp_mon 0 eDP-1 'Samsung Display Corp.' 0x41AA '' 2880x1800@120.00 0 0 1.6)" \
    "$(dsp_mon 1 HDMI-A-2 'LG Electronics' 'LG TV SSCR2' 0x01010101 3840x2160@60.00 1800 0 1.6)"
  dsp_workspaces 1:eDP-1:0 2:HDMI-A-2:1 3:HDMI-A-2:1
}

# dsp_edid <file> <PNP id> <product> <serial number> [name] [serial string]
dsp_edid() {
  python3 - "$@" <<'PY'
import sys
path, mfg, prod, num = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0)
name = sys.argv[5] if len(sys.argv) > 5 else ""
sstr = sys.argv[6] if len(sys.argv) > 6 else ""
e = bytearray(128)
e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
m = ((ord(mfg[0]) - 64) << 10) | ((ord(mfg[1]) - 64) << 5) | (ord(mfg[2]) - 64)
e[8], e[9] = m >> 8, m & 0xFF
e[10], e[11] = prod & 0xFF, prod >> 8
e[12:16] = num.to_bytes(4, "little")
e[18], e[19] = 1, 4
o = 54
for tag, text in ((0xFC, name), (0xFF, sstr)):
    if not text:
        continue
    t = text.encode()[:13]
    if len(t) < 13:
        t += b"\n"
    e[o:o + 5] = bytes([0, 0, 0, tag, 0])
    e[o + 5:o + 18] = t.ljust(13, b" ")
    o += 18
e[127] = (-sum(e[:127])) & 0xFF
open(path, "wb").write(bytes(e))
PY
}

# dsp_lua_run <file>: run a rendered toggle file against a stub `hl`, with the
# /dev/dri links pointed into the fixture. Prints "env K=V", "config a.b=v"
# and "monitor <output> ..." lines.
dsp_lua_run() {
  local f="$T/run.lua"
  sed "s|\"/dev/dri/omarchy-egpu-|\"$FX_ROOT/dev/dri/omarchy-egpu-|g" "$1" >"$f"
  "$DSP_LUA" - "$f" <<'LUA'
local function flat(prefix, t, out)
  for k, v in pairs(t) do
    local key = prefix == "" and k or (prefix .. "." .. k)
    if type(v) == "table" then flat(key, v, out) else out[#out + 1] = key .. "=" .. tostring(v) end
  end
  return out
end
hl = {
  env = function(k, v) print("env " .. k .. "=" .. v) end,
  config = function(t) for _, l in ipairs(flat("", t, {})) do print("config " .. l) end end,
  monitor = function(t) print("monitor " .. t.output .. (t.disabled and " disabled" or "")) end,
}
dofile(arg[1])
LUA
}

# ---------------------------------------------------------------- golden

dsp_test_golden() {
  echo "${BOLD}display: golden toggle file${RESET}"
  dsp_new golden
  dsp_egpu
  dsp render
  if cmp -s "$T/out.json" "$DSP_GOLDEN"; then
    ok "render == the hand-written file, byte for byte (igpu, nvidia eGPU attached, Intel primary, no links)"
  else
    bad "render differs from the golden file: $(diff "$DSP_GOLDEN" "$T/out.json" | head -c 600)"
  fi
  fx_egpu_unplug
  dsp render
  dsp_true "render == golden with the eGPU unplugged (the file must be right for the next login)" cmp -s "$T/out.json" "$DSP_GOLDEN"

  # The engine takes over the user's hand-written file without changing it.
  mkdir -p -- "$(dirname -- "$DSP_FILE")"
  cp -- "$DSP_GOLDEN" "$DSP_FILE"
  : >"$EGPU_FAKE_LOG"
  dsp apply
  dsp_check "apply over the identical hand-written file: unchanged, no backup, no reload" \
    '.changed == false and .backup == null and .reloaded == false and .policy == "igpu"'
  dsp_true "  ...and Hyprland was not reloaded" bash -c "! grep -q 'hyprctl reload' '$EGPU_FAKE_LOG'"
  dsp_true "  ...and no backup directory was made" test ! -e "$EGPU_STATE/backups/toggle"

  rm -f -- "$DSP_FILE"
  : >"$EGPU_FAKE_LOG"
  dsp apply
  dsp_check "apply with no file: written, nothing to back up, reloaded" '.changed == true and .backup == null and .reloaded == true'
  dsp_true "  ...the written file is the golden file" cmp -s "$DSP_FILE" "$DSP_GOLDEN"
  dsp_true "  ...mode 644 like the hand-written one" test "$(stat -c %a "$DSP_FILE")" = 644
  dsp_true "  ...reload, then configerrors (validation, §7.2)" \
    bash -c "grep -n 'hyprctl' '$EGPU_FAKE_LOG' | grep -A1 'hyprctl reload' | grep -q 'hyprctl -j configerrors'"
  dsp_true "  ...no temp files left beside it" bash -c "! compgen -G '$(dirname -- "$DSP_FILE")/.*' >/dev/null"
  dsp apply
  dsp_check "a second apply is a no-op" '.changed == false'

  if [[ -n $DSP_LUA ]]; then
    dsp_lua_run "$DSP_FILE" >"$T/lua.out" 2>&1
    if [[ $(sort "$T/lua.out") == "$(sort <<'EOF'
env __GLX_VENDOR_LIBRARY_NAME=mesa
env LIBVA_DRIVER_NAME=iHD
config cursor.no_hardware_cursors=0
env __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
env QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
EOF
)" ]]; then
      ok "the file runs in Lua and sets exactly the four variables and the hardware cursor"
    else
      bad "Lua run: $(head -c 400 "$T/lua.out")"
    fi
  fi
}

# Values come from the backends and the installed files, not from code.
dsp_test_values() {
  echo "${BOLD}display: values from the backends${RESET}"
  dsp_new values
  rm -f -- "$FX_ROOT/usr/lib/dri/iHD_drv_video.so"
  fx_write usr/lib/dri/i965_drv_video.so ''
  rm -f -- "$FX_ROOT/usr/share/glvnd/egl_vendor.d/50_mesa.json"
  fx_write etc/glvnd/egl_vendor.d/40_mesa-local.json '{"ICD":{"library_path":"libEGL_mesa.so.0"}}'
  dsp render
  dsp_true "VA-API driver detected from the driver files (i965 when iHD is absent)" dsp_has "$T/out.json" 'hl.env("LIBVA_DRIVER_NAME", "i965")'
  dsp_true "EGL vendor file found by its library, /etc first" \
    dsp_has "$T/out.json" 'hl.env("__EGL_VENDOR_LIBRARY_FILENAMES", "/etc/glvnd/egl_vendor.d/40_mesa-local.json")'
  rm -f -- "$FX_ROOT/usr/lib/dri/i965_drv_video.so" "$FX_ROOT/etc/glvnd/egl_vendor.d/40_mesa-local.json"
  dsp render
  dsp_true "no VA-API driver installed: no LIBVA line" bash -c "! grep -q LIBVA_DRIVER_NAME '$T/out.json'"
  dsp_true "no Mesa EGL vendor file: no EGL line" bash -c "! grep -q __EGL_VENDOR '$T/out.json'"
  dsp_true "  ...the GLX vendor still comes from the primary backend" dsp_has "$T/out.json" 'hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")'

  # An AMD APU as the primary: its backend's label, VA-API driver and note text.
  printf '0x1002\n' >"$FX_ROOT/sys/bus/pci/devices/0000:00:02.0/vendor"
  fx_write usr/share/glvnd/egl_vendor.d/50_mesa.json '{"ICD":{"library_path":"libEGL_mesa.so.0"}}'
  dsp render
  dsp_true "AMD primary: LIBVA_DRIVER_NAME=radeonsi" dsp_has "$T/out.json" 'hl.env("LIBVA_DRIVER_NAME", "radeonsi")'
  dsp_true "AMD primary: the notes name it" dsp_has "$T/out.json" "-- renders on AMD. That wastes power"
  printf '0x8086\n' >"$FX_ROOT/sys/bus/pci/devices/0000:00:02.0/vendor"

  # A backend with no session needs (the amdgpu stub as the eGPU): only the
  # managed line. The nvidia lines are the nvidia backend's, not the module's.
  dsp_config '{"backend":"amdgpu"}'
  dsp render
  dsp_true "eGPU backend without session needs: nothing but the managed line" \
    test "$(cat "$T/out.json")" = "-- Managed by omarchy-egpu. Delete this file to undo."
}

# ---------------------------------------------------------------- extensions

dsp_test_links() {
  echo "${BOLD}display: GPU order (udev links) and AQ_MGPU_NO_EXPLICIT${RESET}"
  dsp_new links
  dsp_egpu
  fx_hypr_links card1
  dsp render
  cp "$T/out.json" "$T/igpu.lua"
  dsp_true "with links: the golden file is kept as the first 20 lines" cmp -s <(head -n 20 "$T/igpu.lua") "$DSP_GOLDEN"
  dsp_true "  ...and an AQ_DRM_DEVICES block follows" dsp_has "$T/igpu.lua" 'hl.env("AQ_DRM_DEVICES", "/dev/dri/omarchy-egpu-primary")'
  dsp_true "  ...igpu policy never names the eGPU's link" bash -c "! grep -q 'omarchy-egpu-external' '$T/igpu.lua'"
  dsp_config '{"display":{"policy":"egpu-hdmi","mgpu_no_explicit":true}}'
  dsp render
  cp "$T/out.json" "$T/hdmi.lua"
  dsp_true "egpu-hdmi: the eGPU's link is added when it exists at login" dsp_has "$T/hdmi.lua" 'devices = devices .. ":/dev/dri/omarchy-egpu-external"'
  dsp_true "mgpu_no_explicit: AQ_MGPU_NO_EXPLICIT=1" dsp_has "$T/hdmi.lua" 'hl.env("AQ_MGPU_NO_EXPLICIT", "1")'
  rm -f -- "$FX_ROOT/dev/dri/omarchy-egpu-primary" "$FX_ROOT/dev/dri/omarchy-egpu-external"
  dsp render
  dsp_true "no links (system half not installed): no AQ_DRM_DEVICES at all" bash -c "! grep -q AQ_DRM_DEVICES '$T/out.json'"

  if [[ -n $DSP_LUAC ]]; then
    if "$DSP_LUAC" -p "$T/igpu.lua" "$T/hdmi.lua" 2>"$T/luac.err"; then ok "rendered variants parse (luac -p)"; else bad "luac: $(head -c 300 "$T/luac.err")"; fi
  fi
  if [[ -n $DSP_LUA ]]; then
    local p="$FX_ROOT/dev/dri/omarchy-egpu-primary" e="$FX_ROOT/dev/dri/omarchy-egpu-external"
    fx_hypr_links card1
    dsp_true "Lua, igpu: AQ_DRM_DEVICES = primary only" bash -c "$(declare -f dsp_lua_run); T='$T' FX_ROOT='$FX_ROOT' DSP_LUA='$DSP_LUA'; dsp_lua_run '$T/igpu.lua' | grep -qx 'env AQ_DRM_DEVICES=$p'"
    dsp_true "Lua, egpu-hdmi, eGPU attached at login: primary:external" \
      bash -c "$(declare -f dsp_lua_run); T='$T' FX_ROOT='$FX_ROOT' DSP_LUA='$DSP_LUA'; dsp_lua_run '$T/hdmi.lua' | grep -qx 'env AQ_DRM_DEVICES=$p:/dev/dri/omarchy-egpu-external'"
    rm -f -- "$e"
    dsp_true "Lua, egpu-hdmi, eGPU absent at login: no dead path, primary only" \
      bash -c "$(declare -f dsp_lua_run); T='$T' FX_ROOT='$FX_ROOT' DSP_LUA='$DSP_LUA'; dsp_lua_run '$T/hdmi.lua' | grep -qx 'env AQ_DRM_DEVICES=$p'"
    rm -f -- "$p"
    dsp_true "Lua, links removed later (system half uninstalled): AQ_DRM_DEVICES left unset" \
      bash -c "$(declare -f dsp_lua_run); T='$T' FX_ROOT='$FX_ROOT' DSP_LUA='$DSP_LUA'; ! dsp_lua_run '$T/hdmi.lua' | grep -q AQ_DRM_DEVICES"
  fi
}

# ---------------------------------------------------------------- writes

dsp_test_commit() {
  echo "${BOLD}display: atomic write, backups, validation and restore${RESET}"
  dsp_new commit
  dsp_world_hdmi
  mkdir -p -- "$(dirname -- "$DSP_FILE")" "$EGPU_STATE/backups/toggle"
  printf -- '-- an older file\n' >"$DSP_FILE"
  local i
  for i in $(seq -w 1 25); do : >"$EGPU_STATE/backups/toggle/zz-omarchy-egpu-20260101T0000$i.000Z.lua"; done
  dsp apply
  dsp_check "a different file is replaced; the env changed, so relogin_required" '.changed == true and .relogin_required == true and (.backup | type == "string")'
  dsp_true "  ...the backup holds the previous bytes" bash -c "[[ \$(cat \"\$(jq -r .backup '$T/out.json')\") == '-- an older file' ]]"
  dsp_true "  ...backups are pruned to the newest 20" test "$(find "$EGPU_STATE/backups/toggle" -name '*.lua' | wc -l)" = 20
  dsp_true "  ...the new backup survives the pruning" test -e "$(jq -r .backup "$T/out.json")"

  # A config error that appears with the new file puts the old one back.
  cp -- "$DSP_FILE" "$T/before.lua"
  dsp_config '{"display":{"mgpu_no_explicit":true}}'
  echo '["zz-omarchy-egpu.lua:22: something Hyprland rejects"]' >"$EGPU_FAKE_DIR/hypr/reload-errors.json"
  echo AQ_MGPU_NO_EXPLICIT >"$EGPU_FAKE_DIR/hypr/reload-errors-when"
  : >"$EGPU_FAKE_LOG"
  dsp apply
  dsp_error "new config error after reload" config_errors
  dsp_check "  ...reports the error and that it restored" '.restored == true and (.errors | length == 1)'
  dsp_true "  ...the previous file is back, byte for byte" cmp -s "$DSP_FILE" "$T/before.lua"
  dsp_true "  ...and Hyprland reloaded again with it" test "$(grep -c 'hyprctl reload' "$EGPU_FAKE_LOG")" = 2

  # display.json goes back with the file.
  echo 'disabled = true' >"$EGPU_FAKE_DIR/hypr/reload-errors-when"
  rm -f -- "$EGPU_STATE/display.json"
  cp -- "$DSP_FILE" "$T/before.lua"
  dsp disable "$DSP_TV"
  dsp_error "disable when the file is rejected" config_errors
  dsp_true "  ...display.json is not left claiming the change" test ! -e "$EGPU_STATE/display.json"
  dsp_true "  ...nor the toggle file" cmp -s "$DSP_FILE" "$T/before.lua"

  # Errors that were there before the write are not blamed on it.
  rm -f -- "$EGPU_FAKE_DIR/hypr/reload-errors.json"
  echo '["hyprland.lua:3: the user'"'"'s own mistake"]' >"$EGPU_FAKE_DIR/hypr/base-errors.json"
  cp "$EGPU_FAKE_DIR/hypr/base-errors.json" "$EGPU_FAKE_DIR/hypr/configerrors.json"
  dsp apply
  dsp_check "an existing config error does not block the write" '.changed == true and .reloaded == true'
  dsp_true "  ...the new file is in place" dsp_has "$DSP_FILE" AQ_MGPU_NO_EXPLICIT
}

# ---------------------------------------------------------------- verbs

dsp_test_list_off() {
  echo "${BOLD}display: list and off${RESET}"
  dsp_new off
  dsp_world_hdmi
  dsp list
  dsp_check "list: the TV on the eGPU, not the laptop panel" \
    '.compositor and .policy == "igpu" and .primary.name == "eDP-1" and .card == "card1" and (.monitors | length == 1)'
  dsp_check "list: name, description, connector, mode, modes, workspaces (§7.3)" --arg d "$DSP_TV" '
    .monitors[0] | .name == "HDMI-A-2" and .description == $d and .connector == "HDMI-A-2" and .matched_by == "name"
    and .enabled and .mode == "3840x2160@60.00" and (.modes | index("1920x1080@60.00")) != null
    and ([.workspaces[].id] == [2, 3]) and .position == {x: 1800, y: 0} and .rule == null'

  : >"$EGPU_FAKE_LOG"
  local t0 t1
  t0=$(date +%s%3N)
  dsp off
  t1=$(date +%s%3N)
  dsp_check "off: the TV is disabled" --arg d "$DSP_TV" '.disabled == [{name: "HDMI-A-2", description: $d, connector: "HDMI-A-2"}] and .persisted'
  if (( DSP_RC == 0 && t1 - t0 < 1000 )); then ok "off took $((t1 - t0)) ms end to end (target < 1 s; monitors off after $(jq .elapsed_ms "$T/out.json") ms)"
  else bad "off took $((t1 - t0)) ms (rc $DSP_RC)"; fi
  dsp_true "  ...one hyprctl eval, keyed by description" \
    test "$(grep -c "hyprctl eval hl.monitor({ output = \"desc:$DSP_TV\", disabled = true })" "$EGPU_FAKE_LOG")" = 1
  dsp_true "  ...without reloading Hyprland" bash -c "! grep -q 'hyprctl reload' '$EGPU_FAKE_LOG'"
  dsp_true "  ...hyprctl shows it disabled, the laptop panel still on" \
    test "$(dsp_mon_field "$DSP_TV" .disabled) $(dsp_mon_field 'Samsung Display Corp. 0x41AA' .disabled)" = "true false"
  dsp_true "  ...its workspaces landed on the laptop panel" test "$(dsp_ws_monitor 2) $(dsp_ws_monitor 3)" = "eDP-1 eDP-1"
  dsp_true "  ...persisted in the toggle file" dsp_has "$DSP_FILE" "hl.monitor({ output = \"desc:$DSP_TV\", disabled = true })"
  dsp_true "  ...after the golden part, which is unchanged" cmp -s <(head -n 20 "$DSP_FILE") "$DSP_GOLDEN"
  dsp_true "  ...and in display.json" test "$(jq -r --arg d "$DSP_TV" '.monitors[$d].enabled' "$EGPU_STATE/display.json")" = false

  # Something turns it back on; a reload re-reads the toggle file and it stays off.
  jq -c --arg d "$DSP_TV" 'map(if .description == $d then .disabled = false else . end)' \
    "$EGPU_FAKE_DIR/hypr/monitors.json" >"$T/m.json" && mv "$T/m.json" "$EGPU_FAKE_DIR/hypr/monitors.json"
  hyprctl reload >/dev/null
  dsp_true "reload keeps a disabled monitor off (§11.6)" test "$(dsp_mon_field "$DSP_TV" .disabled)" = true

  dsp off
  dsp_check "off with nothing on: nothing to do, file unchanged" '.disabled == [] and .toggle.changed == false'

  # A monitor that does not turn off.
  jq -c 'map(.disabled = false)' "$EGPU_FAKE_DIR/hypr/monitors.json" >"$T/m.json" && mv "$T/m.json" "$EGPU_FAKE_DIR/hypr/monitors.json"
  touch "$EGPU_FAKE_DIR/hypr/eval-ignore"
  t0=$(date +%s%3N)
  dsp off
  t1=$(date +%s%3N)
  dsp_error "off when hyprctl still shows the monitor on" hdmi_still_active
  dsp_true "  ...after the 3 s wait, not longer ($((t1 - t0)) ms)" test $((t1 - t0)) -ge 3000 -a $((t1 - t0)) -lt 5000
}

dsp_test_enable_disable() {
  echo "${BOLD}display: disable, enable, move-workspaces${RESET}"
  dsp_new endis
  dsp_world_hdmi
  : >"$EGPU_FAKE_LOG"
  dsp disable "$DSP_TV"
  dsp_check "disable <description>: off, workspaces moved first" '.enabled == false and .live and .workspaces.moved == [2, 3] and .workspaces.method == "direct"'
  dsp_true "  ...the moves happened before the monitor went off" bash -c "
    m=\$(grep -n 'hl.dsp.workspace.move' '$EGPU_FAKE_LOG' | tail -n1 | cut -d: -f1)
    e=\$(grep -n 'hyprctl eval' '$EGPU_FAKE_LOG' | head -n1 | cut -d: -f1)
    [[ -n \$m && -n \$e ]] && (( m < e ))"
  dsp_true "  ...by workspace id, to the primary panel" dsp_has "$EGPU_FAKE_LOG" 'hl.dsp.workspace.move({ workspace = "2", monitor = "eDP-1" })'
  dsp_true "  ...persisted with a reload and a configerrors check" bash -c "grep -q 'hyprctl reload' '$EGPU_FAKE_LOG' && grep -q 'hyprctl -j configerrors' '$EGPU_FAKE_LOG'"
  dsp_true "  ...still off after that reload" test "$(dsp_mon_field "$DSP_TV" .disabled)" = true

  dsp enable HDMI-A-2
  dsp_check "enable <name>: on, extended right of the laptop's logical width (2880/1.6)" \
    '.enabled and .rule.at == "1800x0" and .rule.position == "right" and .rule.vrr == false and .rule.scale == 1.6'
  dsp_true "  ...hyprctl shows it on at 1800,0" test "$(dsp_mon_field "$DSP_TV" '"\(.disabled) \(.x),\(.y)"')" = "false 1800,0"
  dsp_true "  ...the persisted rule sets vrr = 0 (NVIDIA forces VRR otherwise, §11.5)" \
    dsp_has "$DSP_FILE" "hl.monitor({ output = \"desc:$DSP_TV\", mode = \"preferred\", position = \"1800x0\", scale = 1.6, vrr = 0 })"

  # Workspaces by focus when Hyprland ignores the id (unverified, §7.3).
  dsp_workspaces 1:eDP-1:0 2:HDMI-A-2:1 3:HDMI-A-2:1
  touch "$EGPU_FAKE_DIR/hypr/no-workspace-arg"
  dsp move-workspaces "desc:$DSP_TV"
  dsp_check "move-workspaces falls back to focus + move" '.moved == [2, 3] and .failed == [] and .method == "focus" and .to == "eDP-1"'
  dsp_true "  ...both are on the laptop panel" test "$(dsp_ws_monitor 2) $(dsp_ws_monitor 3)" = "eDP-1 eDP-1"

  dsp disable eDP-1
  dsp_error "the laptop panel is not an eGPU monitor" monitor_not_found
  dsp disable 'x" }) os.execute("touch /tmp/pwned") --'
  dsp_error "a name that could inject Lua" unsafe_name
  dsp_true "  ...never reached hyprctl" bash -c "! grep -q 'pwned' '$EGPU_FAKE_LOG'"

  # A remembered monitor that is not plugged in: only the file changes.
  dsp_monitors "$(dsp_mon 0 eDP-1 'Samsung Display Corp.' 0x41AA '' 2880x1800@120.00 0 0 1.6)"
  : >"$EGPU_FAKE_LOG"
  dsp disable "$DSP_TV"
  dsp_check "disable a remembered monitor that is unplugged: persisted only" '.live == false and .enabled == false'
  dsp_true "  ...no eval" bash -c "! grep -q 'hyprctl eval' '$EGPU_FAKE_LOG'"
  dsp enable "Some Other Monitor"
  dsp_error "enable an unknown monitor" monitor_not_found
}

dsp_test_set() {
  echo "${BOLD}display: set${RESET}"
  dsp_new set
  dsp_world_hdmi
  dsp set HDMI-A-2 '{"mode":"1920x1080@60","position":"left","scale":1}'
  dsp_check "set mode/left/scale: the mode the monitor lists, left of the laptop" \
    '.rule.mode == "1920x1080@60.00" and .rule.at == "-1920x0" and .rule.scale == 1'
  dsp_true "  ...applied live" test "$(dsp_mon_field "$DSP_TV" '"\(.width)x\(.height) \(.x),\(.y) \(.scale)"')" = "1920x1080 -1920,0 1"
  dsp set HDMI-A-2 '{"position":"above"}'
  dsp_check "set above: keeps the mode, sits above" '.rule.mode == "1920x1080@60.00" and .rule.at == "0x-1080"'
  dsp set HDMI-A-2 '{"position":"below","vrr":true}'
  dsp_check "set below + vrr: below the laptop's logical height (1800/1.6)" '.rule.at == "0x1125" and .rule.vrr == true and (.lua | test("vrr = 1"))'
  dsp set HDMI-A-2 '{"position":"3000,-200"}'
  dsp_check "set x,y" '.rule.at == "3000x-200"'
  dsp set HDMI-A-2 '{"mirror":true}'
  dsp_check "set mirror: mirrors the primary panel" '.rule.mirror == true and .rule.mirror_of == "eDP-1" and (.lua | test("mirror = \"eDP-1\""))'
  dsp_true "  ...persisted" dsp_has "$DSP_FILE" 'mirror = "eDP-1"'
  dsp set HDMI-A-2 '{"mode":"1234x567@60"}'
  dsp_error "a mode the monitor does not list" invalid_value
  dsp set HDMI-A-2 '{"colour":"red"}'
  dsp_error "an unknown key" invalid_value
  dsp set HDMI-A-2 '{"scale":"big"}'
  dsp_error "a bad scale" invalid_value
  dsp set HDMI-A-2 'nope'
  dsp_error "not JSON" invalid_value
  dsp set eDP-1 '{"vrr":true}'
  dsp_error "set on the laptop panel" monitor_not_found

  # display.vrr and display.position are the defaults for a new rule.
  rm -f -- "$EGPU_STATE/display.json"
  dsp_config '{"display":{"vrr":true,"position":"left"}}'
  dsp enable HDMI-A-2
  dsp_check "config display.vrr / display.position are the defaults" '.rule.vrr == true and .rule.position == "left" and .rule.at == "-1920x0"'
}

dsp_test_unsafe() {
  echo "${BOLD}display: unsafe descriptions${RESET}"
  dsp_new unsafe
  dsp_egpu connected:enabled
  dsp_monitors "$(dsp_mon 0 eDP-1 'Samsung Display Corp.' 0x41AA '' 2880x1800@120.00 0 0 1.6)" \
    "$(dsp_mon 1 HDMI-A-2 'Evil"Corp' 'X") os.execute("id' 1 3840x2160@60.00 1800 0 1)"
  : >"$EGPU_FAKE_LOG"
  dsp off
  dsp_check "off still turns off a monitor whose description is unsafe, by its name" '.disabled[0].name == "HDMI-A-2" and .not_persisted == ["HDMI-A-2"]'
  dsp_true "  ...eval used the connector name" dsp_has "$EGPU_FAKE_LOG" 'hl.monitor({ output = "HDMI-A-2", disabled = true })'
  dsp_true "  ...nothing of the description reached the file" bash -c "! grep -q Evil '$DSP_FILE'"
  dsp set HDMI-A-2 '{"vrr":true}'
  dsp_error "set on a monitor with an unsafe description" unsafe_name
}

dsp_test_collision() {
  echo "${BOLD}display: connector name collision (§7.1)${RESET}"
  dsp_new collision
  # The TV on the laptop's HDMI-A-1 and a Dell on the eGPU's port that the
  # driver also calls HDMI-A-1: Hyprland lists two HDMI-A-1.
  dsp_egpu
  fx_connector 0000:00:02.0 card0 HDMI-A-1 connected enabled
  fx_connector 0000:03:00.0 card1 HDMI-A-1 connected enabled
  dsp_edid "$FX_ROOT/sys/bus/pci/devices/0000:00:02.0/drm/card0/card0-HDMI-A-1/edid" GSM 0x0001 0x01010101 'LG TV SSCR2'
  dsp_edid "$FX_ROOT/sys/bus/pci/devices/0000:03:00.0/drm/card1/card1-HDMI-A-1/edid" DEL 0xA0B1 0 'DELL U2720Q' ABC123
  dsp_monitors "$(dsp_mon 0 eDP-1 'Samsung Display Corp.' 0x41AA '' 2880x1800@120.00 0 0 1.6)" \
    "$(dsp_mon 1 HDMI-A-1 'LG Electronics' 'LG TV SSCR2' 0x01010101 3840x2160@60.00 1800 0 1.6)" \
    "$(dsp_mon 2 HDMI-A-1 'Dell Inc.' 'DELL U2720Q' ABC123 3840x2160@60.00 4200 0 1.5)"
  dsp_workspaces 1:eDP-1:0 2:HDMI-A-1:1 3:HDMI-A-1:2
  dsp list
  dsp_check "name collision: the eGPU's monitor is found by EDID, the laptop's TV is not taken" \
    '(.monitors | length == 1) and .monitors[0].description == "Dell Inc. DELL U2720Q ABC123" and .monitors[0].matched_by == "edid" and .monitors[0].connector == "HDMI-A-1"'
  dsp_check "  ...its workspaces by monitor id, not by the shared name" '[.monitors[0].workspaces[].id] == [3]'
  dsp off
  dsp_true "off turns off the Dell only" \
    test "$(dsp_mon_field 'Dell Inc. DELL U2720Q ABC123' .disabled) $(dsp_mon_field "$DSP_TV" .disabled)" = "true false"
  jq -c 'map(.disabled = false)' "$EGPU_FAKE_DIR/hypr/monitors.json" >"$T/m.json" && mv "$T/m.json" "$EGPU_FAKE_DIR/hypr/monitors.json"
  rm -f -- "$FX_ROOT/sys/bus/pci/devices/0000:03:00.0/drm/card1/card1-HDMI-A-1/edid" "$EGPU_STATE/display.json"
  dsp list
  dsp_check "no EDID to settle it: ambiguous, neither monitor is the eGPU's" '(.monitors | length == 0) and (.ambiguous | length == 2)'
  dsp off
  dsp_check "  ...so off touches neither" '.disabled == []'
}

dsp_test_policy() {
  echo "${BOLD}display: policy${RESET}"
  dsp_new policy
  dsp_world_hdmi
  fx_hypr_links card1
  dsp policy
  dsp_check "policy: igpu by default" '.policy == "igpu" and .origin == "default"'
  dsp_config '{"steam":{"account":"123"},"device":{"match":"auto"}}'
  dsp policy set egpu-hdmi
  dsp_check "policy set egpu-hdmi: needs a new session" '.policy == "egpu-hdmi" and .previous == "igpu" and .relogin_required == true and .toggle.changed'
  dsp_true "  ...config.json gains display.policy, other keys kept" \
    test "$(jq -c '[.display.policy, .steam.account, .device.match]' "$EGPU_CONFIG")" = '["egpu-hdmi","123","auto"]'
  dsp_true "  ...the GPU order includes the eGPU" dsp_has "$DSP_FILE" ':/dev/dri/omarchy-egpu-external'
  dsp_true "  ...and the TV on the eGPU gets a rule (extend right, vrr off)" \
    dsp_has "$DSP_FILE" "hl.monitor({ output = \"desc:$DSP_TV\", mode = \"preferred\", position = \"1800x0\", scale = 1.6, vrr = 0 })"
  dsp policy
  dsp_check "policy get: from the file" '.policy == "egpu-hdmi" and .origin == "file"'
  dsp policy set hybrid
  dsp_error "an unknown policy" invalid_value
  dsp policy set igpu
  dsp_check "back to igpu" '.policy == "igpu" and .previous == "egpu-hdmi" and .relogin_required'
  dsp_true "  ...the GPU order is the laptop GPU alone again" bash -c "! grep -q 'omarchy-egpu-external' '$DSP_FILE'"
  echo '["broken"' >"$EGPU_CONFIG"
  dsp policy set egpu-hdmi
  dsp_error "a config.json that is not JSON is not overwritten" config_invalid
  dsp_true "  ...it is left as it was" test "$(cat "$EGPU_CONFIG")" = '["broken"'
}

dsp_test_no_compositor_busy() {
  echo "${BOLD}display: no compositor, busy${RESET}"
  dsp_new nocomp
  dsp_world_hdmi
  local sig=$HYPRLAND_INSTANCE_SIGNATURE
  unset HYPRLAND_INSTANCE_SIGNATURE
  dsp list
  dsp_check "list without Hyprland: compositor false, still answers" '.compositor == false and .monitors == [] and .policy == "igpu"'
  dsp set HDMI-A-2 '{"vrr":true}'
  dsp_error "set without Hyprland" no_compositor
  dsp off
  dsp_check "off without Hyprland: nothing to do" '.compositor == false and .disabled == []'
  : >"$EGPU_FAKE_LOG"
  dsp apply
  dsp_check "apply without Hyprland: written, not reloaded" '.changed and .reloaded == false'
  dsp_true "  ...hyprctl not called" bash -c "! grep -q 'hyprctl' '$EGPU_FAKE_LOG'"
  export HYPRLAND_INSTANCE_SIGNATURE=$sig

  flock "$EGPU_RUN/display.lock" sleep 3 &
  fx_bg $!
  sleep 0.3
  EGPU_DISPLAY_LOCK_WAIT=0 dsp off
  dsp_error "a second display job" busy 3
}

# ---------------------------------------------------------------- health

dsp_health() { "$ENGINE" health >"$T/health.json" 2>"$T/health.err"; }
dsp_row() { # <label> <id> <level> [title regex]
  local got
  got=$(jq -r --arg id "$2" '.[] | select(.id == $id) | "\(.level)\t\(.title)"' "$T/health.json")
  if [[ ${got%%$'\t'*} == "$3" && ( -z ${4:-} || ${got#*$'\t'} =~ $4 ) ]]; then ok "$1: $2 = $3"
  else bad "$1: $2 = ${got:-<missing>}, expected $3${4:+ /$4/} ($(jq -r --arg id "$2" '.[] | select(.id == $id) | .detail' "$T/health.json" | head -c 200))"; fi
}

dsp_test_health() {
  echo "${BOLD}display: health rows against the policy${RESET}"
  dsp_new health
  dsp_egpu
  local log="$FX_XDG/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log"
  echo "DEBUG from aquamarine ]: drm: gpu /dev/dri/card0 becomes primary drm" >"$log"
  dsp_health
  dsp_row "igpu, no links, no file" hypr.links info
  dsp_row "igpu, no links, no file" hypr.order info
  dsp_row "igpu, no links, no file" hypr.session_env warn missing

  dsp apply
  printf '%s\n' __GLX_VENDOR_LIBRARY_NAME=mesa LIBVA_DRIVER_NAME=iHD \
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
    QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi NVD_BACKEND=direct >"$EGPU_FAKE_DIR/session-env.txt"
  dsp_health
  dsp_row "file written, session has its values (this machine today)" hypr.session_env ok

  sed -i 's/^__GLX_VENDOR_LIBRARY_NAME=.*/__GLX_VENDOR_LIBRARY_NAME=nvidia/' "$EGPU_FAKE_DIR/session-env.txt"
  dsp_health
  dsp_row "session started before the file (nvidia.lua's GLX vendor)" hypr.session_env warn "does not have"
  echo '-- edited by hand' >>"$DSP_FILE"
  dsp_health
  dsp_row "file edited by hand" hypr.session_env warn "out of date"
  dsp apply

  fx_hypr_links card1
  dsp_health
  dsp_row "igpu, links installed, session started without the pin" hypr.order warn "not applied"
  dsp_row "  ...the file now pins the order, so it is out of date until applied" hypr.session_env warn "out of date"
  echo "DEBUG from aquamarine ]: drm: Explicit device list /dev/dri/omarchy-egpu-primary:/dev/dri/omarchy-egpu-external" >>"$log"
  dsp_health
  dsp_row "igpu, but the session was started with the eGPU in the list" hypr.order warn "started with the eGPU"
  dsp_row "  ...links ok" hypr.links ok

  rm -f -- "$FX_ROOT/dev/dri/omarchy-egpu-primary" "$FX_ROOT/dev/dri/omarchy-egpu-external"
  echo "DEBUG from aquamarine ]: drm: gpu /dev/dri/card0 becomes primary drm" >"$log"
  dsp_config '{"display":{"policy":"egpu-hdmi"}}'
  dsp_health
  dsp_row "egpu-hdmi, no links" hypr.links warn
  dsp_row "egpu-hdmi, order not pinned" hypr.order warn "not pinned"

  echo "DEBUG from aquamarine ]: drm: gpu /dev/dri/card1 becomes primary drm" >"$log"
  dsp_health
  dsp_row "the eGPU became primary" hypr.order error
}

# The generator is the only writer of the toggle file.
dsp_test_only_writer() {
  echo "${BOLD}display: the generator is the only writer${RESET}"
  local hits
  hits=$(grep -rlF 'zz-omarchy-egpu' "$REPO/lib" "$REPO/bin" | sed "s|^$REPO/||" | sort | paste -sd' ')
  if [[ $hits == lib/display.sh ]]; then ok "only lib/display.sh names the toggle file"; else bad "the toggle file is named in: $hits"; fi
  if awk '
      /^_dsp_commit\(\) \{/ { inside = 1 }
      inside && /^\}/ { inside = 0 }
      /"\$DSP_TOGGLE"/ && /(write_atomic|rm -f|cp |mv |chmod|>)/ && !/cmp -s|cp -- "\$DSP_TOGGLE"/ && !inside { bad = 1; print FILENAME ":" NR ": " $0 }
      END { exit bad }' "$REPO/lib/display.sh" >"$WORK/writers.txt"; then
    ok "every write to it is inside _dsp_commit"
  else
    bad "writes outside _dsp_commit: $(head -c 300 "$WORK/writers.txt")"
  fi
}

test_display() {
  (dsp_test_golden)
  (dsp_test_values)
  (dsp_test_links)
  (dsp_test_commit)
  (dsp_test_list_off)
  (dsp_test_enable_disable)
  (dsp_test_set)
  (dsp_test_unsafe)
  (dsp_test_collision)
  (dsp_test_policy)
  (dsp_test_no_compositor_busy)
  (dsp_test_health)
  dsp_test_only_writer
}
