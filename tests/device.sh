# shellcheck shell=bash
# tests/device.sh — gate E3 of plan-engine.md §12, the part fakes can settle:
# `device connect` and bin/egpu-run. Sourced by tests/run.sh; `tests/run.sh
# device` runs only these.
#
# Every test builds a fresh scenario from fixtures/device/machine (a healthy
# laptop, helper installed, no eGPU) and then plays the hardware itself:
#   dv_autoload      the kernel binding nvidia and udev loading the KMS
#                    modules a moment after the card appears (E0 saw exactly
#                    this on hot-plug)
#   dv_admin MODE    the root helper (E7) as a fake behind the fake pkexec:
#                    `load` binds the card (bind), refuses (fail) or does nothing
#   bolt-authorize.sh  the enclosure's PCI tree appearing once bolt authorizes
# No test reaches real hardware, sudo, pkexec or modprobe: PATH holds only the
# fakes and plain tools, and the fake pkexec runs nothing outside the fixture.

DV_BDF=0000:03:00.0
DV_NV_ENV="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only"

# dv_new <name>: a fresh scenario in the current (sub)shell.
dv_new() {
  setup_scenario "device-$1" "$TESTS/fixtures/device/machine" || exit 1
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  mkdir -p -- "$EGPU_RUN"
  export EGPU_POLL_S=0.05 EGPU_CONNECT_GRACE_S=1 EGPU_SMI_TIMEOUT=1
  export EGPU_GLVND_DIRS="$FX_ROOT/etc/glvnd/egl_vendor.d:$FX_ROOT/usr/share/glvnd/egl_vendor.d"
  # The session as the toggle file leaves it (scope.md DECISIONS 2026-10-10).
  export __GLX_VENDOR_LIBRARY_NAME=mesa
  export __EGL_VENDOR_LIBRARY_FILENAMES="$FX_ROOT/usr/share/glvnd/egl_vendor.d/50_mesa.json"
  unset __NV_PRIME_RENDER_OFFLOAD __VK_LAYER_NV_optimus
}

# Background helpers (dv_autoload) die with the test, not with the suite.
dv_done() {
  local p
  [[ -r $EGPU_FAKE_DIR/bg.pids ]] || return 0
  while IFS= read -r p; do [[ -n $p ]] && kill "$p" 2>/dev/null; done <"$EGPU_FAKE_DIR/bg.pids"
  : >"$EGPU_FAKE_DIR/bg.pids"
}

# The DEG2 authorized, the 4070 SUPER present with no driver yet.
dv_unbound() {
  fx_deg2 authorized true
  fx_egpu_nvidia none
}

# The DEG2 authorized, the 4070 SUPER bound and every KMS module loaded.
dv_ready() {
  fx_deg2 authorized true
  fx_egpu_nvidia nvidia
  fx_nvidia_modules
}

# dv_autoload [delay]: the kernel and udev, as E0 saw them on hot-plug.
dv_autoload() {
  local delay=${1:-0.3}
  (
    while :; do
      if [[ -e $FX_PCI/$DV_BDF/class && ! -L $FX_PCI/$DV_BDF/driver && ! -e $EGPU_FAKE_DIR/no-autoload ]]; then
        sleep "$delay"
        fx_egpu_nvidia nvidia
        fx_nvidia_modules
      fi
      sleep 0.05
    done
  ) >/dev/null 2>&1 &
  fx_bg $!
}

# dv_admin <bind|fail|none> [version]: the root helper behind the fake pkexec.
dv_admin() {
  local mode=$1 v=${2:-}
  [[ -n $v ]] || v=$(jq -r .version "$EGPU_TEST_REPO/manifest.json")
  mkdir -p -- "$(dirname -- "$EGPU_ADMIN")"
  cat >"$EGPU_ADMIN" <<EOF
#!/bin/bash
printf 'admin %s\n' "\$*" >>"\$EGPU_FAKE_LOG"
case \${1:-} in
  version) echo '{"version":"$v"}' ;;
  load)
    [[ \${2:-} == nvidia ]] || { echo '{"error":"usage"}'; exit 1; }
    case $mode in
      bind) source "\$EGPU_TEST_LIB"; fx_egpu_nvidia nvidia; fx_nvidia_modules; echo '{"ok":true}' ;;
      fail) echo '{"error":"no_device"}'; exit 1 ;;
      *) echo '{"ok":true}' ;;
    esac
    ;;
  *) echo '{"error":"usage"}'; exit 1 ;;
esac
EOF
  chmod +x "$EGPU_ADMIN"
}

# dv_connect [args]: `omarchy-egpu device connect`; output in $T/out.json,
# prose in $T/err, exit in DV_RC, wall time in DV_MS.
dv_connect() {
  local t0
  t0=$(date +%s%3N)
  "$ENGINE" device connect "$@" >"$T/out.json" 2>"$T/err"
  DV_RC=$?
  DV_MS=$(( $(date +%s%3N) - t0 ))
}

# dv_check <label> <jq expression over the last output>
dv_check() {
  if jq -e "$2" "$T/out.json" >/dev/null 2>&1; then ok "$1"; else bad "$1: rc $DV_RC $(head -c 300 "$T/out.json") $(head -c 200 "$T/err")"; fi
}

# dv_error <label> <code> [exit]: refused with this code and exit status.
dv_error() {
  local want=${3:-1}
  if (( DV_RC == want )) && jq -e --arg c "$2" '.error == $c' "$T/out.json" >/dev/null 2>&1; then
    ok "$1: $2, exit $want"
  else
    bad "$1: expected $2 (exit $want), got exit $DV_RC: $(head -c 300 "$T/out.json") $(head -c 200 "$T/err")"
  fi
}

dv_log_has() { grep -qE -- "$1" "$EGPU_FAKE_LOG" 2>/dev/null; }
dv_log_count() { grep -cE -- "$1" "$EGPU_FAKE_LOG" 2>/dev/null; }

dv_assert() { # dv_assert <label> <command...>
  local label=$1
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

dv_phase() { "$ENGINE" status --json 2>/dev/null | jq -r '.phase'; }

# The job lock is free and no job is named.
dv_unlocked() { [[ ! -e $EGPU_RUN/job ]] && flock -n "$EGPU_RUN/lock" true; }

# ---------------------------------------------------------------- connect

dv_test_success() {
  echo "${BOLD}device: connect, driver autoloads${RESET}"
  dv_new success
  dv_unbound
  dv_autoload
  dv_connect
  dv_check "connect exits 0 with ok, phase ready" '.ok == true and .phase == "ready" and .already == false'
  (( DV_RC == 0 )) || bad "connect exit $DV_RC"
  dv_check "names the card and the backend" ".bdf == \"$DV_BDF\" and .backend == \"nvidia\""
  dv_check "verified through nvidia-smi" '.gpu.ok == true and .gpu.name == "NVIDIA GeForce RTX 4070 SUPER"'
  dv_check "Vulkan lists the eGPU under the offload env" '.vulkan.state == "ok"'
  dv_assert "vulkaninfo ran with the offload variables" dv_log_has '^vulkaninfo env __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only$'
  dv_check "no bolt step, no helper: the kernel did the work" '.authorized == false and .helper_load == false'
  dv_assert "pkexec was never called" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_assert "boltctl authorize was not called" bash -c "! grep -q '^boltctl authorize' '$EGPU_FAKE_LOG'"
  dv_assert "\"eGPU ready\" notification" dv_log_has '^notify-send .*eGPU ready'
  dv_assert "lock released, no job left" dv_unlocked
  dv_assert "status agrees: phase ready" test "$(dv_phase)" = ready
  dv_done
}

dv_test_already() {
  echo "${BOLD}device: connect when already connected${RESET}"
  dv_new already
  dv_ready
  dv_connect --quiet
  dv_check "exit 0, already true, phase ready" '.ok == true and .already == true and .phase == "ready"'
  (( DV_RC == 0 )) || bad "already: exit $DV_RC"
  dv_check "carries the GPU block" '.gpu.ok == true'
  dv_assert "nothing touched: no boltctl authorize, no pkexec, one nvidia-smi query" \
    bash -c "! grep -qE '^(boltctl authorize|boltctl enroll|pkexec)' '$EGPU_FAKE_LOG' && [ \$(grep -c -- '--query-gpu' '$EGPU_FAKE_LOG') -eq 1 ]"
  dv_assert "--quiet: no notification" bash -c "! grep -q '^notify-send' '$EGPU_FAKE_LOG'"
  dv_connect
  dv_check "a second run is the same answer" '.ok == true and .already == true'
  dv_assert "connect also answers as \`omarchy-egpu connect\`" \
    bash -c "'$ENGINE' connect --quiet 2>/dev/null | jq -e '.already == true' >/dev/null"
  dv_done
}

dv_test_authorize() {
  echo "${BOLD}device: unauthorized enclosure → authorize → ready${RESET}"
  dv_new authorize
  fx_deg2 connected true
  # Authorizing makes the PCI tree appear (unbound), then the kernel binds it.
  cat >"$EGPU_FAKE_DIR/bolt-authorize.sh" <<'EOF'
#!/bin/bash
source "$EGPU_TEST_LIB"
fx_egpu_nvidia none
EOF
  chmod +x "$EGPU_FAKE_DIR/bolt-authorize.sh"
  dv_autoload
  dv_connect --quiet
  dv_check "exit 0, ready, authorized by this run" '.ok == true and .phase == "ready" and .authorized == true'
  dv_assert "ran boltctl authorize <uuid> (bolt's own polkit, no helper)" dv_log_has "^boltctl authorize $FX_DEG2_UUID\$"
  dv_assert "no pkexec" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_assert "bolt now says authorized" bash -c "jq -e '.devices[0].status == \"authorized\"' '$EGPU_FAKE_DIR/bolt.json' >/dev/null"
  dv_done

  echo "${BOLD}device: --enroll stores a new enclosure with policy auto${RESET}"
  dv_new enroll
  fx_deg2 connected false
  cat >"$EGPU_FAKE_DIR/bolt-authorize.sh" <<'EOF'
#!/bin/bash
source "$EGPU_TEST_LIB"
fx_egpu_nvidia none
EOF
  chmod +x "$EGPU_FAKE_DIR/bolt-authorize.sh"
  dv_autoload
  dv_connect --quiet --enroll
  dv_check "exit 0, ready" '.ok == true and .phase == "ready"'
  dv_assert "ran boltctl enroll --policy auto <uuid>" dv_log_has "^boltctl enroll --policy auto $FX_DEG2_UUID\$"
  dv_assert "stored with policy auto" bash -c "jq -e '.devices[0].stored == true and .devices[0].policy == \"auto\"' '$EGPU_FAKE_DIR/bolt.json' >/dev/null"
  dv_done

  echo "${BOLD}device: bolt refuses authorization${RESET}"
  dv_new authorize-fail
  fx_deg2 connected false
  touch "$EGPU_FAKE_DIR/bolt-authorize-fail"
  dv_connect --quiet
  dv_error "authorization refused" not_connected
  dv_check "says bolt refused" '.reason == "bolt_authorize_failed" and .phase == "plugged"'
  dv_assert "lock released" dv_unlocked
  dv_done
}

dv_test_timeout() {
  echo "${BOLD}device: authorized, no GPU appears (timeout)${RESET}"
  dv_new timeout
  fx_deg2 authorized true
  dv_connect --quiet --timeout 1
  dv_error "no PCI device within connect.timeout_s" no_pci_device
  dv_check "carries the DEG2 profile's hint" \
    '.profile == "minisforum-deg2" and (.hints | map(.id) == ["authorized_no_pci"]) and (.hints[0].text | test("mode switch"))'
  if (( DV_MS >= 1000 && DV_MS < 6000 )); then ok "waited the timeout, then stopped (${DV_MS} ms)"; else bad "timeout took ${DV_MS} ms"; fi
  dv_assert "no helper call while there is no card" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_done

  echo "${BOLD}device: connect.timeout_s from config${RESET}"
  dv_new timeout-config
  fx_deg2 authorized true
  echo '{"connect":{"timeout_s":2}}' >"$EGPU_CONFIG"
  dv_connect --quiet
  dv_check "timeout_s 2 from the config file" '.error == "no_pci_device" and .timeout_s == 2'
  if (( DV_MS >= 2000 && DV_MS < 7000 )); then ok "waited 2 s (${DV_MS} ms)"; else bad "config timeout took ${DV_MS} ms"; fi
  dv_done
}

dv_test_helper() {
  echo "${BOLD}device: driver does not autoload, helper not installed${RESET}"
  dv_new helper-missing
  dv_unbound
  rm -f -- "$EGPU_ADMIN"
  dv_connect --quiet --timeout 2
  dv_error "no helper" helper_missing
  dv_check "reason not_installed, names the helper path" ".reason == \"not_installed\" and .helper == \"$EGPU_ADMIN\""
  dv_assert "pkexec never called" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_done

  echo "${BOLD}device: helper out of date${RESET}"
  dv_new helper-old
  dv_unbound
  dv_admin bind 0.0.0-old
  dv_connect --quiet --timeout 2
  dv_error "helper version differs from the plugin's" helper_missing
  dv_check "reason version, both versions named" '.reason == "version" and .have == "0.0.0-old"'
  dv_assert "pkexec never called" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_done

  echo "${BOLD}device: driver does not autoload, helper loads it${RESET}"
  dv_new helper-load
  dv_unbound
  dv_admin bind
  dv_connect --quiet --timeout 2
  dv_check "exit 0, ready, loaded through the helper" '.ok == true and .phase == "ready" and .helper_load == true'
  dv_assert "exactly: pkexec <helper> load nvidia" bash -c "[ \"\$(grep '^pkexec' '$EGPU_FAKE_LOG')\" = 'pkexec $EGPU_ADMIN load nvidia' ]"
  dv_assert "after the autoload grace, not before" dv_log_has '^admin load nvidia$'
  dv_done

  echo "${BOLD}device: the helper refuses to load${RESET}"
  dv_new helper-fail
  dv_unbound
  dv_admin fail
  dv_connect --quiet --timeout 2
  dv_error "helper said no" modules_failed
  dv_check "the helper's own answer is kept" '.helper.error == "no_device" and .rc == 1'
  dv_done

  echo "${BOLD}device: the polkit prompt is declined${RESET}"
  dv_new pkexec-declined
  dv_unbound
  dv_admin bind
  echo 126 >"$EGPU_FAKE_DIR/pkexec-rc"
  dv_connect --quiet --timeout 2
  dv_error "pkexec 126 passes through" modules_failed 126
  dv_check "says declined" '.pkexec == 126'
  dv_done

  echo "${BOLD}device: some KMS modules missing after bind${RESET}"
  dv_new modules-missing
  dv_ready
  fx_modules_remove nvidia_uvm nvidia_drm
  dv_admin none
  dv_connect --quiet --timeout 1
  dv_error "the helper ran but the modules never came" modules_failed
  dv_check "lists what is missing" '.missing == ["nvidia_drm", "nvidia_uvm"] and .driver == "nvidia"'
  dv_assert "asked the helper once" bash -c "[ \$(grep -c '^pkexec' '$EGPU_FAKE_LOG') -eq 1 ]"
  dv_done

  echo "${BOLD}device: another driver has the card${RESET}"
  dv_new other-driver
  dv_unbound
  fx_pci "$DV_BDF" 0x030000 0x10de 0x2783 driver=nouveau
  dv_connect --quiet --timeout 2
  dv_error "nouveau bound" modules_failed
  dv_check "names it" '.driver == "nouveau" and .want == "nvidia"'
  if (( DV_MS < 1500 )); then ok "refused at once (${DV_MS} ms)"; else bad "waited ${DV_MS} ms for a driver that will not change"; fi
  dv_done
}

dv_test_smi_hung() {
  echo "${BOLD}device: nvidia-smi hangs in D state during verify${RESET}"
  dv_new smi-hung
  dv_unbound
  dv_autoload
  touch "$EGPU_FAKE_DIR/smi-hang"
  dv_connect --quiet
  dv_error "verify hung" smi_hung
  dv_check "phase error, the gpu block says D" '.phase == "error" and .gpu.error == "smi_hung" and .gpu.state == "D"'
  local p
  p=$(head -n1 "$EGPU_FAKE_DIR/smi-hang.pids" 2>/dev/null)
  dv_assert "the stuck nvidia-smi is left alone (not killed)" kill -0 "${p:-0}"
  dv_assert "lock released: the stuck child does not hold it" dv_unlocked
  dv_assert "status: phase error, no second nvidia-smi started" \
    bash -c "[ \"\$('$ENGINE' status --json | jq -r .phase)\" = error ] && [ \$(grep -c -- '--query-gpu' '$EGPU_FAKE_LOG') -eq 1 ]"
  dv_connect --quiet
  dv_error "connect again: smi_hung at once, not busy" smi_hung
  dv_assert "…and still only the one nvidia-smi" bash -c "[ \$(grep -c -- '--query-gpu' '$EGPU_FAKE_LOG') -eq 1 ]"
  if (( DV_MS < 3000 )); then ok "the second answer did not wait out another timeout (${DV_MS} ms)"; else bad "second connect took ${DV_MS} ms"; fi
  dv_done
}

dv_test_refusals() {
  echo "${BOLD}device: nothing connected${RESET}"
  dv_new absent
  dv_connect --quiet
  dv_error "absent" not_connected
  dv_check "phase absent" '.phase == "absent"'
  dv_done

  echo "${BOLD}device: unsupported backend (amdgpu stub)${RESET}"
  dv_new amd
  fx_bolt aaaaaaaa-0000-0000-0000-000000000002 "Razer" "Core X" authorized true iommu
  fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0 driver=amdgpu
  fx_modules amdgpu
  dv_connect --quiet
  dv_error "AMD card" backend_stub
  dv_check "names the stub" '.backend == "amdgpu" and .bdf == "0000:05:00.0"'
  dv_assert "no helper call" bash -c "! grep -q '^pkexec' '$EGPU_FAKE_LOG'"
  dv_done

  echo "${BOLD}device: another job holds the lock${RESET}"
  dv_new busy
  dv_ready
  flock "$EGPU_RUN/lock" sleep 5 &
  local holder=$!
  fx_bg "$holder"
  sleep 0.3
  dv_connect --quiet
  dv_error "busy" busy 3
  if (( DV_MS < 1500 )); then ok "busy answers at once (${DV_MS} ms)"; else bad "busy took ${DV_MS} ms"; fi
  dv_done

  echo "${BOLD}device: usage${RESET}"
  dv_new usage
  "$ENGINE" device frobnicate >"$T/out.json" 2>/dev/null
  DV_RC=$?
  dv_error "unknown device verb" usage
  "$ENGINE" device connect --bogus >"$T/out.json" 2>/dev/null
  DV_RC=$?
  dv_error "unknown connect option" usage
  dv_done
}

dv_test_events() {
  echo "${BOLD}device: a failed connect reaches the watcher as connect_failed${RESET}"
  dv_new events
  local out="$T/watch.out" wpid
  EGPU_HEARTBEAT_S=30 "$ENGINE" status watch >"$out" 2>"$T/watch.err" &
  wpid=$!
  fx_bg "$wpid"
  if ! wait_for "$out" 'map(select(.type == "status")) | length >= 1' 10; then
    bad "events: watcher did not start: $(head -c 300 "$T/watch.err")"
    dv_done
    return
  fi
  dv_connect --quiet
  dv_error "absent" not_connected
  if wait_for "$out" 'map(select(.type == "event" and .event == "connect_failed")) | length == 1' 5; then
    ok "connect_failed in the stream within 5 s (the poke, not the 30 s heartbeat)"
  else
    bad "no connect_failed event: $(tail -c 400 "$out")"
  fi
  if jq -e -s 'map(select(.type == "event" and .event == "connect_failed"))[0].detail
               | .error == "not_connected" and .phase == "absent"' "$out" >/dev/null 2>&1; then
    ok "its detail carries the error code and phase"
  else
    bad "connect_failed detail: $(jq -c -s 'map(select(.event == "connect_failed"))' "$out")"
  fi
  sleep 0.5
  if jq -e '.last_event.type == "connect_failed" and (.recent_events[-1].type == "connect_failed")' "$EGPU_RUN/status.json" >/dev/null 2>&1; then
    ok "status.json carries it as last_event and in recent_events"
  else
    bad "status.json last_event = $(jq -c .last_event "$EGPU_RUN/status.json" 2>/dev/null)"
  fi
  dv_assert "the spool is drained" test ! -s "$EGPU_RUN/events.spool"
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  dv_connect --quiet
  dv_assert "with no watcher nothing is spooled" test ! -e "$EGPU_RUN/events.spool"
  dv_done
}

dv_test_cycles() {
  echo "${BOLD}device: 20 plug → connect → unplug cycles${RESET}"
  dv_new cycles
  dv_autoload 0.1
  local i fails=0 slow=0 max=0
  for i in $(seq 1 20); do
    dv_unbound
    dv_connect --quiet --timeout 5
    if (( DV_RC != 0 )) || ! jq -e '.ok == true and .already == false' "$T/out.json" >/dev/null 2>&1; then
      fails=$((fails + 1))
      echo "      cycle $i: rc $DV_RC $(head -c 200 "$T/out.json")"
    fi
    (( DV_MS > max )) && max=$DV_MS
    (( DV_MS > 8000 )) && slow=$((slow + 1))
    dv_unlocked || fails=$((fails + 1))
    fx_egpu_unplug
    fx_modules_remove nvidia nvidia_modeset nvidia_drm nvidia_uvm
  done
  if (( fails == 0 && slow == 0 )); then ok "20 cycles, all ready, lock free after each (slowest ${max} ms)"
  else bad "cycles: $fails failed, $slow slow (slowest ${max} ms)"; fi
  dv_assert "no nvidia-smi or vulkaninfo left running" \
    bash -c "! grep -lsaE '$T/bin/(nvidia-sm[i]|vulkaninf[o])' /proc/[0-9]*/cmdline >/dev/null"
  dv_done
}

# ---------------------------------------------------------------- egpu-run

er() { # er [args…]: bin/egpu-run; stdout $T/run.out, stderr $T/run.err, exit ER_RC
  "$REPO/bin/egpu-run" "$@" >"$T/run.out" 2>"$T/run.err"
  ER_RC=$?
}

dv_test_run() {
  local nvjson
  echo "${BOLD}egpu-run: eGPU ready${RESET}"
  dv_new run-ready
  dv_ready
  nvjson="$FX_ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
  er glxinfo -B
  if (( ER_RC == 0 )) && grep -q 'OpenGL renderer string: NVIDIA GeForce RTX 4070 SUPER' "$T/run.out"; then
    ok "egpu-run glxinfo -B renders on the NVIDIA card"
  else
    bad "egpu-run glxinfo -B: rc $ER_RC $(head -c 300 "$T/run.out") $(head -c 200 "$T/run.err")"
  fi
  er --env
  if [[ $(paste -sd' ' "$T/run.out") == "$DV_NV_ENV __EGL_VENDOR_LIBRARY_FILENAMES=$nvjson" ]]; then
    ok "--env: the PRIME set plus NVIDIA's EGL vendor file (found, not assumed)"
  else
    bad "--env: $(paste -sd' ' "$T/run.out")"
  fi
  er env
  if grep -qxF "__EGL_VENDOR_LIBRARY_FILENAMES=$nvjson" "$T/run.out" && grep -qx '__GLX_VENDOR_LIBRARY_NAME=nvidia' "$T/run.out" &&
    grep -qx '__NV_PRIME_RENDER_OFFLOAD=1' "$T/run.out" && grep -qx '__VK_LAYER_NV_optimus=NVIDIA_only' "$T/run.out"; then
    ok "the command's environment overrides the session's Mesa EGL/GLX pins"
  else
    bad "command env: $(grep -E '^__' "$T/run.out" | paste -sd' ')"
  fi
  er --check
  if (( ER_RC == 0 )) && jq -e ".ready == true and .bdf == \"$DV_BDF\" and .backend == \"nvidia\" and (.env | length) == 4" "$T/run.out" >/dev/null 2>&1; then
    ok "--check: ready, exit 0"
  else
    bad "--check: rc $ER_RC $(head -c 300 "$T/run.out")"
  fi
  dv_assert "readiness never runs nvidia-smi" bash -c "! grep -q '^nvidia-smi' '$EGPU_FAKE_LOG'"
  er bash -c 'exit 7'
  if (( ER_RC == 7 )); then ok "exit status preserved (7)"; else bad "exit status $ER_RC, expected 7"; fi

  # Steam: `egpu-run %command%`. Steam expands it to its own wrapper chain;
  # every argument must arrive exactly, including ones that look like ours.
  cat >"$T/bin/steam-launch-wrapper" <<'EOF'
#!/bin/bash
printf '[%s]' "$@"
printf '\n%s\n' "${__NV_PRIME_RENDER_OFFLOAD:-unset}"
EOF
  chmod +x "$T/bin/steam-launch-wrapper"
  er steam-launch-wrapper -- reaper SteamLaunch AppId=1234 -- "/x/Proton 9.0/proton" waitforexitandrun "Game Name.exe" --check -novid --strict
  if [[ $(head -n1 "$T/run.out") == '[--][reaper][SteamLaunch][AppId=1234][--][/x/Proton 9.0/proton][waitforexitandrun][Game Name.exe][--check][-novid][--strict]' && $(sed -n 2p "$T/run.out") == 1 ]]; then
    ok "as a Steam %command% prefix: arguments untouched, offload env set"
  else
    bad "Steam prefix: $(head -c 300 "$T/run.out")"
  fi
  er -- --strict-is-a-program
  if (( ER_RC == 127 )); then ok "-- ends egpu-run's options (exec of a missing program: 127)"; else bad "-- handling: rc $ER_RC"; fi
  dv_done

  echo "${BOLD}egpu-run: no eGPU${RESET}"
  dv_new run-absent
  er glxinfo -B
  if (( ER_RC == 0 )) && grep -q 'Mesa Intel' "$T/run.out" && grep -q 'running glxinfo on the default GPU' "$T/run.err"; then
    ok "runs on the default GPU with a clear message"
  else
    bad "fallback: rc $ER_RC $(head -c 200 "$T/run.out") $(head -c 200 "$T/run.err")"
  fi
  dv_assert "…and a notification" dv_log_has '^notify-send .*Not on the eGPU'
  EGPU_FAKE_GLXINFO_RC=5 er --quiet glxinfo -B
  if (( ER_RC == 5 )); then ok "fallback preserves the exit status (5)"; else bad "fallback exit $ER_RC, expected 5"; fi
  dv_assert "--quiet: no second notification" bash -c "[ \$(grep -c '^notify-send' '$EGPU_FAKE_LOG') -eq 1 ]"
  er env
  if ! grep -q '^__NV_PRIME_RENDER_OFFLOAD=' "$T/run.out" && grep -qx '__GLX_VENDOR_LIBRARY_NAME=mesa' "$T/run.out"; then
    ok "fallback sets no offload variables; the session's stay"
  else
    bad "fallback env: $(grep -E '^__' "$T/run.out" | paste -sd' ')"
  fi
  : >"$EGPU_FAKE_LOG"
  er --strict glxinfo -B
  if (( ER_RC == 1 )) && jq -e '.error == "not_connected" and .ready == false' "$T/run.out" >/dev/null 2>&1 &&
    ! grep -q '^glxinfo' "$EGPU_FAKE_LOG"; then
    ok "--strict refuses: not_connected, exit 1, command not started"
  else
    bad "--strict: rc $ER_RC $(head -c 200 "$T/run.out")"
  fi
  er --check
  if (( ER_RC == 1 )) && jq -e '.error == "not_connected" and .ready == false' "$T/run.out" >/dev/null 2>&1; then
    ok "--check: not_connected, exit 1"
  else
    bad "--check absent: rc $ER_RC $(head -c 200 "$T/run.out")"
  fi
  er
  if (( ER_RC == 2 )); then ok "no command: usage, exit 2"; else bad "no command: rc $ER_RC"; fi
  dv_done

  echo "${BOLD}egpu-run: card present, driver not bound${RESET}"
  dv_new run-unbound
  dv_unbound
  er --check
  if (( ER_RC == 1 )) && jq -e '.error == "not_connected" and (.detail | test("driver"))' "$T/run.out" >/dev/null 2>&1; then
    ok "--check: not_connected (driver not loaded)"
  else
    bad "unbound: rc $ER_RC $(head -c 200 "$T/run.out")"
  fi
  er --quiet glxinfo -B
  if (( ER_RC == 0 )) && grep -q 'Mesa Intel' "$T/run.out"; then ok "falls back to the default GPU"; else bad "unbound fallback: $(head -c 200 "$T/run.out")"; fi
  dv_done

  echo "${BOLD}egpu-run: the watcher says the driver is hung${RESET}"
  dv_new run-hung
  dv_ready
  jq -cn --argjson at "$(date +%s%3N)" --arg bdf "$DV_BDF" \
    '{schema: 1, written_at: $at, phase: "error", pci: {bdf: $bdf}, gpu: {ok: false, error: "smi_hung"}}' >"$EGPU_RUN/status.json"
  er --check
  if (( ER_RC == 1 )) && jq -e '.error == "smi_hung"' "$T/run.out" >/dev/null 2>&1; then
    ok "a fresh status.json with smi_hung: not ready"
  else
    bad "hung: rc $ER_RC $(head -c 200 "$T/run.out")"
  fi
  jq -c '.written_at -= 60000' "$EGPU_RUN/status.json" >"$EGPU_RUN/s.tmp" && mv "$EGPU_RUN/s.tmp" "$EGPU_RUN/status.json"
  er --check
  if (( ER_RC == 0 )); then ok "a stale one (60 s old) is not believed"; else bad "stale status.json still blocks: $(head -c 200 "$T/run.out")"; fi
  dv_done

  echo "${BOLD}egpu-run: stub backend (amdgpu)${RESET}"
  dv_new run-amd
  fx_bolt aaaaaaaa-0000-0000-0000-000000000002 "Razer" "Core X" authorized true iommu
  fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0 driver=amdgpu
  er --env
  if (( ER_RC == 0 )) && [[ $(cat "$T/run.out") == DRI_PRIME=pci-0000_05_00_0 ]]; then
    ok "the stub's own offload variable (DRI_PRIME)"
  else
    bad "amd env: rc $ER_RC $(cat "$T/run.out")"
  fi
  dv_done
}

test_device() {
  (dv_test_success)
  (dv_test_already)
  (dv_test_authorize)
  (dv_test_timeout)
  (dv_test_helper)
  (dv_test_smi_hung)
  (dv_test_refusals)
  (dv_test_events)
  (dv_test_cycles)
  (dv_test_run)
}
