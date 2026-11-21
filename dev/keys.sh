#!/bin/bash

# The panel's keys, pressed for real, offscreen: Escape steps back one level at a time (the view's own
# sub-level, then the route, and only at the root it closes), the back strip's press walks the same steps,
# standalone and in the notch; and, once the kit's controls are in, Tab, Enter and Space on them.
#
#   ./dev/keys.sh                       every check, both shells
#   ./dev/keys.sh --sets esc            only the Escape checks (all the unchanged panel answers)
#                                       (sets: esc, keys; the switch, confirm and setup runs have their own)
#   ./dev/keys.sh --panel <dir>         the plugin in another checkout
#
# dev/qml-harness/keys.qml sends the key events with QtTest's keyClick into the real NotchPanel.qml on a
# stand-in notch host and into the real Panel.qml's popup. Nothing touches the running shell, the live plugin
# or the machine's eGPU state; the engine is the dev stub on a fixture.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SHELL_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
[[ -d $SHELL_PATH/shell/Ui ]] || { echo "keys: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }
command -v quickshell >/dev/null || { echo "keys: quickshell is not installed" >&2; exit 1; }

panel=$REPO; sets="esc,keys"
while (($#)); do
  case $1 in
    --sets) sets=$2; shift 2 ;;
    --panel) panel=$(cd "$2" && pwd) || exit 2; shift 2 ;;
    *) echo "keys: unknown argument $1" >&2; exit 2 ;;
  esac
done

# What each shell runs of the chosen sets: the notch panel everything, the popup Escape and its keys.
root=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-keys.XXXXXX")
trap 'pkill -f -- "$root/" 2>/dev/null; [[ -n ${KEYS_KEEP:-} ]] || rm -rf "$root"' EXIT
mkdir -p "$root/qs/Ui" "$root/run"
ln -s "$SHELL_PATH/shell/Commons" "$root/qs/Commons"
for f in "$SHELL_PATH"/shell/Ui/*; do
  case ${f##*/} in KeyboardPanel.qml | qmldir) ;; *) ln -s "$f" "$root/qs/Ui/${f##*/}" ;; esac
done
cp "$SHELL_PATH/shell/Ui/qmldir" "$root/qs/Ui/qmldir"
cp "$REPO/dev/qml-harness/KeyboardPanel.qml" "$root/qs/Ui/KeyboardPanel.qml"
ln -s "$panel" "$root/qs/egpu"
cp "$REPO/dev/qml-harness/keys.qml" "$root/qs/shell.qml"
FIX="$panel/dev/fixtures"; [[ -d $FIX ]] || FIX="$REPO/dev/fixtures"

sets_notch=$sets; sets_popup=$sets
failures=0; checks=0
# case | fixture | sets: the notch panel on the ready fixture for Escape and the keys; on ready-hdmi for the
# HDMI switch (with the display verbs); on in-use-procs for the eject confirm; on this-machine for a Fix.
VERBS="device connect,device eject,device rescan,display enable,display disable,display off"
run() { # run <case> <fixture> <sets> [verbs]
  local c=$1 fx=$2 sets=$3 verbs=${4:-}
  echo "${DIM}== $c, $fx: $sets${RESET}"
  rm -f "$root/run/calls.jsonl"
  jq --argjson at "$(date +%s%3N)" '.written_at = $at' "$FIX/$fx/status.json" >"$root/run/status.json"
  log="$root/$c-$fx.log"
  env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
    EGPU_RUN="$root/run" OMARCHY_EGPU_DEV_BIN="$panel/dev/bin" OMARCHY_EGPU_DEV_FIXTURE=$fx OMARCHY_EGPU_DEV_FIXTURES="$FIX" \
    ${verbs:+OMARCHY_EGPU_DEV_VERBS="$verbs"} KEYS_CASE=$c KEYS_SETS=$sets \
    timeout 90 quickshell -p "$root/qs" -n >"$log" 2>&1
  sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^.*KEYS //p' | while IFS= read -r line; do
    case $line in
      pass*) echo "  ${GREEN}pass${RESET}  ${line#pass }" ;;
      FAIL*) echo "  ${RED}FAIL${RESET}  ${line#FAIL }" ;;
    esac
  done
  done_line=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^.*KEYS done //p' | tail -1)
  if [[ -z $done_line ]]; then
    echo "  ${RED}FAIL${RESET}  the $c run did not finish"
    sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'ERROR|TypeError|ReferenceError|Unable|FAIL' | head -5 | sed 's/^/        /'
    failures=$((failures + 1)); return
  fi
  local n=${done_line% *} f=${done_line#* }
  checks=$((checks + n)); failures=$((failures + f))
  sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'TypeError|ReferenceError|is not a function|Unable to assign' | grep -F egpu | head -3 | sed 's/^/      js: /'
}
run hosted ready "$sets_notch"
if [[ $sets == *keys* ]]; then
  run hosted ready-hdmi switch "$VERBS"
  run hosted in-use-procs confirm
  run hosted this-machine setup
fi
run standalone ready "$sets_popup"
[[ $sets == *keys* ]] && run standalone this-machine scroll
echo
if ((failures)); then echo "${RED}$failures of $checks key checks failed${RESET}"; exit 1; fi
echo "${GREEN}all $checks key checks pass${RESET}"
