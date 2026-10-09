# shellcheck shell=bash
# tests/steam.sh — gate E6a/E6b of plan-engine.md §12: the Steam module.
# Sourced by tests/run.sh; `tests/run.sh steam` runs only these.
#
# Every test builds a fresh scenario (fixtures/steam/machine: a healthy laptop,
# no eGPU) and copies Steam roots from fixtures/steam/ under the scenario's
# $HOME. EGPU_STEAM_ROOTS and $HOME both point into the temp dir, and a guard
# stops the test if they do not: the real ~/.local/share/Steam is never read
# or written. Steam, Flatpak and uwsm-app are fakes (tests/fakes/bin).
#
#   fixtures/steam/real      sanitised copies of the user's three accounts
#                            (dev/steam-sanitise.py) plus synthetic manifests
#   fixtures/steam/shapes    one app per §8.3 row and every quirk of §13
#   fixtures/steam/library2  a second library with a duplicate manifest
#   fixtures/steam/corrupt   planted corruption, one defect per file

ST_ENV="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only"
ST_RUN="OMARCHY_EGPU=1 $ST_ENV"

# st_new <name>: a fresh scenario in the current (sub)shell, with the native
# root's path in ST_ROOT (not yet populated).
st_new() {
  setup_scenario "steam-$1" "$TESTS/fixtures/steam/machine" || exit 1
  local real
  real=$(realpath -m -- "$HOME")
  if [[ $real != "$(realpath -- "$WORK")"/* ]]; then
    bad "steam-$1: HOME is outside the test dir; refusing to run"
    exit 1
  fi
  # shellcheck source=tests/lib.sh
  source "$TESTS/lib.sh"
  export PYTHONDONTWRITEBYTECODE=1
  ST_ROOT="$HOME/.local/share/Steam"
  export EGPU_STEAM_ROOTS=$ST_ROOT
  mkdir -p -- "$EGPU_RUN"
  : >"$EGPU_FAKE_DIR/pgrep.txt"
  st_phase absent
}

# st_phase <phase>: what `status` says, as a watcher's status.json. Dated an
# hour ahead so it stays fresh for the whole test.
st_phase() {
  printf '{"phase":"%s","written_at":%s}\n' "$1" "$(( $(date +%s%3N) + 3600000 ))" >"$EGPU_RUN/status.json"
}

st_cfg() { printf '%s\n' "$ST_ROOT/userdata/$1/config/localconfig.vdf"; }
st_nbackups() { find "$EGPU_STATE/backups/steam/$1" -name 'localconfig-*.vdf' 2>/dev/null | wc -l; }
st_tmp_left() { compgen -G "$(dirname -- "$(st_cfg "$1")")/.localconfig.vdf.omarchy-egpu.*" >/dev/null; }

# st <args>: run `omarchy-egpu steam <args>`; output in $T/out.json, exit in ST_RC.
st() {
  "$ENGINE" steam "$@" >"$T/out.json" 2>"$T/err"
  ST_RC=$?
}

# st_check <label> [jq options] <jq expression over the last output>
st_check() {
  local label=$1
  shift
  if jq -e "$@" "$T/out.json" >/dev/null 2>&1; then ok "$label"; else bad "$label: $(head -c 300 "$T/out.json") $(head -c 200 "$T/err")"; fi
}

# st_error <label> <code>: the last command was refused with this code.
st_error() {
  if (( ST_RC == 1 )) && jq -e --arg c "$2" '.error == $c' "$T/out.json" >/dev/null 2>&1; then
    ok "$1: refused with $2"
  else
    bad "$1: expected $2 (exit 1), got exit $ST_RC: $(head -c 300 "$T/out.json")"
  fi
}

st_same() {
  if cmp -s -- "$2" "$3"; then ok "$1"; else bad "$1: files differ"; fi
}

# ---------------------------------------------------------------- E6a

st_test_discovery() {
  echo "${BOLD}steam: discovery${RESET}"
  st_new discovery
  unset EGPU_STEAM_ROOTS
  fx_steam_root real
  mkdir -p "$HOME/.steam" && ln -s "$ST_ROOT" "$HOME/.steam/steam" && ln -s "$ST_ROOT" "$HOME/.steam/root"
  st roots
  st_check "roots: ~/.local/share/Steam and the ~/.steam links are one native root" \
    --arg r "$(realpath "$ST_ROOT")" 'length == 1 and .[0].kind == "native" and .[0].root == $r and .[0].running == false'
  local fp="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  fx_steam_root real "$fp"
  fx_flatpak_steam no
  st roots
  st_check "roots: native and Flatpak installs are both found, native first" 'map(.kind) == ["native", "flatpak"]'
  rm -rf -- "$ST_ROOT" "$HOME/.steam"
  st roots
  st_check "roots: Flatpak only" 'length == 1 and .[0].kind == "flatpak"'
  st list
  st_check "list: works on a Flatpak root" '.kind == "flatpak" and (.games | length) == 6'
  rm -rf -- "$HOME/.var"
  st list
  st_error "list with no Steam" steam_not_found
}

st_test_list() {
  echo "${BOLD}steam: list (E6a)${RESET}"
  st_new list
  fx_steam_root real
  local exp="$TESTS/fixtures/steam/list-expect.json" a
  st accounts
  st_check "accounts: the three accounts with personas, one MostRecent" '
    map(.accountid) == ["100000001", "100000002", "100000003"]
    and map(.persona) == ["Player One", "Player Two", "Player Three"]
    and map(.most_recent) == [false, false, true] and all(.[]; .has_localconfig)'
  st list
  st_check "list: default account is MostRecent" --slurpfile e "$exp" '.account == $e[0].default_account'
  for a in 100000001 100000002 100000003; do
    st list --account "$a"
    st_check "list $a: games in name order, tools hidden" --slurpfile e "$exp" '
      [.games[].appid] == $e[0].order and ([.games[].appid] - $e[0].hidden) == [.games[].appid]'
    st_check "list $a: names" --slurpfile e "$exp" \
      '. as $l | all($e[0].names | to_entries[]; .key as $k | .value == ($l.games[] | select(.appid == $k) | .name))'
    st_check "list $a: per-game state matches the account" --slurpfile e "$exp" --arg a "$a" \
      '(.games | map({(.appid): .state}) | add) == $e[0].accounts[$a].states'
    st_check "list $a: options are the decoded LaunchOptions" --slurpfile e "$exp" --arg a "$a" \
      '. as $l | all($e[0].accounts[$a].options | to_entries[]; .key as $k | .value == ($l.games[] | select(.appid == $k) | .options))'
    st_check "list $a: persona, eGPU not ready, Steam not running" --slurpfile e "$exp" --arg a "$a" \
      '.persona == $e[0].accounts[$a].persona and .egpu_ready == false and .steam_running == false
       and .extras == [{"id": "nvapi", "label": "NVAPI (DLSS)"}]'
  done
  echo '{"steam":{"account":"100000001"}}' >"$EGPU_CONFIG"
  st list
  st_check "list: steam.account in config picks the account" '.account == "100000001"'
  rm -f -- "$EGPU_CONFIG"
  st list --account 424242
  st_error "list --account unknown" account_not_found

  fx_steam_library2 "$ST_ROOT"
  st list
  st_check "list: a second library adds its games" 'any(.games[]; .appid == "4000001" and .name == "Second Library Game")'
  st_check "list: a manifest in two libraries is listed once, from the first" --arg r "$(realpath "$ST_ROOT")" \
    '[.games[] | select(.appid == "383870")] | length == 1 and .[0].name == "Firewatch" and .[0].library == $r'
}

st_test_shapes_list() {
  echo "${BOLD}steam: option shapes and eGPU state${RESET}"
  st_new shapes-list
  fx_steam_root shapes
  st list
  st_check "shapes: one account found without loginusers.vdf" '.account == "100000009" and .persona == null'
  st_check "shapes: states of every row" '
    (.games | map({(.appid): .state}) | add) == {
      "100": "off", "101": "off", "102": "off", "103": "off", "104": "off", "105": "manual", "106": "modified",
      "107": "stale", "108": "off", "109": "off", "110": "off", "111": "off", "112": "off", "113": "off",
      "114": "stale", "115": "manual", "200": "off"}'
  st_check "shapes: escapes are decoded for display" \
    '(.games[] | select(.appid == "108") | .options) == "DXVK_CONFIG=\"dxgi.maxFrameRate = 60\" WINEDLLOVERRIDES=\"dinput8=n,b\" %command% -dir C:\\Games\\Fixture"
     and (.games[] | select(.appid == "113") | .options) == "-arg\tvalue"'
  st_check "shapes: unicode names and options" \
    '(.games[] | select(.appid == "109")) | (.name | startswith("Ærøskøbing ™")) and (.options | contains("🎮"))'
  st_check "shapes: a lowercase launchoptions key is found" '(.games[] | select(.appid == "110") | .options) == "-windowed"'
  st_check "shapes: NVAPI extra inside the run is reported" \
    '(.games[] | select(.appid == "114") | .extras.nvapi) == true and (.games[] | select(.appid == "107") | .extras.nvapi) == false'
  st_phase ready
  st list
  st_check "shapes: marked games are on while the eGPU is ready" \
    '.egpu_ready == true and ([.games[] | select(.appid == "107" or .appid == "114") | .state] == ["on", "on"])'
  # Without a watcher, the phase comes from one `status --json` run.
  rm -f -- "$EGPU_RUN/status.json"
  st list
  st_check "shapes: phase read through status --json when no watcher runs" '.egpu_phase == "absent" and .egpu_ready == false'
  st_phase absent
}

# ---------------------------------------------------------------- E6b

# st_roundtrip <account> <appid> <label> [expected options after on]
st_roundtrip() {
  local acct=$1 id=$2 label=$3 want=${4-} cfg orig n0
  cfg=$(st_cfg "$acct")
  orig="$T/orig-$id.vdf"
  cp -- "$cfg" "$orig"
  n0=$(st_nbackups "$acct")
  st set "$id" on --account "$acct"
  if (( ST_RC != 0 )); then bad "$label: set on failed: $(head -c 300 "$T/out.json")"; return; fi
  if [[ -n $want ]]; then
    st_check "$label: on gives the §8.3 string" --arg w "$want" '.options == $w and .changed and .state == "stale"'
  else
    st_check "$label: on puts the marked run first" --arg r "$ST_RUN" '.options | startswith($r)'
  fi
  # One new backup (the count stops growing at the cap of 20), and it is
  # the file as it was before the write.
  local bk newest
  bk=$(jq -r '.backup' "$T/out.json")
  newest=$(find "$EGPU_STATE/backups/steam/$acct" -name 'localconfig-*.vdf' -printf '%f\n' | sort | tail -n1)
  if [[ ${bk##*/} == "$newest" && $(st_nbackups "$acct") -le 20 ]] &&
    { (( n0 >= 20 )) || [[ $(st_nbackups "$acct") == $((n0 + 1)) ]]; } && cmp -s -- "$bk" "$orig"; then
    ok "$label: one backup, identical to the file before the write"
  else
    bad "$label: backups $n0 → $(st_nbackups "$acct"), backup equal: $(cmp -s -- "$bk" "$orig" && echo yes || echo no)"
  fi
  st set "$id" off --account "$acct"
  st_same "$label: on→off is byte-identical" "$cfg" "$orig"
  st_tmp_left "$acct" && bad "$label: temp file left behind"
}

st_test_rows() {
  echo "${BOLD}steam: §8.3 rows round-trip (E6b)${RESET}"
  st_new rows
  fx_steam_root shapes
  local A=100000009
  st_roundtrip $A 101 "row (empty)" "$ST_RUN %command%"
  st_roundtrip $A 102 "row -novid -fullscreen" "$ST_RUN %command% -novid -fullscreen"
  st_roundtrip $A 103 "row gamemoderun %command% -dx11" "$ST_RUN gamemoderun %command% -dx11"
  st_roundtrip $A 104 "row PROTON_LOG=1 %command%" "$ST_RUN PROTON_LOG=1 %command%"
  st_roundtrip $A 100 "missing LaunchOptions key" "$ST_RUN %command%"
  st_roundtrip $A 200 "missing app block" "$ST_RUN %command%"
  st_roundtrip $A 112 "empty app block" "$ST_RUN %command%"
  st_roundtrip $A 108 "quotes and backslashes"
  st_roundtrip $A 109 "unicode"
  st_roundtrip $A 110 "lowercase key" "$ST_RUN %command% -windowed"
  st_roundtrip $A 111 "leading and trailing spaces" "$ST_RUN %command%  -novid  "
  st_roundtrip $A 113 "tab escape"

  # Insertions copy the siblings' indentation; quoting is re-escaped.
  local cfg
  cfg=$(st_cfg $A)
  st set 100 on --account $A
  if grep -qxF $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$ST_RUN"' %command%"' "$cfg"; then
    ok "missing key: inserted with the siblings' indentation and separator"
  else
    bad "missing key: inserted line not found"
  fi
  st set 100 off --account $A
  st set 200 on --account $A
  local block=$'\t\t\t\t\t"200"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LaunchOptions"\t\t"'"$ST_RUN"$' %command%"\n\t\t\t\t\t}\n\t\t\t\t}\n'
  if [[ $(<"$cfg") == *"$block"* ]]; then
    ok "missing block: inserted as the last app, Steam's layout"
  else
    bad "missing block: inserted block not found"
  fi
  st set 200 off --account $A
  st set 108 on --account $A
  if grep -qF '"'"$ST_RUN"' DXVK_CONFIG=\"dxgi.maxFrameRate = 60\" WINEDLLOVERRIDES=\"dinput8=n,b\" %command% -dir C:\\Games\\Fixture"' "$cfg"; then
    ok "quotes and backslashes: user bytes kept escaped exactly"
  else
    bad "quotes and backslashes: value bytes changed"
  fi
  st set 108 off --account $A

  # An already-marked game the engine did not write: off keeps %command%.
  st set 107 off --account $A
  st_check "already on (not written here): off removes only the run" '.options == "%command%" and .state == "off"'
  st set 107 on --account $A
  st set 107 off --account $A
  st_check "after a round trip the engine knows it added nothing" '.options == "%command%"'

  # CRLF files keep CRLF.
  st_new rows-crlf
  fx_steam_root shapes
  cfg=$(st_cfg $A)
  sed -i 's/$/\r/' "$cfg"
  st_roundtrip $A 100 "CRLF: missing key"
  st_roundtrip $A 200 "CRLF: missing block"
  st_roundtrip $A 102 "CRLF: value"
  st set 200 on --account $A
  st set 100 on --account $A
  if ! grep -q $'[^\r]$' "$cfg"; then ok "CRLF: inserted lines end in CRLF"; else bad "CRLF: a line without CR after insert"; fi
}

st_test_bulk() {
  echo "${BOLD}steam: set-all (E6b)${RESET}"
  st_new bulk
  fx_steam_root real
  local a cfg n0 off
  for a in 100000001 100000002 100000003; do
    cfg=$(st_cfg "$a")
    cp -- "$cfg" "$T/orig.vdf"
    n0=$(st_nbackups "$a")
    off=$(jq --arg a "$a" '[.accounts[$a].states[] | select(. == "off")] | length' "$TESTS/fixtures/steam/list-expect.json")
    st set-all on --account "$a"
    st_check "set-all on $a: every off game changed, manual ones skipped" --argjson n "$off" --arg a "$a" \
      --slurpfile e "$TESTS/fixtures/steam/list-expect.json" '
      .changed == $n and ([.skipped[].appid] | sort) == ([$e[0].accounts[$a].states | to_entries[] | select(.value == "manual") | .key] | sort)'
    if [[ $(st_nbackups "$a") == $((n0 + 1)) ]]; then ok "set-all on $a: exactly one backup"; else bad "set-all on $a: $(( $(st_nbackups "$a") - n0 )) backups"; fi
    st list --account "$a"
    st_check "set-all on $a: listed as stale (eGPU absent)" '[.games[] | select(.state == "off")] == []'
    st set-all off --account "$a"
    if [[ $(st_nbackups "$a") == $((n0 + 2)) ]]; then ok "set-all off $a: exactly one backup"; else bad "set-all off $a: backups"; fi
    st_same "set-all on→off $a is byte-identical" "$cfg" "$T/orig.vdf"
  done

  st_new bulk-stale
  fx_steam_root shapes
  st_phase ready
  st set-all off --only-stale
  st_check "set-all off --only-stale with the eGPU ready changes nothing" '.changed == 0 and .backup == null'
  st_phase absent
  st set-all off --only-stale
  st_check "set-all off --only-stale turns off the stale games" '.changed == 2'
  st list
  st_check "--only-stale: 107 and 114 are off, manual and modified untouched" '
    ([.games[] | select(.appid == "107" or .appid == "114") | .state] == ["off", "off"])
    and ([.games[] | select(.appid == "105" or .appid == "106" or .appid == "115") | .state] == ["manual", "modified", "manual"])'
}

st_test_refusals() {
  echo "${BOLD}steam: never clobber (E6b)${RESET}"
  st_new refusals
  fx_steam_root shapes
  local A=100000009 cfg
  cfg=$(st_cfg $A)
  cp -- "$cfg" "$T/orig.vdf"
  st set 105 on
  st_error "manual options, on" manual_offload
  st set 106 on
  st_error "edited run, on" token_modified
  st set 106 off
  st_error "edited run, off" token_modified
  st set 105 off
  st_check "manual options, off: nothing to do" '.changed == false and .state == "manual"'
  st_same "refusals wrote nothing" "$cfg" "$T/orig.vdf"
  [[ $(st_nbackups $A) == 0 ]] && ok "refusals made no backup" || bad "refusals made a backup"

  st set 115 on --adopt
  st_check "adopt: backend variables replaced by the marked run, the rest kept" --arg r "$ST_RUN" \
    '.options == ($r + " QT_QPA_PLATFORM=xcb VKD3D_FILTER_DEVICE_NAME=\"RTX 4070 SUPER\" %command%") and (.before | contains("QT_QPA"))'
  st set 115 off
  st_check "adopt then off: the user's other options stay" \
    '.options == "QT_QPA_PLATFORM=xcb VKD3D_FILTER_DEVICE_NAME=\"RTX 4070 SUPER\" %command%" and .state == "off"'

  cp -- "$cfg" "$T/orig.vdf"
  st set 102 on --nvapi on
  st_check "nvapi: the extra goes inside the run" --arg r "$ST_RUN" '.options == ($r + " PROTON_ENABLE_NVAPI=1 %command% -novid -fullscreen")'
  st list
  st_check "nvapi: listed as on" '(.games[] | select(.appid == "102") | .extras.nvapi) == true'
  st set 102 on --nvapi off
  st_check "nvapi off: only the extra is removed" --arg r "$ST_RUN" '.options == ($r + " %command% -novid -fullscreen") and .changed'
  st set 102 on --nvapi on
  st set 102 off
  st_same "nvapi: on→nvapi→off is byte-identical" "$cfg" "$T/orig.vdf"
  st set 102 on
  st set 102 on
  st_check "on twice: the second is a no-op" '.changed == false and .backup == null'
  st set 102 off
  st set abc on
  st_error "bad appid" usage
}

st_test_corruption() {
  echo "${BOLD}steam: planted corruption (E6b)${RESET}"
  st_new corruption
  fx_steam_root shapes
  local A=100000009 cfg f
  cfg=$(st_cfg $A)
  for f in "$TESTS"/fixtures/steam/corrupt/*.vdf; do
    cp -- "$f" "$cfg"
    st set 102 on
    st_error "corrupt ${f##*/}: set" vdf_parse_failed
    st_same "corrupt ${f##*/}: file untouched" "$cfg" "$f"
    st list
    st_error "corrupt ${f##*/}: list" vdf_parse_failed
  done
  [[ $(st_nbackups $A) == 0 ]] && ok "corrupt files: no backup made" || bad "corrupt files: backup made"
  st_tmp_left $A && bad "corrupt files: temp file left" || ok "corrupt files: no temp file left"

  # The post-edit check itself: a correct edit passes, and each planted
  # corruption of the edited bytes is rejected with vdf_check_failed.
  if out=$(python3 - "$REPO/lib/steam" "$TESTS/fixtures/steam/shapes/userdata/$A/config/localconfig.vdf" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import vdf
data = open(sys.argv[2], "rb").read()

def edited():
    ed = vdf.Editor(data)
    app = ed.app("102")
    ed.set_value(app.find("LaunchOptions"), b"OMARCHY_EGPU=1 X=1 %command% -novid -fullscreen")
    ed.add(ed.app("100"), b"LaunchOptions", b"x")
    new, sp = ed.result()
    return ed, new, sp

ed, new, sp = edited()
ed.verify(new, sp)
print("ok-clean")
plants = {
    "dropped closing brace": lambda b: b[:b.rindex(b"}")],
    "byte changed outside the span": lambda b: b.replace(b'"Permissions"\t\t"1"', b'"Permissions"\t\t"2"', 1),
    "whitespace changed outside the span": lambda b: b.replace(b"\t\"Broadcast\"", b"  \"Broadcast\"", 1),
    "comment dropped": lambda b: b.replace(b"// a comment", b"", 1),
    "other key edited, same length": lambda b: b.replace(b'"Playtime"\t\t"12"', b'"Playtime"\t\t"13"', 1),
    "extra key added": lambda b: b.replace(b'"Playtime"\t\t"3"', b'"Playtime"\t\t"3"\n\t\t\t\t\t\t"Evil"\t\t"1"', 1),
}
for name, f in plants.items():
    ed, new, sp = edited()
    bad = f(new)
    assert bad != new, name
    try:
        ed.verify(bad, sp)
        print("ACCEPTED " + name)
    except vdf.VdfError as e:
        print(("rejected " if e.code == "vdf_check_failed" else "WRONG-CODE ") + name)
PY
  ); then
    grep -q '^ok-clean$' <<<"$out" && ok "validity check accepts the correct edit" || bad "validity check rejected a correct edit"
    while IFS= read -r line; do
      case $line in
        rejected*) ok "validity check: ${line#rejected } rejected (vdf_check_failed)" ;;
        ok-clean) ;;
        *) bad "validity check: $line" ;;
      esac
    done <<<"$out"
  else
    bad "validity check script failed: $out"
  fi
}

st_test_running() {
  echo "${BOLD}steam: Steam running, queue, changed underneath (E6b)${RESET}"
  st_new running
  fx_steam_root shapes
  local A=100000009 cfg
  cfg=$(st_cfg $A)
  cp -- "$cfg" "$T/orig.vdf"
  fx_steam_running
  st set 102 on
  st_error "Steam running: set" steam_running
  st set-all on
  st_error "Steam running: set-all" steam_running
  st_same "Steam running: nothing written" "$cfg" "$T/orig.vdf"
  [[ $(st_nbackups $A) == 0 ]] && ok "Steam running: no backup" || bad "Steam running: backup made"

  st set 102 on --queue
  st_check "--queue: queued as pending_on" '.queued == true and .state == "pending_on" and .changed'
  st set 107 off --queue
  st_check "--queue: queued as pending_off" '.queued == true and .state == "pending_off"'
  st set 105 on --queue
  st_error "--queue still refuses manual options" manual_offload
  st list
  st_check "list: queued games show pending_*" \
    '(.games[] | select(.appid == "102") | .state) == "pending_on" and (.games[] | select(.appid == "107") | .state) == "pending_off" and .steam_running'
  if jq -e 'length == 2 and all(.[]; .account == "100000009") and (map(.want) | sort) == ["off", "on"]' "$EGPU_STATE/steam-pending.json" >/dev/null 2>&1; then
    ok "queue file steam-pending.json holds [{account, appid, want}]"
  else
    bad "queue file: $(cat "$EGPU_STATE/steam-pending.json" 2>/dev/null)"
  fi
  "$ENGINE" health >"$T/health.json" 2>/dev/null
  if jq -e '.[] | select(.id == "steam.pending") | .level == "info" and (.title | test("^2 "))' "$T/health.json" >/dev/null; then
    ok "health steam.pending lists the queue"
  else
    bad "health steam.pending: $(jq -c '.[] | select(.id == "steam.pending")' "$T/health.json")"
  fi
  st_same "queueing wrote nothing" "$cfg" "$T/orig.vdf"
  st apply
  st_error "apply while Steam runs" steam_running
  [[ -s $EGPU_STATE/steam-pending.json ]] && ok "apply refused: the queue is kept" || bad "apply refused but the queue is gone"

  # Steam started again between preparing and renaming: abort, keep the queue.
  : >"$EGPU_FAKE_DIR/pgrep.txt"
  cat >"$EGPU_FAKE_DIR/pgrep-hook" <<EOF
#!/bin/bash
compgen -G "$(dirname -- "$cfg")/.localconfig.vdf.omarchy-egpu.*" >/dev/null && ! grep -q '^steam ' "$EGPU_FAKE_DIR/pgrep.txt" && echo 'steam 5151' >>"$EGPU_FAKE_DIR/pgrep.txt"
exit 0
EOF
  chmod +x "$EGPU_FAKE_DIR/pgrep-hook"
  st apply
  st_error "Steam started before the rename" steam_running
  st_same "Steam started before the rename: nothing written" "$cfg" "$T/orig.vdf"
  st_tmp_left $A && bad "temp file left after the abort" || ok "temp file removed after the abort"
  [[ $(jq length "$EGPU_STATE/steam-pending.json" 2>/dev/null) == 2 ]] && ok "abort keeps the queue" || bad "abort lost the queue"
  rm -f -- "$EGPU_FAKE_DIR/pgrep-hook"

  : >"$EGPU_FAKE_DIR/pgrep.txt"
  st apply
  st_check "apply once Steam is closed: both changes in one write" '.applied == 2 and .failed == [] and .closed == false'
  [[ ! -e $EGPU_STATE/steam-pending.json ]] && ok "apply empties the queue" || bad "queue still there after apply"
  [[ $(st_nbackups $A) == 1 ]] && ok "apply made one backup" || bad "apply made $(st_nbackups $A) backups"
  st list
  st_check "after apply: 102 stale (on, eGPU absent), 107 off" \
    '(.games[] | select(.appid == "102") | .state) == "stale" and (.games[] | select(.appid == "107") | .state) == "off"'

  # The file changed between the parse and the rename.
  st_new underneath
  fx_steam_root shapes
  cfg=$(st_cfg $A)
  cat >"$EGPU_FAKE_DIR/pgrep-hook" <<EOF
#!/bin/bash
[[ \$1 == steam ]] && compgen -G "$(dirname -- "$cfg")/.localconfig.vdf.omarchy-egpu.*" >/dev/null &&
  [[ ! -e "$T/hooked" ]] && { printf '\n' >>"$cfg"; : >"$T/hooked"; }
exit 0
EOF
  chmod +x "$EGPU_FAKE_DIR/pgrep-hook"
  cp -- "$cfg" "$T/orig.vdf"
  printf '\n' >>"$T/orig.vdf"
  st set 102 on
  st_error "file changed underneath" vdf_changed_underneath
  st_same "changed underneath: only the other writer's change is in the file" "$cfg" "$T/orig.vdf"
  [[ $(st_nbackups $A) == 0 ]] && ok "changed underneath: no backup" || bad "changed underneath: backup made"
  st_tmp_left $A && bad "changed underneath: temp file left" || ok "changed underneath: temp file removed"
  rm -f -- "$EGPU_FAKE_DIR/pgrep-hook"

  # Flatpak Steam running counts for a Flatpak root.
  st_new running-flatpak
  local fp="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  fx_steam_root shapes "$fp"
  export EGPU_STEAM_ROOTS=$fp
  fx_flatpak_steam yes
  st set 102 on
  st_error "Flatpak Steam running: set" steam_running
  st status
  st_check "status: Flatpak Steam reported running" '.running == true and .roots[0].kind == "flatpak"'
}

st_test_close() {
  echo "${BOLD}steam: close, apply, relaunch (fake Steam)${RESET}"
  st_new close
  fx_steam_root shapes
  local A=100000009 i
  fx_steam_running
  st set 102 on --queue
  st apply --close --relaunch
  st_check "apply --close --relaunch: applied" '.applied == 1 and .closed == true and .relaunched == true'
  for i in $(seq 1 30); do grep -q '^steam 4242' "$EGPU_FAKE_DIR/pgrep.txt" && break; sleep 0.1; done
  if grep -q '^steam -shutdown' "$EGPU_FAKE_LOG" && grep -q '^uwsm-app -- steam' "$EGPU_FAKE_LOG" &&
    [[ $(grep -n '^steam -shutdown' "$EGPU_FAKE_LOG" | cut -d: -f1) -lt $(grep -n '^uwsm-app' "$EGPU_FAKE_LOG" | cut -d: -f1) ]]; then
    ok "Steam was shut down, then reopened through uwsm-app"
  else
    bad "close/relaunch calls: $(grep -E '^(steam|uwsm-app)' "$EGPU_FAKE_LOG" | paste -sd'|')"
  fi
  grep -q '^steam 4242' "$EGPU_FAKE_DIR/pgrep.txt" && ok "Steam runs again after relaunch" || bad "Steam not running after relaunch"
  st list
  st_check "the queued change is in the file" '(.games[] | select(.appid == "102") | .state) == "stale"'

  st set 103 on --queue
  echo "reaper 6000" >>"$EGPU_FAKE_DIR/pgrep.txt"
  : >"$EGPU_FAKE_LOG"
  st apply --close
  st_error "a game is running" game_running
  grep -q -- '-shutdown' "$EGPU_FAKE_LOG" && bad "game running: Steam was told to shut down" || ok "game running: Steam left alone"
  sed -i '/^reaper /d' "$EGPU_FAKE_DIR/pgrep.txt"

  : >"$EGPU_FAKE_DIR/steam-ignores-shutdown"
  export EGPU_STEAM_CLOSE_TIMEOUT=1
  st apply --close
  unset EGPU_STEAM_CLOSE_TIMEOUT
  st_error "Steam ignores -shutdown" steam_close_timeout
  [[ $(jq length "$EGPU_STATE/steam-pending.json" 2>/dev/null) == 1 ]] && ok "close timeout keeps the queue" || bad "close timeout lost the queue"
  rm -f -- "$EGPU_FAKE_DIR/steam-ignores-shutdown"
  st close
  st_check "steam close" '.was_running == true and .closed == true'
  st close
  st_check "steam close when not running" '.was_running == false'
  st apply
  st_check "apply after close" '.applied == 1 and .relaunched == false'

  st_new close-flatpak
  local fp="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  fx_steam_root shapes "$fp"
  export EGPU_STEAM_ROOTS=$fp
  fx_flatpak_steam yes
  st set 102 on --queue
  st apply --close --relaunch
  st_check "Flatpak: apply --close --relaunch" '.applied == 1 and .relaunched == true'
  for i in $(seq 1 30); do grep -q 'com.valvesoftware.Steam' "$EGPU_FAKE_DIR/flatpak-ps.txt" && break; sleep 0.1; done
  if grep -q '^flatpak run com.valvesoftware.Steam -shutdown' "$EGPU_FAKE_LOG" && grep -qx 'flatpak run com.valvesoftware.Steam' "$EGPU_FAKE_LOG"; then
    ok "Flatpak: shut down and reopened with flatpak run"
  else
    bad "Flatpak calls: $(grep '^flatpak' "$EGPU_FAKE_LOG" | paste -sd'|')"
  fi
}

st_test_backups() {
  echo "${BOLD}steam: backups, restore, lock${RESET}"
  st_new backups
  fx_steam_root shapes
  local A=100000009 cfg i first
  cfg=$(st_cfg $A)
  cp -- "$cfg" "$T/orig.vdf"
  for i in $(seq 1 11); do
    st set 102 on
    st set 102 off
  done
  [[ $(st_nbackups $A) == 20 ]] && ok "22 writes keep the newest 20 backups" || bad "backups kept: $(st_nbackups $A)"
  st set 103 on
  first=$(find "$EGPU_STATE/backups/steam/$A" -name 'localconfig-*.vdf' -printf '%f\n' | sort | head -n1)
  cp -- "$cfg" "$T/before-restore.vdf"
  st restore $A "$first"
  st_check "restore: reports the restored file and a backup of the current one" '.restored != null and .backup != null'
  st_same "restore: the file is the backup" "$cfg" "$EGPU_STATE/backups/steam/$A/$first"
  st_same "restore: the replaced file was backed up first" "$(jq -r .backup "$T/out.json")" "$T/before-restore.vdf"
  st restore $A ../../../../home/x.vdf
  st_error "restore outside the backups" backup_failed
  fx_steam_running
  st restore $A "$first"
  st_error "restore while Steam runs" steam_running
  : >"$EGPU_FAKE_DIR/pgrep.txt"

  # Another writer holds the lock: exit 3.
  exec {lk}>"$EGPU_RUN/steam.lock"
  flock -n "$lk"
  st set 102 on
  if (( ST_RC == 3 )) && jq -e '.error == "busy"' "$T/out.json" >/dev/null; then ok "lock held: exit 3 busy"; else bad "lock held: exit $ST_RC"; fi
  exec {lk}>&-

  # The backup cannot be written: nothing is renamed into place.
  cp -- "$cfg" "$T/orig.vdf"
  chmod 500 "$EGPU_STATE/backups/steam/$A"
  st set 104 on
  chmod 700 "$EGPU_STATE/backups/steam/$A"
  st_error "backup cannot be written" backup_failed
  st_same "backup_failed: file untouched" "$cfg" "$T/orig.vdf"
  st_tmp_left $A && bad "backup_failed: temp file left" || ok "backup_failed: temp file removed"
}

test_steam() {
  (st_test_discovery)
  (st_test_list)
  (st_test_shapes_list)
  (st_test_rows)
  (st_test_bulk)
  (st_test_refusals)
  (st_test_corruption)
  (st_test_running)
  (st_test_close)
  (st_test_backups)
}
