#!/bin/bash

# Check this plugin's QML before Omarchy runs it (gate G1; the QML half of
# dev/lint.sh, kept in its own file).
#
#   ./dev/lint-qml.sh
#
# A third-party plugin with a QML error does not reach the journal: it just
# fails to appear in the bar. qmllint catches that first, resolving `qs.*`
# imports against the installed Omarchy shell, with the same rules as
# omarchy-profiles' dev/lint.sh:3-30.
#
# Fails when:
#   - qmllint exits non-zero, or reports a category that means "this will not
#     load or bind" (syntax, import, missing-type, unresolved-type, ...), or
#   - a `missing-property` on a real type (a typo against Omarchy's API;
#     members "not found on type QObject" are the untyped injections — `bar`,
#     Style tokens, a Loader's item — and are expected), or
#   - a JS library does not parse, or
#   - a shared view breaks the rules that let both shells use it unforked
#     (plan-gui.md §5.0): colours and sizes only from `theme`, so no `Color.`
#     or `Style.` in views/; no Process in a view; imports only from QtQuick,
#     Quickshell, Quickshell.Io, qs.Commons, qs.Ui and relative paths, or
#   - the notch shell (NotchIntegration.qml, NotchPanel.qml) reads Omarchy's
#     Color (colours come only from surfaceHost), the integration file names a
#     window type or an IpcHandler (the notch declines it: own-window), or
#     either imports outside the notch's allowed set or a view from anywhere
#     but views/ (plan-gui.md §7, gate G8), or
#   - any QML reads the machine itself — /sys, hyprctl, boltctl, nvidia-smi —
#     instead of asking the engine (plan-engine.md §12 E9).
#
# Reported but not fatal: `unqualified` access, members on QObject, and
# Process.onExited's `signal-handler-parameters` (Quickshell's own type info;
# Omarchy's shipped QML produces it too).
#
# dev/qml-harness/ is not linted: it imports the plugin as "egpu" from a
# config root that only dev/g1-offscreen.sh builds.

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
QMLLINT=/usr/lib/qt6/bin/qmllint
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -x $QMLLINT ]] || { echo "lint-qml: $QMLLINT is not installed (qt6-declarative)" >&2; exit 1; }
[[ -d $SHELL_PATH/shell ]] || { echo "lint-qml: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-lint.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/qmlpath"
ln -sfn "$SHELL_PATH/shell" "$work/qmlpath/qs"

FATAL='syntax|import|missing-type|unresolved-type|incompatible-type|read-only-property|duplicated-name|required|unresolved-alias|missing-enum-entry|recursion-depth-errors|attached-property-reuse|non-list-property|property-override'

cd "$REPO" || exit 1
list_files() { git ls-files --cached --others --exclude-standard 2>/dev/null || find . -type f -printf '%P\n'; }
mapfile -t files < <(list_files | grep -E '\.qml$' | grep -v '^dev/qml-harness/' | sort -u)
mapfile -t jsfiles < <(list_files | grep -E '\.js$' | grep -v '^dev/' | sort -u)
failures=0

echo "${BOLD}QML lint${RESET}  ${DIM}${#files[@]} files, qs.* → $SHELL_PATH/shell${RESET}"
out=$("$QMLLINT" -I "$work/qmlpath" -I /usr/lib/qt6/qml "${files[@]}" 2>&1); rc=$?

fatal=$(sed -nE "s#^(Warning|Error): (.*) \[($FATAL)\]\$#  \2 [\3]#p" <<<"$out")
typos=$(grep -E '\[missing-property\]' <<<"$out" | grep -v 'on type "QObject"' | sed -E 's#^Warning: #  #')
counts=$(sed -nE 's#.*\[([a-z-]+)\]$#\1#p' <<<"$out" | sort | uniq -c | sort -rn | awk '{printf "%s %s, ", $1, $2}')
echo "  ${DIM}qmllint exit $rc; ${counts%, }${RESET}"

if (( rc != 0 )); then
  echo "  ${RED}FAIL${RESET}  qmllint exited $rc"
  grep -E '^Error:' <<<"$out" | head -20
  failures=$((failures + 1))
elif [[ -n $fatal ]]; then
  echo "  ${RED}FAIL${RESET}  warnings that mean the QML will not load or bind:"
  printf '%s\n' "$fatal" | head -20
  failures=$((failures + 1))
elif [[ -n $typos ]]; then
  echo "  ${RED}FAIL${RESET}  a member that does not exist on a real type:"
  printf '%s\n' "$typos" | head -20
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  no QML errors, nothing that stops it loading, and no unknown members"
fi

# JS libraries: parsed by node with the `.pragma library` line removed (node
# does not know it; QML does). qmllint only sees them through their importers.
if command -v node >/dev/null 2>&1; then
  bad=()
  for js in "${jsfiles[@]}"; do
    sed '/^\.pragma /d' "$js" >"$work/check.js"
    node --check "$work/check.js" >/dev/null 2>&1 || bad+=("$js")
  done
  if (( ${#bad[@]} )); then
    echo "  ${RED}FAIL${RESET}  JS does not parse: ${bad[*]}"
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  ${#jsfiles[@]} JS libraries parse"
  fi
else
  echo "  ${DIM}skip  node is not installed (JS libraries checked only through qmllint)${RESET}"
fi

echo
echo "${BOLD}Shared views${RESET}  ${DIM}(plan-gui.md §5.0)${RESET}"
mapfile -t views < <(printf '%s\n' "${files[@]}" | grep '^views/')
if (( ${#views[@]} == 0 )); then
  echo "  ${DIM}skip  no views yet${RESET}"
else
  # Code only: comments may name Color/Style to explain why they are not used.
  code() { sed -E 's#//.*$##' "$1"; }
  hits=""
  for v in "${views[@]}"; do
    h=$(code "$v" | grep -nE '(^|[^A-Za-z0-9_.])(Color|Style)\.' | sed "s#^#    $v:#")
    [[ -n $h ]] && hits+="$h"$'\n'
  done
  if [[ -n $hits ]]; then
    echo "  ${RED}FAIL${RESET}  a view reads Omarchy's Color/Style itself (use \`theme\`):"
    printf '%s' "$hits" | head -20
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  ${#views[@]} view(s) take colours and sizes only from \`theme\`"
  fi

  hits=""
  for v in "${views[@]}"; do
    h=$(code "$v" | grep -nE '^[[:space:]]*(Process|component [A-Za-z]+: *Process)[[:space:]]*\{' | sed "s#^#    $v:#")
    [[ -n $h ]] && hits+="$h"$'\n'
  done
  if [[ -n $hits ]]; then
    echo "  ${RED}FAIL${RESET}  a view runs a Process (engine calls go through \`engine\`):"
    printf '%s' "$hits" | head -20
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  no Process in any view"
  fi

  hits=""
  for v in "${views[@]}"; do
    h=$(grep -nE '^import ' "$v" | grep -vE '^[0-9]+:import (QtQuick|Quickshell|Quickshell\.Io|qs\.Commons|qs\.Ui)$' |
      grep -vE '^[0-9]+:import "[^"]+"( as [A-Za-z]+)?$' | sed "s#^#    $v:#")
    [[ -n $h ]] && hits+="$h"$'\n'
  done
  if [[ -n $hits ]]; then
    echo "  ${RED}FAIL${RESET}  an import a notch integration may not use (notch:SURFACE-HOSTING.md:150-152):"
    printf '%s' "$hits" | head -20
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  views import only QtQuick, Quickshell(.Io), qs.Commons, qs.Ui and relative paths"
  fi
fi

echo
echo "${BOLD}Notch shell${RESET}  ${DIM}(plan-gui.md §7; notch:SURFACE-HOSTING.md §1-§4)${RESET}"
notch=(NotchIntegration.qml NotchPanel.qml)
present=()
for f in "${notch[@]}"; do [[ -f $f ]] && present+=("$f"); done
if (( ${#present[@]} == 0 )); then
  echo "  ${DIM}skip  no notch integration yet${RESET}"
else
  code() { sed -E 's#//.*$##' "$1"; }
  # Colours only from surfaceHost: no theme colour may reach the notch.
  hits=""
  for f in "${present[@]}"; do
    h=$(code "$f" | grep -nE '(^|[^A-Za-z0-9_.])Color\.' | sed "s#^#    $f:#")
    [[ -n $h ]] && hits+="$h"$'\n'
  done
  if [[ -n $hits ]]; then
    echo "  ${RED}FAIL${RESET}  the notch shell reads Omarchy's Color (colours come from surfaceHost):"
    printf '%s' "$hits" | head -20
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  no Color.* in the notch shell"
  fi

  # The notch refuses an integration whose entry file names a window type,
  # comments included (own-window), and an integration may not register IPC.
  if [[ -f NotchIntegration.qml ]]; then
    h=$(grep -nE 'PanelWindow|PopupWindow|FloatingWindow|IpcHandler' NotchIntegration.qml | sed 's#^#    NotchIntegration.qml:#')
    if [[ -n $h ]]; then
      echo "  ${RED}FAIL${RESET}  the integration names a window type or registers IPC:"
      printf '%s\n' "$h" | head -10
      failures=$((failures + 1))
    else
      echo "  ${GREEN}pass${RESET}  the integration names no window type and registers no IPC"
    fi
  fi

  # Imports: the set an integration may use, and the only relative ones are
  # this plugin's views/ and common/ (no view forked outside views/; gate G8 b).
  hits=""
  for f in "${present[@]}"; do
    h=$(grep -nE '^import ' "$f" | grep -vE '^[0-9]+:import (QtQuick|Quickshell|Quickshell\.Io|qs\.Commons|qs\.Ui)$' |
      grep -vE '^[0-9]+:import "(views|common)(/[A-Za-z]+\.js)?"( as [A-Za-z]+)?$' | sed "s#^#    $f:#")
    [[ -n $h ]] && hits+="$h"$'\n'
  done
  if [[ -n $hits ]]; then
    echo "  ${RED}FAIL${RESET}  an import outside the notch's allowed set, or a view from outside views/:"
    printf '%s' "$hits" | head -20
    failures=$((failures + 1))
  else
    echo "  ${GREEN}pass${RESET}  notch shell imports only the allowed modules, views/ and common/"
  fi
fi

echo
echo "${BOLD}Engine boundary${RESET}  ${DIM}(plan-engine.md §12 E9)${RESET}"
hits=$(grep -nE '"/sys/|hyprctl|boltctl|nvidia-smi' "${files[@]}" /dev/null | grep -vE ':[0-9]+:[[:space:]]*//' | head -20)
if [[ -n $hits ]]; then
  echo "  ${RED}FAIL${RESET}  QML reads the machine itself instead of asking the engine:"
  printf '%s\n' "$hits" | sed 's/^/    /'
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  no /sys, hyprctl, boltctl or nvidia-smi in any QML"
fi

echo
if (( failures )); then echo "${RED}$failures QML check(s) failed${RESET}"; exit 1; fi
echo "${GREEN}QML passes${RESET}"
