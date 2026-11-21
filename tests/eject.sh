# shellcheck shell=bash
# tests/eject.sh — gate E5 of plan-engine.md §12, the part fakes can settle:
# `device eject`, `device rescan` and `device holders`. Sourced by
# tests/run.sh (after tests/device.sh and tests/display.sh, whose helpers it
# uses); `tests/run.sh eject` runs only these.
#
# The root helper here is the REAL system/omarchy-egpu-admin, unprivileged in
# its test mode (OMARCHY_EGPU_ADMIN_TEST_ROOT = the fixture), behind the fake
# pkexec: remove, unload, holders and rescan run their own checks against the
# fixture tree. The fixture plays the rest:
#   ej_kernel       each function's `remove` attribute is a FIFO; writing 1
#                   removes the function (and, for the GPU, its card node and
#                   by-path link), as the kernel does. ej_kernel_hang leaves
#                   the GPU's FIFO unread: a remove that never returns.
#   ej_rescan_kernel  /sys/bus/pci/rescan likewise brings the card back
#   ej_app          a REAL process (so SIGTERM is real) with a matching
#                   /proc/<pid> in the fixture (comm, uid, environ, fds on
#                   /dev/nvidia*) and, with memory, an nvidia-smi entry. On
#                   SIGTERM it removes both and exits, as an app quitting
#                   would; `stubborn` ignores SIGTERM.
# Nothing reaches real hardware, sudo, a real pkexec, the running Hyprland or
# the real toggle file (display tests' guard applies: HOME is the scenario's).

EJ_BDF=0000:03:00.0

# ej_new <name> [display policy]: a fresh scenario in the current (sub)shell.
ej_new() {
  setup_scenario "eject-$1" "$TESTS/fixtures/device/machine" || exit 1
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  mkdir -p -- "$EGPU_RUN" "$FX_ROOT/run"
  export EGPU_POLL_S=0.05 EGPU_CONNECT_GRACE_S=1 EGPU_SMI_TIMEOUT=2 EJ_DEADLINE=3
  if [[ $(realpath -m -- "$HOME") != "$(realpath -- "$WORK")"/* || $(type -P hyprctl) != "$T/bin/hyprctl" ]]; then
    bad "eject-$1: HOME or hyprctl outside the test dir; refusing to run"
    exit 1
  fi
  [[ -n ${2:-} ]] && printf '{"display":{"policy":"%s"}}\n' "$2" >"$EGPU_CONFIG"
  # The real helper, in test mode, as the fake pkexec would run it.
  mkdir -p -- "$(dirname -- "$EGPU_ADMIN")"
  cat >"$EGPU_ADMIN" <<EOF
#!/bin/bash
printf 'admin %s\n' "\$*" >>"\$EGPU_FAKE_LOG"
OMARCHY_EGPU_ADMIN_TEST_ROOT="\$FX_ROOT" OMARCHY_EGPU_ADMIN_TEST_DEADLINE="\${EJ_DEADLINE:-3}" exec "$REPO/system/omarchy-egpu-admin" "\$@"
EOF
  chmod +x "$EGPU_ADMIN"
  : >"$EGPU_FAKE_DIR/apps"
}

# Background helpers die with the test. Apps get SIGKILL: a stubborn one
# ignores SIGTERM (it is the test's to end, never the engine's).
ej_done() {
  local p
  if [[ -r $EGPU_FAKE_DIR/apps ]]; then
    while IFS= read -r p; do [[ -n $p ]] && kill -KILL "$p" 2>/dev/null; done <"$EGPU_FAKE_DIR/apps"
  fi
  dv_done
  sleep 0.2
}

# ej_kernel: the remove attributes of the slot become FIFOs the "kernel" reads.
ej_kernel() {
  local f d
  for f in "$EJ_BDF" 0000:03:00.1; do
    d=$FX_PCI/$f
    [[ -d $d ]] || continue
    rm -f -- "$d/remove"
    mkfifo -- "$d/remove"
    (
      IFS= read -r x <"$d/remove"
      [[ $x == 1 ]] || exit 0
      if [[ $f == "$EJ_BDF" ]]; then
        fx_drm_remove "$EJ_BDF" card1
        rm -f -- "$EGPU_FAKE_DIR/smi.csv"
      fi
      rm -rf -- "$d"
      # kernel-reload-modules: something loads the stack again once the card
      # is gone (udev, a service); -stuck: and it cannot be unloaded again.
      if [[ $f == "$EJ_BDF" && -e $EGPU_FAKE_DIR/kernel-reload-modules ]]; then
        fx_nvidia_modules
        [[ -e $EGPU_FAKE_DIR/kernel-reload-stuck ]] && echo nvidia_uvm >"$EGPU_FAKE_DIR/modprobe-fail"
      fi
    ) >/dev/null 2>&1 &
    fx_bg $!
  done
}

# The GPU's remove never returns (nobody reads the FIFO); the audio one does.
ej_kernel_hang() {
  ej_kernel
  local d=$FX_PCI/$EJ_BDF
  # Replace the GPU's reader: a fresh FIFO no one opens.
  rm -f -- "$d/remove"
  mkfifo -- "$d/remove"
}

# ej_rescan_kernel: writing 1 to /sys/bus/pci/rescan brings the card back
# (unbound; dv_autoload binds it).
ej_rescan_kernel() {
  local r=$FX_ROOT/sys/bus/pci/rescan
  rm -f -- "$r"
  mkfifo -- "$r"
  (
    IFS= read -r x <"$r"
    [[ $x == 1 ]] && fx_egpu_nvidia none
    rm -f -- "$r"
    : >"$r"
  ) >/dev/null 2>&1 &
  fx_bg $!
}

# The eGPU ready, its slot removable through ej_kernel.
ej_ready() {
  dv_ready
  ej_kernel
}

# ej_proc <pid> <comm> [uid] [node…]: a /proc entry in the fixture.
ej_proc() {
  local pid=$1 comm=$2 uid=${3:-$UID} i=3 n
  shift 3 2>/dev/null || shift $#
  mkdir -p -- "$FX_ROOT/proc/$pid/fd"
  printf '%s\n' "$comm" >"$FX_ROOT/proc/$pid/comm"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" >"$FX_ROOT/proc/$pid/status"
  for n in "$@"; do ln -sfn "$n" "$FX_ROOT/proc/$pid/fd/$i"; i=$((i + 1)); done
}

# ej_app <comm> <mem MiB|-> <term|stubborn> [nodes|-] [KEY=VALUE…]
# A real background process standing for an app; its pid in EJ_PID.
ej_app() {
  local comm=$1 mem=$2 mode=$3 nodes=${4:--} pid
  shift 4 2>/dev/null || shift $#
  # shellcheck disable=SC2016  # the child expands these
  bash -c '
    me=$$
    quit() {
      rm -rf -- "$FX_ROOT/proc/$me"
      f=$EGPU_FAKE_DIR/smi-pids.txt
      if [ -f "$f" ]; then
        flock "$f.lock" sh -c "awk -v p=$me '\''{ b = b \$0 \"\\n\"; n++ } n == 6 { if (b !~ (\"Process ID[ ]+: \" p \"\\n\")) printf \"%s\", b; b = \"\"; n = 0 }'\'' \"$f\" >\"$f.tmp\" && mv -f \"$f.tmp\" \"$f\""
      fi
      exit 0
    }
    if [ "$1" = stubborn ]; then trap "" TERM; else trap quit TERM; fi
    while :; do sleep 0.1; done
  ' _ "$mode" >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null
  echo "$pid" >>"$EGPU_FAKE_DIR/apps"
  if [[ $nodes == - ]]; then
    ej_proc "$pid" "$comm" "$UID"
  else
    # shellcheck disable=SC2086  # a space-separated node list
    ej_proc "$pid" "$comm" "$UID" $nodes
  fi
  if (( $# )); then
    printf '%s\0' "$@" >"$FX_ROOT/proc/$pid/environ"
  else
    printf 'HOME=%s\0' "$HOME" >"$FX_ROOT/proc/$pid/environ"
  fi
  [[ $mem != - ]] && fx_gpu_proc "$pid" G "$comm" "$mem"
  EJ_PID=$pid
}

# ej_world_tv: the LG TV on the eGPU's HDMI-A-2, lit by Hyprland (eGPU present
# at login, policy egpu-hdmi); workspace 1 on the laptop, 2 and 3 on the TV.
# The fake hyprctl mirrors the TV's on/off into the connector's sysfs `enabled`.
ej_world_tv() {
  fx_egpu_nvidia nvidia connected:enabled
  ln -sfn /dev/dri/card1 "$FX_ROOT/proc/1217/fd/20"
  dsp_monitors "$(dsp_mon 0 eDP-1 'Samsung Display Corp.' 0x41AA '' 2880x1800@120.00 0 0 1.6)" \
    "$(dsp_mon 1 HDMI-A-2 'LG Electronics' 'LG TV SSCR2' 0x01010101 3840x2160@60.00 1800 0 1.6)"
  dsp_workspaces 1:eDP-1:0 2:HDMI-A-2:1 3:HDMI-A-2:1
  jq -cn --arg d "$DSP_TV" --arg p "$FX_PCI/$EJ_BDF/drm/card1/card1-HDMI-A-2" '{($d): $p}' >"$EGPU_FAKE_DIR/hypr/sysfs.json"
}

# ej <args>: `omarchy-egpu device eject <args>`; $T/out.json, $T/err, DV_RC, DV_MS.
ej() {
  local t0
  t0=$(date +%s%3N)
  "$ENGINE" device eject "$@" >"$T/out.json" 2>"$T/err"
  DV_RC=$?
  DV_MS=$(( $(date +%s%3N) - t0 ))
}

ej_rescan() {
  "$ENGINE" device rescan "$@" >"$T/out.json" 2>"$T/err"
  DV_RC=$?
}

ej_alive() { kill -0 "$1" 2>/dev/null; }
ej_line() { grep -nE -- "$1" "$EGPU_FAKE_LOG" | head -n1 | cut -d: -f1; }

# ---------------------------------------------------------------- tests

ej_test_clean() {
  echo "${BOLD}eject: clean (igpu policy, no apps)${RESET}"
  ej_new clean
  ej_ready
  ej
  dv_check "exit 0, phase ejected, not already" '.ok == true and .phase == "ejected" and .already == false'
  (( DV_RC == 0 )) || bad "clean eject exit $DV_RC"
  dv_check "both functions removed" ".removed == [\"0000:03:00.1\", \"$EJ_BDF\"]"
  dv_check "nothing held: modules unloaded through the helper" \
    '.modules.held_after_eject == false and .modules.unloaded == true and .modules.held_by == []'
  dv_check "igpu policy: no eGPU monitor, the display was left alone" '.display.policy == "igpu" and .display.off == []'
  dv_assert "exactly: holders, unload nvidia, remove <bdf> through pkexec (unload BEFORE remove)" \
    test "$(grep '^pkexec' "$EGPU_FAKE_LOG" | sed "s|$EGPU_ADMIN|H|" | paste -sd'|')" = \
    "pkexec H holders|pkexec H unload nvidia|pkexec H remove $EJ_BDF"
  dv_assert "the modules were unloaded in the reverse load order, before the remove was asked" \
    bash -c "[ \"\$(grep '^modprobe' '$EGPU_FAKE_LOG' | paste -sd'|')\" = 'modprobe -r -- nvidia_uvm|modprobe -r -- nvidia_drm|modprobe -r -- nvidia_modeset|modprobe -r -- nvidia' ] &&
      [ \"\$(grep -n '^modprobe -r -- nvidia\$' '$EGPU_FAKE_LOG' | cut -d: -f1)\" -lt \"\$(grep -n 'pkexec .* remove $EJ_BDF' '$EGPU_FAKE_LOG' | cut -d: -f1)\" ]"
  dv_assert "no hyprctl eval and no toggle file written" \
    bash -c "! grep -q '^hyprctl eval' '$EGPU_FAKE_LOG' && [ ! -e '$HOME/.local/state/omarchy/toggles/hypr/zz-omarchy-egpu.lua' ]"
  dv_assert "the modules are gone (fake modprobe -r)" test ! -e "$FX_ROOT/sys/module/nvidia"
  dv_assert "the marker names the enclosure" \
    bash -c "jq -e '.uuid == \"$FX_DEG2_UUID\" and .bdf == \"$EJ_BDF\"' '$EGPU_RUN/ejected' >/dev/null"
  dv_assert "lock released, no job left" dv_unlocked
  dv_assert "status: ejected, safe_to_unplug" \
    bash -c "'$ENGINE' status --json | jq -e '.phase == \"ejected\" and .summary.state == \"safe_to_unplug\" and .modules.held_after_eject == false' >/dev/null"
  dv_assert "\"Safe to unplug\" notification" dv_log_has '^notify-send .*Safe to unplug the eGPU'

  # Idempotent.
  : >"$EGPU_FAKE_LOG"
  ej --quiet
  dv_check "eject again: exit 0, already, phase ejected" '.ok == true and .already == true and .phase == "ejected"'
  (( DV_RC == 0 )) || bad "second eject exit $DV_RC"
  dv_assert "…and nothing ran: no pkexec, no hyprctl eval" bash -c "! grep -qE '^(pkexec|hyprctl eval)' '$EGPU_FAKE_LOG'"

  # Unplugged: the marker belongs to that connection only.
  fx_deg2 disconnected true
  dv_assert "unplugged: phase absent, the marker dropped" \
    bash -c "[ \"\$('$ENGINE' status --json | jq -r .phase)\" = absent ] && [ ! -e '$EGPU_RUN/ejected' ]"
  ej --quiet
  dv_error "eject with nothing connected" not_connected
  ej --force
  dv_error "--force does not exist" usage
  ej_done
}

ej_test_hdmi() {
  echo "${BOLD}eject: egpu-hdmi, the TV on the eGPU is turned off first${RESET}"
  ej_new hdmi egpu-hdmi
  ej_ready
  ej_world_tv
  ej --quiet
  dv_check "exit 0, ejected" '.ok == true and .phase == "ejected"'
  dv_check "the TV was turned off and its workspaces moved" \
    ".display.policy == \"egpu-hdmi\" and .display.off[0].description == \"$DSP_TV\" and .display.still_on == []
     and .display.workspaces[0].moved == [2, 3]"
  dv_assert "workspaces 2 and 3 are on the laptop panel" test "$(dsp_ws_monitor 2)|$(dsp_ws_monitor 3)" = "eDP-1|eDP-1"
  local ws ev rm
  ws=$(ej_line 'hyprctl dispatch hl.dsp.workspace.move')
  ev=$(ej_line 'hyprctl eval hl.monitor.*disabled = true')
  rm=$(ej_line "^pkexec .* remove $EJ_BDF")
  if [[ -n $ws && -n $ev && -n $rm ]] && (( ws < ev && ev < rm )); then
    ok "order: workspaces moved, then the monitor disabled, then pkexec … remove (log lines $ws < $ev < $rm)"
  else
    bad "order: move $ws, disable $ev, remove $rm"
  fi
  dv_assert "the kernel's view agreed before the remove (connector disabled)" \
    bash -c "! grep -q '^pkexec .* remove' '$EGPU_FAKE_LOG' || [ ! -d '$FX_PCI/$EJ_BDF' ]"
  dv_assert "the toggle file records the TV as disabled" \
    grep -qF "hl.monitor({ output = \"desc:$DSP_TV\", disabled = true })" "$HOME/.local/state/omarchy/toggles/hypr/zz-omarchy-egpu.lua"
  dv_check "the compositor holding the card did not block, and was not signalled" '.closed == []'
  ej_done

  echo "${BOLD}eject: the monitor will not turn off (hdmi_still_active)${RESET}"
  ej_new hdmi-stuck egpu-hdmi
  ej_ready
  ej_world_tv
  touch "$EGPU_FAKE_DIR/hypr/eval-ignore"
  ej --quiet
  dv_error "the TV stays on" hdmi_still_active
  dv_check "names it" ".monitors == [\"$DSP_TV\"]"
  dv_check "the error names the phase the card is left in (ready)" '.phase == "ready"'
  dv_assert "nothing was removed or unloaded (the read-only holders check ran first)" bash -c "! grep -qE '^pkexec .* (unload|remove|load) ' '$EGPU_FAKE_LOG'"
  dv_assert "no marker, lock released, phase ready" \
    bash -c "[ ! -e '$EGPU_RUN/ejected' ] && [ \"\$('$ENGINE' status --json | jq -r .phase)\" = ready ]"
  ej_done

  echo "${BOLD}eject: igpu policy, but the kernel still lights the eGPU's port (console)${RESET}"
  ej_new console-lit
  ej_ready
  fx_egpu_nvidia nvidia connected:enabled
  ej --quiet
  dv_error "Hyprland lists nothing, the connector is enabled" hdmi_still_active
  dv_check "names the connector, not a Hyprland monitor" '.connectors == ["card1-HDMI-A-2"] and .monitors == []'
  dv_assert "nothing removed, the display untouched" bash -c "! grep -qE '^(pkexec .* remove|hyprctl eval)' '$EGPU_FAKE_LOG'"
  ej_done
}

ej_test_holders() {
  echo "${BOLD}eject: a real GPU user blocks; --close asks it to quit${RESET}"
  ej_new app
  ej_ready
  ej_app vkcube 120 term "/dev/nvidia0 /dev/nvidiactl"
  local app=$EJ_PID
  fx_modules nvidia
  echo 1 >"$FX_ROOT/sys/module/nvidia/refcnt"
  ej --quiet
  dv_error "without --close" holders_present
  dv_check "lists vkcube as a closeable app with its GPU memory" \
    "[.holders[] | {pid, comm, role, why, closeable, gpu_mem_mb}] == [{pid: $app, comm: \"vkcube\", role: \"app\", why: \"gpu_memory\", closeable: true, gpu_mem_mb: 120}]
     and .can_close == true"
  dv_assert "vkcube is still running (nothing signalled without --close)" ej_alive "$app"
  dv_assert "nothing removed" bash -c "! grep -q 'remove $EJ_BDF' '$EGPU_FAKE_LOG'"
  dv_assert "phase back to ready, no marker" \
    bash -c "[ ! -e '$EGPU_RUN/ejected' ] && [ \"\$('$ENGINE' status --json | jq -r .phase)\" = ready ]"
  echo 0 >"$FX_ROOT/sys/module/nvidia/refcnt"
  ej --quiet --close
  dv_check "--close: exit 0, ejected, vkcube closed" ".ok == true and .phase == \"ejected\" and .closed == [{pid: $app, comm: \"vkcube\"}]"
  sleep 0.2
  dv_assert "vkcube got SIGTERM and quit" bash -c "! kill -0 $app 2>/dev/null"
  ej_done

  echo "${BOLD}eject: --close, and the app ignores SIGTERM (timeout)${RESET}"
  ej_new stubborn
  ej_ready
  echo '{"eject":{"close_timeout_s":1}}' >"$EGPU_CONFIG"
  ej_app game 900 stubborn "/dev/nvidia0"
  local stub=$EJ_PID
  ej_app helperapp 40 term "/dev/nvidia0"
  local polite=$EJ_PID
  ej --quiet --close
  dv_error "a survivor" holders_present
  dv_check "it is named as the survivor; the polite one as closed; timed out after close_timeout_s" \
    ".timed_out == true and .close_timeout_s == 1 and .survivors == [{pid: $stub, comm: \"game\"}] and .closed == [{pid: $polite, comm: \"helperapp\"}]"
  if (( DV_MS >= 1000 && DV_MS < 6000 )); then ok "waited the close timeout, then stopped (${DV_MS} ms)"; else bad "close timeout took ${DV_MS} ms"; fi
  dv_assert "the survivor was not killed (no SIGKILL, ever)" ej_alive "$stub"
  dv_assert "nothing removed, no marker" bash -c "! grep -q 'remove $EJ_BDF' '$EGPU_FAKE_LOG' && [ ! -e '$EGPU_RUN/ejected' ]"
  ej_done

  echo "${BOLD}eject: Steam game and egpu-run app with no GPU memory still count${RESET}"
  ej_new offload
  ej_ready
  ej_app reaper - term - OMARCHY_EGPU=1 __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only SteamAppId=1234
  local game=$EJ_PID
  ej_app glxgears - term "/dev/nvidiactl" __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
  local glx=$EJ_PID
  ej_app terminal - term - __NV_PRIME_RENDER_OFFLOAD=1
  ej --quiet
  dv_error "the Steam game and the offloaded app" holders_present
  dv_check "why: steam (the managed marker) and offload (the egpu-run set); a lone PRIME variable is not enough" \
    "[.holders[] | {pid, why}] == ([{pid: $game, why: \"steam\"}, {pid: $glx, why: \"offload\"}] | sort_by(.pid))"
  ej --quiet --close
  dv_check "--close: both closed, ejected" ".ok == true and (.closed | map(.pid) | sort) == ([$game, $glx] | sort)"
  ej_done

  echo "${BOLD}eject: the shell with memory on the card blocks, and is never signalled${RESET}"
  ej_new shell-mem
  ej_ready
  ej_app quickshell 900 term "/dev/nvidia0"
  local qs=$EJ_PID
  ej --quiet --close
  dv_error "quickshell with 900 MiB" holders_present
  dv_check "role shell, not closeable, --close cannot help" \
    "[.holders[] | {pid, role, closeable}] == [{pid: $qs, role: \"shell\", closeable: false}] and .can_close == false"
  dv_assert "quickshell was not signalled" ej_alive "$qs"
  ej_done
}

# 0.1.1: the driver is unloaded BEFORE the remove, and a driver that cannot be
# unloaded aborts the eject with the card still attached (docs/plan-engine.md
# §6.3, DECISION 2026-11-21): a removed GPU with the modules left loaded
# oopses the next suspend.
ej_test_unload() {
  echo "${BOLD}eject: incidental holders keep the driver loaded: aborted, nothing removed${RESET}"
  ej_new incidental
  ej_ready
  ej_proc 7001 quickshell "$UID" /dev/nvidia0 /dev/nvidiactl
  ej_proc 7002 voxtype-osd-gtk "$UID" /dev/nvidia0
  ej_proc 7003 nvidia-persiste 0 /dev/nvidiactl
  echo 12 >"$FX_ROOT/sys/module/nvidia/refcnt"
  ej --quiet
  dv_error "the modules are held" driver_in_use
  dv_check "names the holders, every role, sorted" \
    '.names == ["nvidia-persiste", "quickshell", "voxtype-osd-gtk"]
     and ([.holders[] | {comm, role}] | sort_by(.comm)) == [{comm: "nvidia-persiste", role: "incidental"}, {comm: "quickshell", role: "shell"}, {comm: "voxtype-osd-gtk", role: "incidental"}]'
  dv_check "names the busy module and its references; the session holds it, --close cannot help" \
    '.modules == [{module: "nvidia", refcnt: 12, expected: 0, foreign: []}] and .session_holds == true and .can_close == false and .closed == []'
  dv_check "the sentence names them, says the eGPU is left attached, and what to do" \
    '.detail | test("nvidia-persiste, quickshell, voxtype-osd-gtk") and test("left attached") and test("log out")'
  dv_check "the error names the phase the card is left in (ready) and carries the display" '.phase == "ready" and (.display | has("policy"))'
  dv_assert "the unload was not even asked for (the engine read the refcounts first), nothing removed" \
    bash -c "! grep -qE 'unload|remove|^modprobe' '$EGPU_FAKE_LOG'"
  dv_assert "the card is still on the bus and still bound" test -d "$FX_PCI/$EJ_BDF" -a -L "$FX_PCI/$EJ_BDF/driver"
  dv_assert "the modules are all still loaded" test -d "$FX_ROOT/sys/module/nvidia_uvm" -a -d "$FX_ROOT/sys/module/nvidia"
  dv_assert "no ejected marker; status: ready, not safe_to_unplug, no held_after_eject" \
    bash -c "[ ! -e '$EGPU_RUN/ejected' ] && '$ENGINE' status --json | jq -e '.phase == \"ready\" and .summary.state != \"safe_to_unplug\" and .modules.held_after_eject == false' >/dev/null"
  dv_assert "no \"Safe to unplug\" notification, lock released, no job left" \
    bash -c "! grep -q 'Safe to unplug' '$EGPU_FAKE_LOG' && [ ! -e '$EGPU_RUN/job' ]"
  dv_assert "nothing was signalled: every holder's /proc entry is still there" test -d "$FX_ROOT/proc/7001" -a -d "$FX_ROOT/proc/7002" -a -d "$FX_ROOT/proc/7003"
  ej --quiet --close
  dv_error "--close changes nothing here: it only closes apps (none), never the shell or a root service" driver_in_use
  # The holders let go: the same eject now goes through, unloading first.
  rm -rf -- "${FX_ROOT:?}/proc/7001" "${FX_ROOT:?}/proc/7002" "${FX_ROOT:?}/proc/7003"
  echo 0 >"$FX_ROOT/sys/module/nvidia/refcnt"
  : >"$EGPU_FAKE_LOG"
  ej --quiet
  dv_check "once nothing holds the driver the eject goes through: unloaded, then removed" \
    '.ok == true and .phase == "ejected" and .modules == {held_after_eject: false, held_by: [], unloaded: true, unload: {ok: true, backend: "nvidia", unloaded: ["nvidia_uvm","nvidia_drm","nvidia_modeset","nvidia"], rc: 0}}'
  ej_done

  echo "${BOLD}eject: references with no process to name, and a holder that is a foreign module${RESET}"
  ej_new refs
  ej_ready
  echo 3 >"$FX_ROOT/sys/module/nvidia_drm/refcnt"
  ej --quiet
  dv_error "nvidia_drm has 3 references and no holder" driver_in_use
  dv_check "no process to name; the module is named; the sentence says the kernel still counts references" \
    '.names == [] and .modules == [{module: "nvidia_drm", refcnt: 3, expected: 0, foreign: []}] and (.detail | test("kernel still counts"))'
  echo 0 >"$FX_ROOT/sys/module/nvidia_drm/refcnt"
  mkdir -p "$FX_ROOT/sys/module/nvidia/holders"
  : >"$FX_ROOT/sys/module/nvidia/holders/nvidia_peermem"
  echo 1 >"$FX_ROOT/sys/module/nvidia/refcnt"
  ej --quiet
  dv_error "a module outside the stack holds nvidia" driver_in_use
  dv_check "named as foreign" '.modules == [{module: "nvidia", refcnt: 1, expected: 1, foreign: ["nvidia_peermem"]}]'
  dv_assert "nothing removed, nothing unloaded" bash -c "! grep -qE 'unload|remove|^modprobe' '$EGPU_FAKE_LOG'"
  ej_done

  echo "${BOLD}eject: another NVIDIA GPU in the machine shares the driver${RESET}"
  ej_new shared
  ej_ready
  fx_pci 0000:01:00.0 0x030200 0x10de 0x28e0 boot_vga=0
  ej --quiet
  dv_error "the helper refuses to unload under the laptop's own NVIDIA GPU" driver_in_use
  dv_check "says it is shared; the helper's answer is attached" \
    '.shared_driver == true and .helper.error == "device_present" and (.detail | test("shared with another NVIDIA GPU"))'
  dv_assert "nothing removed, the eGPU attached, no modprobe, no marker" \
    bash -c "! grep -qE 'remove|^modprobe' '$EGPU_FAKE_LOG' && [ -d '$FX_PCI/$EJ_BDF' ] && [ ! -e '$EGPU_RUN/ejected' ]"
  ej_done

  echo "${BOLD}eject: the unload fails half way: the stack is put back${RESET}"
  ej_new partial
  ej_ready
  echo nvidia_modeset >"$EGPU_FAKE_DIR/modprobe-fail"
  ej --quiet
  dv_error "nvidia_modeset will not unload (after nvidia_uvm and nvidia_drm did)" driver_in_use
  dv_check "the helper's answer lists what went" '.helper.error == "modules_failed" and .helper.module == "nvidia_modeset" and .helper.unloaded == ["nvidia_uvm","nvidia_drm"]'
  dv_assert "the engine asked the helper to load the driver again, nothing was removed" \
    bash -c "grep -q 'pkexec .* load nvidia' '$EGPU_FAKE_LOG' && ! grep -q 'remove' '$EGPU_FAKE_LOG'"
  dv_assert "all four modules are loaded again, the card attached, no marker" \
    bash -c "for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do [ -d \"$FX_ROOT/sys/module/\$m\" ] || exit 1; done; [ -d '$FX_PCI/$EJ_BDF' ] && [ ! -e '$EGPU_RUN/ejected' ]"
  ej_done

  echo "${BOLD}eject: the remove fails after the unload: the driver is put back${RESET}"
  ej_new remove-fails
  ej_ready
  # No kernel stand-in: the slot's functions have no `remove` attribute.
  rm -f -- "${FX_PCI:?}/${EJ_BDF:?}/remove" "${FX_PCI:?}/0000:03:00.1/remove"
  ej --quiet
  dv_error "the helper cannot remove (no remove attribute)" remove_failed
  dv_assert "unload ran first, then remove, then the driver was loaded again" \
    bash -c "[ \"\$(grep '^pkexec' '$EGPU_FAKE_LOG' | sed 's|$EGPU_ADMIN|H|' | paste -sd'|')\" = 'pkexec H holders|pkexec H unload nvidia|pkexec H remove $EJ_BDF|pkexec H load nvidia' ]"
  dv_assert "the modules are loaded again, no marker, the card attached" \
    bash -c "[ -d '$FX_ROOT/sys/module/nvidia_uvm' ] && [ -d '$FX_PCI/$EJ_BDF' ] && [ ! -e '$EGPU_RUN/ejected' ]"
  ej_done

  echo "${BOLD}eject: the remove hangs after the unload: nothing more is touched${RESET}"
  ej_new remove-hangs
  ej_ready
  ej_kernel_hang
  EJ_DEADLINE=2 ej
  dv_error "remove never returns" remove_timeout
  dv_assert "the driver was NOT loaded again (the card is in an unknown state): no load call" \
    bash -c "! grep -q 'pkexec .* load' '$EGPU_FAKE_LOG'"
  dv_assert "\"Do not unplug\" notification, no marker" bash -c "grep -q '^notify-send .*Do not unplug the eGPU' '$EGPU_FAKE_LOG' && [ ! -e '$EGPU_RUN/ejected' ]"
  ej_done

  echo "${BOLD}eject: modules that were never loaded (nothing to unload)${RESET}"
  ej_new no-modules
  ej_ready
  fx_modules_remove nvidia nvidia_modeset nvidia_drm nvidia_uvm
  ej --quiet
  dv_check "ejected; no unload asked for; unloaded false" '.ok == true and .modules.unloaded == false and .modules.unload == null and .modules.held_after_eject == false'
  dv_assert "no unload call" bash -c "! grep -q unload '$EGPU_FAKE_LOG'"
  ej_done

  echo "${BOLD}eject: already ejected; unsupported backend${RESET}"
  ej_new already
  ej_ready
  ej --quiet
  dv_check "ejected" '.ok == true and .already == false'
  : >"$EGPU_FAKE_LOG"
  ej --quiet
  dv_check "again: already, nothing touched" '.ok == true and .already == true and .bdf == null and .modules.held_after_eject == false'
  dv_assert "no pkexec, no modprobe" bash -c "! grep -qE '^(pkexec|modprobe)' '$EGPU_FAKE_LOG'"
  ej_done
  ej_new stub
  fx_bolt aaaaaaaa-0000-0000-0000-000000000002 "Razer" "Core X" authorized true iommu
  fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0 driver=amdgpu
  fx_modules amdgpu
  ej --quiet
  dv_error "an AMD eGPU: the backend is a stub" backend_stub
  dv_assert "nothing unloaded, nothing removed" bash -c "! grep -qE '^(pkexec|modprobe)' '$EGPU_FAKE_LOG'"
  ej_done

  echo "${BOLD}eject: a cable pull leaves the driver loaded; rescan refuses (modules_held)${RESET}"
  ej_new pulled
  ej_ready
  fx_egpu_unplug
  dv_assert "status: modules loaded with no card is held_after_eject (the sleep guard's case)" \
    bash -c "'$ENGINE' status --json | jq -e '.modules.held_after_eject == true' >/dev/null"
  ej_rescan --quiet
  dv_error "rescan after a pull, modules still loaded" modules_held
  dv_assert "...refused before pkexec" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  ej_done
}


# S2: the monitors are not turned off for an eject that cannot succeed, and are
# turned back on when it fails after they were.
ej_test_display_safety() {
  local tv_log=$HOME/.local/state/omarchy/toggles/hypr/zz-omarchy-egpu.lua
  echo "${BOLD}eject: only the session holds the driver: driver_in_use BEFORE any monitor is touched${RESET}"
  ej_new tv-incidental egpu-hdmi
  ej_ready
  ej_world_tv
  ej_proc 7001 quickshell "$UID" /dev/nvidia0 /dev/nvidiactl
  ej_proc 7002 voxtype-osd-gtk "$UID" /dev/nvidia0
  echo 12 >"$FX_ROOT/sys/module/nvidia/refcnt"
  local toggle_before
  toggle_before=$(cksum <"$tv_log" 2>/dev/null || echo absent)
  ej --quiet
  dv_error "the shell and an incidental holder keep the modules" driver_in_use
  dv_check "the display was not touched: nothing off, nothing moved" '.display.touched == false and .display.off == [] and .display.workspaces == [] and (.display | has("restored") | not)'
  dv_assert "the TV is still on, its workspaces still on it" \
    test "$(dsp_mon_field "$DSP_TV" .disabled)|$(dsp_ws_monitor 2)|$(dsp_ws_monitor 3)" = "false|HDMI-A-2|HDMI-A-2"
  dv_assert "no hyprctl eval or dispatch, and the toggle file is as it was" \
    bash -c "! grep -qE '^hyprctl (eval|dispatch)' '$EGPU_FAKE_LOG' && [ \"\$(cksum <'$tv_log' 2>/dev/null || echo absent)\" = '$toggle_before' ]"
  dv_assert "only the read-only holders call went to the helper" \
    test "$(grep '^pkexec' "$EGPU_FAKE_LOG" | sed "s|$EGPU_ADMIN|H|" | paste -sd'|')" = "pkexec H holders"
  ej_done

  echo "${BOLD}eject: the apps are closed, then the driver turns out to be held: the monitors come back${RESET}"
  ej_new tv-late egpu-hdmi
  ej_ready
  ej_world_tv
  ej_app glxgears 300 term "/dev/nvidiactl"
  echo 3 >"$FX_ROOT/sys/module/nvidia_drm/refcnt"
  ej --quiet --close
  dv_error "the app quits, the kernel still counts references" driver_in_use
  dv_check "the TV went off and came back: restored, none left off" \
    ".display.off[0].description == \"$DSP_TV\" and .display.restored == [\"$DSP_TV\"] and .display.restore_failed == []"
  dv_assert "the TV is on again; its workspaces stay on the laptop panel" \
    test "$(dsp_mon_field "$DSP_TV" .disabled)|$(dsp_ws_monitor 2)|$(dsp_ws_monitor 3)" = "false|eDP-1|eDP-1"
  local off on
  off=$(ej_line 'hyprctl eval hl.monitor.*disabled = true')
  on=$(ej_line 'hyprctl eval hl.monitor.*desc:.*LG TV.*(mode|position|scale)')
  [[ -n $off && -n $on ]] && (( off < on )) && ok "order: disabled (log line $off), then enabled again ($on)" || bad "order: off $off, on $on"
  dv_assert "nothing was unloaded or removed" bash -c "! grep -qE '^pkexec .* (unload|remove) ' '$EGPU_FAKE_LOG'"
  dv_assert "the toggle file no longer says the TV is disabled" bash -c "! grep -qF 'disabled = true' '$tv_log'"
  ej_done

  echo "${BOLD}eject: the failure after the monitors went off, and they will not come back${RESET}"
  ej_new tv-restore-fails egpu-hdmi
  ej_ready
  ej_world_tv
  echo nvidia_modeset >"$EGPU_FAKE_DIR/modprobe-fail"
  printf '%s\n' "$EGPU_FAKE_DIR/hypr/eval-ignore" >"$EGPU_FAKE_DIR/pkexec-touch-unload"
  ej --quiet
  dv_error "the unload fails half way, and the compositor ignores the enable" driver_in_use
  dv_check "named as not restored, with the TV; the answer says so" \
    ".display.restored == [] and .display.restore_failed == [\"$DSP_TV\"]"
  dv_assert "the failure was said on the terminal" grep -q 'Could not turn on' "$T/err"
  ej_done

  echo "${BOLD}eject: holders_present keeps the monitors off (the convention)${RESET}"
  ej_new tv-holders egpu-hdmi
  ej_ready
  ej_world_tv
  ej_app glxgears 300 term "/dev/nvidiactl"
  ej --quiet
  dv_error "an app with memory blocks" holders_present
  dv_check "the screens went off and the answer says so" ".display.off[0].description == \"$DSP_TV\" and (.display | has(\"restored\") | not)"
  dv_assert "the TV is still off" test "$(dsp_mon_field "$DSP_TV" .disabled)" = true
  ej_done
}

# M3 and M4: a put-back that fails is reported; modules loaded again after the
# remove get one more unload, and are never called "safe to unplug".
ej_test_late_modules() {
  echo "${BOLD}eject: the stack is put back after a partial unload, and the put-back fails${RESET}"
  ej_new load-back-fails
  ej_ready
  echo nvidia_modeset >"$EGPU_FAKE_DIR/modprobe-fail"
  echo nvidia_drm >"$EGPU_FAKE_DIR/modprobe-fail-load"
  ej --quiet
  dv_error "nvidia_modeset will not unload, nvidia_drm will not load again" driver_in_use
  dv_check "the failed restore is in the answer and in the sentence" \
    '.restore.ok == false and (.restore.error | type == "string") and (.detail | test("could not be loaded again"))'
  dv_assert "and said on the terminal" grep -q 'could not be put back' "$T/err"
  ej_done

  echo "${BOLD}eject: the remove fails after a full unload, and the put-back fails${RESET}"
  ej_new remove-load-back-fails
  ej_ready
  rm -f -- "${FX_PCI:?}/${EJ_BDF:?}/remove" "${FX_PCI:?}/0000:03:00.1/remove"
  echo nvidia_uvm >"$EGPU_FAKE_DIR/modprobe-fail-load"
  ej --quiet
  dv_error "no remove attribute, and the driver cannot be loaded again" remove_failed
  dv_check "the failed restore is in the answer" '.restore.ok == false and (.restore.error | type == "string")'
  ej_done

  echo "${BOLD}eject: a put-back that works says so (restore.ok)${RESET}"
  ej_new load-back-ok
  ej_ready
  rm -f -- "${FX_PCI:?}/${EJ_BDF:?}/remove" "${FX_PCI:?}/0000:03:00.1/remove"
  ej --quiet
  dv_error "the remove fails" remove_failed
  dv_check "restore ok" '.restore == {ok: true, rc: 0, error: null}'
  ej_done

  echo "${BOLD}eject: the driver is loaded again after the remove, and one more unload works${RESET}"
  ej_new reload-ok
  ej_ready
  touch "$EGPU_FAKE_DIR/kernel-reload-modules"
  ej
  dv_check "ejected; unloaded by the second try" '.ok == true and .phase == "ejected" and .modules.held_after_eject == false and .modules.unloaded == true and .modules.unload.ok == true'
  dv_assert "two unloads were asked for, the second after the remove" \
    bash -c "[ \"\$(grep -c 'pkexec .* unload nvidia' '$EGPU_FAKE_LOG')\" = 2 ] && [ \"\$(grep 'pkexec' '$EGPU_FAKE_LOG' | sed 's|$EGPU_ADMIN|H|' | paste -sd'|')\" = 'pkexec H holders|pkexec H unload nvidia|pkexec H remove $EJ_BDF|pkexec H unload nvidia' ]"
  dv_assert "\"Safe to unplug\" is said" dv_log_has '^notify-send .*Safe to unplug the eGPU'
  ej_done

  echo "${BOLD}eject: the driver is loaded again after the remove and will not unload: not \"safe to unplug\"${RESET}"
  ej_new reload-stuck
  ej_ready
  touch "$EGPU_FAKE_DIR/kernel-reload-modules" "$EGPU_FAKE_DIR/kernel-reload-stuck"
  ej_proc 7001 quickshell "$UID" /dev/nvidiactl
  ej
  dv_error "the modules stay loaded with no card" modules_held
  dv_check "do not suspend, log out; phase ejected; the card is gone" \
    '.do_not_suspend == true and .phase == "ejected" and .bdf == "0000:03:00.0" and (.removed | length) == 2 and (.detail | test("Do not suspend") and test("log out"))'
  dv_assert "no \"Safe to unplug\" anywhere: not on the terminal, not in a notification" \
    bash -c "! grep -q 'Safe to unplug' '$T/err' '$EGPU_FAKE_LOG' '$T/out.json'"
  dv_assert "a \"Do not suspend\" notification" dv_log_has '^notify-send .*Do not suspend the computer'
  dv_assert "the marker is there and names who holds the driver" \
    bash -c "jq -e '.bdf == \"$EJ_BDF\" and (.held_by | type == \"array\")' '$EGPU_RUN/ejected' >/dev/null"
  dv_assert "status: ejected, held_after_eject (the guard's state), not safe_to_unplug" \
    bash -c "'$ENGINE' status --json | jq -e '.phase == \"ejected\" and .modules.held_after_eject == true' >/dev/null"
  dv_assert "lock released" dv_unlocked
  ej_done
}

ej_test_failures() {
  echo "${BOLD}eject: the helper's remove times out${RESET}"
  ej_new remove-timeout
  dv_ready
  ej_kernel_hang
  EJ_DEADLINE=2 ej
  dv_error "remove never returns" remove_timeout
  dv_check "the helper's own answer is kept" '.helper.error == "remove_timeout" and .step == "remove"'
  dv_assert "no marker: status does not say safe to unplug" \
    bash -c "[ ! -e '$EGPU_RUN/ejected' ] && [ \"\$('$ENGINE' status --json | jq -r .summary.state)\" != safe_to_unplug ]"
  dv_assert "\"Do not unplug\" notification" dv_log_has '^notify-send .*Do not unplug the eGPU'
  dv_assert "lock released" dv_unlocked
  ej_done

  echo "${BOLD}eject: helper not installed${RESET}"
  ej_new helper-missing egpu-hdmi
  ej_ready
  ej_world_tv
  rm -f -- "$EGPU_ADMIN"
  ej --quiet
  dv_error "no helper" helper_missing
  dv_check "reason not_installed" '.reason == "not_installed"'
  dv_assert "refused before anything changed: no pkexec, no hyprctl eval" \
    bash -c "! grep -qE '^(pkexec|hyprctl eval)' '$EGPU_FAKE_LOG'"
  dv_assert "…the TV is still on" test "$(dsp_mon_field "$DSP_TV" .disabled)" = false
  ej_done

  echo "${BOLD}eject: the polkit prompt is declined${RESET}"
  ej_new declined
  ej_ready
  echo 126 >"$EGPU_FAKE_DIR/pkexec-rc"
  ej --quiet
  dv_error "pkexec 126 passes through" remove_failed 126
  dv_check "says declined" '.pkexec == 126'
  ej_done

  echo "${BOLD}eject: busy${RESET}"
  ej_new busy
  ej_ready
  flock "$EGPU_RUN/lock" sleep 5 &
  fx_bg $!
  sleep 0.3
  ej --quiet
  dv_error "another job holds the lock" busy 3
  ej_done
}

ej_test_rescan() {
  echo "${BOLD}rescan: an ejected card comes back without replugging${RESET}"
  ej_new rescan
  ej_ready
  ej --quiet
  dv_check "ejected first" '.ok == true and .phase == "ejected"'
  ej_rescan_kernel
  dv_autoload 0.1
  ej_rescan --quiet --timeout 5
  dv_check "exit 0, ready, rescanned, verified" '.ok == true and .phase == "ready" and .rescanned == true and .gpu.ok == true'
  (( DV_RC == 0 )) || bad "rescan exit $DV_RC"
  dv_assert "pkexec … rescan was the helper call" dv_log_has "^pkexec $EGPU_ADMIN rescan\$"
  dv_assert "the marker is gone" test ! -e "$EGPU_RUN/ejected"
  ej_rescan --quiet
  dv_check "rescan when present: already" '.ok == true and .already == true'
  ej_done

  echo "${BOLD}rescan: nothing connected${RESET}"
  ej_new rescan-absent
  ej_rescan --quiet
  dv_error "absent" not_connected
  ej_done
}

ej_test_holders_verb() {
  echo "${BOLD}device holders: read-only${RESET}"
  ej_new holders-verb
  ej_ready
  ej_app vkcube 64 term "/dev/nvidia0"
  local app=$EJ_PID
  ej_proc 7001 quickshell "$UID" /dev/nvidia0
  "$ENGINE" device holders >"$T/out.json" 2>"$T/err"
  DV_RC=$?
  dv_check "classified: vkcube blocks, quickshell does not" \
    ".bdf == \"$EJ_BDF\" and .blocking == 1 and .can_close == true
     and ([.holders[] | {pid, role, blocks}] | sort_by(.pid)) == ([{pid: $app, role: \"app\", blocks: true}, {pid: 7001, role: \"shell\", blocks: false}] | sort_by(.pid))"
  dv_assert "nothing signalled, nothing removed" bash -c "kill -0 $app && ! grep -qE 'remove|unload' '$EGPU_FAKE_LOG'"
  ej_done
}

ej_test_events() {
  echo "${BOLD}eject: events reach the watcher, once each${RESET}"
  ej_new events
  ej_ready
  ej_app vkcube 64 term "/dev/nvidia0"
  local out="$T/watch.out" wpid
  EGPU_HEARTBEAT_S=30 "$ENGINE" status watch >"$out" 2>"$T/watch.err" &
  wpid=$!
  fx_bg "$wpid"
  if ! wait_for "$out" 'map(select(.type == "status")) | length >= 1' 10; then
    bad "events: watcher did not start: $(head -c 300 "$T/watch.err")"
    ej_done
    return
  fi
  ej --quiet
  dv_error "blocked" holders_present
  if wait_for "$out" 'map(select(.type == "event" and .event == "eject_failed")) | length == 1' 5; then
    ok "eject_failed in the stream"
  else
    bad "no eject_failed: $(tail -c 400 "$out")"
  fi
  jq -e -s 'map(select(.event == "eject_failed"))[0].detail | .error == "holders_present" and .phase == "ready"' "$out" >/dev/null 2>&1 &&
    ok "eject_failed carries the error code" || bad "eject_failed detail: $(jq -c -s 'map(select(.event == "eject_failed"))' "$out")"
  ej --quiet --close
  dv_check "then ejected" '.ok == true'
  if wait_for "$out" 'map(select(.type == "event" and .event == "eject_ready")) | length == 1' 5; then
    ok "eject_ready in the stream"
  else
    bad "no eject_ready: $(tail -c 400 "$out")"
  fi
  sleep 1.5
  local seq
  seq=$(jq -r 'select(.type == "event") | .event' "$out" | grep '^eject_' | paste -sd' ')
  if [[ $seq == "eject_started eject_failed eject_started eject_ready" ]]; then
    ok "eject events once each, in order: $seq"
  else
    bad "eject events: '$seq'"
  fi
  jq -e -s 'map(select(.event == "eject_ready"))[0].detail | .held == false and .held_by == []' "$out" >/dev/null 2>&1 &&
    ok "eject_ready says held: false" || bad "eject_ready detail: $(jq -c -s 'map(select(.event == "eject_ready"))' "$out")"
  jq -e -s '[.[] | select(.type == "event" and .event == "yanked")] | length == 0' "$out" >/dev/null &&
    ok "an eject is not a yank" || bad "a yank was reported during the eject"
  jq -e '.phase == "ejected" and .summary.state == "safe_to_unplug" and .recent_events[-1].type == "eject_ready"' "$EGPU_RUN/status.json" >/dev/null 2>&1 &&
    ok "status.json: safe_to_unplug, eject_ready last" || bad "status.json: $(jq -c '{phase, last_event}' "$EGPU_RUN/status.json")"
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  ej_done
}

ej_test_cycles() {
  echo "${BOLD}eject: 10 plug → connect → use → eject → unplug → replug cycles${RESET}"
  ej_new cycles
  dv_autoload 0.1
  local i fails=0 app
  for i in $(seq 1 10); do
    fx_deg2 authorized true
    fx_egpu_nvidia none
    ej_kernel
    dv_connect --quiet --timeout 5
    jq -e '.ok == true' "$T/out.json" >/dev/null 2>&1 || { fails=$((fails + 1)); echo "      cycle $i connect: $(head -c 200 "$T/out.json")"; }
    ej_app vkcube 100 term "/dev/nvidia0"
    app=$EJ_PID
    ej --quiet
    jq -e '.error == "holders_present"' "$T/out.json" >/dev/null 2>&1 || { fails=$((fails + 1)); echo "      cycle $i first eject: $(head -c 200 "$T/out.json")"; }
    ej --quiet --close
    if (( DV_RC != 0 )) || ! jq -e '.ok == true and .modules.held_after_eject == false' "$T/out.json" >/dev/null 2>&1; then
      fails=$((fails + 1))
      echo "      cycle $i eject: rc $DV_RC $(head -c 200 "$T/out.json")"
    fi
    sleep 0.15
    ej_alive "$app" && { fails=$((fails + 1)); echo "      cycle $i: app still running"; }
    dv_unlocked || fails=$((fails + 1))
    fx_deg2 disconnected true
  done
  if (( fails == 0 )); then ok "10 cycles: connect, holders_present, --close, ejected, unloaded; lock free after each"
  else bad "cycles: $fails failures"; fi
  sleep 0.3
  local left
  left=$(grep -lsaE "$T/bin/(nvidia-sm[i]|pkexe[c])|$REPO/system/omarchy-egpu-admi[n]|$REPO/bin/omarchy-egp[u]" /proc/[0-9]*/cmdline 2>/dev/null | wc -l)
  dv_assert "no engine, helper, pkexec or nvidia-smi process left running" test "$left" = 0
  (( left == 0 )) || grep -lsaE "$T/bin/(nvidia-sm[i]|pkexe[c])|$REPO/system/omarchy-egpu-admi[n]|$REPO/bin/omarchy-egp[u]" /proc/[0-9]*/cmdline | while read -r f; do echo "      $(tr '\0' ' ' <"$f" | head -c 200)"; done
  local alive=0 p
  while IFS= read -r p; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done <"$EGPU_FAKE_DIR/apps"
  dv_assert "no app left running (all 10 quit on SIGTERM)" test "$alive" = 0
  dv_assert "no FIFO left unread by the fake kernel (every remove was consumed)" \
    test -z "$(find "$FX_PCI" -type p 2>/dev/null)"
  ej_done
}

# EJ_ONLY="ej_test_unload ej_test_late_modules" runs just those groups.
ej_run() { [[ -z ${EJ_ONLY:-} || " $EJ_ONLY " == *" $1 "* ]] && ("$1"); return 0; }

test_eject() {
  ej_run ej_test_clean
  ej_run ej_test_hdmi
  ej_run ej_test_holders
  ej_run ej_test_unload
  ej_run ej_test_display_safety
  ej_run ej_test_late_modules
  ej_run ej_test_failures
  ej_run ej_test_rescan
  ej_run ej_test_holders_verb
  ej_run ej_test_events
  ej_run ej_test_cycles
}
