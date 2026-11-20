#!/bin/bash

# The consistency gate (plan-apple-ui.md 6.2): fails on any non-canonical
# variant of a control, and prints a per-plugin consistency score.
#
#   ./dev/check-ui.sh                      the gate, on this repo
#   ./dev/check-ui.sh --score              also the score and the class table (plan section 3)
#   ./dev/check-ui.sh --counts             the headline counts, by the one method below
#   ./dev/check-ui.sh --repo <dir> [--ref <sha>]    another repo; --ref reads that commit with `git archive`
#   ./dev/check-ui.sh --walk <root.qml>    run the walk (rule 5) on this root as well (needs the kit's ui/)
#   ./dev/check-ui.sh --no-walk            static rules only
#
# A line that must stay may carry `// ui-allow: <reason>`; it is skipped and
# listed. It measures structure (lint plus rendered metrics), not behaviour.
#
# Rules (each prints pass or FAIL with file:line):
#   1. ui/ hash mismatch against ui/KIT; a file in ui/ not listed there; a type in ui/ not starting with U
#   2. outside ui/: pixelSize: <digit>, "#hex" and Qt.rgba(<digits> colour literals,
#      radius: <digit>, duration: <digit>, Style.font.caption
#   3. a component named *Switch|Toggle|Choice|Chip|Confirm|Tip|Toast*; a *Row that is not a URow; the Omarchy or
#      QtQuick Controls Button, Toggle, TextField, ToggleSwitch, ConfirmDialog, Dropdown, PanelActionButton, ToolTip
#   4. a dismiss label of Close, Keep, Later, Dismiss, OK, Okay; raw Key_Escape or onEscapePressed (UKeys owns Esc)
#   5. the walk (dev/harness/ui-walk.qml): names, hit targets, text size, contrast from rendered pixels, loops
#      under reduced motion, no translucent item in contract-1 mode
#
# Counting method (--counts, and the numbers recorded in the plan): QML files
# outside ui/, dev/, upstream/, docs/; a "line" is a line with at least one
# hit, a "hit" is one occurrence. This tool and the plan quote these figures.

set -uo pipefail
export LC_ALL=C.UTF-8

GREEN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo=$HERE; ref=""; score=0; counts=0; walk=auto; walkroot=""
while (($#)); do
  case $1 in
    --repo) repo=${2:-}; shift 2 ;;
    --ref) ref=${2:-}; shift 2 ;;
    --score) score=1; shift ;;
    --counts) counts=1; shift ;;
    --walk) walk=yes; walkroot=${2:-}; shift 2 ;;
    --no-walk) walk=no; shift ;;
    *) echo "check-ui: unknown argument $1" >&2; exit 2 ;;
  esac
done
repo=$(cd "$repo" 2>/dev/null && pwd) || { echo "check-ui: no such directory" >&2; exit 2; }

work=""
cleanup() { [[ -n $work ]] && rm -rf "$work"; }
trap cleanup EXIT
if [[ -n $ref ]]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-ui-check.XXXXXX")
  git -C "$repo" archive "$ref" | tar -x -C "$work" || { echo "check-ui: cannot read $ref in $repo" >&2; exit 2; }
  scan=$work
else
  scan=$repo
fi
cd "$scan" || exit 2

failures=0
fail() { failures=$((failures + 1)); }

# The QML files outside ui/, dev/, upstream/, docs/.
mapfile -t src < <(find . -name '*.qml' -not -path './ui/*' -not -path './dev/*' -not -path '*/upstream/*' -not -path './docs/*' -not -path '*/node_modules/*' -not -path './.git/*' | sed 's#^\./##' | sort)

allowfile=$(mktemp "${TMPDIR:-/tmp}/omarchy-ui-allow.XXXXXX")
trap 'cleanup; rm -f "$allowfile"' EXIT
# hits <pattern> -> the hits in src, minus `ui-allow` lines (which go to $allowfile, to be listed)
hits() {
  local pattern=$1 line
  ((${#src[@]})) || return 0
  while IFS= read -r line; do
    if [[ $line == *"// ui-allow:"* ]]; then printf '%s\n' "$line" >>"$allowfile"; else printf '%s\n' "$line"; fi
  done < <(grep -nP -- "$pattern" "${src[@]}" 2>/dev/null | sed -E 's/^([^:]+):([0-9]+):/\1:\2: /')
}

rule() { # rule <description> <pattern>
  local out
  out=$(hits "$2")
  if [[ -z $out ]]; then
    echo "  ${GREEN}pass${RESET}  $1"
  else
    echo "  ${RED}FAIL${RESET}  $1 ${DIM}($(wc -l <<<"$out") hit(s))${RESET}"
    head -n 6 <<<"$out" | cut -c1-150 | sed 's/^/        /'
    fail
  fi
}

echo "${BOLD}UI consistency gate${RESET}  ${DIM}$repo${ref:+ @ $ref}, ${#src[@]} QML files outside ui/${RESET}"

# ---------------------------------------------------------------- rule 1
echo
echo "${BOLD}1. The vendored kit${RESET}"
if [[ -d ui ]]; then
  # a type in ui/ that does not start with U: a QML file, or an inline component
  badtypes=$(find ui -name '*.qml' ! -name 'U*.qml' | sort; grep -nP '^\s*component\s+(?!U)\w+\s*:' ui/*.qml 2>/dev/null)
  if [[ -z $badtypes ]]; then echo "  ${GREEN}pass${RESET}  every type in ui/ starts with U"
  else echo "  ${RED}FAIL${RESET}  a type in ui/ does not start with U (bare names collide with QtQuick and qs.Ui, where the last import wins):"; sed 's/^/        /' <<<"$badtypes" | head -6; fail; fi
fi
if [[ -f ui/KIT ]]; then
  first=$(head -n 1 ui/KIT)
  if [[ ! $first =~ ^omarchy-ui\ [0-9a-f]{40}$ ]]; then
    echo "  ${RED}FAIL${RESET}  ui/KIT line 1 is not 'omarchy-ui <40-hex sha>': $first"; fail
  else
    mismatched=(); missing=(); listed=()
    while read -r hash path; do
      [[ $hash =~ ^[0-9a-f]{64}$ ]] || continue
      listed+=("$path")
      if [[ ! -f $path ]]; then missing+=("$path")
      elif [[ $(sha256sum "$path" | cut -d' ' -f1) != "$hash" ]]; then mismatched+=("$path"); fi
    done < <(tail -n +2 ui/KIT)
    extra=()
    for f in ui/*; do
      [[ $f == ui/KIT ]] && continue
      [[ " ${listed[*]} " == *" $f "* ]] || extra+=("$f")
    done
    if ((${#mismatched[@]} + ${#missing[@]} + ${#extra[@]} == 0)); then
      echo "  ${GREEN}pass${RESET}  ui/ matches ui/KIT ${DIM}(${first#omarchy-ui }, ${#listed[@]} files; major $(sed -n 's/^major //p' ui/KIT))${RESET}"
    else
      echo "  ${RED}FAIL${RESET}  ui/ differs from ui/KIT: a fix goes to the omarchy-ui repo, then dev/sync-ui.sh"
      ((${#mismatched[@]})) && echo "        edited:   ${mismatched[*]}"
      ((${#missing[@]})) && echo "        missing:  ${missing[*]}"
      ((${#extra[@]})) && echo "        not in KIT: ${extra[*]}"
      fail
    fi
  fi
elif [[ -d ui ]]; then
  if [[ -f ui/UTheme.qml && -d dev/harness && -f dev/gallery.qml ]]; then
    echo "  ${DIM}skip  ui/KIT: this is the kit's own source (plugins carry the KIT file)${RESET}"
  else
    echo "  ${RED}FAIL${RESET}  ui/ has no ui/KIT: copy the kit with dev/sync-ui.sh --from <omarchy-ui>"; fail
  fi
else
  echo "  ${DIM}skip  no ui/ in this repo yet${RESET}"
fi

# ---------------------------------------------------------------- rule 2
echo
echo "${BOLD}2. Literals outside ui/${RESET}"
rule 'pixelSize: <digit> (a size is a token: theme.titleSize, bodySize, footnoteSize)' 'pixelSize:\s*[0-9]'
rule '"#hex" colour literals (a colour is a role: theme.label, secondary, accent, ...)' '["'"'"']#[0-9a-fA-F]{3,8}["'"'"']'
rule 'Qt.rgba(<digits> (same)' 'Qt\.rgba\(\s*[0-9.]'
rule 'radius: <digit> (theme.radius(h))' '\bradius:\s*[0-9]'
rule 'duration: <digit> (a motion token: theme.controlMs, arriveMs, fadeOutMs, ...)' '\bduration:\s*[0-9]'
rule 'Style.font.caption (10 px; the footnote is 11)' 'Style\.font\.caption'

# ---------------------------------------------------------------- rule 3
echo
echo "${BOLD}3. One component per control class${RESET}"
rule 'no private Switch, Toggle, Choice, Chip, Confirm, Tip or Toast component' '^\s*component\s+\w*(Switch|Toggle|Choice|Chip|Confirm|Tip|Toast)\w*\s*:'
rule 'every *Row component is a URow' '^\s*component\s+\w*Row\s*:\s*(?!URow\b)'
rule 'no ToggleSwitch, ConfirmDialog, Dropdown, PanelActionButton or ToolTip' '\b(ToggleSwitch|ConfirmDialog|Dropdown|PanelActionButton|ToolTip)\s*\{'
rule 'no Button, Toggle or TextField (Omarchy qs.Ui or QtQuick Controls): UButton, USwitch, UField' '\b(Button|Toggle|TextField)\s*\{'

# ---------------------------------------------------------------- rule 4
echo
echo "${BOLD}4. Dismiss words and Esc${RESET}"
rule 'no Close, Keep, Later, Dismiss, OK or Okay as a label (Cancel, Done, Not now; action verbs are open)' '(text|label)\s*:\s*"(Close|Keep|Later|Dismiss|OK|Okay)"'
rule 'no raw Key_Escape or onEscapePressed (UKeys)' 'Key_Escape|onEscapePressed'

# ---------------------------------------------------------------- rule 5
echo
echo "${BOLD}5. The walk${RESET}"
walkscript=$HERE/dev/walk.sh
[[ -f $scan/dev/walk.sh && -z $ref ]] && walkscript=$scan/dev/walk.sh
if [[ $walk == no ]]; then
  echo "  ${DIM}skip  --no-walk${RESET}"
elif [[ -n $ref ]]; then
  echo "  ${DIM}skip  a --ref checkout is read statically${RESET}"
elif [[ ! -f $scan/dev/harness/ui-walk.qml || ! -f $scan/ui/UTheme.qml ]]; then
  echo "  ${DIM}skip  no dev/harness/ui-walk.qml or no ui/ here${RESET}"
else
  if [[ -z $walkroot ]]; then
    if [[ -f dev/gallery.qml ]]; then walkroot=dev/gallery.qml
    elif [[ $walk == yes ]]; then echo "  ${RED}FAIL${RESET}  --walk needs a root file"; fail
    else echo "  ${DIM}skip  no walk root: this plugin names one with --walk <file.qml> (a QML file with a \`theme\` property)${RESET}"; fi
  fi
  if [[ -n $walkroot ]]; then
    # the walk takes the repo it runs in: the kit's own, or the plugin's
    for cfg in "standalone black" "hosted black" "hosted white" "styled black" "styled white" "hosted black reduced" "standalone black reduced"; do
      read -r wmode whost wred <<<"$cfg"
      args=(--root "$walkroot" --mode "$wmode" --host "$whost"); [[ -n ${wred:-} ]] && args+=(--reduced)
      out=$("$walkscript" "${args[@]}" 2>&1); rc=$?
      label=$wmode; [[ $wmode != standalone ]] && label="$wmode/$whost"; [[ -n ${wred:-} ]] && label="$label, reduced motion"
      if ((rc == 0)); then
        worst=$(sed -n 's/^contrast pass .*worst \([0-9.]*\):1.*/\1/p' <<<"$out")
        echo "  ${GREEN}pass${RESET}  $label ${DIM}(worst text ${worst:-n/a}:1, $(sed -n 's/^items //p' <<<"$out") items)${RESET}"
      else
        echo "  ${RED}FAIL${RESET}  $label"; grep -E 'FAIL|-item|^load|^timeout|  !' <<<"$out" | head -8 | cut -c1-200 | sed 's/^/        /'; fail
      fi
    done
  fi
fi

if [[ -s $allowfile ]]; then echo; echo "${BOLD}Allowed with // ui-allow (listed for the PR)${RESET}"; sort -u "$allowfile" | cut -c1-170 | sed 's/^/        /'; fi

# ---------------------------------------------------------------- counts
count() { # count <pattern> -> "lines hits"
  ((${#src[@]})) || { echo "0 0"; return; }
  local l h
  l=$(grep -hP -- "$1" "${src[@]}" 2>/dev/null | wc -l)
  h=$(grep -ohP -- "$1" "${src[@]}" 2>/dev/null | wc -l)
  echo "$l $h"
}
if ((counts)); then
  echo
  echo "${BOLD}Counts${RESET}  ${DIM}QML files outside ui/, dev/, upstream/, docs/: ${#src[@]}${RESET}"
  printf '  %-44s %8s %8s\n' "" "lines" "hits"
  for spec in 'Style. (any token)|\bStyle\.' 'duration: <digit> (numeric literal)|\bduration:\s*[0-9]' 'duration: (any)|\bduration:' 'Style.font.caption|Style\.font\.caption' 'theme.font.caption|\.font\.caption' 'pixelSize: <digit>|pixelSize:\s*[0-9]' '"#hex" literals|["'"'"']#[0-9a-fA-F]{3,8}["'"'"']' 'Qt.rgba(<digits>|Qt\.rgba\(\s*[0-9.]' 'radius: <digit>|\bradius:\s*[0-9]' 'Accessible.|\bAccessible\.' 'reduced-motion reads|REDUCED_MOTION|reducedMotion'; do
    read -r l h <<<"$(count "${spec#*|}")"
    printf '  %-44s %8s %8s\n' "${spec%%|*}" "$l" "$h"
  done
fi

# ---------------------------------------------------------------- score
if ((score)); then
  echo
  echo "${BOLD}Consistency by class${RESET}  ${DIM}(plan-apple-ui.md section 3: a class counts when the plugin has it, in either form)${RESET}"
  printf '  %-18s %6s %9s   %s\n' "class" "canon" "variants" "verdict"
  present=0; matched=0
  # name@@canonical pattern@@variant pattern
  classes=(
    'Back@@\bUBack\s*\{|\bBackStrip\s*\{@@(text|label|iconText)\s*:\s*"[^"]*\bBack\b[^"]*"|\\u\{f004d\}'
    'Close@@\bUClose\s*\{@@(text|label|iconText)\s*:\s*"[^"]*[✕✖×][^"]*"|\\u2715'
    'Dismiss words@@(text|label)\s*:\s*"(Cancel|Done|Not now)"@@(text|label)\s*:\s*"(Close|Keep|Later|Dismiss|OK|Okay)"'
    'Primary button@@\bUButton\s*\{@@(?<![A-Za-z])(NotchButton|PanelActionButton|Button|Action)\s*\{'
    'Destructive@@kind:\s*"destructive"@@^(?!.*destructive).*(text|label)\s*:\s*"(Delete|Remove|Erase|Purge)\b'
    'Confirm@@\bUConfirmSheet\s*\{@@\bConfirmDialog\s*\{|\bNotchConfirmDialog\b|^\s*component\s+\w*Confirm\w*\s*:'
    'Switch@@\bUSwitch\s*\{@@\bToggleSwitch\s*\{|\bToggle\s*\{|^\s*component\s+\w*Switch\w*\s*:|(?<![A-Za-z])Switch\s*\{'
    'Pick / segmented@@\b(USegmented|UPick)\s*\{@@\b(ButtonGroup|Dropdown)\s*\{|^\s*component\s+\w*(Choice|Chip)\w*\s*:|\b\w*(Chips|ChoiceRow|ScopeChoice)\s*\{'
    'Field@@\b(UField|UStepper)\s*\{@@\b(TextField|NumberField|SpinBox)\s*\{'
    'Row@@\bURow\s*\{@@^\s*component\s+\w*Row\s*:\s*(?!URow\b)'
    'Section header@@\bUSection\s*\{@@\bPanelSectionHeader\s*\{|^\s*component\s+\w*(Section|Heading)\w*\s*:'
    'Tip@@\bUTip\s*\{@@\b(ToolTip|PanelToolTip)\s*\{|^\s*component\s+\w*Tip\w*\s*:'
    'Toast / notice@@\b(UToast|UNotice)\s*\{@@^\s*component\s+\w*(Toast|Notice)\w*\s*:'
    'Empty@@\bUEmpty\s*\{@@(text|label)\s*:\s*"(Nothing [^"]*|No [^"]* yet)\.?"'
    'Error@@\bUNotice\s*\{@@(text|label)\s*:[^"]*"[^"]*(did not work|failed)[^"]*"\s*\+'
    'Progress@@\bURing\s*\{@@\b(BusyIndicator|Spinner|ProgressBar)\s*\{|^\s*component\s+\w*Spinner\w*\s*:'
    'Keys@@\bUKeys\s*\{@@Key_Escape|onEscapePressed|\bPanelKeyCatcher\s*\{'
  )
  for spec in "${classes[@]}"; do
    name=${spec%%@@*}; rest=${spec#*@@}
    canon=${rest%%@@*}; variants=${rest#*@@}
    read -r c _ <<<"$(count "$canon")"
    read -r v _ <<<"$(count "$variants")"
    if ((c + v == 0)); then
      printf '  %-18s %6s %9s   %s\n' "$name" "$c" "$v" "${DIM}n/a (the plugin has none)${RESET}"
      continue
    fi
    present=$((present + 1))
    if ((v == 0)); then matched=$((matched + 1)); verdict="${GREEN}pass${RESET}"; else verdict="${RED}FAIL${RESET}"; fi
    printf '  %-18s %6s %9s   %s\n' "$name" "$c" "$v" "$verdict"
  done
  if ((present)); then
    printf '\n  %sconsistency%s  %s of %s classes canonical  =  %s%s / 10%s\n' "$BOLD" "$RESET" "$matched" "$present" "$BOLD" "$(awk -v m=$matched -v p=$present 'BEGIN{printf "%.1f", 10*m/p}')" "$RESET"
  else
    echo "  consistency  no classes present"
  fi
fi

echo
if ((failures)); then echo "${RED}$failures rule(s) failed${RESET}"; exit 1; fi
echo "${GREEN}no failures${RESET}"
