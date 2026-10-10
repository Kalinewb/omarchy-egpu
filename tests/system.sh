# shellcheck shell=bash
# tests/system.sh — gate E7 of plan-engine.md §12, the part that needs no real
# root: the root helper against a fake sysfs, the installer into a temp root,
# and the pins. Sourced by tests/run.sh; `tests/run.sh system` runs only these.
#
# The helper runs UNPRIVILEGED with OMARCHY_EGPU_ADMIN_TEST_ROOT pointing at the
# scenario's fixture tree (the same tree EGPU_SYS etc. point into); it honours
# that variable only when it is not root. One group then runs the unmodified
# helper as uid 0 inside a throw-away user + mount namespace (unshare -rm),
# with the fixture bind-mounted over /sys, a tmpfs on /run and fakes over
# /usr/bin/modprobe and /usr/bin/logger, to show what root ignores (the test
# root, EGPU_*, the caller's PATH, exported functions). It is skipped where
# unprivileged user namespaces are off.
#
# Nothing here runs sudo, pkexec or a real modprobe, or writes outside $WORK.
# The installer runs with --root into the fixture tree.

SY_EGPU=0000:03:00.0
SY_AUDIO=0000:03:00.1
SY_IGPU=0000:00:02.0

# sy_new <name>: a fresh scenario in the current (sub)shell.
sy_new() {
  setup_scenario "system-$1" "$TESTS/fixtures/system/machine" || exit 1
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  # Tools the installer and check-pins need beyond the runner's plain set.
  local t p
  mkdir -p "$T/xbin"
  for t in sha256sum install diff; do
    p=$(PATH=/usr/bin:/bin type -P "$t") && ln -sf "$p" "$T/xbin/$t"
  done
  export PATH="$PATH:$T/xbin"
  SY_ADMIN="$REPO/system/omarchy-egpu-admin"
  SY_INSTALL="$REPO/system/install.sh"
}

# sy_admin <args…>: the helper in test mode. Output in $T/out.json, prose in
# $T/err, exit in SY_RC.
sy_admin() {
  OMARCHY_EGPU_ADMIN_TEST_ROOT="$FX_ROOT" OMARCHY_EGPU_ADMIN_TEST_DEADLINE="${SY_DEADLINE:-3}" \
    timeout 60 "$SY_ADMIN" "$@" >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
}

# sy_install <args…>: the installer into the fixture root.
sy_install() {
  timeout 60 bash "$SY_INSTALL" --root "$FX_ROOT" "$@" >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
}

sy_one_doc() { [[ $(jq -s 'length' "$T/out.json" 2>/dev/null) == 1 ]]; }

# sy_check <label> <jq expression>: exit 0 and the expression holds.
sy_check() {
  if ((SY_RC == 0)) && sy_one_doc && jq -e "$2" "$T/out.json" >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1: rc $SY_RC $(head -c 300 "$T/out.json") $(head -c 300 "$T/err")"
  fi
}

# sy_error <label> <code> [exit]: refused with exactly one {"error":code} document.
sy_error() {
  local want=${3:-1}
  if ((SY_RC == want)) && sy_one_doc && jq -e --arg c "$2" '.error == $c' "$T/out.json" >/dev/null 2>&1; then
    ok "$1: $2"
  else
    bad "$1: expected $2 (exit $want), got exit $SY_RC: $(head -c 300 "$T/out.json") $(head -c 200 "$T/err")"
  fi
}

sy_assert() { # sy_assert <label> <command…>
  local label=$1
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

# Background helpers (sy_kernel, lock holders) die with the test.
sy_done() {
  local p
  [[ -r $EGPU_FAKE_DIR/bg.pids ]] || return 0
  while IFS= read -r p; do [[ -n $p ]] && kill "$p" 2>/dev/null; done <"$EGPU_FAKE_DIR/bg.pids"
  : >"$EGPU_FAKE_DIR/bg.pids"
}

sy_log_has() { grep -qE -- "$1" "$EGPU_FAKE_LOG" 2>/dev/null; }
sy_no_modprobe() { ! grep -q '^modprobe' "$EGPU_FAKE_LOG" 2>/dev/null; }

# sy_kernel <bdf…>: each function's `remove` becomes a FIFO, and a background
# "kernel" removes the function's directory (and its bus/pci/devices link,
# under sy_enclosure) once 1 is written to it. A FIFO with no reader instead
# blocks the writer, like a remove that never returns.
sy_kernel() {
  local f d real
  for f in "$@"; do
    d=$FX_PCI/$f
    real=$(realpath -e -- "$d")
    rm -f -- "$real/remove"
    mkfifo -- "$real/remove"
    (
      IFS= read -r x <"$real/remove"
      [[ $x == 1 ]] && rm -rf -- "$real" "$d"
    ) >/dev/null 2>&1 &
    fx_bg $!
  done
}

# sy_enclosure: the eGPU's functions moved into a device tree shaped like this
# machine's (dev/e0-facts.md): root port 00:07.0 (no `removable`) → the
# enclosure's switch 01:00.0 → its downstream port 02:00.0 → 03:00.x, the
# last two removable, with bus/pci/devices/ holding relative links as the
# kernel's do. The helper's eject latch names the enclosure by 02:00.0.
SY_PORT=sys/devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0
sy_enclosure() {
  local f p=$FX_ROOT/sys/devices/pci0000:00/0000:00:07.0
  mkdir -p -- "$FX_ROOT/$SY_PORT"
  printf '0x060400\n' >"$p/class"
  printf '0x060400\n' >"$p/0000:01:00.0/class"
  printf 'removable\n' >"$p/0000:01:00.0/removable"
  printf '0x060400\n' >"$FX_ROOT/$SY_PORT/class"
  printf 'removable\n' >"$FX_ROOT/$SY_PORT/removable"
  for f in "$SY_EGPU" "$SY_AUDIO"; do
    [[ -d $FX_PCI/$f && ! -L $FX_PCI/$f ]] || continue
    mv -- "$FX_PCI/$f" "$FX_ROOT/$SY_PORT/$f"
    ln -s -- "../../../${SY_PORT#sys/}/$f" "$FX_PCI/$f"
  done
}

# sy_replug: the enclosure unplugged and plugged in again, as sysfs shows it:
# its port is a new directory (made while the old one still exists, so its
# inode number differs on any filesystem), and the eGPU is back below it.
sy_replug() {
  local port=$FX_ROOT/$SY_PORT
  rm -f -- "$FX_PCI/$SY_EGPU" "$FX_PCI/$SY_AUDIO"
  mv -- "$port" "$port.old"
  mkdir -- "$port"
  printf '0x060400\n' >"$port/class"
  printf 'removable\n' >"$port/removable"
  rm -rf -- "$port.old"
  fx_egpu_nvidia none
  sy_enclosure
}

sy_latch() { cat "$FX_ROOT/run/omarchy-egpu-admin.ejected" 2>/dev/null; }

# ---------------------------------------------------------------- helper: callers

sy_test_callers() {
  sy_new callers
  fx_egpu_nvidia nvidia

  "$SY_ADMIN" version >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_check "helper: version answers unprivileged" ".version == \"$(jq -r .version "$REPO/manifest.json")\""
  "$SY_ADMIN" version extra >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_error "helper: version takes no arguments" bad_arguments

  # Unprivileged with no test root: refused, whatever EGPU_* says.
  EGPU_SYS="$FX_ROOT/sys" EGPU_ETC="$FX_ROOT/etc" "$SY_ADMIN" remove "$SY_EGPU" >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_error "helper: not root and no test root, EGPU_SYS set" not_root
  OMARCHY_EGPU_ADMIN_TEST_ROOT=relative/root "$SY_ADMIN" rescan >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_error "helper: a relative test root is refused" not_root
  OMARCHY_EGPU_ADMIN_TEST_ROOT="$FX_ROOT/../$(basename "$FX_ROOT")" "$SY_ADMIN" rescan >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_error "helper: a test root with .. is refused" not_root

  # EGPU_SYS pointing at a tree WITH the eGPU, the test root at one without:
  # the helper reads only its own root.
  mkdir -p "$T/empty/sys/bus/pci/devices" "$T/empty/run"
  OMARCHY_EGPU_ADMIN_TEST_ROOT="$T/empty" EGPU_SYS="$FX_ROOT/sys" "$SY_ADMIN" remove "$SY_EGPU" >"$T/out.json" 2>"$T/err"
  SY_RC=$?
  sy_error "helper: EGPU_SYS is ignored" no_pci_device

  sy_admin
  sy_error "helper: no verb" no_verb
  local v
  for v in eval install-system --help -r "load;id" "remove " status sh; do
    sy_admin "$v"
    sy_error "helper: unknown verb '$v' refused" unknown_verb
  done
  sy_admin load
  sy_error "helper: load without a backend" bad_arguments
  sy_admin load nvidia extra
  sy_error "helper: load with two arguments" bad_arguments
  sy_admin rescan now
  sy_error "helper: rescan with an argument" bad_arguments
  sy_admin holders -a
  sy_error "helper: holders with an argument" bad_arguments
  sy_admin inspect-initramfs /etc/shadow
  sy_error "helper: inspect-initramfs with a path" bad_arguments
  sy_admin remove
  sy_error "helper: remove without an address" bad_arguments
  sy_admin autoconnect
  sy_error "helper: autoconnect without on|off" bad_arguments
  sy_admin autoconnect on off
  sy_error "helper: autoconnect with two arguments" bad_arguments
  for v in maybe ON '' 'on off' /etc/omarchy-egpu/autoconnect -r 1; do
    sy_admin autoconnect "$v"
    sy_error "helper: autoconnect '$v' refused" bad_arguments
  done

  # bash -p (M3): no shell function is imported from the environment and
  # BASH_ENV is not read. Both would happen before the helper's first line, so
  # only the interpreter's mode can stop them; run without it, it refuses.
  sy_assert "helper: the first line is #!/bin/bash -p" test "$(head -n1 "$SY_ADMIN")" = '#!/bin/bash -p'
  # shellcheck disable=SC2329,SC2317
  modprobe() { touch "$T/function-ran"; }
  export -f modprobe
  sy_admin load nvidia
  unset -f modprobe
  sy_assert "helper: an exported modprobe() function is not run" test ! -e "$T/function-ran"
  sy_check "  …and the real (fake) modprobe loaded the stack" '.ok == true and (.loaded | length) == 4'
  # Functions named like the builtins a cleanup loop would itself use.
  (
    # shellcheck disable=SC2329,SC2317
    unset() { touch "$T/function-ran"; }
    # shellcheck disable=SC2329,SC2317
    read() { touch "$T/function-ran"; }
    # shellcheck disable=SC2329,SC2317
    flock() { touch "$T/function-ran"; }
    export -f unset read flock
    sy_admin rescan
  )
  sy_assert "helper: exported unset(), read() and flock() functions are not run" test ! -e "$T/function-ran"
  printf 'touch %q\n' "$T/bash-env-ran" >"$T/bash-env"
  BASH_ENV="$T/bash-env" ENV="$T/bash-env" sy_admin version
  sy_assert "helper: BASH_ENV and ENV are not read" test ! -e "$T/bash-env-ran"
  OMARCHY_EGPU_ADMIN_TEST_ROOT="$FX_ROOT" bash "$SY_ADMIN" version >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
  sy_error "helper: run as 'bash omarchy-egpu-admin' (no -p)" not_privileged_mode
  sy_done
}

# ---------------------------------------------------------------- helper: remove

sy_test_remove() {
  sy_new remove
  fx_egpu_nvidia nvidia
  fx_pci 0000:01:00.0 0x030200 0x10de 0x28e0 boot_vga=0 driver=nvidia            # internal dGPU, not removable
  fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0     # an AMD eGPU
  fx_pci 0000:06:00.0 0x030000 0x10de 0x2783 removable=fixed boot_vga=0         # removable=fixed
  fx_pci 0000:07:00.0 0x030000 0x10de 0x2783 removable=removable boot_vga=0     # GPU whose slot mate is internal
  fx_pci 0000:07:00.1 0x040300 0x10de 0x22bc boot_vga=0
  fx_pci 0000:08:00.0 0x030000 0x10de 0x2783 removable=removable boot_vga=1     # removable but boot VGA
  local a
  for a in ../../../etc 0000:03:00.0/../../../x '0000:03:00.0;id' "0000:03:00.0 " $'0000:03:00.0\n' \
    0000:0A:00.0 0000:03:00.8 0000:3:00.0 00000:03:00.0 -r --force '*' '0000:03:00.?' '$(id)' ''; do
    sy_admin remove "$a"
    sy_error "helper: remove '$(printf '%q' "$a")' refused" bad_address
  done
  sy_admin remove "$SY_IGPU"
  sy_error "helper: remove the iGPU" not_egpu
  sy_check_reason() { jq -e --arg r "$1" '.reason == $r' "$T/out.json" >/dev/null 2>&1 && ok "  …reason $1" || bad "  …reason: $(cat "$T/out.json")"; }
  sy_check_reason boot_vga
  sy_admin remove 0000:01:00.0
  sy_error "helper: remove an internal (non-removable) NVIDIA GPU" not_egpu
  sy_check_reason not_removable
  sy_admin remove 0000:06:00.0
  sy_error "helper: remove a device with removable=fixed" not_egpu
  sy_admin remove 0000:05:00.0
  sy_error "helper: remove a removable GPU of a vendor with no backend" not_egpu
  sy_check_reason vendor
  sy_admin remove "$SY_AUDIO"
  sy_error "helper: remove the HDMI audio function directly" not_egpu
  sy_check_reason not_display
  sy_admin remove 0000:07:00.0
  sy_error "helper: remove a GPU whose slot has a non-removable function" not_egpu
  sy_check_reason slot_function
  sy_admin remove 0000:08:00.0
  sy_error "helper: remove a removable boot VGA device" not_egpu
  sy_admin remove 0000:09:00.0
  sy_error "helper: remove an address that does not exist" no_pci_device
  sy_assert "helper: every refusal left the devices in place" \
    test -d "$FX_PCI/$SY_IGPU" -a -d "$FX_PCI/0000:01:00.0" -a -d "$FX_PCI/$SY_EGPU" -a -d "$FX_PCI/0000:07:00.1"
  sy_assert "  …and wrote no eject latch" test ! -e "$FX_ROOT/run/omarchy-egpu-admin.ejected"

  # D1: a lit monitor on the card (the TV still on the eGPU's HDMI).
  sy_kernel "$SY_EGPU" "$SY_AUDIO"
  fx_connector "$SY_EGPU" card1 HDMI-A-2 connected enabled
  sy_admin remove "$SY_EGPU"
  sy_error "helper: remove while a connector of the card is enabled" monitor_active
  jq -e '.connector == "card1-HDMI-A-2" and .device == "0000:03:00.0"' "$T/out.json" >/dev/null &&
    ok "  …names the connector" || bad "  …detail: $(cat "$T/out.json")"
  sy_assert "  …removed nothing, latched nothing" test -d "$FX_PCI/$SY_EGPU" -a ! -e "$FX_ROOT/run/omarchy-egpu-admin.ejected"
  fx_connector "$SY_EGPU" card1 HDMI-A-2 connected disabled

  # The eGPU: both functions go, audio first, GPU last.
  sy_admin remove "$SY_EGPU"
  sy_check "helper: remove the eGPU removes every function of its slot" \
    ".ok == true and .device == \"$SY_EGPU\" and .removed == [\"$SY_AUDIO\", \"$SY_EGPU\"]"
  sy_assert "  …and they are gone from sysfs" test ! -e "$FX_PCI/$SY_EGPU" -a ! -e "$FX_PCI/$SY_AUDIO"
  sy_assert "  …the iGPU is untouched" test -d "$FX_PCI/$SY_IGPU"
  # No enclosure to name in this flat tree: the latch holds the address only.
  sy_assert "  …the eject latch names the address, no enclosure" test "$(sy_latch)" = "$SY_EGPU"$'\t-\t-'
  sy_admin remove "$SY_EGPU"
  sy_error "helper: removing it again" no_pci_device

  # The card back at the same address: `load auto` leaves it alone.
  fx_egpu_nvidia none
  : >"$EGPU_FAKE_LOG"
  sy_admin load auto
  sy_error "helper: load auto for the ejected address" eject_latched
  sy_assert "  …ran no modprobe" sy_no_modprobe
  sy_done
}

sy_test_remove_timeout() {
  sy_new remove-timeout
  fx_egpu_nvidia nvidia
  mkfifo "$FX_PCI/$SY_AUDIO/remove" "$FX_PCI/$SY_EGPU/remove"     # nobody reads: the write never returns
  local t0
  t0=$SECONDS
  SY_DEADLINE=2 sy_admin remove "$SY_EGPU"
  sy_error "helper: a remove that never returns" remove_timeout
  sy_assert "  …answers within the deadline ($((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 6
  sy_assert "  …and leaves the devices" test -d "$FX_PCI/$SY_EGPU"

  # A plain file: the write "succeeds" but the device stays.
  rm -f "$FX_PCI/$SY_AUDIO/remove" "$FX_PCI/$SY_EGPU/remove"
  : >"$FX_PCI/$SY_AUDIO/remove"
  : >"$FX_PCI/$SY_EGPU/remove"
  sy_admin remove "$SY_EGPU"
  sy_error "helper: a device still present after the write" remove_failed
  sy_assert "  …wrote exactly '1' to remove" test "$(cat "$FX_PCI/$SY_EGPU/remove")" = 1
}

# ---------------------------------------------------------------- helper: load / unload / rescan

sy_test_modules() {
  sy_new modules
  # A lock an older release left world-readable (M1).
  (umask 022 && : >"$FX_ROOT/run/omarchy-egpu-admin.lock")
  sy_admin load nvidia
  sy_error "helper: load with no eGPU (never load with no card)" no_pci_device
  sy_assert "  …ran no modprobe" sy_no_modprobe
  sy_assert "helper: the lock is root's alone, mode 600 (was 644)" \
    test "$(stat -c %a "$FX_ROOT/run/omarchy-egpu-admin.lock")" = 600
  rm -f "$FX_ROOT/run/omarchy-egpu-admin.lock"
  (umask 022 && sy_admin load nvidia)
  sy_assert "  …and created 600 under a permissive umask" test "$(stat -c %a "$FX_ROOT/run/omarchy-egpu-admin.lock")" = 600
  fx_pci 0000:01:00.0 0x030200 0x10de 0x28e0 boot_vga=0
  sy_admin load nvidia
  sy_error "helper: load with only an internal NVIDIA GPU" no_pci_device
  fx_pci_remove 0000:01:00.0
  fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0
  sy_admin load auto
  sy_error "helper: load auto with only an AMD eGPU (no root backend)" no_pci_device
  local b
  for b in amdgpu intel ../nvidia 'nvidia nvidia_drm' nvidia_drm -r '' NVIDIA; do
    sy_admin load "$b"
    sy_error "helper: load '$b' refused" unknown_backend
    sy_admin unload "$b"
    sy_error "helper: unload '$b' refused" unknown_backend
  done
  sy_assert "  …ran no modprobe" sy_no_modprobe

  fx_egpu_nvidia none
  sy_admin load nvidia
  sy_check "helper: load nvidia with the eGPU present" \
    ".ok == true and .backend == \"nvidia\" and .device == \"$SY_EGPU\" and .loaded == [\"nvidia\",\"nvidia_modeset\",\"nvidia_drm\",\"nvidia_uvm\"]"
  sy_assert "  …in the fixed order, with --" test "$(grep '^modprobe' "$EGPU_FAKE_LOG" | paste -sd'|')" = \
    "modprobe -- nvidia|modprobe -- nvidia_modeset|modprobe -- nvidia_drm|modprobe -- nvidia_uvm"
  sy_admin load auto
  sy_check "helper: load auto again: everything already loaded" '.backend == "nvidia" and .loaded == [] and (.already | length) == 4'

  fx_modules_remove nvidia_drm nvidia_uvm
  echo nvidia_drm >"$EGPU_FAKE_DIR/modprobe-fail"
  sy_admin load nvidia
  sy_error "helper: a module that fails to load" modules_failed
  jq -e '.module == "nvidia_drm" and (.detail | test("No such device"))' "$T/out.json" >/dev/null &&
    ok "  …names the module and modprobe's error" || bad "  …detail: $(cat "$T/out.json")"
  rm -f "$EGPU_FAKE_DIR/modprobe-fail"
  touch "$EGPU_FAKE_DIR/modprobe-hang"
  local t0=$SECONDS
  SY_DEADLINE=2 sy_admin load nvidia
  sy_error "helper: a modprobe that hangs" modules_failed
  sy_assert "  …answers within the deadline ($((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 6
  rm -f "$EGPU_FAKE_DIR/modprobe-hang"

  # M4: an abandoned child, and anything it started, never gets the lock's
  # descriptor, so the next call is not busy behind it.
  touch "$EGPU_FAKE_DIR/modprobe-orphan"
  SY_DEADLINE=2 sy_admin load nvidia
  sy_error "helper: a modprobe that hangs and leaves a grandchild running" modules_failed
  rm -f "$EGPU_FAKE_DIR/modprobe-orphan"
  SY_DEADLINE=2 sy_admin load nvidia
  sy_check "  …the next call gets the lock: the grandchild holds no copy of it" '.ok == true and .loaded == ["nvidia_drm","nvidia_uvm"]'

  # Unload: refused while the card exists.
  fx_nvidia_modules
  : >"$EGPU_FAKE_LOG"
  sy_admin unload nvidia
  sy_error "helper: unload with the eGPU present" device_present
  sy_assert "  …ran no modprobe" sy_no_modprobe

  # The card gone; the stack as the kernel shows it: each module held only by
  # the allowlisted ones above it, plus the compositor on nvidia_drm.
  fx_egpu_unplug
  fx_pci_remove 0000:05:00.0
  mkdir -p "$FX_ROOT/sys/module/nvidia/holders" "$FX_ROOT/sys/module/nvidia_modeset/holders"
  : >"$FX_ROOT/sys/module/nvidia/holders/nvidia_uvm"
  : >"$FX_ROOT/sys/module/nvidia/holders/nvidia_drm"
  : >"$FX_ROOT/sys/module/nvidia/holders/nvidia_modeset"
  : >"$FX_ROOT/sys/module/nvidia_modeset/holders/nvidia_drm"
  echo 3 >"$FX_ROOT/sys/module/nvidia/refcnt"
  echo 1 >"$FX_ROOT/sys/module/nvidia_modeset/refcnt"
  echo 2 >"$FX_ROOT/sys/module/nvidia_drm/refcnt"
  sy_admin unload nvidia
  sy_error "helper: unload while the compositor holds nvidia_drm" modules_in_use
  sy_assert "  …unloaded nothing" sy_no_modprobe
  echo 0 >"$FX_ROOT/sys/module/nvidia_drm/refcnt"
  : >"$FX_ROOT/sys/module/nvidia/holders/evil_mod"
  sy_admin unload nvidia
  sy_error "helper: unload with a module outside the allowlist holding nvidia" modules_in_use
  rm -f "$FX_ROOT/sys/module/nvidia/holders/evil_mod"
  echo 4 >"$FX_ROOT/sys/module/nvidia/refcnt"
  sy_admin unload nvidia
  sy_error "helper: unload with a process holding /dev/nvidia*" modules_in_use
  echo 3 >"$FX_ROOT/sys/module/nvidia/refcnt"

  # rescan: refused while the modules are held with no card (O2).
  sy_admin rescan
  sy_error "helper: rescan while the modules are loaded with no card" modules_held
  sy_assert "  …wrote nothing to rescan" test ! -s "$FX_ROOT/sys/bus/pci/rescan"

  sy_admin unload nvidia
  sy_check "helper: unload with only the stack's own references" '.ok == true and .unloaded == ["nvidia_uvm","nvidia_drm","nvidia_modeset","nvidia"]'
  sy_assert "  …in reverse order, with -r --" test "$(grep '^modprobe' "$EGPU_FAKE_LOG" | paste -sd'|')" = \
    "modprobe -r -- nvidia_uvm|modprobe -r -- nvidia_drm|modprobe -r -- nvidia_modeset|modprobe -r -- nvidia"
  sy_admin unload nvidia
  sy_check "helper: unload with nothing loaded" '.ok == true and .unloaded == []'

  fx_pci 0000:01:00.0 0x030200 0x10de 0x28e0 boot_vga=0
  sy_admin unload nvidia
  sy_error "helper: unload while an internal NVIDIA GPU exists" device_present
  fx_pci_remove 0000:01:00.0

  sy_admin rescan
  sy_check "helper: rescan after a clean eject" '.ok == true'
  sy_assert "  …wrote 1 to /sys/bus/pci/rescan" test "$(cat "$FX_ROOT/sys/bus/pci/rescan")" = 1

  # Busy: another privileged job holds the lock.
  (exec 7>>"$FX_ROOT/run/omarchy-egpu-admin.lock" && flock 7 && exec sleep 20) &
  local lp=$!
  fx_bg "$lp"
  sleep 0.3
  SY_DEADLINE=1 sy_admin rescan
  sy_error "helper: rescan while another job holds the lock" busy 3
  kill "$lp" 2>/dev/null
  wait "$lp" 2>/dev/null
  sy_assert "helper: no private work dir left in /run" test -z "$(find "$FX_ROOT/run" -maxdepth 1 -name 'omarchy-egpu-admin.*' -type d)"
}

# ---------------------------------------------------------------- helper: read-only verbs

sy_test_readonly() {
  sy_new readonly
  fx_egpu_nvidia nvidia
  mkdir -p "$FX_PCI/$SY_EGPU/drm/renderD129"
  sy_proc() { # sy_proc <pid> <comm> <uid> <link…>
    local pid=$1 comm=$2 uid=$3 i=3 l
    shift 3
    mkdir -p "$FX_ROOT/proc/$pid/fd"
    printf '%s\n' "$comm" >"$FX_ROOT/proc/$pid/comm"
    printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" >"$FX_ROOT/proc/$pid/status"
    for l in "$@"; do ln -s "$l" "$FX_ROOT/proc/$pid/fd/$i"; i=$((i + 1)); done
  }
  sy_proc 4242 quickshell 1000 /dev/nvidia0 /dev/nvidiactl /dev/dri/card0 /dev/nvidia0
  sy_proc 5151 steam 1000 /dev/dri/renderD129 /dev/null
  sy_proc 6000 bash 1000 /dev/null /dev/dri/card0 /dev/dri/renderD128
  sy_proc 7000 'ev"il\name' 0 /dev/nvidia-uvm /dev/nvidia0x /dev/nvidia-modeset
  sy_proc 812 Hyprland 1000 /dev/dri/card1
  sy_proc 9000 $'bad\xff\x01name' 1000 /dev/nvidiactl
  # M2: link targets are chosen by whoever opened the file. One that holds a
  # newline and a tab must not read as a row for pid 1; one that ends in a tab
  # is not /dev/nvidiactl.
  sy_proc 4343 forger 1000 $'/tmp/x\n/proc/1/fd\t/dev/nvidia0' $'/tmp/y\n'"$FX_ROOT"$'/proc/1/fd\t/dev/nvidia0' $'/dev/nvidiactl\t'
  mkdir -p "$FX_ROOT/proc/self" "$FX_ROOT/proc/sys/fd"
  sy_admin holders
  sy_check "helper: holders lists the eGPU's holders, any user, sorted by pid" \
    '[.holders[].pid] == [812, 4242, 5151, 7000, 9000]'
  sy_check "  …a link target with a newline or tab forges no row (no pid 1, not the forger)" \
    '[.holders[].pid | select(. == 1 or . == 4343)] == []'
  sy_check "  …with their nodes, deduplicated, never the iGPU's" \
    '(.holders[] | select(.pid == 4242) | .nodes) == ["/dev/nvidia0","/dev/nvidiactl"]
     and (.holders[] | select(.pid == 5151) | .nodes) == ["/dev/dri/renderD129"]
     and (.holders[] | select(.pid == 812) | .nodes) == ["/dev/dri/card1"]'
  sy_check "  …uid and an escaped comm" \
    '(.holders[] | select(.pid == 7000)) as $h | $h.uid == 0 and $h.comm == "ev\"il\\name" and $h.nodes == ["/dev/nvidia-modeset","/dev/nvidia-uvm"]'
  sy_check "  …a non-UTF-8 comm still gives valid JSON" '(.holders[] | select(.pid == 9000) | .comm) == "bad??name"'
  sy_check "  …and the eGPU DRM nodes it matched" '.nodes == ["/dev/dri/card1","/dev/dri/renderD129"]'

  mkdir -p "$FX_ROOT/boot/EFI/Linux"
  printf '%s\n' usr/lib/modules/7.2.5/kernel/drivers/gpu/drm/xe/xe.ko.zst usr/lib/modules/7.2.5/kernel/drivers/thunderbolt/thunderbolt.ko.zst \
    >"$FX_ROOT/boot/initramfs-linux.img"
  printf '%s\n' usr/lib/modules/7.2.5/updates/dkms/nvidia.ko.zst usr/lib/modules/7.2.5/updates/dkms/nvidia-drm.ko.zst \
    usr/lib/modules/7.2.5/updates/dkms/nvidia-uvm.ko.xz usr/lib/modules/7.2.5/updates/dkms/nvidia-peermem.ko usr/bin/nvidia-smi \
    >"$FX_ROOT/boot/initramfs-linux-fallback.img"
  printf '%s\n' usr/lib/modules/7.2.5/kernel/drivers/gpu/drm/xe/xe.ko.zst >"$FX_ROOT/boot/EFI/Linux/arch-linux.efi"
  ln -s /etc/shadow "$FX_ROOT/boot/evil.img"
  : >"$EGPU_FAKE_LOG"
  sy_admin inspect-initramfs
  sy_check "helper: inspect-initramfs lists each image's allowlisted modules" \
    '[.images[] | {p: .path, m: .modules}] == [
       {p: "/boot/initramfs-linux-fallback.img", m: ["nvidia","nvidia_drm","nvidia_uvm"]},
       {p: "/boot/initramfs-linux.img", m: []},
       {p: "/boot/EFI/Linux/arch-linux.efi", m: []}]
     and all(.images[]; .ok) and .checked == ["nvidia","nvidia_modeset","nvidia_drm","nvidia_uvm"]'
  sy_assert "  …and does not follow a symlinked image" bash -c '! grep -q evil "$1"' _ "$EGPU_FAKE_LOG"
}

# ---------------------------------------------------------------- helper: as uid 0 in a namespace

sy_test_namespace() {
  sy_new namespace
  local unshare_ok
  unshare_ok=$(PATH=/usr/bin:/bin type -P unshare) &&
    timeout 10 "$unshare_ok" -rm /usr/bin/mount -t tmpfs tmpfs /run >/dev/null 2>&1 || unshare_ok=''
  if [[ -z $unshare_ok ]]; then
    echo "  ${DIM}skip  unprivileged user namespaces are not available${RESET}"
    return 0
  fi
  fx_egpu_nvidia none
  mkdir -p "$T/evilbin"
  printf '#!/bin/bash\ntouch %q\n' "$T/evil-path-ran" >"$T/evilbin/modprobe"
  chmod +x "$T/evilbin/modprobe"
  mkdir -p "$T/decoy/sys/bus/pci/devices" "$T/decoy/run"
  # sy_ns <args…>: the installed-path helper as uid 0 in a mount namespace
  # where /sys is the fixture's, /run is empty and modprobe/logger are fakes.
  # The test root, EGPU_SYS and PATH all point somewhere else.
  sy_ns() {
    local unshare_bin
    unshare_bin=$(PATH=/usr/bin:/bin type -P unshare)
    OMARCHY_EGPU_ADMIN_TEST_ROOT="$T/decoy" EGPU_SYS="$T/decoy/sys" PATH="$T/evilbin:$PATH" \
      timeout 60 "$unshare_bin" -rm /usr/bin/bash -c '
        /usr/bin/mount --bind "$1" /sys && /usr/bin/mount -t tmpfs tmpfs /run &&
          /usr/bin/mount --bind "$2" /usr/bin/modprobe && /usr/bin/mount --bind "$3" /usr/bin/logger || exit 99
        shift 3
        [[ -n ${SY_BASH_ENV:-} ]] && export BASH_ENV=$SY_BASH_ENV
        exec "$@"' _ "$FX_ROOT/sys" "$TESTS/fakes/bin/modprobe" "$TESTS/fakes/bin/logger" \
      "$SY_ADMIN" "$@" >"$T/out.json" 2>"$T/err" </dev/null
    SY_RC=$?
  }
  sy_ns version
  sy_check "namespace (uid 0): version" '.version | type == "string"'
  sy_ns remove "$SY_IGPU"
  sy_error "namespace (uid 0): remove the iGPU from the real-path /sys" not_egpu
  sy_ns load nvidia
  sy_check "namespace (uid 0): load nvidia through /usr/bin/modprobe, not the caller's PATH" '.ok == true and (.loaded | length) == 4'
  sy_assert "  …the caller's modprobe never ran" test ! -e "$T/evil-path-ran"
  sy_assert "  …the action was logged (fake logger)" sy_log_has '^logger .*load nvidia'
  sy_kernel "$SY_EGPU" "$SY_AUDIO"
  sy_ns remove "$SY_EGPU"
  sy_check "namespace (uid 0): remove the eGPU, ignoring the decoy test root" '.ok == true and (.removed | length) == 2'
  sy_ns remove ../../../etc
  sy_error "namespace (uid 0): path traversal" bad_address
  printf 'touch %q\n' "$T/bash-env-ran" >"$T/bash-env"
  # Set by the wrapper just before it execs the helper: its own bash -c
  # would read BASH_ENV itself.
  SY_BASH_ENV="$T/bash-env" sy_ns version
  sy_check "namespace (uid 0): version with BASH_ENV set" '.version | type == "string"'
  sy_assert "  …BASH_ENV is not read" test ! -e "$T/bash-env-ran"

  # M10: a logger stuck on a wedged journal is abandoned like any child.
  touch "$EGPU_FAKE_DIR/logger-hang"
  local t0=$SECONDS
  sy_ns unload nvidia
  sy_check "namespace (uid 0): unload answers although logger hangs" '.ok == true and (.unloaded | length) == 4'
  sy_assert "  …within the audit deadline ($((SECONDS - t0)) s)" test $((SECONDS - t0)) -le 9
  rm -f "$EGPU_FAKE_DIR/logger-hang"

  # The installer as uid 0 without --root refuses at its gate, before it
  # opens a lock or reads the plugin folder: run from the plugin folder; from a
  # root-only copy without the fetched checksum; with a checksum not its own.
  local good
  good=$(cut -d' ' -f1 "$REPO/system/install.sh.sha256")
  sy_ns_install() { # sy_ns_install <copy|direct> <args…>
    local how=$1 unshare_bin
    shift
    unshare_bin=$(PATH=/usr/bin:/bin type -P unshare)
    timeout 60 "$unshare_bin" -rm /usr/bin/bash -c '
      /usr/bin/mount -t tmpfs tmpfs /run || exit 99
      src=$1 how=$2
      shift 2
      if [[ $how == copy ]]; then
        t=$(/usr/bin/mktemp -d /run/omarchy-egpu-installer.XXXXXX) && /usr/bin/cp -- "$src" "$t/install.sh" || exit 99
        src=$t/install.sh
      fi
      exec /usr/bin/bash "$src" "$@"' _ "$SY_INSTALL" "$how" "$@" >"$T/out.json" 2>"$T/err" </dev/null
    SY_RC=$?
  }
  sy_ns_install direct --expect-sha256 "$good" install "$REPO" "$(id -un)"
  sy_error "namespace (uid 0): install.sh run straight from the plugin folder" not_a_root_copy
  sy_ns_install copy install "$REPO" "$(id -un)"
  sy_error "namespace (uid 0): a root-only copy without --expect-sha256" no_expected_checksum
  sy_ns_install copy --expect-sha256 "$(printf 'f%.0s' {1..64})" install "$REPO" "$(id -un)"
  sy_error "namespace (uid 0): a root-only copy whose checksum differs" self_check_failed

  # M7: --root skips the root-copy check, so as root it is refused unless
  # the tests ask for it; and OWNER_UID never comes from the environment.
  mkdir -p "$T/plugin"
  cp -r "$REPO/system" "$T/plugin/system"
  sy_ns_install direct --root "$FX_ROOT" --yes install "$T/plugin" "$(id -un)"
  sy_error "namespace (uid 0): --root as root" test_root_as_root
  sy_assert "  …installed nothing" test ! -e "$FX_ROOT/usr/local/bin/omarchy-egpu-admin"
  OMARCHY_EGPU_INSTALL_TEST=1 OWNER_UID=4242 sy_ns_install direct --root "$FX_ROOT" --yes install "$T/plugin" "$(id -un)"
  sy_check "namespace (uid 0): --root with OMARCHY_EGPU_INSTALL_TEST=1, OWNER_UID=4242 in the environment is ignored" \
    '.ok == true and .autoconnect == true'
  sy_done
}

# ---------------------------------------------------------------- helper: the eject latch

# With auto-connect on, the udev rule runs `load auto` on every add of the
# card. After a Safe eject the enclosure is still plugged in, so a rescan or a
# re-enumeration would load the driver again behind the user's back.
sy_test_latch() {
  sy_new latch
  fx_egpu_nvidia none
  sy_enclosure
  local port_ino
  port_ino=$(stat -c %i "$FX_ROOT/$SY_PORT")

  sy_kernel "$SY_EGPU" "$SY_AUDIO"
  sy_admin remove "$SY_EGPU"
  sy_check "latch: remove the eGPU (in its enclosure)" '.ok == true and (.removed | length) == 2'
  sy_assert "  …the latch names the device and its enclosure's port, by path and inode" \
    test "$(sy_latch)" = "$SY_EGPU"$'\t'"/$SY_PORT"$'\t'"$port_ino"
  sy_assert "  …root's file in /run, mode 644" test "$(stat -c %a "$FX_ROOT/run/omarchy-egpu-admin.ejected")" = 644

  # The card back on the same connection (a rescan, a re-enumeration).
  fx_egpu_nvidia none
  sy_enclosure
  : >"$EGPU_FAKE_LOG"
  sy_admin load auto
  sy_error "latch: load auto for the card the user ejected" eject_latched
  sy_check_detail() { jq -e "$1" "$T/out.json" >/dev/null 2>&1 && ok "$2" || bad "$2: $(cat "$T/out.json")"; }
  sy_check_detail ".device == \"$SY_EGPU\" and .ejected == \"$SY_EGPU\"" "  …names it"
  sy_assert "  …ran no modprobe, kept the latch" bash -c '! grep -q "^modprobe" "$1" && [[ -s $2 ]]' _ \
    "$EGPU_FAKE_LOG" "$FX_ROOT/run/omarchy-egpu-admin.ejected"
  sy_admin load auto
  sy_error "latch: and again (the latch is not used up)" eject_latched

  # The user connects: an explicit backend clears it.
  sy_admin load nvidia
  sy_check "latch: load nvidia (Connect) loads" '.ok == true and (.loaded | length) == 4'
  sy_assert "  …and clears the latch" test ! -e "$FX_ROOT/run/omarchy-egpu-admin.ejected"

  # Eject, unplug, plug in again: auto-connect works again.
  fx_modules_remove nvidia nvidia_modeset nvidia_drm nvidia_uvm
  sy_kernel "$SY_EGPU" "$SY_AUDIO"
  sy_admin remove "$SY_EGPU"
  sy_check "latch: eject again" '.ok == true'
  sy_replug
  sy_assert "  …(the port came back as a new directory)" test "$(stat -c %i "$FX_ROOT/$SY_PORT")" != "$port_ino"
  : >"$EGPU_FAKE_LOG"
  sy_admin load auto
  sy_check "latch: after an unplug and replug, load auto loads" '.ok == true and (.loaded | length) == 4'
  sy_assert "  …and the stale latch is gone" test ! -e "$FX_ROOT/run/omarchy-egpu-admin.ejected"

  # Another enclosure's card is not held back by this one's latch.
  fx_modules_remove nvidia nvidia_modeset nvidia_drm nvidia_uvm
  sy_kernel "$SY_EGPU" "$SY_AUDIO"
  sy_admin remove "$SY_EGPU"
  fx_pci 0000:08:00.0 0x030000 0x10de 0x2783 removable=removable boot_vga=0
  sy_admin load auto
  sy_check "latch: a different eGPU loads while the ejected one's latch stands" '.ok == true and .device == "0000:08:00.0"'
  sy_assert "  …and the latch stays" test -s "$FX_ROOT/run/omarchy-egpu-admin.ejected"
  fx_pci_remove 0000:08:00.0
  fx_modules_remove nvidia nvidia_modeset nvidia_drm nvidia_uvm

  # A latch that cannot be read holds every device back, until Connect.
  fx_egpu_nvidia none
  sy_enclosure
  local bad_latch
  for bad_latch in 'garbage' "$SY_EGPU"$'\t/sys/devices/../../etc\t1' "$SY_EGPU"$'\t/etc/shadow\t1' $'0000:03:00.0\t-\tx'; do
    printf '%s\n' "$bad_latch" >"$FX_ROOT/run/omarchy-egpu-admin.ejected"
    sy_admin load auto
    sy_error "latch: an unreadable latch ('$(printf '%q' "$bad_latch")') is honoured" eject_latched
  done
  rm -f "$FX_ROOT/run/omarchy-egpu-admin.ejected"
  ln -s /dev/null "$FX_ROOT/run/omarchy-egpu-admin.ejected"
  sy_admin load auto
  sy_error "latch: a latch that is a symlink is honoured, not followed" eject_latched
  sy_admin load nvidia
  sy_check "latch: Connect clears even that" '.ok == true'
  sy_assert "  …the link removed, its target untouched" test ! -L "$FX_ROOT/run/omarchy-egpu-admin.ejected" -a -c /dev/null
  sy_done
}

# ---------------------------------------------------------------- helper: autoconnect

# The verb's refusals; the round trip on an installed tree is in
# sy_test_install, next to the installer's own flag.
sy_test_autoconnect() {
  sy_new autoconnect
  local dir=$FX_ROOT/etc/omarchy-egpu flag=$FX_ROOT/etc/omarchy-egpu/autoconnect
  chmod 0755 "$FX_ROOT/etc"

  sy_admin autoconnect on
  sy_error "autoconnect: on with no system half (no directory)" not_installed
  sy_assert "  …created nothing (no mkdir)" test ! -e "$dir"
  sy_admin autoconnect off
  sy_check "autoconnect: off with no directory is already off" '.ok == true and .autoconnect == false'

  mkdir -m 0777 "$dir"
  sy_admin autoconnect on
  sy_error "autoconnect: a directory others may write" unsafe_dir
  chmod 0755 "$dir"
  chmod 0777 "$FX_ROOT/etc"
  sy_admin autoconnect on
  sy_error "autoconnect: an /etc others may write" unsafe_dir
  chmod 0755 "$FX_ROOT/etc"
  rmdir "$dir"
  mkdir -p "$T/elsewhere"
  ln -s "$T/elsewhere" "$dir"
  sy_admin autoconnect on
  sy_error "autoconnect: the directory is a symlink" unsafe_dir
  sy_assert "  …nothing written through it" test -z "$(ls -A "$T/elsewhere")"
  rm "$dir"
  mkdir -m 0755 "$dir"

  # The flag's place taken by a directory, then by a link.
  mkdir "$flag"
  sy_admin autoconnect on
  sy_error "autoconnect: on, with a directory in the flag's place" autoconnect_failed
  sy_admin autoconnect off
  sy_error "autoconnect: off, with a directory in the flag's place" autoconnect_failed
  rmdir "$flag"
  printf 'keep\n' >"$T/target"
  ln -s "$T/target" "$flag"
  sy_admin autoconnect on
  sy_check "autoconnect: on over a symlink" '.ok == true'
  sy_assert "  …replaces the link with the flag, the link's target untouched" \
    test -f "$flag" -a ! -L "$flag" -a "$(cat "$T/target")" = keep
  rm "$flag"
  ln -s "$T/target" "$flag"
  sy_admin autoconnect off
  sy_check "autoconnect: off over a symlink" '.ok == true and .autoconnect == false'
  sy_assert "  …removes the link only" test ! -L "$flag" -a "$(cat "$T/target")" = keep

  # Busy, like every verb that changes something.
  (exec 7>>"$FX_ROOT/run/omarchy-egpu-admin.lock" && flock 7 && exec sleep 20) &
  local lp=$!
  fx_bg "$lp"
  sleep 0.3
  SY_DEADLINE=1 sy_admin autoconnect on
  sy_error "autoconnect: while another job holds the lock" busy 3
  kill "$lp" 2>/dev/null
  wait "$lp" 2>/dev/null
  sy_assert "  …wrote nothing" test ! -e "$flag"
}

# ---------------------------------------------------------------- policy and rule

sy_test_files() {
  sy_new files
  # The helper's verbs, from its case labels (version is answered before).
  local verbs
  verbs=$(sed -n 's/^  \([a-z-]*\))$/\1/p' "$REPO/system/omarchy-egpu-admin" | paste -sd' ')
  sy_assert "helper: its verbs are the documented ones ($verbs)" \
    test "$verbs" = "load unload remove rescan holders inspect-initramfs autoconnect"
  if python3 - "$REPO/system/no.kalinewb.egpu.policy" "$verbs" <<'PY' 2>"$T/err"
import sys, xml.etree.ElementTree as ET
PATH, ARGV1 = "org.freedesktop.policykit.exec.path", "org.freedesktop.policykit.exec.argv1"
root = ET.parse(sys.argv[1]).getroot()
verbs = set(sys.argv[2].split())
acts = root.findall("action")
ids = [a.get("id") for a in acts]
assert len(ids) == len(set(ids)), "duplicate action ids"
assert all(i.startswith("no.kalinewb.egpu.") for i in ids), "namespace"
seen = {}
for a in acts:
    ann = {x.get("key"): x.text for x in a.findall("annotate")}
    # Every action names its verb: no catch-all whose order could matter.
    assert set(ann) == {PATH, ARGV1}, f"{a.get('id')}: annotations {sorted(ann)}"
    assert ann[PATH] == "/usr/local/bin/omarchy-egpu-admin", f"{a.get('id')}: exec.path"
    v = ann[ARGV1]
    assert v not in seen, f"argv1 {v} twice"
    seen[v] = a.get("id")
    d = a.find("defaults")
    want = "auth_self" if v == "autoconnect" else "yes"
    got = (d.findtext("allow_any"), d.findtext("allow_inactive"), d.findtext("allow_active"))
    assert got == ("no", "no", want), f"{a.get('id')}: defaults {got}"
    msg = a.findtext("message")
    if v == "autoconnect":
        assert msg.startswith("Authentication is required"), "autoconnect message"
    else:
        assert "without a password" in msg and "Authentication" not in msg, f"{a.get('id')}: message"
assert set(seen) == verbs, f"argv1 {sorted(seen)} != helper verbs {sorted(verbs)}"
PY
  then ok "policy: one action per helper verb by argv1, device verbs allow_active=yes, autoconnect auth_self, no catch-all"
  else bad "policy: $(cat "$T/err")"; fi

  local rules=$REPO/system/61-omarchy-egpu.rules
  sy_assert "rule: links only drm_minor card nodes" \
    test "$(grep -c 'SYMLINK+=' "$rules")" = 2 -a "$(grep 'SYMLINK+=' "$rules" | grep -c 'ENV{DEVTYPE}=="drm_minor"')" = 2
  sy_assert "rule: primary by the by-path ID_PATH, external by display class + removable, never cardN" \
    bash -c 'grep -q "ENV{ID_PATH}==\"pci-@PRIMARY_BDF@\".*dri/omarchy-egpu-primary" "$1" &&
      grep -q "ATTRS{class}==\"0x03\[0-9\]\*\", ATTRS{removable}==\"removable\".*dri/omarchy-egpu-external" "$1" &&
      ! grep -qE "card[0-9]+\"|KERNEL==\"card1" "$1"' _ "$rules"
  sy_assert "rule: auto-connect runs only 'load auto', only with the flag file" \
    bash -c '[[ $(grep -c "RUN+=" "$1") == 1 ]] && grep "RUN+=" "$1" | grep -q "TEST==\"/etc/omarchy-egpu/autoconnect\".*RUN+=\"/usr/local/bin/omarchy-egpu-admin load auto\"$"' _ "$rules"
  local udevadm_bin
  if udevadm_bin=$(PATH=/usr/bin:/bin type -P udevadm) && "$udevadm_bin" verify --help >/dev/null 2>&1; then
    sed 's/@PRIMARY_BDF@/0000:00:02.0/' "$rules" >"$T/61-omarchy-egpu.rules"
    if "$udevadm_bin" verify "$T/61-omarchy-egpu.rules" >"$T/err" 2>&1; then ok "rule: udevadm verify accepts the rendered rule"
    else bad "rule: udevadm verify: $(head -c 300 "$T/err")"; fi
  else
    echo "  ${DIM}skip  udevadm verify is not available${RESET}"
  fi
}

# ---------------------------------------------------------------- installer

# sy_tree: a listing of everything install may touch, with content hashes.
sy_tree() {
  (cd "$FX_ROOT" && find etc usr var -printf '%p %y %m %s\n' 2>/dev/null | sort &&
    find etc usr var -type f -exec sha256sum {} + 2>/dev/null | sort -k2)
}

sy_test_install() {
  sy_new install
  mkdir -p "$T/plugin"
  cp -r "$REPO/system" "$T/plugin/system"
  local me
  me=$(id -un)
  sy_tree >"$T/tree.before"

  "$ENGINE" health >"$T/health.before" 2>/dev/null
  jq -e '(.[] | select(.id == "boot.modules_load_mask") | .level) == "error"
     and (.[] | select(.id == "system.helper") | .level) == "error"' "$T/health.before" >/dev/null &&
    ok "install: before, health shows boot.modules_load_mask and system.helper as errors" ||
    bad "install: health before: $(jq -c '[.[] | select(.id == "boot.modules_load_mask" or .id == "system.helper") | {id, level}]' "$T/health.before")"

  bash "$SY_INSTALL" install "$T/plugin" "$me" >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
  sy_error "install: unprivileged without --root" not_root
  sy_install install "$T/plugin"
  sy_error "install: missing the account" bad_arguments
  sy_install install relative/plugin "$me"
  sy_error "install: relative plugin dir" plugin_missing
  sy_install --expect-sha256 "$(printf '0%.0s' {1..64})" install "$T/plugin" "$me"
  sy_error "install: --expect-sha256 that is not this file's" self_check_failed
  sy_install --primary ../x install "$T/plugin" "$me"
  sy_error "install: --primary that is not an address" bad_arguments
  sy_install --autoconnect maybe install "$T/plugin" "$me"
  sy_error "install: --autoconnect maybe" bad_arguments

  # A tampered plugin file, then a symlinked one: nothing installed.
  printf '\n# extra\n' >>"$T/plugin/system/omarchy-egpu-admin"
  sy_install --yes install "$T/plugin" "$me"
  sy_error "install: a system file that does not match its pin" snapshot_modified
  cp "$REPO/system/omarchy-egpu-admin" "$T/plugin/system/omarchy-egpu-admin"
  rm "$T/plugin/system/no.kalinewb.egpu.policy"
  ln -s "$REPO/system/no.kalinewb.egpu.policy" "$T/plugin/system/no.kalinewb.egpu.policy"
  sy_install --yes install "$T/plugin" "$me"
  sy_error "install: a symlinked system file" snapshot_unsafe
  rm "$T/plugin/system/no.kalinewb.egpu.policy"
  cp "$REPO/system/no.kalinewb.egpu.policy" "$T/plugin/system/"
  sy_assert "install: refusals installed nothing and left no snapshot" \
    test ! -e "$FX_ROOT/usr/local/bin/omarchy-egpu-admin" -a -z "$(find "$FX_ROOT/run" -name 'omarchy-egpu-install.*' -type d)"
  sy_tree >"$T/tree.refused"
  sy_assert "  …and created no directory either" diff -q "$T/tree.before" "$T/tree.refused"
  sy_assert "install: the install lock is mode 600" test "$(stat -c %a "$FX_ROOT/run/omarchy-egpu-install.lock")" = 600

  # M5: root's part of the printed command runs nothing from the user's PATH.
  local cmd rootpart
  cmd=$(bash "$SY_INSTALL" --print-command install)
  rootpart=${cmd#*"sudo /usr/bin/bash -c '"}
  rootpart=${rootpart%%"' omarchy-egpu "*}
  sy_assert "install: the printed command is 'sudo /usr/bin/bash -c' with PATH=/usr/bin first" \
    test "${rootpart:0:14}" = 'PATH=/usr/bin;' -a "$rootpart" != "$cmd"
  sy_assert "  …absolute tools, the installer under bash -p, and it parses" bash -c '
    [[ $1 == *"/usr/bin/mktemp -d "* && $1 == *"/usr/bin/cp -- "* && $1 == *"/usr/bin/sha256sum -c"* &&
       $1 == *"/usr/bin/bash -p \"\$t/install.sh\""* && $1 == *"/usr/bin/rm -rf"* ]] &&
    ! grep -qE "(^|[;&|(] *)(mktemp|cp|sha256sum|bash|rm|sudo) " <<<"$1" && bash -n -c "$2"' _ "$rootpart" "$cmd"

  # Non-interactive without --yes: the stale mask is explained and left.
  sy_install --expect-sha256 "$(cut -d' ' -f1 "$REPO/system/install.sh.sha256")" install "$T/plugin" "$me"
  sy_check "install: installs (pinned checksum given), the stale mask left without --yes" \
    '.ok == true and .primary == "0000:00:02.0" and .masked == ["/etc/modules-load.d/nvidia-580xx-utils.conf"]
     and .stale_removed == [] and (.warnings | any(test("nvidia-utils.conf is a stale empty mask")))'
  sy_assert "  …the question was shown" grep -q 'masks nothing and does nothing' "$T/err"

  sy_install --yes install "$T/plugin" "$me"
  sy_check "install: again with --yes moves the stale mask to the backup; auto-connect on (the default)" \
    '.ok == true and .stale_removed == ["/etc/modules-load.d/nvidia-utils.conf"] and .autoconnect == true
     and (.backup | startswith("/var/backups/omarchy-egpu/"))'
  local backup
  backup=$(jq -r .backup "$T/out.json")
  sy_assert "  …the helper is the repo's bytes, mode 755" \
    bash -c 'cmp -s "$1" "$2" && [[ $(stat -c %a "$2") == 755 ]]' _ "$REPO/system/omarchy-egpu-admin" "$FX_ROOT/usr/local/bin/omarchy-egpu-admin"
  sy_assert "  …the policy, mode 644" \
    bash -c 'cmp -s "$1" "$2" && [[ $(stat -c %a "$2") == 644 ]]' _ "$REPO/system/no.kalinewb.egpu.policy" "$FX_ROOT/usr/share/polkit-1/actions/no.kalinewb.egpu.policy"
  sy_assert "  …the rule, with the boot VGA address filled in on one line only" \
    bash -c 'diff <(sed "s/@PRIMARY_BDF@/0000:00:02.0/" "$1") "$2" >/dev/null && grep -q "ENV{ID_PATH}==\"pci-0000:00:02.0\"" "$2"' \
    _ "$REPO/system/61-omarchy-egpu.rules" "$FX_ROOT/etc/udev/rules.d/61-omarchy-egpu.rules"
  sy_assert "  …the mask under the shipped file's name, loading nothing" \
    bash -c 'cmp -s "$1" "$2" && ! grep -qv "^#" "$2"' _ "$REPO/system/omarchy-egpu-modules.conf" "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_assert "  …the stale file is in the backup, empty" test -f "$FX_ROOT$backup/etc/modules-load.d/nvidia-utils.conf" -a ! -s "$FX_ROOT$backup/etc/modules-load.d/nvidia-utils.conf"
  sy_assert "  …the auto-connect flag, mode 644, in a 755 directory" \
    test -f "$FX_ROOT/etc/omarchy-egpu/autoconnect" -a "$(stat -c %a "$FX_ROOT/etc/omarchy-egpu/autoconnect")" = 644 \
    -a "$(stat -c %a "$FX_ROOT/etc/omarchy-egpu")" = 755
  sy_assert "  …a record of every file and backup" \
    bash -c '[[ $(grep -c "^file" "$1") == 5 && $(grep -c "^backup" "$1") == 1 ]]' _ "$FX_ROOT/var/lib/omarchy-egpu/installed"

  "$ENGINE" health >"$T/health.after" 2>/dev/null
  jq -e '(.[] | select(.id == "boot.modules_load_mask") | .level) == "ok"
     and (.[] | select(.id == "system.helper") | .level) == "ok"' "$T/health.after" >/dev/null &&
    ok "install: after, health shows both rows ok (the real helper answers version)" ||
    bad "install: health after: $(jq -c '[.[] | select(.id == "boot.modules_load_mask" or .id == "system.helper") | {id, level, detail}]' "$T/health.after")"

  # S1: a reinstall that is refused leaves the install as it was: the mask,
  # the flag, the helper, the record.
  sy_tree >"$T/tree.installed"
  printf '\n# extra\n' >>"$T/plugin/system/omarchy-egpu-admin"
  sy_install --yes reinstall "$T/plugin" "$me"
  sy_error "install: reinstall from a tampered plugin" snapshot_modified
  cp "$REPO/system/omarchy-egpu-admin" "$T/plugin/system/omarchy-egpu-admin"
  sy_tree >"$T/tree.after-refusal"
  if diff "$T/tree.installed" "$T/tree.after-refusal" >"$T/tree.diff"; then
    ok "  …and left the old install byte-for-byte in place, mask included"
  else
    bad "  …the tree changed: $(head -c 400 "$T/tree.diff")"
  fi
  sy_install --yes --primary 0000:09:00.0 reinstall "$T/plugin" "$me"
  sy_error "install: reinstall with a primary that does not exist" no_primary
  sy_tree >"$T/tree.after-refusal"
  sy_assert "  …left it in place too" diff -q "$T/tree.installed" "$T/tree.after-refusal"

  # The panel's switch: the helper's `autoconnect` verb on the installed
  # tree. Its flag is the installer's, byte for byte, and the engine reads
  # connect.auto from it, whatever config.json says.
  cp "$FX_ROOT/etc/omarchy-egpu/autoconnect" "$T/flag.installer"
  echo '{"connect":{"auto":true}}' >"$EGPU_CONFIG"
  sy_admin autoconnect off
  sy_check "autoconnect: off through the helper" '.ok == true and .autoconnect == false'
  sy_assert "  …the flag is gone, the directory stays" test ! -e "$FX_ROOT/etc/omarchy-egpu/autoconnect" -a -d "$FX_ROOT/etc/omarchy-egpu"
  sy_assert "  …status says connect.auto false although config.json says true" \
    test "$("$ENGINE" status --json 2>/dev/null | jq -c .connect)" = '{"auto":false}'
  sy_assert "  …health says it is off" \
    test "$("$ENGINE" health 2>/dev/null | jq -r '.[] | select(.id == "system.autoconnect") | .level')" = info
  sy_admin autoconnect off
  sy_check "autoconnect: off again is fine" '.ok == true and .autoconnect == false'
  sy_admin autoconnect on
  sy_check "autoconnect: on through the helper" '.ok == true and .autoconnect == true'
  sy_assert "  …the same bytes the installer writes, mode 644" \
    bash -c 'cmp -s "$1" "$2" && [[ $(stat -c %a "$2") == 644 ]]' _ "$T/flag.installer" "$FX_ROOT/etc/omarchy-egpu/autoconnect"
  sy_assert "  …status says connect.auto true" test "$("$ENGINE" status --json 2>/dev/null | jq -c .connect)" = '{"auto":true}'
  sy_assert "  …health says it is on" \
    test "$("$ENGINE" health 2>/dev/null | jq -r '.[] | select(.id == "system.autoconnect") | .level')" = ok
  sy_assert "  …no temp file left beside it" test -z "$(find "$FX_ROOT/etc/omarchy-egpu" -name '.autoconnect.*')"
  rm -f "$EGPU_CONFIG"

  sy_install --autoconnect on reinstall "$T/plugin" "$me"
  sy_check "install: reinstall with --autoconnect on" '.ok == true and .autoconnect == true'
  sy_assert "  …the flag exists" test -f "$FX_ROOT/etc/omarchy-egpu/autoconnect"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "install: a later install without --autoconnect keeps it" '.autoconnect == true'
  sy_install --autoconnect off install "$T/plugin" "$me"
  sy_check "install: --autoconnect off" '.autoconnect == false'
  sy_assert "  …the flag is gone" test ! -e "$FX_ROOT/etc/omarchy-egpu/autoconnect"
  sy_install --yes --autoconnect on install "$T/plugin" "$me"

  # Busy: another install holds the lock.
  (exec 7>>"$FX_ROOT/run/omarchy-egpu-install.lock" && flock 7 && exec sleep 20) &
  local lp=$!
  fx_bg "$lp"
  sleep 0.3
  sy_install --yes install "$T/plugin" "$me"
  sy_error "install: while another install runs" busy 3
  kill "$lp" 2>/dev/null
  wait "$lp" 2>/dev/null

  # A reinstall keeps the user's choice, and says nothing about boot loading
  # (the mask is back by the time it ends).
  sy_admin autoconnect off
  sy_install --yes reinstall "$T/plugin" "$me"
  sy_check "install: a reinstall keeps auto-connect off when the user turned it off" \
    '.ok == true and .autoconnect == false and (.warnings | all(test("at boot again") | not))'
  sy_admin autoconnect on

  # The flag goes whatever it holds: it is only a switch.
  printf 'edited by hand\n' >"$FX_ROOT/etc/omarchy-egpu/autoconnect"
  sy_install uninstall
  sy_check "install: uninstall removes everything and restores the stale file" \
    '.ok == true and .kept == [] and .restored == ["/etc/modules-load.d/nvidia-utils.conf"] and (.removed | length) == 5
     and any(.removed[]; . == "/etc/omarchy-egpu/autoconnect")'
  # M9: the freeze condition comes back with the mask gone, and says so.
  sy_check "  …warns that nvidia_uvm loads at boot again" \
    '.warnings | any(test("/usr/lib/modules-load.d/nvidia-580xx-utils.conf loads nvidia_uvm at boot again"))'
  sy_assert "  …loudly, on the terminal" grep -q 'WARNING: /usr/lib/modules-load.d/nvidia-580xx-utils.conf loads nvidia_uvm' "$T/err"
  sy_tree >"$T/tree.after"
  if diff "$T/tree.before" "$T/tree.after" >"$T/tree.diff"; then
    ok "install: after uninstall the tree is byte-for-byte what it was"
  else
    bad "install: tree differs after uninstall: $(head -c 400 "$T/tree.diff")"
  fi
  sy_install uninstall
  sy_check "install: uninstall again is a no-op" '.ok == true and .removed == [] and .restored == []'
}

sy_test_install_masks() {
  sy_new install-masks
  mkdir -p "$T/plugin"
  cp -r "$REPO/system" "$T/plugin/system"
  local me
  me=$(id -un)

  # The user's own mask that LOADS the module, under the shipped name:
  # backed up, replaced, restored by uninstall.
  printf 'nvidia-uvm\n' >"$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_tree >"$T/tree.before"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: an /etc file of the shipped name loading the module is replaced" \
    '.masked == ["/etc/modules-load.d/nvidia-580xx-utils.conf"]'
  sy_assert "  …after a backup" test -f "$FX_ROOT$(jq -r .backup "$T/out.json")/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_install uninstall
  sy_tree >"$T/tree.after"
  sy_assert "  …and uninstall restores it exactly" diff -q "$T/tree.before" "$T/tree.after"

  # Already masked by a link to /dev/null, or by an empty file: left alone.
  rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  ln -s /dev/null "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: a /dev/null link mask is left alone" \
    '.masked == [] and .already_masked == ["/etc/modules-load.d/nvidia-580xx-utils.conf"]'
  sy_assert "  …still the link" test -L "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_install uninstall

  rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  printf 'nvidia_uvm\ni2c-dev\n' >"$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: a file that also loads other modules is not replaced" \
    '.masked == [] and (.warnings | any(test("also loads other modules")))'
  sy_install uninstall
  rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"

  # A non-empty stale-looking file, and an empty one whose package still
  # ships the file: both are real, and left alone.
  printf 'nvidia-uvm\n' >"$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"
  fx_write usr/lib/modules-load.d/nvidia-open-utils.conf ''
  : >"$FX_ROOT/etc/modules-load.d/nvidia-open-utils.conf"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: only an EMPTY stale file with no shipped counterpart is removed" \
    '.stale_removed == [] and (.warnings | any(test("nvidia-utils.conf is not empty")))'
  sy_assert "  …both still there" test -s "$FX_ROOT/etc/modules-load.d/nvidia-utils.conf" -a -e "$FX_ROOT/etc/modules-load.d/nvidia-open-utils.conf"
  sy_install uninstall

  # A shipped file under a new name is found by its content, not its name.
  rm -f "$FX_ROOT/usr/lib/modules-load.d/nvidia-580xx-utils.conf"
  fx_write usr/lib/modules-load.d/nvidia-590xx-utils.conf '# shipped
nvidia_uvm'
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: the shipped file's name is detected, not assumed" \
    '.masked == ["/etc/modules-load.d/nvidia-590xx-utils.conf"]'
  sy_install uninstall

  # M8: every directory systemd-modules-load reads. A file in /usr/local/lib
  # is masked too; an empty /run file of the shipped name is not a mask (it
  # is gone at the next boot, and /usr/lib's then loads). First install with
  # --autoconnect off: no flag, but the directory the panel's switch needs.
  fx_write usr/local/lib/modules-load.d/nvidia-local.conf 'nvidia-drm'
  mkdir -p "$FX_ROOT/run/modules-load.d"
  : >"$FX_ROOT/run/modules-load.d/nvidia-590xx-utils.conf"
  sy_install --yes --autoconnect off install "$T/plugin" "$me"
  sy_check "masks: /usr/local/lib is masked too; a /run override does not count as a mask" \
    '.masked == ["/etc/modules-load.d/nvidia-590xx-utils.conf","/etc/modules-load.d/nvidia-local.conf"] and .autoconnect == false'
  sy_assert "  …--autoconnect off on a first install: no flag, its directory there" \
    test ! -e "$FX_ROOT/etc/omarchy-egpu/autoconnect" -a -d "$FX_ROOT/etc/omarchy-egpu"
  sy_install --yes install "$T/plugin" "$me"
  sy_check "  …a later install keeps it off" '.autoconnect == false'
  sy_install uninstall
  sy_check "  …uninstall warns for both files" \
    '[.warnings[] | select(test("at boot again"))] | length == 2'
  rm -rf "$FX_ROOT/usr/local/lib/modules-load.d" "$FX_ROOT/run/modules-load.d"

  # Masking a shipped file stops everything it loads; that is said.
  fx_write usr/lib/modules-load.d/nvidia-590xx-utils.conf 'nvidia-uvm
i2c-dev'
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: a shipped file that also loads other modules is masked, with a warning naming them" \
    '.masked == ["/etc/modules-load.d/nvidia-590xx-utils.conf"] and (.warnings | any(test("also loads i2c_dev")))'
  sy_install uninstall

  # An empty /etc file is not stale while /usr/local/lib (or /run) has the name.
  : >"$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"
  fx_write usr/local/lib/modules-load.d/nvidia-utils.conf 'crypto_user'
  sy_install --yes install "$T/plugin" "$me"
  sy_check "masks: an empty /etc file whose name /usr/local/lib ships is a real mask, kept" '.stale_removed == []'
  sy_install uninstall
  rm -rf "$FX_ROOT/usr/local/lib/modules-load.d" "$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"

  # Two boot VGA display devices: the primary is not guessed.
  fx_pci 0000:02:00.0 0x030000 0x1002 0x1234 boot_vga=1
  sy_install --yes install "$T/plugin" "$me"
  sy_error "install: two boot VGA devices" no_primary
  sy_install --yes --primary 0000:00:02.0 install "$T/plugin" "$me"
  sy_check "install: --primary picks one" '.primary == "0000:00:02.0"'
  sy_install --yes --primary 0000:03:00.0 install "$T/plugin" "$me"
  sy_error "install: --primary that does not exist" no_primary

  # A hand-edited installed rule is not deleted by uninstall.
  printf '# my own rule now\n' >"$FX_ROOT/etc/udev/rules.d/61-omarchy-egpu.rules"
  sy_install uninstall
  sy_check "install: uninstall keeps an installed file that was replaced by hand" \
    '.kept == ["/etc/udev/rules.d/61-omarchy-egpu.rules"]'
}

# ---------------------------------------------------------------- pins

sy_test_pins() {
  sy_new pins
  local out
  if out=$("$REPO/dev/check-pins.sh" 2>&1); then ok "pins: dev/check-pins.sh passes on the repo"
  else bad "pins: dev/check-pins.sh: $(head -c 400 <<<"$out")"; fi

  # A copy of the repo's relevant parts, then one break at a time.
  sy_pins_copy() {
    rm -rf "$T/repo"
    mkdir -p "$T/repo"
    cp -r "$REPO/system" "$REPO/dev" "$REPO/manifest.json" "$REPO/README.md" "$T/repo/"
  }
  sy_pins_fails() { # sy_pins_fails <label> <expected message>
    if out=$("$T/repo/dev/check-pins.sh" 2>&1); then bad "pins: $1 passed"
    elif grep -qF -- "$2" <<<"$out"; then ok "pins: $1 fails"
    else bad "pins: $1: $(head -c 300 <<<"$out")"; fi
  }
  sy_pins_copy
  if out=$("$T/repo/dev/check-pins.sh" 2>&1); then ok "pins: a clean copy passes"; else bad "pins: clean copy: $out"; fi
  printf '\n' >>"$T/repo/system/61-omarchy-egpu.rules"
  sy_pins_fails "a changed rule" "61-omarchy-egpu.rules does not match its pin"
  sy_pins_copy
  sed -i 's/^MASK_MODULES=(nvidia /MASK_MODULES=(/' "$T/repo/system/install.sh"
  sy_pins_fails "an edited installer (stale install.sh.sha256)" "install.sh.sha256 is not system/install.sh's checksum"
  sy_pins_fails "  …and a mask list that is not the allowlist" "is not the helper's allowlist"
  sy_pins_copy
  jq '.version = "0.2.0"' "$REPO/manifest.json" >"$T/repo/manifest.json"
  sy_pins_fails "a plugin version the system half does not carry" "manifest.json says '0.2.0'"
  sy_pins_copy
  sed -i 's|sudo /usr/bin/bash -c|sudo  /usr/bin/bash -c|' "$T/repo/README.md"
  sy_pins_fails "a README command that drifted" "README.md's install command is not the one install.sh prints"

  # update-pins repairs a changed file, and the installer then accepts it.
  sy_pins_copy
  printf '# local change\n' >>"$T/repo/system/omarchy-egpu-modules.conf"
  if "$T/repo/dev/update-pins.sh" >/dev/null 2>&1 && "$T/repo/dev/check-pins.sh" >/dev/null 2>&1; then
    ok "pins: dev/update-pins.sh repairs the pins"
  else
    bad "pins: update-pins did not repair: $("$T/repo/dev/check-pins.sh" 2>&1 | head -c 300)"
  fi
  timeout 60 bash "$T/repo/system/install.sh" --root "$FX_ROOT" --yes install "$T/repo" "$(id -un)" >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
  sy_check "pins: the re-pinned installer installs the changed file" '.ok == true'
  sy_assert "  …which is the changed bytes" cmp -s "$T/repo/system/omarchy-egpu-modules.conf" "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  timeout 60 bash "$SY_INSTALL" --root "$FX_ROOT" --yes install "$T/repo" "$(id -un)" >"$T/out.json" 2>"$T/err" </dev/null
  SY_RC=$?
  sy_error "pins: the repo's installer refuses that changed file" snapshot_modified
}

test_system() {
  echo "${BOLD}system${RESET}  ${DIM}(root helper, installer, pins; no root needed)${RESET}"
  (sy_test_callers)
  (sy_test_remove)
  (sy_test_remove_timeout)
  (sy_test_modules)
  (sy_test_readonly)
  (sy_test_latch)
  (sy_test_autoconnect)
  (sy_test_namespace)
  (sy_test_files)
  (sy_test_install)
  (sy_test_install_masks)
  (sy_test_pins)
}
