#!/bin/bash

# Check this plugin's shell before Omarchy runs it.
#
#   ./dev/lint.sh
#
# Every bash script in the repo (engine, libraries, backends, test runner,
# fakes, fixtures) must parse with `bash -n`. When shellcheck is installed it
# runs too: errors fail the lint, warnings are listed but do not.
#
# QML lint (qmllint against the installed Omarchy shell, as omarchy-profiles'
# dev/lint.sh does) joins this script with the first QML file (gate G1).
#
# Fails when:
#   - any script does not parse, or
#   - shellcheck reports anything at severity error, or
#   - the manifest or a profile is not valid JSON, or
#   - the repo contains a symlink (`omarchy plugin update` would roll back
#     every later update; plan-gui.md §2).

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO" || exit 1
failures=0

# Tracked files plus new ones not yet added, minus ignored.
list_files() { git ls-files --cached --others --exclude-standard 2>/dev/null || find . -type f -printf '%P\n'; }

echo "${BOLD}Shell${RESET}"
scripts=()
while IFS= read -r f; do
  [[ -f $f && ! -L $f ]] || continue
  case $f in
    *.sh) scripts+=("$f") ;;
    *) head -n1 "$f" 2>/dev/null | grep -q '^#!.*bash' && scripts+=("$f") ;;
  esac
done < <(list_files | grep -vE '^(docs|\.git)/')

bad=()
for s in "${scripts[@]}"; do
  bash -n "$s" 2>/dev/null || bad+=("$s")
done
if (( ${#bad[@]} )); then
  echo "  ${RED}FAIL${RESET}  syntax errors: ${bad[*]}"
  for s in "${bad[@]}"; do bash -n "$s" 2>&1 | head -5 | sed 's/^/        /'; done
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  ${#scripts[@]} scripts parse"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -x -S error "${scripts[@]}" 2>&1); then
    echo "  ${GREEN}pass${RESET}  shellcheck (errors only) is clean"
  else
    echo "  ${RED}FAIL${RESET}  shellcheck reports errors:"
    printf '%s\n' "$out" | head -30 | sed 's/^/        /'
    failures=$((failures + 1))
  fi
  warn=$(shellcheck -x -S warning -f gcc "${scripts[@]}" 2>/dev/null | grep -c ': warning:')
  if (( warn )); then
    echo "  ${DIM}note  shellcheck: $warn warning(s), not fatal (shellcheck -x -S warning <file>)${RESET}"
  else
    echo "  ${DIM}note  shellcheck: no warnings${RESET}"
  fi
else
  echo "  ${DIM}skip  shellcheck is not installed (bash -n only)${RESET}"
fi

echo
echo "${BOLD}Data${RESET}"
jbad=()
while IFS= read -r f; do
  [[ -f $f ]] || continue
  jq -e . "$f" >/dev/null 2>&1 || jbad+=("$f")
done < <(list_files | grep -E '^(manifest\.json|profiles/.*\.json|tests/schema/.*\.json)$')
if (( ${#jbad[@]} )); then
  echo "  ${RED}FAIL${RESET}  invalid JSON: ${jbad[*]}"
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  manifest, profiles and schema are valid JSON"
fi

links=$(find . -path ./.git -prune -o -type l -print)
if [[ -n $links ]]; then
  echo "  ${RED}FAIL${RESET}  symlinks in the repo (fixtures must build theirs at test time):"
  printf '%s\n' "$links" | head -10 | sed 's/^/        /'
  failures=$((failures + 1))
else
  echo "  ${GREEN}pass${RESET}  no symlinks"
fi

echo
echo "${BOLD}QML${RESET}"
if list_files | grep -q '\.qml$'; then
  echo "  ${RED}FAIL${RESET}  QML files exist but qmllint is not wired in yet (gate G1)"
  failures=$((failures + 1))
else
  echo "  ${DIM}skip  no QML yet${RESET}"
fi

echo
if (( failures )); then echo "${RED}$failures check(s) failed${RESET}"; exit 1; fi
echo "${GREEN}everything passes${RESET}"
