#!/bin/bash

# Everything the plugin checks about itself, nothing installed, nothing reloaded, no hardware.
#
#   ./dev/test.sh              lint, the engine tests, the panel offscreen (G1, G8), the keys, the UI gate
#   ./dev/test.sh --quick      lint only (shell, JSON, QML)
#   ./dev/test.sh --no-engine  everything but tests/run.sh (the engine suite, about 7 minutes)
#
# tests/run.sh has one check that fails here on main as well, before any UI work ("device: 20 cycles":
# every cycle reports `already: true`; not looked into, it is the engine's); everything else in it passes.
#
# Each part prints its own pass/FAIL lines; this prints one summary. The marketplace scanner (bin/scan.mjs
# in the suite repo) and dev/check-pins.sh are run by hand: the scanner is not part of this repo.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
quick=0; engine=1
for a in "$@"; do
  case $a in
    --quick) quick=1 ;;
    --no-engine) engine=0 ;;
    *) echo "test: unknown argument $a" >&2; exit 2 ;;
  esac
done
cd "$REPO" || exit 1

failures=0
run() { # run <name> <command...>
  local name=$1; shift
  echo; echo "${BOLD}== $name${RESET}"
  if "$@"; then :; else failures=$((failures + 1)); echo "  ${RED}FAIL${RESET}  $name exited non-zero"; fi
}

run "shell, Python, JSON and QML lint" ./dev/lint.sh
if ((!quick)); then
  ((engine)) && run "the engine suite (fake hardware)" ./tests/run.sh
  run "G1: the bar, the popup, Overview, Setup and the eject sheet, from fixtures" ./dev/g1-offscreen.sh
  run "G8: the notch integration, against the notch's own rules" ./dev/g8-offscreen.sh
  run "the keys, pressed for real, in the notch and the popup" ./dev/keys.sh
  run "the UI gate: ui/ is the kit, no literals, no private controls, one Esc; the walk on every page, in seven configurations" \
    ./dev/check-ui.sh --score --walk dev/walk-root.qml
  run "the kit's scripts start no service, ask for no privilege and fetch nothing" bash -c '
    ! grep -nE "systemctl|sudo|pkexec|curl|git (clone|fetch|pull)" dev/sync-ui.sh dev/check-ui.sh dev/walk.sh dev/harness/ui-walk.qml dev/harness/walk.js'
fi

echo
if ((failures)); then echo "${RED}$failures part(s) failed${RESET}"; exit 1; fi
echo "${GREEN}everything passes${RESET}"
