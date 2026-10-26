#!/bin/bash

# Gate G8, the part that needs no hardware, no live shell and no live notch
# (plan-gui.md §10 G8):
#
#   ./dev/g8-offscreen.sh            every check
#   ./dev/g8-offscreen.sh --png DIR  also keep a PNG of the Glance and the
#                                    compact view for every fixture
#
# Runs the REAL NotchIntegration.qml, NotchPanel.qml, Panel.qml and
# views/{Glance,CompactView,StatusView}.qml in a throwaway Quickshell
# (dev/qml-harness/notch.qml) on the offscreen platform, with a stand-in for
# the notch's surfaceHost that records what the plugin asks of it. Then holds
# what the plugin declared against the notch's OWN rules, read from its
# checkout ($NOTCH_REPO, default ~/Work/omarchy-notch; skipped when absent):
# the integration scanner (bin/notch-integrations, read-only) on a copy of
# this plugin, platform.js's acceptance and claim checks, and contract.js's
# descriptor check, all under node.
#
# Nothing touches the live session: no WAYLAND_DISPLAY, a temp config root, a
# temp $EGPU_RUN, and the notch's checkout is only read.
#
# Not covered here (needs the live shell with the notch as its bar):
#   - `omarchy-shell notch integration kalinewb.egpu` answering accepted
#   - a click under the notch opening `main` on the clicked screen
#   - real key events (Escape is driven through the same back() the key calls)
#   - the notch drawing claims (`omarchy-shell notch activities`)
#   - colours with the notch's mono shader off, on a real theme

set -uo pipefail

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; DIM=$'\e[2m'; RESET=$'\e[0m'
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$REPO/dev/fixtures"
NOTCH_REPO=${NOTCH_REPO:-$HOME/Work/omarchy-notch}

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

command -v quickshell >/dev/null || { echo "g8-offscreen: quickshell is not installed" >&2; exit 1; }
SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
: "${SHELL_PATH:=${OMARCHY_PATH:-/usr/share/omarchy}}"
[[ -d $SHELL_PATH/shell/Ui ]] || { echo "g8-offscreen: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }

# The config root, as dev/g1-offscreen.sh builds it. Symlinks live only here.
root=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-g8.XXXXXX")
trap 'pkill -f -- "$root/" 2>/dev/null; rm -rf "$root"' EXIT
mkdir -p "$root/qs/Ui" "$root/run" "$root/logs"
ln -s "$SHELL_PATH/shell/Commons" "$root/qs/Commons"
for f in "$SHELL_PATH"/shell/Ui/*; do
  case ${f##*/} in KeyboardPanel.qml | qmldir) ;; *) ln -s "$f" "$root/qs/Ui/${f##*/}" ;; esac
done
cp "$SHELL_PATH/shell/Ui/qmldir" "$root/qs/Ui/qmldir"
cp "$REPO/dev/qml-harness/KeyboardPanel.qml" "$root/qs/Ui/KeyboardPanel.qml"
ln -s "$REPO" "$root/qs/egpu"
cp "$REPO/dev/qml-harness/notch.qml" "$root/qs/shell.qml"

RUN="$root/run"
LAST_LOG="$root/logs/last.log"

# put <fixture> <seq> [jq filter]: status.json as the watcher writes it, now.
put() {
  jq --argjson at "$(date +%s%3N)" --argjson seq "$2" ".written_at = \$at | .seq = \$seq | ${3:-.}" \
    "$FIX/$1/status.json" >"$RUN/.s" && mv "$RUN/.s" "$RUN/status.json"
}
# ev <seq> <type>: one recent_events record.
ev() { printf '{"seq":%d,"type":"%s","at":%d}' "$1" "$2" "$(date +%s%3N)"; }

# harness <case> [env…]: prints the HARNESS lines as key=value; the whole log
# is kept for the JS-error check.
harness() {
  local c=$1
  shift
  env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= \
    EGPU_RUN="$RUN" OMARCHY_EGPU_DEV_BIN="$REPO/dev/bin" EGPU_HARNESS_CASE="$c" "$@" \
    timeout 60 quickshell -p "$root/qs" >"$LAST_LOG" 2>&1
  sed -n 's/^.*HARNESS \([a-zA-Z0-9._-]*\) \(.*\)$/\1=\2/p' "$LAST_LOG"
}
field() { sed -n "s/^$1=//p" <<<"$2" | head -1; }
# JavaScript errors anywhere in the last run's log (ours, not Quickshell's).
jserrors() {
  grep -E 'TypeError|ReferenceError|is not a function|Cannot read property|Unable to assign' "$LAST_LOG" |
    grep -F -- 'egpu' | head -3 | sed 's/^/      /'
}
noerrors() { # noerrors <description>
  local e
  e=$(jserrors)
  check "$1: no JavaScript errors from the plugin" "" "$e"
}

echo "G8 — notch integration, offscreen"
echo "${DIM}shell: $SHELL_PATH/shell   plugin: $REPO   notch: $NOTCH_REPO${RESET}"

ALLVERBS="device connect,device eject,device rescan,display enable,display disable,display off"

# =============================================================================
step "notice rules (plan-gui.md §7.5; common/Notices.js under node)"
if command -v node >/dev/null 2>&1; then
  js=$(cat <<EOF
const vm = require("vm"), fs = require("fs")
function load(path) {
  const c = { Math, JSON, String, Number, Array, Object }
  vm.createContext(c)
  vm.runInContext(fs.readFileSync(path, "utf8").replace(/^\.pragma library/m, ""), c)
  return c
}
const N = load("$REPO/common/Notices.js")
const out = []
function t(r, can) { const n = N.describe(r, null, can, "G"); return n ? n.title + (n.warning ? " [warning]" : "") : "none" }
out.push("plugged=" + t({ seq: 2, event: "plugged" }, false))
out.push("pluggedCanConnect=" + t({ seq: 2, event: "plugged" }, true))
out.push("eject_ready=" + t({ seq: 3, event: "eject_ready" }, false))
out.push("yanked=" + t({ seq: 4, event: "yanked" }, false))
const quiet = ["authorized", "ready", "unplugged", "monitor_added", "eject_started", "dev_fixture", ""].map(e => t({ seq: 9, event: e }, true))
out.push("quiet=" + quiet.join(","))
const c = N.claimFor(N.describe({ seq: 2, event: "plugged" }, null, false, "G"))
out.push("claimKeys=" + Object.keys(c).sort().join(","))
out.push("claim=" + [c.key, c.priority, c.ttlMs, c.view, c.panelRoute].join("|"))
console.log(out.join("\n"))
EOF
)
  out=$(node -e "$js" 2>&1)
  check "plug-in: 'eGPU connected' while the engine has no connect verb" "eGPU connected" "$(field plugged "$out")"
  check "plug-in: 'load driver?' once it has (§7.5)" "eGPU connected — load driver?" "$(field pluggedCanConnect "$out")"
  check "safe to unplug" "Safe to unplug the eGPU" "$(field eject_ready "$out")"
  check "a yank is a warning notice" "eGPU unplugged without ejecting [warning]" "$(field yanked "$out")"
  check "no other event makes a notice" "none,none,none,none,none,none,none" "$(field quiet "$out")"
  check "the claim carries the notch's fields only (no names, no detail)" "glyph,key,panelRoute,priority,title,ttlMs,view" "$(field claimKeys "$out")"
  check "key kalinewb.egpu.notice, transient, 8 s, view egpu, opens main" \
    "kalinewb.egpu.notice|transient|8000|egpu|main" "$(field claim "$out")"
else
  echo "  ${DIM}skip  node is not installed${RESET}"
fi

# =============================================================================
step "GATE: Glance and CompactView render every summary.state (§7.4, §7.6)"
docs="$root/docs.json"
for fx in "$FIX"/*/; do fx=${fx%/}; fx=${fx##*/}; jq --arg n "$fx" '{($n): .}' "$FIX/$fx/status.json"; done | jq -s 'add' >"$docs"
out=$(harness states EGPU_HARNESS_DOCS="$docs" ${PNG:+EGPU_HARNESS_PNG_DIR="$PNG"})
outv=$(harness states EGPU_HARNESS_DOCS="$docs" OMARCHY_EGPU_DEV_VERBS="$ALLVERBS")
noerrors "states"
# fixture | state | word | glyph role | badge | pulse | monitor | headline (the
# Overview's, common/Overview.js) | buttons with every verb | buttons with only
# the verbs the engine has built (common/Engine.qml). No health rows here: what
# the compact view shows before its first read (dev/g1-offscreen.sh has both).
while IFS='|' read -r fx state word role badge pulse monitor headline buttons built; do
  [[ -n $fx ]] || continue
  check "$fx → glance $state: '$word', $role glyph, badge $badge, pulse $pulse, monitor $monitor" \
    "$state|$word|$role|$badge|$pulse|$monitor" "$(field "g.$fx" "$out")"
  check "$fx: glance drawn; pulse $( [[ $pulse == true ]] && echo runs || echo idle ) while active, stopped when not" \
    "true|$pulse|true" "$(field "g.$fx.drawn" "$out")|$(field "g.$fx.pulsing" "$out")|$(field "g.$fx.pulseIdle" "$out")"
  check "$fx: compact says the Overview's headline, fits 320 px" "$headline|yes|true" \
    "$(field "c.$fx.headline" "$out")|$(grep -qF -- "$headline" <<<"$(field "c.$fx.text" "$out")" && echo yes || echo no)|$(field "c.$fx.size" "$out")"
  check "$fx: only the host's colours, only radiusFor() radii" "host-only|radiusFor" \
    "$(field "c.$fx.colours" "$out")|$(field "c.$fx.radii" "$out")"
  check "$fx: only the built verbs' buttons: $built" "$built" "$(field "c.$fx.buttons" "$out")"
  check "$fx: with the verbs: $buttons" "$buttons" "$(field "c.$fx.buttons" "$outv")"
  check "$fx: …still host colours and radii" "host-only|radiusFor" \
    "$(field "c.$fx.colours" "$outv")|$(field "c.$fx.radii" "$outv")"
  check "$fx: nothing names Setup without a way to it" "none" "$(field "c.$fx.orphans" "$out")"
done <<'TABLE'
absent|absent|none|secondary|none|false|false|Plug in your eGPU|Open full panel|Open full panel
stranger-no-tb|absent|none|secondary|none|false|false|No Thunderbolt or USB4 port|Open Setup,Open full panel|Open Setup,Open full panel
plugged-unauthorized|connecting|connecting|foreground|none|true|false|Getting your eGPU ready…|Connect,Open full panel|Connect,Open full panel
authorized-no-pci|connecting|connecting|foreground|none|true|false|Enclosure found, no graphics card|Show me,Open full panel|Show me,Open full panel
bound-nvidia|connecting|connecting|foreground|none|true|false|Getting your eGPU ready…|Connect,Open full panel|Connect,Open full panel
ready|ready|ready|accent|none|false|false|eGPU ready|Safe eject,Open full panel|Safe eject,Open full panel
ready-hdmi|in_use|in use|accent|accent|false|true|eGPU in use by a screen|Safe eject…,Turn off now,Open full panel|Safe eject…,Open full panel
in-use-procs|in_use|in use|accent|accent|false|false|eGPU in use by vkcube and worker|Safe eject…,Open full panel|Safe eject…,Open full panel
ejecting|ejecting|ejecting|foreground|none|true|false|Ejecting…|Ejecting…(off),Open full panel|Ejecting…(off),Open full panel
ejected-clean|safe_to_unplug|unplug|good|none|false|false|Safe to unplug|Done,Open full panel|Done,Open full panel
ejected-held|attention|log out|good|warn|false|false|Safe to unplug|Done,Open full panel|Done,Open full panel
this-machine|attention|log out|accent|warn|false|false|Log out to use the HDMI monitor|Safe eject,Open full panel|Safe eject,Open full panel
amd-stub|attention|check setup|foreground|warn|false|false|This graphics card is not supported yet|Open Setup,Open full panel|Open Setup,Open full panel
bolt-down|attention|check setup|accent|warn|false|false|Setup has found a problem|Fix,Safe eject,Open full panel|Fix,Safe eject,Open full panel
smi-hung|error|error|foreground|bad|false|false|The driver is not answering. Do not unplug: save your work, then log out or reboot.|Open full panel|Open full panel
auth-error|error|error|foreground|bad|false|false|Thunderbolt could not allow your enclosure.|Try again,Open Setup,Open full panel|Try again,Open Setup,Open full panel
TABLE

has() { grep -qF -- "$2" <<<"$(field "c.$1.text" "$3")" && echo yes || echo no; }
check "HDMI quick toggle: the first eGPU monitor, with Turn off now" "yes|yes" \
  "$(has ready-hdmi 'HDMI · HDMI-A-2' "$outv")|$(has ready-hdmi 'Turn off now' "$outv")"
check "…and not without the display verbs" "no" "$(has ready-hdmi 'HDMI · HDMI-A-2' "$out")"
check "the card, its temperature and how busy it is in one line while it answers" "yes|no" \
  "$(has ready 'RTX 4070 SUPER · 29 °C · idle' "$out")|$(has absent '°C' "$out")"
check "attention: log out for the HDMI monitor" "yes" \
  "$(has this-machine 'The HDMI monitor needs a new session to appear. Offloading apps works now.' "$out")"
check "attention: held modules" "yes" "$(has ejected-held 'Log out before plugging the eGPU in again.' "$out")"
check "attention: smi_hung says do not unplug" "yes" \
  "$(has smi-hung 'The driver is not answering. Do not unplug: save your work, then log out or reboot.' "$out")"
check "attention: an unsupported backend" "yes" "$(has amd-stub 'This kind of GPU is detected but not supported yet.' "$out")"
check "attention: a Setup problem is the headline, and the one button is Fix" "yes|Fix" \
  "$(has bolt-down 'Setup has found a problem' "$out")|$(field c.bolt-down.buttons "$out" | cut -d, -f1)"
check "the HDMI monitor mark in the glance while HDMI is on" "yes" \
  "$(grep -qF -- "$(printf '\U000F0379')" <<<"$(field c.ready-hdmi.text "$out")" && echo yes || echo no)"

# =============================================================================
step "GATE: available — declines on a machine with no Thunderbolt (§7.2)"
avail() { # avail <fixture> [jq filter] -> availableAtLoad|available|reason
  put "$1" 1 "${2:-.}"
  local o
  o=$(harness integration EGPU_HARNESS_WAIT_MS=700)
  echo "$(field availableAtLoad "$o")|$(field available "$o")|$(field reason "$o")"
}
check "stranger-no-tb: declined at load, with the plugin's reason" \
  "false|false|This machine has no Thunderbolt or USB4 port." "$(avail stranger-no-tb)"
noerrors "no-Thunderbolt integration"
check "bolt-down (Thunderbolt present, boltd not answering): available" "true|true|none" "$(avail bolt-down)"
check "absent on a Thunderbolt machine: available" "true|true|none" "$(avail absent)"
check "no Thunderbolt but an eGPU on the PCI bus (OCuLink): available" "true|true|none" \
  "$(avail stranger-no-tb '.pci.present = true')"
check "an older engine with no bolt.domain: available (never declines on a guess)" "true|true|none" \
  "$(avail stranger-no-tb 'del(.bolt.domain)')"
rm -f "$RUN/status.json"
o=$(harness integration EGPU_HARNESS_WAIT_MS=1500 OMARCHY_EGPU_DEV_FIXTURE=ready)
check "no status file yet: available, then the one-shot status" "true|true|ready" \
  "$(field availableAtLoad "$o")|$(field available "$o")|$(field state "$o")"
check "the integration has a panel and the notice row 'egpu'" "true|egpu" "$(field hasPanel "$o")|$(field activityViews "$o")"

# =============================================================================
step "GATE: plug-in and safe-to-unplug claims (§7.5), from status.json"
# notices <claim answer> [env…]: absent, then a plug-in batch, then an eject.
notices() {
  local answer=$1
  shift
  put absent 1
  ( sleep 1.6
    put plugged-unauthorized 4 ".recent_events = [$(ev 2 plugged),$(ev 3 authorized)] | .last_event = .recent_events[-1]"
    sleep 1.6
    put ejected-clean 6 ".recent_events = [$(ev 2 plugged),$(ev 3 authorized),$(ev 5 eject_ready)] | .last_event = .recent_events[-1]" ) &
  harness integration EGPU_HARNESS_WAIT_MS=4600 EGPU_HARNESS_CLAIM_ANSWER="$answer" "$@"
  wait
}
o=$(notices shown)
noerrors "notices"
check "a plug-in hidden behind 'authorized' in one recompute still makes its notice, then safe-to-unplug" \
  "eGPU connected — load driver? | Safe to unplug the eGPU" "$(field claimTitles "$o")"
check "both claimed under kalinewb.egpu.notice, transient, 8 s, view egpu, panelRoute main" \
  "kalinewb.egpu.notice|transient|8000|egpu|main" \
  "$(field claims "$o" | jq -r '[.[] | "\(.key)|\(.priority)|\(.ttlMs)|\(.view)|\(.panelRoute)"] | unique | join(";")')"
check "the notice is live: the glance row shows its title" "Safe to unplug the eGPU|glyph Safe to unplug the eGPU" \
  "$(field noticeTitle "$o")|$(field noticeRow "$o")"
check "the notch's answer is kept (shown)" "shown" "$(field lastAnswer "$o")"
CLAIMS_SHOWN=$(field claims "$o")
o=$(notices queued)
check "…or queued" "queued" "$(field lastAnswer "$o")"
o=$(notices declined:hidden)
check "…or declined (bar hidden): kept, nothing breaks" "declined:hidden" "$(field lastAnswer "$o")"
o=$(notices shown OMARCHY_EGPU_DEV_VERBS="device connect")
check "with a connect verb the plug-in notice asks 'load driver?'" "eGPU connected — load driver?" \
  "$(field claimTitles "$o" | sed 's/ | .*//')"
o=$(notices shown EGPU_HARNESS_NO_HOST=1)
check "no notch: no claims, the notice still lives for the bar, answer no-host" "no-host|Safe to unplug the eGPU" \
  "$(field lastAnswer "$o")|$(field noticeTitle "$o")"
noerrors "no-notch integration"

# A yank: monitor_removed, yanked, unplugged in one recompute.
put ready-hdmi 1
( sleep 1.6; put absent 5 ".recent_events = [$(ev 2 monitor_removed),$(ev 3 yanked),$(ev 4 unplugged)] | .last_event = .recent_events[-1]" ) &
o=$(harness integration EGPU_HARNESS_WAIT_MS=3200); wait
check "a yank reaches the notch as a warning even though 'unplugged' came last" "eGPU unplugged without ejecting" "$(field claimTitles "$o")"
put ready-hdmi 1
( sleep 1.6; put absent 5 ".last_event = $(ev 4 unplugged) | del(.recent_events)" ) &
o=$(harness integration EGPU_HARNESS_WAIT_MS=3200); wait
check "(an older engine with last_event only loses it: why recent_events exists)" "none" "$(field claimTitles "$o")"
put plugged-unauthorized 4 ".recent_events = [$(ev 2 plugged),$(ev 3 authorized)]"
o=$(harness integration EGPU_HARNESS_WAIT_MS=1500)
check "events already in the first document read are not announced" "none" "$(field claimTitles "$o")"

# =============================================================================
step "GATE: the notch panel: routes, Back and Escape (§7.6, §7.7)"
put ready 1
o=$(harness stack ${PNG:+EGPU_HARNESS_PNG_DIR="$PNG"})
noerrors "stack"
check "open(main) shows the compact view, active, background is the host's colour (not painted)" "main|true|#000000" "$(field open.main "$o")"
check "the panel insets its content by the one padding token, 16 px on every side (the notch adds none)" "16,16|16" "$(field inset "$o")"
check "…the compact view's content: headline, facts, the one button, Open full panel" \
  "glyph ¦ eGPU ready ¦ RTX 4070 SUPER · 29 °C · idle ¦ Safe eject ¦ Open full panel" "$(field main.texts "$o")"
check "no Back at the root" "false" "$(field main.back "$o")"
check "Open full panel pushes the Overview" "main>overview" "$(field toFull "$o")"
check "full: the tabs and ‹ Back, then the shared Overview, the state said once" "yes|yes|no" \
  "$(grep -qF 'Overview ¦ Setup ¦ ‹ Back ¦ glyph ¦ eGPU ready ¦ RTX 4070 SUPER · 29 °C · idle ¦ Safe eject' <<<"$(field full.texts "$o")" && echo yes || echo no)|$(grep -qF 'Details ›' <<<"$(field full.texts "$o")" && echo yes || echo no)|$(grep -qF 'TBGAA' <<<"$(field full.texts "$o")" && echo yes || echo no)"
check "‹ Back keeps the inset from the right edge, and sits below the top inset" "16|yes" \
  "$(field backGap "$o" | cut -d, -f1)|$( (( $(field backGap "$o" | cut -d, -f2) >= 16 )) && echo yes || echo no)"
check "full: only the host's colours, only radiusFor() radii" "host-only|radiusFor" "$(field full.colours "$o")|$(field full.radii "$o")"
check "a Fix opens Setup on its row, pushed (Back returns)" "main>overview>setup|system.helper" "$(field toSetup "$o")"
check "Details ›: the Details page, pushed, titled" "main>overview>details|Details" "$(field toDetails "$o")"
check "a tab picked in the header replaces the tab on screen" "main>setup" "$(field pickTab "$o")"
check "an unbuilt route (games) is refused, not shown blank" "main>overview" "$(field unbuiltGames "$o")"
check "the eject sheet is built and pushed over the Overview" "main>overview>eject|Safe eject" "$(field builtEject "$o")"
check "Escape: a view's own dialog → eject → overview → main → closed" \
  "view:main>overview>eject route:main>overview route:main close:main|1" "$(field escape "$o")|$(field closes "$o")"
check "opened straight at full, Escape still goes overview → main → closed" "main>overview route:main close:main" "$(field escapeFromFull "$o")"
check "the notch opening an unbuilt route lands on main" "main" "$(field openGames "$o")"
check "the notch rebinding route while open moves the stack" "main>overview" "$(field routeRebind "$o")"
check "close() is a real close; reopening starts at main, active" "false|main|true" "$(field closed.active "$o")|$(field reopen "$o")"
check "sized within maxWidth/maxHeight, takes focus" "true|true|true" "$(field size "$o")|$(field focus "$o")"
check "NotchPanel imports no view file from outside views/" "" \
  "$(grep -E '^import "' "$REPO/NotchPanel.qml" | grep -vE '^import "(views|common/Palette\.js)"' )"

# =============================================================================
step "GATE: the bar widget under a notch, and with none (§7.2, §7.3, §7.8)"
press() { # press <open answer> [env…] -> press result|own popup|opens
  put ready 1
  local o
  o=$(harness widget EGPU_HARNESS_WAIT_MS=1200 EGPU_HARNESS_OPEN_ANSWER="$1" "${@:2}")
  echo "$(field press1 "$o")|$(field opens "$o")"
}
check "the notch opens it: main, on the clicked screen; no own popup" "opened|own-closed|main@HDMI-A-1" "$(press opened)"
check "the click closed the notch's panel: no own popup either" "closed|own-closed|main@HDMI-A-1" "$(press closed)"
check "bar hidden: own popup" "own:declined:hidden|own-open|main@HDMI-A-1" "$(press declined:hidden)"
check "integration switched off: own popup" "own:declined:not-accepted|own-open|main@HDMI-A-1" "$(press declined:not-accepted)"
check "no notch at all (omarchy.bar): own popup, nothing asked" "own:no-host|own-open|none" "$(press opened EGPU_HARNESS_NO_HOST=1)"
noerrors "widget without a notch"

descr() { # descr <fixture> [jq] [after-fixture jq…]: the descriptor at the end
  put "$1" 1 "${2:-.}"
  [[ -n ${3:-} ]] && ( sleep 1.4; put "$3" 4 "$4" ) &
  local o
  o=$(harness widget EGPU_HARNESS_WAIT_MS=2600)
  wait
  echo "$o"
}
o=$(descr ready)
D_READY=$(field descriptor "$o")
check "descriptor while ready: closedView widget, expandedView a Component, persistent-low" \
  '{"closedView":"widget","expandedView":"component","priority":"persistent-low","groupable":true,"hideable":true}' "$D_READY"
check "…its expandedView is the compact view" "glyph ¦ eGPU ready" "$(field expandedView "$o")"
check "in use: persistent" "persistent" "$(field descriptor "$(descr in-use-procs)" | jq -r .priority)"
check "attention: persistent" "persistent" "$(field descriptor "$(descr this-machine)" | jq -r .priority)"
o=$(descr absent . plugged-unauthorized ".recent_events = [$(ev 2 plugged)] | .last_event = .recent_events[-1]")
D_NOTICE=$(field descriptor "$o")
check "a live notice: transient, not groupable" "transient|false|true" \
  "$(jq -r '"\(.priority)|\(.groupable)"' <<<"$D_NOTICE")|$(field noticeLive "$o")"

# =============================================================================
step "against the notch's own rules ($NOTCH_REPO, read-only)"
if [[ -x $NOTCH_REPO/bin/notch-integrations && -f $NOTCH_REPO/platform.js ]] && command -v node >/dev/null; then
  # A copy of the plugin as it would be installed: tracked files, no symlink.
  mkdir -p "$root/plugins/kalinewb.egpu"
  (cd "$REPO" && git ls-files --cached --others --exclude-standard | tar -cf - -T -) | tar -xf - -C "$root/plugins/kalinewb.egpu"
  scan=$("$NOTCH_REPO/bin/notch-integrations" scan "$root/plugins")
  check "the notch's scanner finds the integration, contract 1, with no problems" "kalinewb.egpu|NotchIntegration.qml|1|" \
    "$(jq -r '.[] | select(.id == "kalinewb.egpu") | "\(.id)|\(.entry)|\(.contract)|\(.problems | join(","))"' <<<"$scan")"
  js=$(cat <<EOF
const vm = require("vm"), fs = require("fs")
function load(path) {
  const c = { console, Math, JSON, Date, Array, Object, String, Number }
  vm.createContext(c)
  vm.runInContext(fs.readFileSync(path, "utf8").replace(/^\.pragma library/m, ""), c)
  return c
}
const P = load("$NOTCH_REPO/platform.js"), C = load("$NOTCH_REPO/contract.js"), A = load("$NOTCH_REPO/activities.js")
const scan = JSON.parse(process.argv[1]).filter(s => s.id === "kalinewb.egpu")[0]
const out = []
let v = P.acceptance(scan, true, false, "ready", true); out.push("accepted=" + v.accepted + "|" + v.reason)
v = P.acceptance(scan, true, false, "ready", false); out.push("unavailable=" + v.accepted + "|" + v.reason + "|" + P.reasonText(v.reason, v.detail))
v = P.acceptance(scan, true, true, "ready", true); out.push("userOff=" + v.accepted + "|" + v.reason)
function comp(d) { d = JSON.parse(d); for (const k in d) if (d[k] === "component") d[k] = { createObject() {} }; return d }
for (const [name, raw] of [["ready", process.argv[2]], ["notice", process.argv[3]]]) {
  const w = C.widget("kalinewb.egpu", "eGPU", comp(raw), 32)
  out.push("descriptor." + name + "=" + w.declared + "|" + w.invalid.join(",") + "|" + w.priority + "|" + C.isComponent(w.expandedView))
}
const claims = JSON.parse(process.argv[4])
const checked = claims.map(c => P.validClaim("kalinewb.egpu", c, false))
out.push("claims=" + checked.map(r => r.ok ? r.claim.key + "|" + r.claim.priority + "|" + r.claim.ttlMs : "bad:" + r.reason).join(";"))
let st = A.create(), r = A.claim(st, checked[0].claim, 1000)
out.push("queue=" + r.result)
console.log(out.join("\n"))
EOF
)
  out=$(node -e "$js" "$scan" "$D_READY" "$D_NOTICE" "$CLAIMS_SHOWN" 2>&1)
  check "platform.js accepts it when enabled and available" "true|" "$(field accepted "$out")"
  check "…declines it, in the notch's words, when available is false" "false|unavailable|Not available right now" "$(field unavailable "$out")"
  check "…and when the user switches it off" "false|user-off" "$(field userOff "$out")"
  check "contract.js takes the descriptor with no invalid field (ready)" "true||persistent-low|true" "$(field descriptor.ready "$out")"
  check "…and with a live notice" "true||transient|true" "$(field descriptor.notice "$out")"
  check "platform.js accepts both claims as sent" \
    "kalinewb.egpu.notice|transient|8000;kalinewb.egpu.notice|transient|8000" "$(field claims "$out")"
  check "an empty queue shows the plug-in claim at once" "shown" "$(field queue "$out")"

  # §7.1 re-checked against the notch's head (gate G8 e). These pin today's
  # behaviour: when one fails, the notch has changed and the plan's one-line
  # switches apply (closedView → glanceComponent; stop suppressing nothing).
  check "the notch draws activities at rest now (Bar.qml activitiesRendered: true)" "true" \
    "$(sed -nE 's/^ *readonly property bool activitiesRendered: (true|false).*/\1/p' "$NOTCH_REPO/Bar.qml" | head -1)"
  # Bar.qml never names closedView, and every expanded-view host it has is
  # bound to one of its own "notch.*" descriptors or the integration's panel.
  check "the notch still never draws a widget's declared closedView/expandedView (closedView stays \"widget\")" "0|0" \
    "$(grep -c 'closedView' "$NOTCH_REPO/Bar.qml")|$(awk '/ExpandedHost \{/ { f = 1 } f && /plugin:/ { print; f = 0 }' "$NOTCH_REPO/Bar.qml" | grep -vcE 'byId\["notch\.|id: "notch\.')"
  check "the notch reads activityViews only to list their names (its row draws glyph + title)" "0" \
    "$(grep -rn 'activityViews' --include='*.qml' "$NOTCH_REPO" | grep -v '/dev/' | grep -vc 'Object.keys(item.activityViews)')"
else
  echo "  ${YELLOW}skip${RESET}  no notch checkout at $NOTCH_REPO (or no node): its rules were not applied"
fi

# =============================================================================
echo
[[ -n $PNG ]] && echo "${DIM}PNGs in $PNG${RESET}"
if (( failures )); then echo "${RED}$failures of $checks checks failed${RESET}"; exit 1; fi
echo "${GREEN}all $checks checks passed${RESET}"
echo "${YELLOW}not checked here${RESET}: the live notch accepting the integration, a real click and real keys under it, claims drawn on screen, the mono-shader-off colour check, and G1–G7 under omarchy.bar (dev/g1-offscreen.sh is the offline part of that)"
