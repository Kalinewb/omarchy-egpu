#!/bin/bash

# Gate G1, the part that needs no hardware and no live shell (plan-gui.md §10):
# "All phases of §4 render from fixtures", plus the status plumbing behind them.
#
#   ./dev/g1-offscreen.sh            every check
#   ./dev/g1-offscreen.sh --png DIR  also keep a PNG of the bar glyph per state,
#                                    of the Overview per fixture and of the popup
#
# Runs the REAL Panel.qml, Service.qml and views/StatusView.qml in a throwaway
# Quickshell (dev/qml-harness/shell.qml) on the offscreen platform: no
# WAYLAND_DISPLAY, a temp config root, a temp $EGPU_RUN. The live
# omarchy-shell is never contacted and nothing is written under
# ~/.config/omarchy. The status documents are dev/fixtures/*, i.e. what the
# real engine printed for tests/fixtures (dev/make-fixtures.sh).
#
# Not covered here, and why:
#   - the popup's real layer-shell window (placement, focus, outside click):
#     it needs a compositor; the harness swaps in a plain Window
#   - the built-in bar actually handing over the service, and the service
#     mounting at shell start without keepLoaded: both need the live shell
#     (the plumbing on each side of that handover is checked below)

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$REPO/dev/fixtures"

PNG=""
[[ ${1:-} == --png ]] && { PNG=$(realpath -m -- "${2:?--png needs a directory}"); mkdir -p "$PNG"; }

failures=0
checks=0
check() { # check <description> <expected> <actual>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then echo "  ${GREEN}pass${RESET}  $1"
  else echo "  ${RED}FAIL${RESET}  $1 ${DIM}(expected '$2', got '$3')${RESET}"; failures=$((failures + 1)); fi
}
step() { echo; echo "${DIM}== $*${RESET}"; }

command -v quickshell >/dev/null || { echo "g1-offscreen: quickshell is not installed" >&2; exit 1; }
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Ui ]] || { echo "g1-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

# The config root: qs.Commons and qs.Ui from the installed shell, except
# KeyboardPanel (layer-shell; see dev/qml-harness/KeyboardPanel.qml), and the
# plugin itself as ./egpu. Symlinks live only in this temp dir, never the repo.
root=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-g1.XXXXXX")
trap 'pkill -f -- "$root/" 2>/dev/null; rm -rf "$root"' EXIT
mkdir -p "$root/qs/Ui" "$root/run"
ln -s "$SHELL_PATH/shell/Commons" "$root/qs/Commons"
for f in "$SHELL_PATH"/shell/Ui/*; do
  case ${f##*/} in KeyboardPanel.qml | qmldir) ;; *) ln -s "$f" "$root/qs/Ui/${f##*/}" ;; esac
done
cp "$SHELL_PATH/shell/Ui/qmldir" "$root/qs/Ui/qmldir"
cp "$REPO/dev/qml-harness/KeyboardPanel.qml" "$root/qs/Ui/KeyboardPanel.qml"
ln -s "$REPO" "$root/qs/egpu"
cp "$REPO/dev/qml-harness/shell.qml" "$root/qs/shell.qml"

RUN="$root/run"

# put <fixture> [age ms] [jq filter]: status.json as the watcher would have
# written it that long ago.
put() {
  local at=$(( $(date +%s%3N) - ${2:-0} ))
  jq --argjson at "$at" ".written_at = \$at | ${3:-.}" "$FIX/$1/status.json" >"$RUN/.s" && mv "$RUN/.s" "$RUN/status.json"
}

harness() { # harness <case> [env…]: prints key=value lines
  local c=$1
  shift
  env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
    EGPU_RUN="$RUN" OMARCHY_EGPU_DEV_BIN="$REPO/dev/bin" EGPU_HARNESS_CASE="$c" "$@" \
    timeout 60 quickshell -p "$root/qs" 2>&1 |
    sed -n 's/^.*HARNESS \([a-zA-Z0-9]*\) \(.*\)$/\1=\2/p'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G1 — bar indicator, status plumbing and Overview, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO${RESET}"

# =============================================================================
step "GATE: every summary.state renders on the bar (plan-gui.md §4)"
# fixture | state | glyph role | badge | pulse | monitor | word
while IFS='|' read -r fx state role badge pulse monitor word; do
  [[ -n $fx ]] || continue
  rm -f "$RUN/status.json"; put "$fx"
  out=$(harness indicator EGPU_HARNESS_WAIT_MS=1500 ${PNG:+EGPU_HARNESS_BAR_PNG="$PNG/bar-$fx.png"})
  [[ -n $out ]] || { check "$fx: the harness printed something (QML loaded)" "yes" "no"; continue; }
  line=$(jq -r '.summary.line' "$FIX/$fx/status.json")
  got="$(field state "$out")|$(field role "$out")|$(field badge "$out")|$(field pulse "$out")|$(field monitor "$out")|$(field word "$out")"
  check "$fx → $state ($role glyph, badge $badge, pulse $pulse, monitor $monitor, '$word')" \
    "$state|$role|$badge|$pulse|$monitor|$word" "$got"
  check "$fx: tooltip is summary.line verbatim" "$line" "$(field buttonTooltip "$out")"
  check "$fx: glyph shown at full opacity, painted in its role colour" "glyph|true|1|${pulse/true/pulsing}" \
    "$(field buttonText "$out")|$(field buttonVisible "$out")|$(field buttonOpacity "$out")|$(field glyphColour "$out" | sed 's/^role$/false/')"
  check "$fx: read live from status.json" "file|live" "$(field source "$out")|$(field outcome "$out")"
done <<'TABLE'
absent|absent|secondary|none|false|false|none
stranger-no-tb|absent|secondary|none|false|false|none
plugged-unauthorized|connecting|foreground|none|true|false|connecting
authorized-no-pci|connecting|foreground|none|true|false|connecting
bound-nvidia|connecting|foreground|none|true|false|connecting
ready|ready|accent|none|false|false|ready
ready-hdmi|in_use|accent|accent|false|true|in use
in-use-procs|in_use|accent|accent|false|false|in use
ejecting|ejecting|foreground|none|true|false|ejecting
ejected-clean|safe_to_unplug|good|none|false|false|unplug
ejected-held|attention|good|warn|false|false|log out
this-machine|attention|accent|warn|false|false|log out
amd-stub|attention|foreground|warn|false|false|check setup
smi-hung|error|foreground|bad|false|false|error
auth-error|error|foreground|bad|false|false|error
TABLE

# =============================================================================
step "status file rules (plan-engine.md §5.1)"

rm -f "$RUN/status.json"; put ready 60000
out=$(harness indicator EGPU_HARNESS_WAIT_MS=2500 OMARCHY_EGPU_DEV_FIXTURE=ejected-clean)
check "a file older than 10 s is stale: status --json is run once instead" \
  "safe_to_unplug|watcher not running" "$(field state "$out")|$(field outcome "$out")"

rm -f "$RUN/status.json"
out=$(harness indicator EGPU_HARNESS_WAIT_MS=2500 OMARCHY_EGPU_DEV_FIXTURE=ready)
check "no file at all (no watcher ever ran): the one-shot answer, marked not live" \
  "ready|watcher not running" "$(field state "$out")|$(field outcome "$out")"

rm -f "$RUN/status.json"; put ready 0 '.schema = 2'
out=$(harness indicator EGPU_HARNESS_WAIT_MS=1500)
check "a newer schema is refused, and the tooltip says to update" \
  "unknown|eGPU · status from a newer engine; update the plugin" \
  "$(field state "$out")|$(field buttonTooltip "$out")"
check "…and the glyph stays on the bar, dimmed" "glyph|true|secondary" \
  "$(field buttonText "$out")|$(field buttonVisible "$out")|$(field role "$out")"

rm -f "$RUN/status.json"
out=$(harness indicator EGPU_HARNESS_WAIT_MS=1500 OMARCHY_EGPU_DEV_BIN=/nonexistent/omarchy-egpu-dev)
check "no engine and no file: says the engine is missing, in Errors.js's words" \
  "unknown|eGPU · The plugin's engine (bin/omarchy-egpu) is missing. Reinstall the plugin." \
  "$(field state "$out")|$(field buttonTooltip "$out")"

# =============================================================================
step "the Service: one watcher, followed through the own-service lookup (§3)"

rm -f "$RUN/status.json" "$RUN/watch.lock"
seq_fx=absent,plugged-unauthorized,bound-nvidia,ready,ready-hdmi,ejecting,ejected-clean
out=$(harness service EGPU_HARNESS_WAIT_MS=9000 OMARCHY_EGPU_DEV_FIXTURE=$seq_fx OMARCHY_EGPU_DEV_STEP_S=1)
check "the widget follows the Service, not the file" "service|running" "$(field source "$out")|$(field watchState "$out")"
# "unknown" first only if the 100 ms sampler caught the moment before the
# first record; either way nothing else may come between.
check "it shows every state the stream sends, in order" \
  "absent connecting ready in_use ejecting safe_to_unplug" "$(field states "$out" | sed 's/^unknown //')"
check "…and the Service re-raises each event once" \
  "dev_fixture#2 dev_fixture#4 dev_fixture#6 dev_fixture#8 dev_fixture#10 dev_fixture#12" "$(field events "$out")"
check "the watcher kept status.json for everyone else" "safe_to_unplug" "$(jq -r '.summary.state' "$RUN/status.json" 2>/dev/null)"
sleep 0.5
if flock -n "$RUN/watch.lock" true 2>/dev/null; then lock=free; else lock=held; fi
check "destroying the Service stops its watcher (the lock is free)" "free" "$lock"

step "…and when someone else already is the watcher"
rm -f "$RUN/status.json"
OMARCHY_EGPU_DEV_FIXTURE=in-use-procs EGPU_RUN="$RUN" "$REPO/dev/bin/omarchy-egpu" status watch >/dev/null 2>&1 &
other=$!
sleep 1
out=$(harness service EGPU_HARNESS_WAIT_MS=2500 OMARCHY_EGPU_DEV_FIXTURE=ready)
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
check "a second watcher is refused (exit 3) and the Service reads the other's file" \
  "busy|in_use|in_use" "$(field watchState "$out")|$(field serviceStatus "$out")|$(field state "$out")"

# =============================================================================
step "routes (§5, §7.7)"
rm -f "$RUN/status.json"; put ready
out=$(harness indicator EGPU_HARNESS_WAIT_MS=1200)
check "a route that is not built yet is refused, not shown blank" "overview" "$(field unbuiltRoute "$out")"
check "only built tabs are offered (G1: Overview alone, so no tab row)" "overview" "$(field tabs "$out")"

out=$(harness popup EGPU_HARNESS_WAIT_MS=1500 ${PNG:+EGPU_HARNESS_PNG="$PNG/popup-ready.png"})
check "the popup opens with the Overview inside it" "true|true" "$(field opened "$out")|$(field popupVisible "$out")"
check "…its header is the view's title and the engine's line" "TBGAA|EGPU READY · EJECT BEFORE UNPLUGGING" \
  "$(sed -n 's/^text=//p' <<<"$out" | sed -n '2p')|$(sed -n 's/^text=//p' <<<"$out" | sed -n '3p')"
check "…with no Back at the root" "false" "$(field backVisible "$out")"
check "Escape (back) at the root closes it" "closed" "$(field afterBack "$out")"

# =============================================================================
step "Overview from fixtures (§5.1, read-only half)"

view() { # view <fixture> [env…]
  local fx=$1
  shift
  harness view EGPU_HARNESS_WAIT_MS=700 EGPU_HARNESS_STATUS="$FIX/$fx/status.json" \
    ${PNG:+EGPU_HARNESS_PNG="$PNG/overview-$fx.png"} "$@"
}
has() { grep -qxF -- "text=$1" <<<"$2" && echo yes || echo no; }

out=$(view in-use-procs)
check "title is the enclosure, meta the engine's line" "TBGAA|eGPU in use · 2 apps" "$(field title "$out")|$(field meta "$out")"
check "apps on the card are listed by name and pid" "yes|yes|yes" \
  "$(has 'vkcube · 12 MB' "$out")|$(has '4343' "$out")|$(has 'Apps on the eGPU (2)' "$out")"
check "the link is plain information" "yes" "$(has '16.0 GT/s × 4 · max 16.0 GT/s × 16' "$out")"
check "no sub-sheet yet: popView() falls through to the shell" "false" "$(field popView "$out")"

out=$(view this-machine)
check "needs_relogin shows the plan's banner" "yes" \
  "$(has 'The HDMI monitor needs a new session to appear. Offloading apps works now.' "$out")"
check "…and the profile's hint for the same thing is not repeated" "no" \
  "$(has 'The HDMI monitor needs a new session to appear. Offloading apps to the eGPU works now.' "$out")"

out=$(view ejected-held)
check "held modules show 'log out before plugging in again'" "yes" "$(has 'Log out before plugging the eGPU in again.' "$out")"

out=$(view authorized-no-pci)
check "an enclosure profile hint is shown (DEG2 mode switch)" "yes" \
  "$(has "Check the dock's mode switch is set to TBT, not OCuLink." "$out")"

out=$(view smi-hung)
check "smi_hung says do not unplug, from Errors.js" "yes" \
  "$(has 'The driver is not answering. Do not unplug: save your work, then log out or reboot.' "$out")"

out=$(view amd-stub)
check "an unsupported backend says so (backend_stub)" "yes" \
  "$(has 'This kind of GPU is detected but not supported yet.' "$out")"

out=$(view stranger-no-tb)
check "a machine with no Thunderbolt says so" "yes" "$(has 'Thunderbolt service (boltd) is not running' "$out")"

out=$(view ready EGPU_HARNESS_NOTE="watcher not running")
check "a status that will not update says so" "yes" "$(has 'Not live: watcher not running.' "$out")"

out=$(view ready EGPU_HARNESS_DENSITY=compact)
check "compact density drops the detail rows" "no|no|yes" \
  "$(has 'Modules' "$out")|$(has 'Link' "$out")|$(has 'GPU' "$out")"

# =============================================================================
echo
[[ -n $PNG ]] && echo "${DIM}PNGs in $PNG${RESET}"
if (( failures )); then echo "${RED}$failures of $checks checks failed${RESET}"; exit 1; fi
echo "${GREEN}all $checks checks passed${RESET}"
echo "${YELLOW}not checked here${RESET}: the live layer-shell popup, the built-in bar handing over the service, the service mounting at shell start (needs the live shell)"
