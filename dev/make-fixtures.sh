#!/bin/bash

# Build the panel's fixtures from the engine's own test scenarios.
#
#   ./dev/make-fixtures.sh              the scenarios the panel renders (below)
#   ./dev/make-fixtures.sh ready ...    only these
#
# For each scenario this builds the same fake machine tests/run.sh builds
# (tests/lib.sh + tests/fixtures/<name>/setup.sh), runs the REAL engine against
# it, and keeps what it printed:
#
#   dev/fixtures/<name>/status.json    `omarchy-egpu status --json`
#   dev/fixtures/<name>/health.json    `omarchy-egpu health`
#
# So every document the panel is developed against is one the engine actually
# produced, never a hand-written guess at its shape (plan-gui.md §9: "the panel
# can be built before any engine phase lands" — and against the engine that has
# landed, once it has). The stub engine in dev/bin answers from these files.
#
# Re-run it after any change to lib/status.sh or lib/health.sh and commit the
# diff; a field the panel reads that the engine stopped writing shows up there
# first. The setup below repeats tests/run.sh's setup_scenario (that file is
# the engine suite's, and is not sourced so it can change on its own terms).

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TESTS="$REPO/tests"
ENGINE="$REPO/bin/omarchy-egpu"
OUT="$REPO/dev/fixtures"

(( EUID != 0 )) || { echo "make-fixtures: do not run as root" >&2; exit 2; }

# Every summary.state at least once, and each flag the bar shows (plan-gui.md
# §4): connecting with and without a hint, HDMI on, apps on the card, relogin,
# held modules, an unsupported backend, both kinds of error, a stranger's
# machine with no Thunderbolt at all, and its opposite for the notch
# integration's `available` (G8): Thunderbolt present but boltd not answering.
DEFAULT=(absent stranger-no-tb plugged-unauthorized authorized-no-pci bound-nvidia ready
  ready-hdmi in-use-procs ejecting ejected-clean ejected-held this-machine amd-stub
  smi-hung auth-error bolt-down)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-fixtures.XXXXXX") || exit 2
cleanup() {
  local f p
  for f in "$WORK"/*/fake/bg.pids "$WORK"/*/fake/smi-hang.pids; do
    [[ -r $f ]] || continue
    while IFS= read -r p; do [[ -n $p ]] && kill "$p" 2>/dev/null; done <"$f"
  done
  chmod -R u+rwX "$WORK" 2>/dev/null
  rm -rf -- "$WORK"
}
trap cleanup EXIT

SYSTOOLS=(bash sh env cat ls readlink basename dirname realpath timeout flock sleep date mv cp
  mktemp grep sed awk find sort head tail tr cut wc stat mkdir rm rmdir touch kill pkill jq
  python3 mkfifo paste uname ln chmod seq tee uniq xargs id true false printf compgen)
mkdir -p "$WORK/sysbin"
for t in "${SYSTOOLS[@]}"; do
  p=$(type -P "$t") || continue
  ln -s "$p" "$WORK/sysbin/$t"
done

build() { # build <name>: runs in a subshell, writes $OUT/<name>/
  local name=$1 dir="$TESTS/fixtures/$1" T f
  [[ -r $dir/setup.sh ]] || { echo "  skip  $name (no such engine scenario)"; return 1; }
  T="$WORK/$name"
  mkdir -p "$T"/{root,xdg,fake,run,state,home,bin}
  export FX_ROOT="$T/root" FX_XDG="$T/xdg" EGPU_FAKE_DIR="$T/fake" EGPU_FAKE_LOG="$T/calls.log"
  export EGPU_TEST_REPO="$REPO" EGPU_TEST_LIB="$TESTS/lib.sh"
  export EGPU_SYS="$FX_ROOT/sys" EGPU_DEV="$FX_ROOT/dev" EGPU_PROC="$FX_ROOT/proc" EGPU_ETC="$FX_ROOT/etc"
  export EGPU_USRLIB="$FX_ROOT/usr/lib" EGPU_BOOT="$FX_ROOT/boot" EGPU_RUN="$T/run" EGPU_STATE="$T/state"
  export EGPU_USRSHARE="$FX_ROOT/usr/share"
  export EGPU_CONFIG="$T/config.json"
  # The engine honours EGPU_ADMIN only in test mode (lib/common.sh).
  export OMARCHY_EGPU_TEST=1 EGPU_ADMIN="$FX_ROOT/usr/local/bin/omarchy-egpu-admin"
  export EGPU_POLICY="$FX_ROOT/usr/share/polkit-1/actions/no.kalinewb.egpu.policy"
  export XDG_RUNTIME_DIR="$FX_XDG" HOME="$T/home" TMPDIR="$T"
  unset HYPRLAND_INSTANCE_SIGNATURE XDG_CONFIG_HOME XDG_STATE_HOME WAYLAND_DISPLAY
  for f in "$dir"/*; do
    case ${f##*/} in setup.sh | expect.json) ;; *) cp -r -- "$f" "$EGPU_FAKE_DIR/" ;; esac
  done
  mkdir -p "$FX_ROOT/sys/bus/pci/devices" "$FX_ROOT/sys/module" "$FX_ROOT/dev/dri" "$FX_ROOT/proc" "$FX_ROOT/etc"
  # shellcheck disable=SC2123  # deliberate: setup sees only the plain tools
  (PATH="$WORK/sysbin"; source "$TESTS/lib.sh" && source "$dir/setup.sh") || { echo "  FAIL  $name: setup"; return 1; }
  # shellcheck source=/dev/null
  [[ -r $EGPU_FAKE_DIR/env ]] && source "$EGPU_FAKE_DIR/env"
  for f in "$TESTS"/fakes/bin/*; do
    grep -qxF -- "${f##*/}" "$EGPU_FAKE_DIR/absent-tools" 2>/dev/null && continue
    ln -s "$f" "$T/bin/${f##*/}"
  done
  export PATH="$T/bin:$WORK/sysbin"

  mkdir -p "$OUT/$name"
  if ! "$ENGINE" status --json >"$T/status.json" 2>"$T/status.err"; then
    echo "  FAIL  $name: status --json: $(head -c 200 "$T/status.err")"; return 1
  fi
  "$ENGINE" health >"$T/health.json" 2>/dev/null || { echo "  FAIL  $name: health"; return 1; }
  # Pretty-printed so a re-run's diff reads field by field, with the fake
  # machine's temp root taken back out of every path (health details name
  # files: /tmp/…/root/etc/x reads /etc/x, as it would on a real machine; the
  # fake home reads ~, so a re-run does not differ by its temp name) and the
  # clock pinned. The stub stamps written_at fresh when it serves a file.
  local strip="$FX_ROOT"
  local clean='walk(if type == "string" then gsub($h; "~") | gsub($r; "") else . end)'
  jq --arg r "$strip" --arg h "$HOME" "$clean"' | .written_at = 1791590400000' \
    "$T/status.json" >"$OUT/$name/status.json" || return 1
  jq --arg r "$strip" --arg h "$HOME" "$clean" \
    "$T/health.json" >"$OUT/$name/health.json" || return 1
  echo "  ok    $name  $(jq -r '"\(.summary.state)  \(.summary.line)"' "$T/status.json")"
}

targets=("$@")
(( ${#targets[@]} )) || targets=("${DEFAULT[@]}")
failed=0
for s in "${targets[@]}"; do (build "$s") || failed=$((failed + 1)); done
(( failed == 0 )) || { echo "make-fixtures: $failed scenario(s) failed" >&2; exit 1; }
