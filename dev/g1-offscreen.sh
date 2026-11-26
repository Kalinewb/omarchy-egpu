#!/bin/bash

# Gate G1, the part that needs no hardware and no live shell (plan-gui.md §10):
# "All phases of §4 render from fixtures", plus the status plumbing behind them.
#
#   ./dev/g1-offscreen.sh            every check
#   ./dev/g1-offscreen.sh --png DIR  also keep a PNG of the bar glyph per state,
#                                    of the popup and of every view rendered
#
# Runs the REAL Panel.qml, Service.qml and views/*.qml in a throwaway
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
    timeout 60 quickshell -p "$root/qs" >"$root/last.log" 2>&1
  sed -n 's/^.*HARNESS \([a-zA-Z0-9._-]*\) \(.*\)$/\1=\2/p' "$root/last.log"
}
# JavaScript errors from the plugin in the last run's log (as g8-offscreen.sh):
# an undefined palette shows up here first (Omarchy 4.0.5's bare `Color`).
jserrors() {
  grep -E 'TypeError|ReferenceError|is not a function|Cannot read property|Unable to assign' "$root/last.log" |
    grep -F -- 'egpu' | head -3 | sed 's/^/      /'
}

field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }

echo "G1 — bar indicator, status plumbing, Overview, Setup (G6) and the eject sheet (G3), offscreen"
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
step "the popup: header, padding and routes (ui-scope.md §0, §2; §7.7)"
rm -f "$RUN/status.json"; put ready
out=$(harness indicator EGPU_HARNESS_WAIT_MS=1200)
check "a route that is not built yet is refused, not shown blank" "overview" "$(field unbuiltRoute "$out")"
check "the built tabs are offered: Overview, Games and Setup" "overview,games,setup" "$(field tabs "$out")"

out=$(harness popup EGPU_HARNESS_WAIT_MS=1500 ${PNG:+EGPU_HARNESS_PNG="$PNG/popup-ready.png"})
texts=$(sed -n 's/^text=//p' <<<"$out" | paste -sd'|')
check "the popup opens with the Overview inside it" "true|true" "$(field opened "$out")|$(field popupVisible "$out")"
check "…its header is the tab row and the one close, then the headline, said once (no enclosure name, no engine line)" \
  "Overview|Games|Setup|✕|glyph|eGPU ready|RTX 4070 SUPER · 29 °C · idle|Safe eject|no|no" \
  "$(cut -d'|' -f1-8 <<<"$texts")|$(grep -qF 'TBGAA' <<<"$texts" && echo yes || echo no)|$(grep -qiF 'eject before unplugging' <<<"$texts" && echo yes || echo no)"
check "…with no Back at the root" "false" "$(field backVisible "$out")"
check "Escape (back) at the root closes it" "closed" "$(field afterBack "$out")"
check "…and the popup, its header and the Overview throw no JavaScript errors" "" "$(jserrors)"

rm -f "$RUN/status.json"; put ready
out=$(harness routes EGPU_HARNESS_WAIT_MS=1500)
inset=$(field inset "$out")
check "the popup pads its content by the kit's one inset token (sp.lg, ${inset:-?} at this spacing scale)" \
  "$( [[ $inset =~ ^[0-9]+$ ]] && echo "$inset" || echo 'a token')" "$(field padding "$out")"
check "routes: Fix pushes Setup on its row, Back pops it, Details and the eject sheet push, tabs replace, Escape at the root closes" \
  "open:overview:open fix:overview>setup:system.helper back:overview details:overview>details eject:overview>details>eject back2:overview tab:setup tab2:overview unbuilt:overview viewBack:overview root:closed" \
  "$(field routes "$out")"
rm -f "$RUN/status.json"; put stranger-no-tb
out=$(harness routes EGPU_HARNESS_WAIT_MS=1500 OMARCHY_EGPU_DEV_FIXTURE=stranger-no-tb)
check "first run (helper never installed, no eGPU): the popup opens on Setup" "open:setup:open" "$(field routes "$out" | cut -d' ' -f1)"
rm -f "$RUN/status.json"; put this-machine
out=$(harness routes EGPU_HARNESS_WAIT_MS=1500 OMARCHY_EGPU_DEV_FIXTURE=this-machine)
check "…but not while an eGPU is there to show (this machine: ready)" "open:overview:open" "$(field routes "$out" | cut -d' ' -f1)"

# =============================================================================
step "the kit's tokens, used by every view (ui-scope.md §0.2, §5; omarchy-ui)"
# common/Palette.js is the look half only now (glyphs, look(), tone()); the private palette and padding tokens
# it used to build are the kit's (ui/UTheme.qml, sp.xs to sp.xxl).
check "common/Palette.js: look(), the glyphs and tone(); no private palette or spacing left" "yes|no|no|no" \
  "$(grep -qE '^function (look|tone)\(' "$REPO/common/Palette.js" && echo yes || echo no)|$(grep -qE '^function (make|fromHost|spacing)\(' "$REPO/common/Palette.js" && echo yes || echo no)|$(grep -q 'SPACE' "$REPO/common/Palette.js" && echo yes || echo no)|$(ls "$REPO/views/ui" 2>/dev/null | grep -q . && echo yes || echo no)"
check "Palette.tone() maps a look's role to the kit's theme: secondary, accent, good, warn, bad, anything else" "S|A|A|W|B|L" \
  "$(node -e '
const fs = require("fs"), vm = require("vm"); const c = {}; vm.createContext(c)
vm.runInContext(fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library/m, ""), c)
const t = { secondary: "S", accentText: "A", warning: "W", destructive: "B", label: "L" }
console.log(["secondary", "accent", "good", "warn", "bad", "foreground"].map(r => c.tone(t, r)).join("|"))' "$REPO/common/Palette.js" 2>&1)"
for v in "$REPO"/views/*.qml; do
  n=${v##*/}
  # The kit's named steps (`theme.sp.md`, or the `sp` shorthand a view binds to them).
  uses=$(grep -cE '\bsp\.(xs|sm|md|lg|xl|xxl)\b' "$v")
  raw=$(sed -E 's#//.*$##' "$v" | grep -cE '^\s*spacing:\s*[0-9]')
  case $n in Glance.qml | StatusNotes.qml | Header.qml | DetailsView.qml) need=0 ;; *) need=1 ;; esac
  check "$n lays out with the kit's named steps, never a raw spacing number" "yes|0" "$( (( uses >= need )) && echo yes || echo no)|$raw"
done
check "both shells pad by the kit's step: KeyboardPanel padding and NotchPanel's inset" "yes|yes" \
  "$(grep -qF 'padding: Math.round(popupTheme.sp.lg)' "$REPO/Panel.qml" && echo yes || echo no)|$(grep -qF 'readonly property real inset: root.theme.sp.lg' "$REPO/NotchPanel.qml" && echo yes || echo no)"

# =============================================================================
step "Setup's words: every health row id has copy, in plain words (common/SetupRows.js)"
# The ids lib/ can emit, from its own source, against SetupRows.IDS; then every
# engine title lib/ can print, and every row in every fixture, through
# describe(): a sentence, and no jargon on the surface (the id, file names,
# module names and policy words belong under Details).
JS_LOAD='
const fs = require("fs"), vm = require("vm"), path = require("path")
function load(file, ctx) {
  ctx = ctx || {}
  let src = fs.readFileSync(file, "utf8").replace(/^\.pragma library/m, "")
  src = src.replace(/^\.import "([^"]+)" as (\w+)$/mg, (m, f, n) => { ctx[n] = load(path.join(path.dirname(file), f)); return "" })
  const c = Object.assign({ Math, JSON, String, Number, Array, Object, RegExp }, ctx)
  vm.createContext(c); vm.runInContext(src, c); return c
}'
lib_ids=$(grep -rhoE 'health_row [a-z_]+\.[a-z_]+' "$REPO/lib" | awk '{print $2}' | sort -u | paste -sd,)
js_ids=$(node -e "$JS_LOAD"'; const R = load(process.argv[1]); console.log(R.IDS.slice().sort().join(","))' "$REPO/common/SetupRows.js")
check "the ids SetupRows.js knows are exactly the ids lib/ emits" "$lib_ids" "$js_ids"
JARGON='toggle file|modprobe|mkinitcpio|initramfs|boltd|\bbolt\b|nvidia[-_]drm|AQ_DRM|polkit|udev|/etc/|/dev/|/usr/|modeset|fbdev|persistenced|vulkaninfo|system half|policy|\.conf\b|\.lua\b|localconfig|vdf|kms|pkexec'
variants=$(grep -rhE 'health_row [a-z_]+\.[a-z_]+ [a-z]+ ("?\$?[a-z]+"?) "' "$REPO/lib" |
  sed -E 's/.*health_row ([a-z_.]+) [a-z]+ "?\$?([a-z]+)"? "([^"]*)".*/\1\t\2\t\3/' | sort -u)
fixture_rows=$(cat "$FIX"/*/health.json | jq -s -c 'add')
out=$(node -e "$JS_LOAD"'
const R = load(process.argv[1]); const jargon = new RegExp(process.argv[2], "i")
const rows = JSON.parse(process.argv[4])
for (const line of process.argv[3].split("\n").filter(Boolean)) {
  const [id, lv, title] = line.split("\t")
  const level = ["ok","info","warn","error","skipped"].includes(lv) ? lv : "warn"
  for (const fx of [{kind: "none", label: ""}, {kind: "user", label: "Log out and in"}, {kind: "system", label: "Install the system half"}])
    rows.push({ id, level, title, detail: "", fix: fx })
}
const bad = [], unknown = []
let n = 0
for (const r of rows) {
  n++
  if (!R.known(r.id)) unknown.push(r.id)
  const d = R.describe(r, rows)
  const words = d.sentence + " " + d.why + " " + d.fix.label
  if (!d.sentence || d.sentence === r.id || words.indexOf(r.id) !== -1 || jargon.test(words)) bad.push(r.id + " [" + r.title + "]: " + words)
  if (d.details.indexOf(r.id) !== 0) bad.push(r.id + ": Details does not start with the id")
}
console.log("rows=" + n); console.log("unknown=" + ([...new Set(unknown)].join(",") || "none")); console.log("bad=" + (bad.slice(0, 5).join(" ;; ") || "none"))
' "$REPO/common/SetupRows.js" "$JARGON" "$variants" "$fixture_rows" 2>&1)
check "every engine title variant and fixture row ($(field rows "$out") rows) has a known id" "none" "$(field unknown "$out")"
check "…a plain sentence, no jargon, the id only under Details" "none" "$(field bad "$out")"

# =============================================================================
step "the install command (common/Install.js; ui-scope.md §7)"
out=$(node -e "$JS_LOAD"'
const cp = require("child_process"); const I = load(process.argv[1])
const out = []
for (const m of ["install", "uninstall"]) {
  const cmd = cp.execFileSync("bash", [process.argv[2], "--print-command", m]).toString()
  out.push(m + "=" + I.commandOk(cmd, m))
}
const cmd = cp.execFileSync("bash", [process.argv[2], "--print-command", "install"]).toString()
out.push("tampered=" + [cmd.trim() + "; rm -rf ~", "echo hi", cmd.replace("raw.githubusercontent.com/Kalinewb", "evil.example/x"), cmd.trim() + "\nid"].map(c => I.commandOk(c, "install")).join(","))
fs.writeFileSync(process.argv[3], I.terminalScript(cmd))
console.log(out.join("\n"))' "$REPO/common/Install.js" "$REPO/system/install.sh" "$root/script.sh" 2>&1)
check "install.sh --print-command's install and uninstall commands pass the shape check" "true|true" "$(field install "$out")|$(field uninstall "$out")"
check "…anything appended, replaced or added on a new line does not" "false,false,false,false" "$(field tampered "$out")"
check "the terminal script parses, explains first, waits for Enter, checks the release, then ends with exactly the command" "yes|yes|yes|yes|yes" \
  "$(bash -n "$root/script.sh" 2>/dev/null && echo yes || echo no)|$(head -1 "$root/script.sh" | grep -qF "lets the panel connect and eject the eGPU without a password" && echo yes || echo no)|$(sed -n 2p "$root/script.sh" | grep -qF "read -r -p 'Press Enter" && echo yes || echo no)|$(sed -n 3p "$root/script.sh" | grep -q "^code=\$(curl -sSI .*raw.githubusercontent.com/Kalinewb/omarchy-egpu/v[0-9.]*/system/install.sh.sha256" && echo yes || echo no)|$( [[ $(tail -n 1 "$root/script.sh") == "$(bash "$REPO/system/install.sh" --print-command install)" ]] && echo yes || echo no)"

# The release check, run for real against a fake curl and a fake sudo: an unpublished tag (HTTP 404, the
# user's "curl: (22) ... 404" on a fresh install) is named, not a bare curl failure, and sudo never runs;
# no network and any other answer likewise; only a 200 goes on to the command.
fakebin="$root/fakebin"; mkdir -p "$fakebin"
cat >"$fakebin/curl" <<'FAKE'
#!/bin/bash
# `curl -sSI ... -w %{http_code}` (the check) answers $FAKE_CODE; any other curl is the command's own.
for a in "$@"; do [[ $a == -sSI ]] && { printf '%s' "$FAKE_CODE"; exit 0; }; done
echo "RAN-CURL"; exit 0
FAKE
cat >"$fakebin/sudo" <<'FAKE'
#!/bin/bash
echo "RAN-SUDO"
FAKE
chmod +x "$fakebin/curl" "$fakebin/sudo"
release_run() { # release_run <http code> -> "<exit>|<output with newlines as /,>"
  local o rc
  o=$(printf '\n' | env PATH="$fakebin:$PATH" HOME="$root/home" FAKE_CODE="$1" bash "$root/script.sh" 2>&1); rc=$?
  echo "$rc|$(tr '\n' '/' <<<"${o##*to cancel. }")"
}
r404=$(release_run 404); r000=$(release_run 000); r500=$(release_run 503); r200=$(release_run 200)
check "an unpublished release (404): named, exit 1, no sudo, no curl of the command's own" "1|yes|no" \
  "${r404%%|*}|$(grep -qF 'Release v' <<<"$r404" && grep -qF 'is not published on GitHub yet' <<<"$r404" && echo yes || echo no)|$(grep -qE 'RAN-(SUDO|CURL)' <<<"$r404" && echo yes || echo no)"
check "no network (000): says so, exit 1, no sudo" "1|yes|no" \
  "${r000%%|*}|$(grep -qF 'Could not reach GitHub' <<<"$r000" && echo yes || echo no)|$(grep -qE 'RAN-(SUDO|CURL)' <<<"$r000" && echo yes || echo no)"
check "any other answer (503): names the HTTP code, exit 1, no sudo" "1|yes|no" \
  "${r500%%|*}|$(grep -qF 'HTTP 503' <<<"$r500" && echo yes || echo no)|$(grep -qE 'RAN-(SUDO|CURL)' <<<"$r500" && echo yes || echo no)"
check "a published release (200) goes on to the command" "yes" "$(grep -qE 'RAN-(SUDO|CURL)' <<<"$r200" && echo yes || echo no)"

# =============================================================================
step "GATE: the one primary button per state, Overview and compact (ui-scope.md §2.1)"
docs="$root/docs.json"
for fx in "$FIX"/*/; do fx=${fx%/}; fx=${fx##*/}
  jq -n --arg n "$fx" --slurpfile s "$FIX/$fx/status.json" --slurpfile h "$FIX/$fx/health.json" '{($n): {status: $s[0], health: $h[0]}}'
done | jq -s 'add' >"$docs"
out=$(harness primaries EGPU_HARNESS_DOCS="$docs")
# fixture | summary.state | headline | primary button (label|enabled), the same
# in the Overview and the compact view, with Setup's rows read
while IFS='|' read -r fx state headline label on; do
  [[ -n $fx ]] || continue
  want="$label|$on"; [[ $label == none ]] && want=none
  check "$fx ($state): '$headline' · $( [[ $label == none ]] && echo 'no button' || echo "[$label]$( [[ $on == off ]] && echo ' disabled')")" \
    "$headline / $headline|$want|$want" "$(field "p.$fx.headline" "$out")|$(field "p.$fx.full" "$out")|$(field "p.$fx.compact" "$out")"
  check "$fx: nothing names Setup without a way to it" "none" "$(field "p.$fx.orphans" "$out")"
done <<'TABLE'
stranger-no-tb|absent, never set up|No port|Set up eGPU support|on
absent|absent|No eGPU|none|
plugged-unauthorized|connecting|Connecting…|Connect|on
bound-nvidia|connecting|Connecting…|Connect|on
authorized-no-pci|connecting, no GPU|No card|Show me|on
ready|ready|eGPU ready|Safe eject|on
in-use-procs|in_use|In use|Safe eject…|on
ready-hdmi|in_use|In use|Safe eject…|on
ejecting|ejecting|Ejecting…|Ejecting…|off
ejected-clean|safe_to_unplug|Ejected|Done|on
bolt-down|attention (Setup)|Setup issue|Fix|on
this-machine|attention (log out)|Log out|Safe eject|on
ejected-held|attention (held)|Log out|Done|on
held-no-device|attention (held, no card)|Log out|none|
amd-stub|attention (unsupported)|Unsupported|none|
auth-error|error|Error|Open Setup|on
smi-hung|error (driver hung)|Error|none|
TABLE
check "before Setup's rows arrive, first run shows no button yet rather than a wrong one" "none" "$(field p.stranger-no-tb.norows "$out")"
check "error with no Setup row to open: Try again" "Try again|on" "$(field p.auth-error.norows "$out")"
check "a Setup problem's Fix is not said twice (no sentence repeating it)" "no" \
  "$(grep -qF 'Your enclosure could not be allowed' <<<"$(field p.auth-error.texts "$out")" && echo yes || echo no)"
check "the compact view leaves out the quiet Setup line when all is well" "yes|no" \
  "$(grep -qF 'Setup has one suggestion.' <<<"$(field p.ready.texts "$out")" && echo yes || echo no)|$(grep -qF 'Setup has one suggestion.' <<<"$(field p.ready.ctexts "$out")" && echo yes || echo no)"

# =============================================================================
step "GATE G6: Setup renders from fixtures (plan-gui.md §5.5, ui-scope.md §2.6)"
out=$(harness setups EGPU_HARNESS_DOCS="$docs")
for fx in "$FIX"/*/; do fx=${fx%/}; fx=${fx##*/}
  n=$(jq '[.[] | select(.id != "system.autoconnect")] | length' "$FIX/$fx/health.json")
  check "$fx: every row drawn ($n)" "$n" "$(field "s.$fx.rows" "$out")"
done
st=$(field s.this-machine.texts "$out")
check "this machine: the boot-time driver load is the first problem, an error the install fixes" "boot.modules_load_mask|yes" \
  "$(field s.this-machine.first "$out")|$(grep -qF 'The eGPU driver loads at startup (can freeze)' <<<"$st" && echo yes || echo no)"
check "first run: ONE button, Set up eGPU support, and no per-row Install or Fix all" "*Set up eGPU support|0|0" \
  "$(field s.this-machine.buttons "$out" | cut -d, -f1)|$(field s.this-machine.buttons "$out" | tr ',' '\n' | grep -cxE 'Install|\*Fix all')|$(field s.stranger-no-tb.buttons "$out" | tr ',' '\n' | grep -cxE 'Install|\*Fix all')"
check "helper installed: no first-run button; the toggle file row has its own Fix" "0|yes" \
  "$(field s.ready.buttons "$out" | tr ',' '\n' | grep -c 'Set up eGPU support')|$(field s.ready.buttons "$out" | tr ',' '\n' | grep -qx 'Fix' && echo yes || echo no)"
check "auto-connect is a value, never a disabled switch, and says who set it (no helper; helper installed)" "yes|yes" \
  "$(grep -qF 'Auto-connect ¦ Needs the system helper' <<<"$st" && echo yes || echo no)|$(grep -qF "Auto-connect ¦ Off" <<<"$(field s.ready.texts "$out")" && echo yes || echo no)"
check "a stranger's machine says it has no Thunderbolt port, in words" "yes" \
  "$(grep -qF 'This computer has no Thunderbolt or USB4 port' <<<"$(field s.stranger-no-tb.texts "$out")" && echo yes || echo no)"
check "no engine title or id on the surface (only under Details)" "no|no" \
  "$(grep -qF 'boot.modules_load_mask' <<<"$st" && echo yes || echo no)|$(grep -qF 'The system half is not installed' <<<"$st" && echo yes || echo no)"

# =============================================================================
step "Setup's actions, against the stub engine and the launch stub (no terminal, no clipboard)"
view() { # view <name> <fixture> [env…]: one view, its status, the stub answering for the fixture
  local v=$1 fx=$2
  shift 2
  rm -f "$RUN/launches.jsonl" "$RUN/calls.jsonl"
  harness view EGPU_HARNESS_VIEW="$v" EGPU_HARNESS_WAIT_MS=1200 EGPU_HARNESS_STATUS="$FIX/$fx/status.json" \
    OMARCHY_EGPU_DEV_FIXTURE="$fx" ${PNG:+EGPU_HARNESS_PNG="$PNG/$v-$fx${PNGTAG:-}.png"} "$@"
}
has() { grep -qF -- "$1" <<<"$2" && echo yes || echo no; }
launched() { jq -r --arg k "$1" 'select(.kind == $k) | .text' "$RUN/launches.jsonl" 2>/dev/null; }
calls() { paste -sd' ' "$RUN/calls.jsonl" 2>/dev/null; }

out=$(PNGTAG=-installed view setup this-machine EGPU_HARNESS_CLICK="Set up eGPU support")
script=$(launched terminal)
check "Set up eGPU support opens a terminal (the launcher, once) with the explanation and the pinned command" "1|yes|yes" \
  "$(launched terminal | grep -c "read -r -p 'Press Enter")|$(has "lets the panel connect and eject the eGPU without a password" "$script")|$( [[ $(tail -n 1 <<<"$script") == "$(bash "$REPO/system/install.sh" --print-command install)" ]] && echo yes || echo no)"
check "…the panel then says a terminal opened, and offers to check again" "yes|yes" \
  "$(has 'A terminal opened. Type your password there' "$(field after.texts "$out")")|$(has 'Check again' "$(field after.buttons "$out")")"
check "…and nothing was asked of the engine or the clipboard" "|" "$(calls)|$(launched copy)"
out=$(PNGTAG=-nolauncher view setup this-machine EGPU_HARNESS_CLICK="Set up eGPU support" OMARCHY_EGPU_DEV_LAUNCH_EXIT=127)
check "no Omarchy terminal: the command is shown with a Copy button instead" "yes|yes|yes" \
  "$(has "Omarchy's terminal could not be found" "$(field after.texts "$out")")|$(has 'd="$HOME/.config/omarchy/plugins/kalinewb.egpu"' "$(field after.texts "$out")")|$(has 'Copy command' "$(field after.buttons "$out")")"
out=$(view setup this-machine EGPU_HARNESS_CLICK="Copy command")
check "Copy command (the graphics check tool) copies it, and says so only once copied" "omarchy-pkg-add vulkan-tools|yes" \
  "$(launched copy)|$(has 'Copied. Paste it into a terminal' "$(field after.texts "$out")")"
out=$(view setup this-machine EGPU_HARNESS_CLICK="Copy command" OMARCHY_EGPU_DEV_LAUNCH_EXIT=1)
check "…and says it could not when wl-copy fails" "yes" "$(has 'It could not be copied: wl-copy did not run.' "$(field after.texts "$out")")"
out=$(view setup this-machine EGPU_HARNESS_CLICK="Fix" EGPU_HARNESS_FOCUS=hypr.session_env)
check "a Fix the plugin can do runs its engine verb (display apply), the rows are read again" '["display","apply"]|yes' \
  "$(calls)|$(has 'Done.' "$(field after.texts "$out")")"
check "Setup opened on a row puts it first, details open" "yes" \
  "$(has "The desktop's graphics settings are not written yet ¦ Fix ¦ They keep the desktop and its apps on the laptop's graphics. ¦ Hide details ¦ hypr.session_env" "$(field texts "$out")")"

out=$(view games in-use-procs)
check "Games with a queued change and Steam closed applies it at once (steam apply, never --close)" "yes|no" \
  "$(has '["steam","apply"]' "$(calls)")|$(has '"--close"' "$(calls)")"

# =============================================================================
step "Overview and Details from fixtures (§5.1, ui-scope.md §2.1-2.2)"
out=$(view overview plugged-unauthorized EGPU_HARNESS_CLICK="Connect")
check "Connect runs device connect" '["device","connect"]' "$(calls)"
out=$(view overview bolt-down EGPU_HARNESS_CLICK="Fix")
check "attention: Fix opens Setup on the problem's row" "setup:bolt.daemon" "$(field after.routes "$out")"
out=$(view overview stranger-no-tb EGPU_HARNESS_CLICK="Set up eGPU support")
check "never set up: the button opens Setup" "setup" "$(field after.routes "$out")"
out=$(view overview ready EGPU_HARNESS_CLICK="Safe eject")
check "ready: Safe eject opens the eject sheet" "eject" "$(field after.routes "$out")"
out=$(view overview ejected-clean EGPU_HARNESS_CLICK="Done")
check "safe to unplug: Done closes the panel" "1" "$(field after.closes "$out")"
out=$(view overview authorized-no-pci EGPU_HARNESS_CLICK="Show me")
check "no GPU behind the enclosure: Show me shows the profile's hint (DEG2 mode switch)" "no|yes" \
  "$(has "Check the dock's mode switch is set to TBT, not OCuLink." "$(field texts "$out")")|$(has "Check the dock's mode switch is set to TBT, not OCuLink." "$(field after.texts "$out")")"
out=$(view overview this-machine)
check "needs_relogin: the plan's sentence" "yes" \
  "$(has 'The HDMI monitor needs a new session to appear. Offloading apps works now.' "$(field texts "$out")")"
out=$(view overview ejected-held)
check "held modules: the warning leads, and nothing says it is safe to unplug" "yes|yes|no" \
  "$(has 'Do not suspend the computer: the driver is still loaded. Log out first, then plug the eGPU in again.' "$(field texts "$out")")|$(has 'Do not suspend · the driver is still loaded · log out first' "$(field texts "$out")")|$(has 'Safe to unplug' "$(field texts "$out")")"
out=$(view overview amd-stub)
check "an unsupported backend says so (backend_stub), with a way to Setup" "yes|yes" \
  "$(has 'This kind of GPU is detected but not supported yet.' "$(field texts "$out")")|$(has 'Open Setup' "$(field buttons "$out")")"
out=$(view overview ready EGPU_HARNESS_NOTE="watcher not running")
check "a status that will not update says so" "yes" "$(has 'Not live: watcher not running.' "$(field texts "$out")")"
out=$(view overview ready)
check "Details is a row that opens the Details page" "yes|no" "$(has 'Details' "$(field buttons "$out")")|$(has 'Modules' "$(field texts "$out")")"

out=$(view details in-use-procs)
dt=$(field texts "$out")
check "Details: titled, apps on the card by name with pid and memory" "Details|yes|yes" \
  "$(field title "$out")|$(has 'vkcube ¦ 12 MB · pid 4242' "$dt")|$(has 'Apps on the eGPU (2)' "$dt")"
check "Details: the link is plain information" "yes" "$(has 'PCIe 16.0 GT/s × 4 (up to 16.0 GT/s × 16)' "$dt")"
out=$(view details smi-hung)
check "Details: an error's code lives here, under its sentence" "yes|yes" "$(has 'Code ¦ smi_hung' "$(field texts "$out")")|$(has 'Message' "$(field texts "$out")")"
out=$(view details stranger-no-tb)
check "Details: a machine with no Thunderbolt says so" "yes" "$(has 'No Thunderbolt or USB4 port' "$(field texts "$out")")"

# =============================================================================
step "GATE G3 offline: the eject sheet (plan-gui.md §5.2, ui-scope.md §2.5)"
out=$(PNGTAG=-closed view eject in-use-procs EGPU_HARNESS_CLICK="Close 2 apps|Close 2 apps")
check "it runs device eject as it opens, names the apps, and the harmless ones apart; closing them is a destructive verb with its object" "Safe eject|yes|yes|Cancel,Close 2 apps" \
  "$(field title "$out")|$(has 'vkcube and worker are using the eGPU.' "$(field texts "$out")")|$(has 'Also open (harmless) ¦ chromium' "$(field texts "$out")")|$(field buttons "$out")"
check "Close 2 apps asks first (the confirm), then re-runs it with --close; never anything else" '["device","eject"] ["device","eject","--close"]' "$(calls)"
check "…then, the answer (a stale one: the engine no longer says ok with the driver loaded) saying the driver is still loaded: Do not suspend, never Safe to unplug, and Done" "yes|no|*Done" \
  "$(has 'Do not suspend' "$(field after.texts "$out")")|$(has 'Safe to unplug' "$(field after.texts "$out")")|$(field after.buttons "$out")"
out=$(view eject in-use-procs EGPU_HARNESS_CLICK="Close 2 apps")
check "the first Close only asks: the question names the consequence, nothing is closed yet, and the sheet stays" '["device","eject"]|yes|none' \
  "$(calls)|$(has 'Save your work first.' "$(field after.texts "$out")")|$(field after.routes "$out")"
out=$(view eject in-use-procs EGPU_HARNESS_CLICK="Close 2 apps|Cancel")
check "Cancel in the confirm puts the two buttons back, still on the sheet and nothing closed" 'Cancel,Close 2 apps|["device","eject"]|none' \
  "$(field after.buttons "$out")|$(calls)|$(field after.routes "$out")"
out=$(view eject ready)
check "nothing holding it: straight to Safe to unplug" "yes|*Done" "$(has 'Safe to unplug' "$(field texts "$out")")|$(field buttons "$out")"
out=$(view eject ready-hdmi)
check "a monitor still on: the sentence, Try again or Cancel, the code under Details" "yes|Details,Cancel,*Try again" \
  "$(has 'The monitor on the eGPU is still on.' "$(field texts "$out")")|$(field buttons "$out")"
out=$(view eject ready-hdmi EGPU_HARNESS_CLICK="Cancel")
check "Cancel asks the shell for Back" "back" "$(field after.routes "$out")"
# The failed step, answer by answer (lib/device.sh; dev/fixtures/eject-*/device-eject.json are its templates).
out=$(view eject eject-in-use)
check "driver_in_use, names only: the sentence, who still uses it, no session line, Cancel and Try again, no Close" "yes|yes|no|Details,Cancel,*Try again" \
  "$(has 'The driver is still in use, so the eGPU was left connected.' "$(field texts "$out")")|$(has 'Still using it: nvidia-persiste, quickshell and voxtype-osd-gtk.' "$(field texts "$out")")|$(has 'Your session itself' "$(field texts "$out")")|$(field buttons "$out")"
out=$(view eject eject-in-use-session)
check "driver_in_use with session_holds: it says the session itself holds the driver, and logging out lets go" "yes|yes" \
  "$(has 'Still using it: Hyprland, nvidia-persiste, quickshell and voxtype-osd-gtk.' "$(field texts "$out")")|$(has 'Your session itself holds the driver; logging out lets go of it.' "$(field texts "$out")")"
out=$(view eject eject-in-use-closeable EGPU_HARNESS_CLICK="Close chromium|Close chromium")
check "driver_in_use with can_close: Close <app> (the confirm), then --close; Try again is not offered beside it" "Cancel,Close chromium,Details|"'["device","eject"] ["device","eject","--close"]' \
  "$(field buttons "$out")|$(calls)"
out=$(view eject eject-in-use-shared)
check "driver_in_use, shared_driver: the shared-GPU sentence instead of the generic one, shut down; no Try again, no Close, no names" "yes|no|Details|no" \
  "$(has "This computer's own NVIDIA GPU shares the driver, so the eGPU cannot be ejected safely. Shut down before unplugging." "$(field texts "$out")")|$(has 'The driver is still in use' "$(field texts "$out")")|$(field buttons "$out")|$(has 'Still using it' "$(field texts "$out")")"
out=$(view eject eject-in-use-screens EGPU_HARNESS_CLICK="Turn the screens back on")
check "monitors the eject turned off and the engine did not restore: Turn the screens back on runs display enable for each, then says so" "Details,Turn the screens back on,Cancel,*Try again|"'["device","eject"] ["display","enable","Samsung TV"]|yes|no' \
  "$(field buttons "$out")|$(calls)|$(has 'The screens are back on.' "$(field after.texts "$out")")|$(has 'Turn the screens back on' "$(field after.buttons "$out")")"
out=$(view eject eject-modules-held)
check "modules_held with do_not_suspend: the engine's detail, Do not suspend. Log out first., and no Try again" "yes|yes|Details" \
  "$(has 'Do not suspend the computer: log out first.' "$(field texts "$out")")|$(has 'Do not suspend. Log out first.' "$(field texts "$out")")|$(field buttons "$out")"
out=$(view eject eject-unloaded EGPU_HARNESS_CLICK="Connect")
check "remove_failed with driver_unloaded: the unloaded sentence and the engine's detail, Connect is the primary and Try again is not offered; Connect runs device connect and leaves the sheet" "yes|yes|Details,Cancel,*Connect|"'["device","eject"] ["device","connect"]|back' \
  "$(has 'The driver is unloaded. Open the lid or press Connect to bring the eGPU back.' "$(field texts "$out")")|$(has 'the driver was not loaded again' "$(field texts "$out")")|$(field buttons "$out")|$(calls)|$(field after.routes "$out")"
out=$(view eject eject-unloaded-connect-fails EGPU_HARNESS_CLICK="Connect")
check "…and when Connect fails it says why, in its own notice, and stays on the sheet" "yes|none" \
  "$(has 'The driver could not be loaded.' "$(field after.texts "$out")")|$(field after.routes "$out")"
out=$(view eject eject-hung-screens)
check "smi_hung with the screens off: the way back is the lid (a hung driver cannot be asked), no Turn the screens back on" "yes|no" \
  "$(has 'The screens on the eGPU are off. Open the lid or turn the display back on.' "$(field texts "$out")")|$(has 'Turn the screens back on' "$(field buttons "$out")")"
out=$(view eject absent)
check "an engine answer it does not know still says something, never success" "yes" "$(has 'This needs a newer version' "$(field texts "$out")")"

# =============================================================================
echo
[[ -n $PNG ]] && echo "${DIM}PNGs in $PNG${RESET}"
if (( failures )); then echo "${RED}$failures of $checks checks failed${RESET}"; exit 1; fi
echo "${GREEN}all $checks checks passed${RESET}"
echo "${YELLOW}not checked here${RESET}: the live layer-shell popup, the built-in bar handing over the service, the service mounting at shell start (needs the live shell)"
