# shellcheck shell=bash
# tests/apps.sh — the apps module (lib/apps.sh, lib/apps.py) and Steam's own
# window (`steam client`). Sourced by tests/run.sh; `tests/run.sh apps` runs
# only these. Each test builds a scenario whose HOME and XDG_DATA_HOME are in
# the temp dir, with system desktop entries in $AP_SYS (EGPU_APPS_DIRS); a guard
# stops the test if HOME is outside it. Nothing real is read or written.

# ap_new <name>: a fresh scenario; AP_SYS holds the system entries, AP_USER the user's.
ap_new() {
  setup_scenario "apps-$1" "$TESTS/fixtures/steam/machine" || exit 1
  if [[ $(realpath -m -- "$HOME") != "$(realpath -- "$WORK")"/* ]]; then
    bad "apps-$1: HOME is outside the test dir; refusing to run"
    exit 1
  fi
  export PYTHONDONTWRITEBYTECODE=1
  AP_SYS=$HOME/sys-apps
  AP_USER=$HOME/.local/share/applications
  export XDG_DATA_HOME=$HOME/.local/share EGPU_APPS_DIRS=$AP_SYS
  mkdir -p -- "$AP_SYS" "$AP_USER" "$EGPU_RUN"
  : >"$EGPU_FAKE_DIR/pgrep.txt"
}

ap_entry() { # <file> <Name> <Exec> [extra lines…]
  local f=$AP_SYS/$1 name=$2 exec=$3
  shift 3
  { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$name" "$exec"; (( $# )) && printf '%s\n' "$@"; } >"$f"
}

ap() { "$ENGINE" "$@" >"$T/out.json" 2>"$T/err"; AP_RC=$?; }

ap_check() {
  local label=$1
  shift
  if jq -e "$@" "$T/out.json" >/dev/null 2>&1; then ok "$label"; else bad "$label: $(head -c 300 "$T/out.json") $(head -c 200 "$T/err")"; fi
}

ap_error() {
  if (( AP_RC == 1 )) && jq -e --arg c "$2" '.error == $c' "$T/out.json" >/dev/null 2>&1; then ok "$1: refused with $2"
  else bad "$1: expected $2 (exit 1), got exit $AP_RC: $(head -c 300 "$T/out.json")"; fi
}

ap_test_list() {
  echo "${BOLD}apps: list${RESET}"
  ap_new list
  ap_entry zeta.desktop "Zeta Game" "zeta --fs %U" "Categories=Game;" "Icon=zeta"
  ap_entry alpha.desktop "alpha editor" "alpha %F" "Terminal=true"
  ap_entry hidden.desktop "Hidden" "hidden" "NoDisplay=true"
  ap_entry gone.desktop "Gone" "gone" "Hidden=true"
  ap_entry steamgame.desktop "A Steam game" "steam steam://rungameid/440"
  ap_entry steam.desktop "Steam" "/usr/bin/steam %U" "Categories=Game;"
  printf '[Desktop Entry]\nType=Link\nName=Link\nURL=x\n' >"$AP_SYS/link.desktop"
  printf '[Desktop Entry]\nType=Application\nName=My web app\nExec=chromium --app=x\n' >"$AP_USER/webapp.desktop"
  printf 'not a desktop file\n' >"$AP_SYS/readme.txt"
  ap apps list
  ap_check "only real apps, sorted by name without case: alpha editor, Zeta Game" '[.apps[].id] == ["alpha.desktop", "zeta.desktop"]'
  ap_check "name, icon, game flag, terminal flag, state off" \
    '(.apps[1] | .name == "Zeta Game" and .icon == "zeta" and .game == true and .terminal == false and .state == "off") and (.apps[0].terminal == true)'
  ap_check "Steam games, the Steam client, hidden entries and the user'\''s own web apps are not listed" \
    '[.apps[].id] | (index("steamgame.desktop") == null and index("steam.desktop") == null and index("hidden.desktop") == null and index("webapp.desktop") == null)'
  ap_check "on is 0 and run is the wrapper" '.on == 0 and (.run | endswith("/bin/egpu-run"))'
}

ap_test_toggle() {
  echo "${BOLD}apps: turning one on and off${RESET}"
  ap_new toggle
  ap_entry foo.desktop "Foo" "foo --flag %U" "DBusActivatable=true" "" "[Desktop Action new]" "Name=New window" "Exec=foo --new"
  local sys_sum
  sys_sum=$(sha256sum <"$AP_SYS/foo.desktop")
  ap apps set foo.desktop on
  ap_check "on: answers on" '.id == "foo.desktop" and .state == "on"'
  local f=$AP_USER/foo.desktop run
  run=$(jq -r '.run' < <("$ENGINE" apps list))
  if grep -qx "Exec=$run --quiet -- foo --flag %U" "$f"; then ok "the main Exec is wrapped in egpu-run, its arguments kept"; else bad "main Exec: $(grep '^Exec' "$f")"; fi
  if grep -qx "Exec=$run --quiet -- foo --new" "$f"; then ok "an action's Exec is wrapped too"; else bad "action Exec: $(grep '^Exec' "$f")"; fi
  if grep -qx 'X-Omarchy-eGPU=managed' "$f" && grep -qx 'DBusActivatable=false' "$f"; then ok "marked as ours; D-Bus activation off so a launcher cannot skip Exec"; else bad "marker/dbus: $(head -5 "$f")"; fi
  [[ $(sha256sum <"$AP_SYS/foo.desktop") == "$sys_sum" ]] && ok "the system entry is untouched" || bad "the system entry changed"
  ap apps list
  ap_check "list says on, on count 1" '.apps[0].state == "on" and .on == 1'
  ap apps set foo.desktop on
  ap_check "turning on twice does not wrap twice" '.state == "on"'
  [[ $(grep -c -- '--quiet --' "$f") == 2 ]] && ok "still one wrapper per Exec line" || bad "wrapped twice: $(grep '^Exec' "$f")"
  ap apps set foo.desktop off
  ap_check "off: answers off" '.state == "off"'
  [[ ! -e $f ]] && ok "off removes the copy" || bad "copy still there"
  ap apps set foo.desktop off
  ap_check "off when already off is fine" '.state == "off"'
}

ap_test_safety() {
  echo "${BOLD}apps: what is never touched${RESET}"
  ap_new safety
  ap_entry mine.desktop "Mine" "mine"
  ap_entry other.desktop "Other" "other"
  printf '[Desktop Entry]\nType=Application\nName=Mine (my version)\nExec=mine --my-way\n' >"$AP_USER/mine.desktop"
  ap apps list
  ap_check "the user's own override of a system entry is state manual" '(.apps[] | select(.id == "mine.desktop") | .state) == "manual"'
  ap apps set mine.desktop on
  ap_error "turning on over the user's own file" app_manual
  ap apps set mine.desktop off
  ap_error "turning off the user's own file" app_manual
  grep -q -- '--my-way' "$AP_USER/mine.desktop" && ok "the user's file is intact" || bad "the user's file was changed"
  ap apps set ../escape.desktop on
  ap_error "a path is not an id" invalid_value
  ap apps set nothere.desktop on
  ap_error "an app that is not installed" app_not_found
  ap apps set other.desktop maybe
  ap_error "a state that is not on or off" usage
  ap apps set other.desktop on
  ap apps set-all off
  ap_check "set-all off removes only the managed copies" '.removed == ["other.desktop"]'
  [[ -e $AP_USER/mine.desktop && ! -e $AP_USER/other.desktop ]] && ok "the user's own file survived set-all" || bad "set-all touched the wrong files"
  ap_entry odd.desktop "Odd" "odd"
  mkdir -p "$HOME/with space/bin"
  printf '#!/bin/sh\n' >"$HOME/with space/bin/egpu-run"
  chmod +x "$HOME/with space/bin/egpu-run"
  printf '{"apps":{"run_path":"%s"}}\n' "$HOME/with space/bin/egpu-run" >"$EGPU_CONFIG"
  ap apps set odd.desktop on
  grep -q "^Exec=\"$HOME/with space/bin/egpu-run\" --quiet -- odd\$" "$AP_USER/odd.desktop" && ok "a wrapper path with a space is quoted" || bad "quoting: $(grep '^Exec' "$AP_USER/odd.desktop")"
}

ap_test_steam_client() {
  echo "${BOLD}steam client: the window stays off the eGPU${RESET}"
  ap_new client
  export EGPU_STATE=$HOME/state
  mkdir -p "$EGPU_STATE"
  # Health only looks at Steam once it has a root, as on any machine that has run it.
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  export EGPU_STEAM_ROOTS=$HOME/.local/share/Steam
  fx_steam_root real
  ap_entry steam.desktop "Steam" "/usr/bin/steam %U" "" "[Desktop Action Store]" "Name=Store" "Exec=steam steam://store"
  ap steam client status
  ap_check "status before: off, with the option" '.state == "off" and .args == ["-cef-disable-gpu"]'
  ap steam client apply
  ap_check "apply: on, takes effect at the next start" '.state == "on" and .takes_effect != null'
  grep -qx 'Exec=/usr/bin/steam -cef-disable-gpu %U' "$AP_USER/steam.desktop" && ok "the option goes right after the steam command" || bad "Exec: $(grep '^Exec' "$AP_USER/steam.desktop")"
  grep -qx 'Exec=steam -cef-disable-gpu steam://store' "$AP_USER/steam.desktop" && ok "an action's Exec gets it too" || bad "action: $(grep '^Exec' "$AP_USER/steam.desktop")"
  ap apps list
  ap_check "the Steam client is not in the apps list" '[.apps[].id] | index("steam.desktop") == null'
  ap apps set-all off
  [[ -e $AP_USER/steam.desktop ]] && ok "apps set-all off leaves the Steam launcher alone" || bad "set-all removed the Steam launcher"
  "$ENGINE" health --json >"$T/out.json" 2>/dev/null
  ap_check "health: steam.client is ok" '[.[] | select(.id == "steam.client")][0].level == "ok"'
  ap steam client restore
  ap_check "restore: off" '.state == "off"'
  [[ ! -e $AP_USER/steam.desktop ]] && ok "restore removes the copy" || bad "copy still there"
  "$ENGINE" health --json >"$T/out.json" 2>/dev/null
  ap_check "health: steam.client warns with a fix while it is off" \
    '[.[] | select(.id == "steam.client")][0] | .level == "warn" and .fix.kind == "user" and (.fix.label | test("steam client apply"))'
  ap steam client apply --once
  ap_check "--once after a restore does nothing: the user's choice stands" '.skipped == true'
  rm -f "$EGPU_STATE/steam-client.json"
  ap steam client apply --once
  ap_check "--once on a fresh machine applies" '.state == "on"'
  ap steam client apply --once
  ap_check "--once the second time does nothing" '.skipped == true'
  rm -f "$AP_USER/steam.desktop" "$AP_SYS/steam.desktop" "$EGPU_STATE/steam-client.json"
  ap steam client apply --once
  ap_check "--once with no Steam is quiet and leaves no state" '.skipped == true and (.reason == "steam_not_found")'
  [[ ! -e $EGPU_STATE/steam-client.json ]] && ok "no state file, so it tries again at the next start" || bad "state file written without Steam"
  printf '[Desktop Entry]\nType=Application\nName=Steam (mine)\nExec=steam -mine\n' >"$AP_USER/steam.desktop"
  ap_entry steam.desktop "Steam" "/usr/bin/steam %U"
  ap steam client apply
  ap_error "the user's own Steam launcher" app_manual
  grep -qx 'Exec=steam -mine' "$AP_USER/steam.desktop" && ok "it is left as it was" || bad "the user's launcher changed"
}

test_apps() {
  (ap_test_list)
  (ap_test_toggle)
  (ap_test_safety)
  (ap_test_steam_client)
}
