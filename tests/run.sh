#!/bin/bash

# tests/run.sh — the engine's test suite. Plain bash; bats is not assumed.
#
#   tests/run.sh               every scenario, the Steam gate tests, then the watcher
#   tests/run.sh absent ...    only these scenarios ("watch" for the watcher,
#                              "steam" for the Steam module, tests/steam.sh,
#                              "device" for connect and egpu-run, tests/device.sh,
#                              "display" for monitors and the toggle file, tests/display.sh)
#
# Each scenario in fixtures/<name>/ has:
#   setup.sh      builds the fake machine with tests/lib.sh (sysfs, /dev,
#                 /proc, /etc, /usr/lib, /boot, bolt.json, ...)
#   expect.json   what status and health must say:
#                   phase, summary_state      exact values
#                   status_checks             jq expressions, each must be true
#                   health_levels             {row id: level}
#                   health_checks             jq expressions over the rows
#                   shell                     bash snippets, each must exit 0
#
# The engine runs with every EGPU_* root pointed into the fixture and a PATH of
# only tests/fakes/bin plus the plain tools it needs, so nothing on this
# machine (a real boltctl, nvidia-smi, vulkaninfo, Hyprland) leaks in. Nothing
# outside a temp directory is written. Never run as root: unreadable-parameter
# fixtures rely on file modes.

set -uo pipefail

TESTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$TESTS/.." && pwd)
ENGINE="$REPO/bin/omarchy-egpu"
SCHEMA="$TESTS/schema/status-1.json"
GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

(( EUID != 0 )) || { echo "tests/run.sh: do not run as root" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-tests.XXXXXX") || exit 2
RESULTS="$WORK/results"
: >"$RESULTS"

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

ok() { echo "pass" >>"$RESULTS"; echo "  ${GREEN}pass${RESET}  $*"; }
bad() { echo "fail $*" >>"$RESULTS"; echo "  ${RED}FAIL${RESET}  $*"; }

# The plain tools the engine, the fakes and the fixtures may use.
SYSTOOLS=(bash sh env cat ls readlink basename dirname realpath timeout flock sleep date mv cp
  mktemp grep sed awk find sort head tail tr cut wc stat mkdir rm rmdir touch kill pkill jq
  python3 mkfifo paste uname ln chmod seq tee uniq xargs id true false printf compgen cmp)
mkdir -p "$WORK/sysbin"
for t in "${SYSTOOLS[@]}"; do
  p=$(type -P "$t") || continue
  ln -s "$p" "$WORK/sysbin/$t"
done
for t in bash jq python3 flock timeout mkfifo awk; do
  [[ -e $WORK/sysbin/$t ]] || { echo "tests/run.sh: needs $t" >&2; exit 2; }
done

# setup_scenario <name> <fixture dir>: exports the scenario's environment in
# the current (sub)shell and builds the fixture.
setup_scenario() {
  local name=$1 dir=$2 f
  T="$WORK/$name"
  mkdir -p "$T"/{root,xdg,fake,run,state,home,bin}
  export FX_ROOT="$T/root" FX_XDG="$T/xdg" EGPU_FAKE_DIR="$T/fake" EGPU_FAKE_LOG="$T/calls.log"
  export EGPU_TEST_REPO="$REPO" EGPU_TEST_LIB="$TESTS/lib.sh"
  export EGPU_SYS="$FX_ROOT/sys" EGPU_DEV="$FX_ROOT/dev" EGPU_PROC="$FX_ROOT/proc" EGPU_ETC="$FX_ROOT/etc"
  export EGPU_USRLIB="$FX_ROOT/usr/lib" EGPU_BOOT="$FX_ROOT/boot" EGPU_RUN="$T/run" EGPU_STATE="$T/state"
  export EGPU_USRSHARE="$FX_ROOT/usr/share"
  export EGPU_CONFIG="$T/config.json"
  export EGPU_ADMIN="$FX_ROOT/usr/local/bin/omarchy-egpu-admin"
  export EGPU_POLICY="$FX_ROOT/usr/share/polkit-1/actions/no.kalinewb.egpu.policy"
  export XDG_RUNTIME_DIR="$FX_XDG" HOME="$T/home" TMPDIR="$T"
  unset HYPRLAND_INSTANCE_SIGNATURE XDG_CONFIG_HOME XDG_STATE_HOME WAYLAND_DISPLAY
  for f in "$dir"/*; do
    case ${f##*/} in setup.sh | expect.json) ;; *) cp -r -- "$f" "$EGPU_FAKE_DIR/" ;; esac
  done
  mkdir -p "$FX_ROOT/sys/bus/pci/devices" "$FX_ROOT/sys/module" "$FX_ROOT/dev/dri" "$FX_ROOT/proc" "$FX_ROOT/etc"
  # shellcheck disable=SC2123  # deliberate: setup sees only the plain tools
  if ! (PATH="$WORK/sysbin"; source "$TESTS/lib.sh" && source "$dir/setup.sh"); then
    bad "$name: fixture setup failed"
    return 1
  fi
  # shellcheck source=/dev/null
  [[ -r $EGPU_FAKE_DIR/env ]] && source "$EGPU_FAKE_DIR/env"
  for f in "$TESTS"/fakes/bin/*; do
    grep -qxF -- "${f##*/}" "$EGPU_FAKE_DIR/absent-tools" 2>/dev/null && continue
    ln -s "$f" "$T/bin/${f##*/}"
  done
  export PATH="$T/bin:$WORK/sysbin"
}

# Health rows must all have the §9 shape.
check_health_shape() {
  local name=$1 file=$2
  if jq -e '
      type == "array" and length > 0
      and all(.[]; (.id | type == "string") and (.group | type == "string")
        and (.level | IN("ok", "info", "warn", "error", "skipped"))
        and (.title | type == "string") and (.detail | type == "string")
        and (.fix.kind | IN("user", "system", "none")) and (.fix.label | type == "string"))
      and (map(.id) | length == (unique | length))' "$file" >/dev/null; then
    ok "$name: health rows have the §9 shape, ids unique"
  else
    bad "$name: health rows malformed: $(head -c 300 "$file")"
  fi
}

run_scenario() {
  local name=$1 dir="$TESTS/fixtures/$1" expect rc
  expect="$dir/expect.json"
  echo "${BOLD}$name${RESET}"
  setup_scenario "$name" "$dir" || return

  "$ENGINE" status --json >"$T/status.json" 2>"$T/status.err"
  rc=$?
  if (( rc == 0 )); then ok "$name: status --json exits 0"; else bad "$name: status --json exit $rc: $(head -c 300 "$T/status.err")"; return; fi
  if python3 "$TESTS/schema/validate.py" "$SCHEMA" "$T/status.json" 2>"$T/schema.err"; then
    ok "$name: status validates against status-1.json"
  else
    bad "$name: schema: $(head -c 400 "$T/schema.err")"
  fi

  local want got
  for key in phase summary_state; do
    want=$(jq -r --arg k "$key" '.[$k] // empty' "$expect")
    [[ -n $want ]] || continue
    if [[ $key == phase ]]; then got=$(jq -r '.phase' "$T/status.json"); else got=$(jq -r '.summary.state' "$T/status.json"); fi
    if [[ $got == "$want" ]]; then ok "$name: $key = $want"; else bad "$name: $key = $got, expected $want (line: $(jq -r .summary.line "$T/status.json"))"; fi
  done

  local expr
  while IFS= read -r expr; do
    [[ -n $expr ]] || continue
    if jq -e "$expr" "$T/status.json" >/dev/null 2>&1; then ok "$name: $expr"; else bad "$name: status: $expr"; fi
  done < <(jq -r '.status_checks[]?' "$expect")

  "$ENGINE" health >"$T/health.json" 2>"$T/health.err"
  rc=$?
  if (( rc == 0 )); then ok "$name: health exits 0"; else bad "$name: health exit $rc: $(head -c 300 "$T/health.err")"; return; fi
  check_health_shape "$name" "$T/health.json"

  local id level
  while IFS=$'\t' read -r id level; do
    [[ -n $id ]] || continue
    got=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .level' "$T/health.json")
    if [[ $got == "$level" ]]; then ok "$name: health $id = $level"
    else bad "$name: health $id = ${got:-<missing>}, expected $level ($(jq -r --arg id "$id" '.[] | select(.id == $id) | .detail' "$T/health.json" | head -c 200))"; fi
  done < <(jq -r '(.health_levels // {}) | to_entries[] | "\(.key)\t\(.value)"' "$expect")

  while IFS= read -r expr; do
    [[ -n $expr ]] || continue
    if jq -e "$expr" "$T/health.json" >/dev/null 2>&1; then ok "$name: $expr"; else bad "$name: health: $expr"; fi
  done < <(jq -r '.health_checks[]?' "$expect")

  while IFS= read -r expr; do
    [[ -n $expr ]] || continue
    if (bash -c "$expr") >/dev/null 2>&1; then ok "$name: shell: $expr"; else bad "$name: shell: $expr"; fi
  done < <(jq -r '.shell[]?' "$expect")

  if "$ENGINE" status --human >"$T/human.txt" 2>&1 && [[ -s $T/human.txt ]]; then
    ok "$name: status --human prints"
  else
    bad "$name: status --human failed: $(head -c 200 "$T/human.txt")"
  fi
}

# ---------------------------------------------------------------- watcher

# Waits until <file> has a line matching the jq filter, up to <seconds>.
wait_for() {
  local file=$1 filter=$2 secs=$3 i
  for ((i = 0; i < secs * 10; i++)); do
    [[ -s $file ]] && jq -e -s "$filter" "$file" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

test_watch() {
  local name=watch dir="$TESTS/fixtures/watch-sequence"
  echo "${BOLD}watch${RESET}  ${DIM}(scripted plug → ready → HDMI → yank, ~25 s)${RESET}"
  setup_scenario "$name" "$dir" || return
  chmod +x "$EGPU_FAKE_DIR/watch-script.sh"

  local out="$T/watch.out" err="$T/watch.err" wpid
  "$ENGINE" status watch >"$out" 2>"$err" &
  wpid=$!
  echo "$wpid" >>"$EGPU_FAKE_DIR/bg.pids"

  if wait_for "$out" 'map(select(.type == "status")) | length >= 1' 10; then
    ok "watch: first status record within 10 s"
  else
    bad "watch: no status record: $(head -c 300 "$err")"
    return
  fi

  # One watcher per session.
  local rc2 out2
  out2=$(timeout 10 "$ENGINE" status watch 2>/dev/null)
  rc2=$?
  if (( rc2 == 3 )) && jq -e '.error == "busy"' <<<"$out2" >/dev/null 2>&1; then
    ok "watch: a second watcher exits 3 with {\"error\":\"busy\"}"
  else
    bad "watch: second watcher exit $rc2, output: $out2"
  fi

  # status.json must parse on every read while the watcher rewrites it, and
  # be replaced by rename (new inode), not rewritten in place.
  local reads=0 torn=0 inodes
  inodes=$(mktemp)
  local end=$(( SECONDS + 9 ))
  while (( SECONDS < end )); do
    if [[ -e $EGPU_RUN/status.json ]]; then
      reads=$((reads + 1))
      jq -e '.schema == 1' "$EGPU_RUN/status.json" >/dev/null 2>&1 || torn=$((torn + 1))
      stat -c %i "$EGPU_RUN/status.json" >>"$inodes" 2>/dev/null
    fi
    sleep 0.02
  done
  if (( reads > 50 && torn == 0 )); then
    ok "watch: status.json parsed on all $reads reads during changes (no torn writes)"
  else
    bad "watch: status.json reads=$reads torn=$torn"
  fi
  if (( $(sort -u "$inodes" | wc -l) > 1 )); then
    ok "watch: status.json is replaced by rename ($(sort -u "$inodes" | wc -l) inodes seen)"
  else
    bad "watch: status.json kept one inode; not written by rename"
  fi
  rm -f "$inodes"

  wait_for "$out" 'map(select(.type == "event" and .event == "unplugged")) | length >= 1' 20 ||
    bad "watch: no unplugged event within 20 s"
  sleep 1

  local events expected
  events=$(jq -r 'select(.type == "event") | .event' "$out" | paste -sd' ')
  expected=$(jq -r '.events | join(" ")' "$dir/expect.json")
  if [[ $events == "$expected" ]]; then
    ok "watch: events = $events"
  else
    bad "watch: events = '$events', expected '$expected'"
  fi

  local states expected_states
  states=$(jq -r 'select(.type == "status") | .summary.state' "$out" | uniq | paste -sd' ')
  expected_states=$(jq -r '.summary_states | join(" ")' "$dir/expect.json")
  if [[ $states == "$expected_states" ]]; then
    ok "watch: summary.state sequence = $states"
  else
    bad "watch: summary.state sequence = '$states', expected '$expected_states'"
  fi

  if jq -c 'select(.type == "status") | del(.type)' "$out" >"$T/records.jsonl" &&
    python3 "$TESTS/schema/validate.py" "$SCHEMA" "$T/records.jsonl" 2>"$T/schema.err"; then
    ok "watch: every status record ($(wc -l <"$T/records.jsonl")) validates"
  else
    bad "watch: status record schema: $(head -c 300 "$T/schema.err")"
  fi
  if jq -s -e 'map(.seq) | . == (sort | unique)' "$out" >/dev/null; then
    ok "watch: seq strictly increases across records"
  else
    bad "watch: seq not strictly increasing"
  fi
  if jq -e --slurpfile s <(jq -c 'select(.type == "event")' "$out" | tail -n1) \
    '.last_event.seq == $s[0].seq and .last_event.type == $s[0].event' "$EGPU_RUN/status.json" >/dev/null 2>&1; then
    ok "watch: status.json carries the last event"
  else
    bad "watch: status.json last_event does not match the last event"
  fi
  # A file reader sees one document per recompute, and the yank raises three
  # events in one (plan-gui.md §7.5 needs `yanked`, not only the last word).
  if jq -e --slurpfile s <(jq -c 'select(.type == "event")' "$out" | tail -n3 | jq -sc 'map({seq, type: .event, at})') \
    '.recent_events[-3:] == $s[0] and (.recent_events | length) <= 8 and .recent_events[-1] == .last_event' \
    "$EGPU_RUN/status.json" >/dev/null 2>&1; then
    ok "watch: status.json keeps the recent events (the yank's three, in order)"
  else
    bad "watch: status.json recent_events = $(jq -c '.recent_events' "$EGPU_RUN/status.json" 2>/dev/null)"
  fi
  if jq -e 'select(.type == "event" and .event == "ready") | .detail.bdf == "0000:03:00.0"' "$out" >/dev/null 2>&1; then
    ok "watch: ready event names the BDF"
  else
    bad "watch: ready event detail"
  fi

  # Heartbeat: with nothing happening, written_at stays within 5 s (+ the
  # time one recompute takes) of now.
  local i age max_age=0 first_at last_at
  first_at=$(jq -r '.written_at' "$EGPU_RUN/status.json")
  for i in 1 2 3; do
    sleep 4
    age=$(( $(date +%s%3N) - $(jq -r '.written_at' "$EGPU_RUN/status.json") ))
    (( age > max_age )) && max_age=$age
  done
  last_at=$(jq -r '.written_at' "$EGPU_RUN/status.json")
  if (( max_age < 6500 && last_at > first_at )); then
    ok "watch: heartbeat keeps status.json fresh while idle (max age ${max_age} ms over 12 s)"
  else
    bad "watch: heartbeat max age ${max_age} ms, written_at $first_at → $last_at"
  fi

  # Shutdown: TERM stops the watcher, its producers and its fifo.
  local prod_u prod_b
  prod_u=$(cat "$EGPU_FAKE_DIR/udevadm-monitor.pid" 2>/dev/null)
  prod_b=$(cat "$EGPU_FAKE_DIR/boltctl-monitor.pid" 2>/dev/null)
  kill -TERM "$wpid"
  for i in $(seq 1 50); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.1; done
  if ! kill -0 "$wpid" 2>/dev/null; then ok "watch: exits on TERM"; else bad "watch: still running after TERM"; fi
  sleep 0.3
  if [[ -n $prod_u && -n $prod_b ]] && ! kill -0 "$prod_u" 2>/dev/null && ! kill -0 "$prod_b" 2>/dev/null; then
    ok "watch: udevadm and boltctl monitors stopped with it"
  else
    bad "watch: producers left running (udevadm ${prod_u:-?}, boltctl ${prod_b:-?})"
  fi
  if ! compgen -G "$EGPU_RUN/.watch.*" >/dev/null; then ok "watch: fifo and temp files removed"; else bad "watch: left $(ls -a "$EGPU_RUN")"; fi

  # The lock goes with the process: a new watcher starts.
  rm -f "$EGPU_FAKE_DIR/watch-script.sh"
  "$ENGINE" status watch >"$T/watch2.out" 2>/dev/null &
  wpid=$!
  echo "$wpid" >>"$EGPU_FAKE_DIR/bg.pids"
  if wait_for "$T/watch2.out" 'map(select(.type == "status")) | length >= 1' 10; then
    ok "watch: lock released; a new watcher starts"
  else
    bad "watch: a new watcher could not start"
  fi
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
}

# ---------------------------------------------------------------- steam

# shellcheck source=tests/steam.sh
source "$TESTS/steam.sh"

# ---------------------------------------------------------------- device

# shellcheck source=tests/device.sh
source "$TESTS/device.sh"

# ---------------------------------------------------------------- display

# shellcheck source=tests/display.sh
source "$TESTS/display.sh"

# ---------------------------------------------------------------- main

# Scenarios are the fixture dirs with an expect.json; fixtures/steam holds the
# Steam data the steam tests copy.
mapfile -t ALL < <(cd "$TESTS/fixtures" && for d in */; do
  d=${d%/}
  [[ $d != watch-sequence && -r $d/expect.json ]] && echo "$d"
done)
targets=("$@")
(( ${#targets[@]} )) || targets=("${ALL[@]}" steam device display watch)

for s in "${targets[@]}"; do
  if [[ $s == watch ]]; then
    (test_watch)
  elif [[ $s == steam ]]; then
    test_steam
  elif [[ $s == device ]]; then
    test_device
  elif [[ $s == display ]]; then
    test_display
  elif [[ -d $TESTS/fixtures/$s && -r $TESTS/fixtures/$s/expect.json ]]; then
    (run_scenario "$s")
  else
    bad "no such scenario: $s"
  fi
done

passed=$(grep -c '^pass' "$RESULTS")
failed=$(grep -c '^fail' "$RESULTS")
echo
if (( failed )); then
  echo "${RED}$failed failed${RESET}, $passed passed"
  grep '^fail' "$RESULTS" | sed 's/^fail /  /'
  exit 1
fi
echo "${GREEN}all $passed checks passed${RESET} (${#targets[@]} scenario groups)"
