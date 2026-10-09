#!/bin/bash

# steam.sh — module: per-game "Run on eGPU" in Steam. plan-engine.md §8.
#
#   omarchy-egpu steam roots                       [{kind, root, running}]
#   omarchy-egpu steam accounts [--root R]         [{accountid, persona, most_recent, has_localconfig}]
#   omarchy-egpu steam list [--account A] [--root R]
#   omarchy-egpu steam set <appid> on|off [--nvapi on|off] [--adopt] [--account A] [--root R] [--queue]
#   omarchy-egpu steam set-all on|off [--only-stale] [--account A] [--root R] [--queue]
#   omarchy-egpu steam apply [--close] [--relaunch]
#   omarchy-egpu steam close [--root R]
#   omarchy-egpu steam restore <accountid> <backup> [--root R]
#   omarchy-egpu steam status                      roots, default account, queue
#
# Works without an eGPU and without Hyprland. The option string comes only from
# the backend (be_offload_env, be_steam_extras), the eGPU's readiness only from
# `status`. lib/steam/vdf.py parses and edits localconfig.vdf: it changes only
# the bytes of one value (or inserts/removes one line or block) and checks the
# result before anything is renamed into place (§8.2).
#
# Writes: localconfig.vdf (only while Steam is closed, after a backup), and
# under $EGPU_STATE: backups/steam/<account>/, steam-state.json (what the engine
# added, so on→off is byte-identical), steam-pending.json (the queue, §8.4).
#
# Steam roots come from EGPU_STEAM_ROOTS (colon-separated; the test seam), else
# the `steam.roots` config key, else the native and Flatpak defaults under $HOME.

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../common.sh"

STEAM_LIB="$EGPU_LIB/steam"
STEAM_FLATPAK_APP=com.valvesoftware.Steam
STEAM_PENDING="$EGPU_STATE/steam-pending.json"
STEAM_STATEFILE="$EGPU_STATE/steam-state.json"
STEAM_BACKUPS="$EGPU_STATE/backups/steam"
STEAM_KEEP_BACKUPS=20
STEAMID_BASE=76561197960265728

_vdf() { python3 "$STEAM_LIB/vdf.py" "$@"; }

# ---------------------------------------------------------------- roots

# Candidate roots as "kind<TAB>path", in probe order.
_steam_candidates() {
  local p kind
  if [[ -n ${EGPU_STEAM_ROOTS:-} ]]; then
    local IFS=:
    for p in $EGPU_STEAM_ROOTS; do
      kind=native
      [[ $p == *"/.var/app/$STEAM_FLATPAK_APP/"* ]] && kind=flatpak
      printf '%s\t%s\n' "$kind" "$p"
    done
    return
  fi
  local cfg
  cfg=$(config_get steam.roots null)
  if [[ $cfg != null ]]; then
    jq -r --arg app "$STEAM_FLATPAK_APP" '
      .[]? | if type == "string" then {root: .} else . end
      | "\(.kind // (if (.root | contains("/.var/app/" + $app + "/")) then "flatpak" else "native" end))\t\(.root)"' <<<"$cfg"
    return
  fi
  printf 'native\t%s\n' "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"
  printf 'flatpak\t%s\n' "$HOME/.var/app/$STEAM_FLATPAK_APP/.local/share/Steam"
}

# Existing roots as "kind<TAB>realpath", de-duplicated by realpath (§8.1).
steam_roots_tsv() {
  local kind p real seen=$'\n'
  while IFS=$'\t' read -r kind p; do
    [[ -n $p && -d $p ]] || continue
    [[ -d $p/steamapps || -d $p/userdata ]] || continue
    real=$(realpath -- "$p" 2>/dev/null) || continue
    [[ $seen == *$'\n'"$real"$'\n'* ]] && continue
    seen+="$real"$'\n'
    printf '%s\t%s\n' "$kind" "$real"
  done < <(_steam_candidates)
}

_steam_root_kind() {
  local kind p
  while IFS=$'\t' read -r kind p; do
    [[ $p == "$1" ]] && { echo "$kind"; return 0; }
  done < <(steam_roots_tsv)
  return 1
}

# ---------------------------------------------------------------- processes

# Native: any steam/steamwebhelper process of this user. A Flatpak Steam's
# processes are visible on the host too, so with both installs a running
# Flatpak Steam also counts here; refusing is the safe side (§8.4).
_steam_native_running() { user_pids steam >/dev/null || user_pids steamwebhelper >/dev/null; }

_steam_flatpak_running() {
  command -v flatpak >/dev/null 2>&1 || return 1
  timeout 5 flatpak ps --columns=application 2>/dev/null | grep -qxF "$STEAM_FLATPAK_APP"
}

steam_kind_running() {
  case $1 in
    flatpak) _steam_flatpak_running ;;
    *) _steam_native_running ;;
  esac
}

# Any Steam of this user (status.sh's steam.running).
steam_any_running() {
  _steam_native_running && return 0
  steam_roots_tsv | cut -f1 | grep -qx flatpak && _steam_flatpak_running
}

# A game Steam launched: every launch runs under Steam's `reaper`.
_steam_game_running() { user_pids reaper >/dev/null; }

# ---------------------------------------------------------------- accounts

# steam_accounts_json <root>: every account in loginusers.vdf or userdata/.
steam_accounts_json() {
  local root=$1 lu="$1/config/loginusers.vdf" users='{}' sid d
  if [[ -r $lu ]]; then
    users=$(_vdf dump --lower "$lu" | jq -c --arg f "$lu" '.[$f].users // {}' 2>/dev/null)
    [[ -n $users ]] || users='{}'
  fi
  # "accountid<TAB>steamid64" lines. The subtraction is done in bash: jq's
  # doubles cannot hold 17 digits.
  {
    while IFS= read -r sid; do
      [[ $sid =~ ^[0-9]{17}$ ]] && printf '%s\t%s\n' "$(( sid - STEAMID_BASE ))" "$sid"
    done < <(jq -r 'keys[]' <<<"$users")
    for d in "$root"/userdata/*/; do
      d=${d%/}
      d=${d##*/}
      [[ $d =~ ^[0-9]+$ && $d != 0 ]] && printf '%s\t\n' "$d"
    done
  } | sort -t$'\t' -k1,1n -k2,2r | awk -F'\t' '!seen[$1]++' |
    while IFS=$'\t' read -r d sid; do
      printf '%s\t%s\t%s\n' "$d" "$sid" "$([[ -r $root/userdata/$d/config/localconfig.vdf ]] && echo 1)"
    done |
    jq -R -s -c --argjson users "$users" '
      split("\n") | map(select(length > 0) | split("\t") |
        ($users[.[1]] // {}) as $u |
        {accountid: .[0], persona: ($u.personaname // null),
         most_recent: (($u.mostrecent // "0") == "1"), has_localconfig: (.[2] == "1")})'
}

# _steam_default_account <root> <accounts json>: steam.account from config
# when it names one, else MostRecent, else the only one, else the newest file.
_steam_default_account() {
  local root=$1 accts=$2 want a best='' best_t=0 t
  want=$(config_str steam.account "")
  if [[ -n $want ]] && jq -e --arg a "$want" 'any(.[]; .accountid == $a and .has_localconfig)' <<<"$accts" >/dev/null; then
    echo "$want"
    return 0
  fi
  a=$(jq -r 'map(select(.has_localconfig and .most_recent)) | .[0].accountid // empty' <<<"$accts")
  [[ -n $a ]] && { echo "$a"; return 0; }
  while IFS= read -r a; do
    [[ -n $a ]] || continue
    t=$(stat -c %Y -- "$root/userdata/$a/config/localconfig.vdf" 2>/dev/null || echo 0)
    (( t > best_t )) || [[ -z $best ]] || continue
    best=$a best_t=$t
  done < <(jq -r '.[] | select(.has_localconfig) | .accountid' <<<"$accts")
  [[ -n $best ]] && { echo "$best"; return 0; }
  return 1
}

# _steam_resolve [root] [account]: sets S_ROOT, S_KIND, S_ACCOUNT, S_FILE,
# S_ACCOUNTS. On failure prints the error JSON and returns 1.
_steam_resolve() {
  local want_root=${1:-} want_acct=${2:-} kind p
  S_ROOT='' S_KIND=''
  while IFS=$'\t' read -r kind p; do
    if [[ -z $want_root || $p == "$(realpath -- "$want_root" 2>/dev/null)" ]]; then
      S_ROOT=$p S_KIND=$kind
      break
    fi
  done < <(steam_roots_tsv)
  if [[ -z $S_ROOT ]]; then
    json_error steam_not_found "$(jq -cn --arg r "$want_root" '{detail: (if $r == "" then "No Steam install found." else "Not a Steam root: \($r)" end)}')"
    return 1
  fi
  S_ACCOUNTS=$(steam_accounts_json "$S_ROOT")
  if [[ -n $want_acct ]]; then
    if ! jq -e --arg a "$want_acct" 'any(.[]; .accountid == $a and .has_localconfig)' <<<"$S_ACCOUNTS" >/dev/null; then
      json_error account_not_found "$(jq -cn --arg a "$want_acct" --argjson l "$S_ACCOUNTS" \
        '{account: $a, accounts: [$l[] | select(.has_localconfig) | .accountid]}')"
      return 1
    fi
    S_ACCOUNT=$want_acct
  elif ! S_ACCOUNT=$(_steam_default_account "$S_ROOT" "$S_ACCOUNTS"); then
    json_error account_not_found '{"detail":"No Steam account with a localconfig.vdf."}'
    return 1
  fi
  S_FILE="$S_ROOT/userdata/$S_ACCOUNT/config/localconfig.vdf"
}

# ---------------------------------------------------------------- games

# Library paths of a root, the root first, de-duplicated, existing only.
_steam_libraries() {
  local root=$1 f p seen=$'\n' real
  {
    printf '%s\n' "$root"
    for f in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
      [[ -r $f ]] || continue
      _vdf dump --lower "$f" | jq -r --arg f "$f" '.[$f].libraryfolders // {} | to_entries[] | .value.path? // empty' 2>/dev/null
      break
    done
  } | while IFS= read -r p; do
    [[ -n $p && -d $p/steamapps ]] || continue
    real=$(realpath -- "$p" 2>/dev/null) || continue
    [[ $seen == *$'\n'"$real"$'\n'* ]] && continue
    seen+="$real"$'\n'
    printf '%s\n' "$real"
  done
}

# steam_games_json <root>: installed games, tools hidden (tools.json), one
# entry per appid (the first library wins), sorted by name.
steam_games_json() {
  local root=$1 lib files=()
  while IFS= read -r lib; do
    for f in "$lib"/steamapps/appmanifest_*.acf; do
      [[ -r $f ]] && files+=("$f")
    done
  done < <(_steam_libraries "$root")
  (( ${#files[@]} )) || { echo '[]'; return 0; }
  _vdf dump --lower "${files[@]}" | jq -c --slurpfile tools "$STEAM_LIB/tools.json" --args '
    . as $docs | $tools[0] as $t |
    [ $ARGS.positional[] as $f | $docs[$f].appstate // empty |
      select(.appid != null and (.appid | test("^[0-9]+$"))) |
      {appid: .appid, name: (.name // ("App " + .appid)), installdir: (.installdir // null),
       library: ($f | sub("/steamapps/appmanifest_[0-9]+\\.acf$"; ""))} ]
    | reduce .[] as $g ({seen: {}, out: []};
        if .seen[$g.appid] then . else .seen[$g.appid] = true | .out += [$g] end)
    | .out
    | map(select(.appid as $a | ($t.appids | index($a)) | not))
    | map(select(.name as $n | all($t.name_prefixes[]; ($n | startswith(.)) | not)))
    | sort_by(.name | ascii_downcase)' "${files[@]}"
}

# ---------------------------------------------------------------- backend

# Sets STEAM_ENV (JSON array of KEY=VALUE) and STEAM_EXTRAS ([{id, token,
# label}]) from the backend: the present eGPU's, else the configured one, else
# the one remembered from the last write, else the first implemented one.
# STEAM_BACKEND_OK=1 when that backend is implemented.
_steam_backend() {
  local bdf b='' want
  bdf=$(pci_egpu_candidates | head -n1)
  if [[ -n $bdf ]] && backend_select "$bdf"; then
    b=$EGPU_BACKEND
  else
    want=$(config_str backend auto)
    if [[ $want != auto ]] && backend_load "$want"; then
      b=$want
    else
      want=$(jq -r '.backend // empty' "$STEAM_STATEFILE" 2>/dev/null)
      if [[ -n $want ]] && backend_load "$want"; then
        b=$want
      else
        for want in "${EGPU_BACKENDS[@]}"; do
          backend_load "$want" && [[ $BE_STATUS == implemented ]] && { b=$want; break; }
        done
      fi
    fi
  fi
  STEAM_BACKEND=$b
  STEAM_BACKEND_OK=0
  [[ -n $b && $BE_STATUS == implemented ]] && STEAM_BACKEND_OK=1
  STEAM_ENV=$(be_offload_env "$bdf" 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))')
  STEAM_EXTRAS=$(be_steam_extras 2>/dev/null | jq -c 'if type == "array" then map({id, token: "\(.key)=\(.value)", label}) else [] end' 2>/dev/null)
  [[ -n $STEAM_EXTRAS ]] || STEAM_EXTRAS='[]'
  [[ -n $STEAM_ENV ]] || STEAM_ENV='[]'
}

# ---------------------------------------------------------------- eGPU state

# The eGPU phase, through `status` only (§8): the caller's own status run,
# else a fresh status.json from the watcher, else one `status --json`.
_steam_phase() {
  if [[ -n ${EGPU_STATUS_PHASE:-} ]]; then
    printf '%s\n' "$EGPU_STATUS_PHASE"
    return
  fi
  local f="$EGPU_RUN/status.json" at
  if [[ -r $f ]]; then
    at=$(jq -r '.written_at // 0' "$f" 2>/dev/null)
    if [[ $at =~ ^[0-9]+$ ]] && (( $(now_ms) - at < 10000 )); then
      jq -r '.phase // "unknown"' "$f"
      return
    fi
  fi
  if [[ -z ${EGPU_STEAM_NO_STATUS:-} ]]; then
    EGPU_STEAM_NO_STATUS=1 "$EGPU_ROOT/bin/omarchy-egpu" status --json 2>/dev/null | jq -r '.phase // "unknown"' 2>/dev/null && return
  fi
  echo unknown
}

# ---------------------------------------------------------------- state files

_steam_state_for() { jq -c --arg a "$1" '.accounts[$a] // {}' "$STEAM_STATEFILE" 2>/dev/null || echo '{}'; }

_steam_state_save() {
  local acct=$1 st=$2 cur
  cur=$(jq -c . "$STEAM_STATEFILE" 2>/dev/null) || cur='{}'
  [[ -n $cur ]] || cur='{}'
  jq -c --arg a "$acct" --argjson s "$st" --arg b "$STEAM_BACKEND" \
    '.accounts[$a] = $s | .backend = $b' <<<"$cur" | write_atomic "$STEAM_STATEFILE"
}

_steam_queue() { jq -c 'if type == "array" then . else [] end' "$STEAM_PENDING" 2>/dev/null || echo '[]'; }

_steam_queue_write() {
  if [[ $(jq 'length' <<<"$1") == 0 ]]; then
    rm -f -- "$STEAM_PENDING"
  else
    jq -c . <<<"$1" | write_atomic "$STEAM_PENDING"
  fi
}

# _steam_queue_drop <root> <account> <appids json>: remove entries for these.
_steam_queue_drop() {
  local q
  q=$(_steam_queue)
  [[ $(jq 'length' <<<"$q") == 0 ]] && return 0
  _steam_queue_write "$(jq -c --arg r "$1" --arg a "$2" --argjson ids "$3" \
    'map(select((.root == $r and .account == $a and (.appid as $x | $ids | index($x))) | not))' <<<"$q")"
}

# ---------------------------------------------------------------- locking

# One writer at a time. Exit 3 when another engine job holds the lock (§1.1).
_steam_lock() {
  mkdir -p -- "$EGPU_RUN" 2>/dev/null
  exec {STEAM_LOCK_FD}>"$EGPU_RUN/steam.lock" || return 1
  if ! flock -n "$STEAM_LOCK_FD"; then
    json_error busy '{"detail":"Another Steam change is running."}'
    return 3
  fi
}

# ---------------------------------------------------------------- writing

_steam_utc() { date -u +%Y%m%dT%H%M%S.%3NZ; }

_steam_prune_backups() {
  local dir="$STEAM_BACKUPS/$1" old
  mapfile -t old < <(find "$dir" -maxdepth 1 -name 'localconfig-*.vdf' -printf '%f\n' 2>/dev/null | sort | head -n -"$STEAM_KEEP_BACKUPS")
  for f in "${old[@]}"; do rm -f -- "${dir:?}/$f"; done
}

# _steam_commit <tmp> <sha> → prints the backup path. Checks Steam once more
# immediately before the rename (§8.4): Steam would overwrite the file on exit.
_steam_commit() {
  local tmp=$1 sha=$2 backup out
  if steam_kind_running "$S_KIND"; then
    rm -f -- "$tmp"
    json_error steam_running '{"detail":"Steam started while the change was prepared; nothing was written."}'
    return 1
  fi
  backup="$STEAM_BACKUPS/$S_ACCOUNT/localconfig-$(_steam_utc).vdf"
  if ! out=$(_vdf commit --file "$S_FILE" --tmp "$tmp" --sha "$sha" --backup "$backup"); then
    printf '%s\n' "$out"
    return 1
  fi
  _steam_prune_backups "$S_ACCOUNT"
  printf '%s\n' "$backup"
}

# _steam_plan <changes json> [--dry-run]: runs vdf.py plan for S_FILE.
_steam_plan() {
  _vdf plan --env "$STEAM_ENV" --extras "$STEAM_EXTRAS" --state "$(_steam_state_for "$S_ACCOUNT")" \
    --changes "$1" ${2:+"$2"} "$S_FILE"
}

# _steam_apply_changes <changes json>: one parse, one check, one backup, one
# write for any number of games (§8.2 Bulk). Prints the plan result with
# .backup set (null when nothing changed). Steam must already be closed.
_steam_apply_changes() {
  local plan rc tmp backup
  plan=$(_steam_plan "$1")
  rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$plan"
    return 1
  fi
  tmp=$(jq -r '.tmp // empty' <<<"$plan")
  if [[ -z $tmp ]]; then
    jq -c '. + {backup: null}' <<<"$plan"
    return 0
  fi
  if ! backup=$(_steam_commit "$tmp" "$(jq -r .sha256 <<<"$plan")"); then
    printf '%s\n' "$backup"
    return 1
  fi
  _steam_state_save "$S_ACCOUNT" "$(jq -c .state <<<"$plan")"
  _steam_queue_drop "$S_ROOT" "$S_ACCOUNT" "$(jq -c '[.results[] | select(.changed) | .appid]' <<<"$plan")"
  jq -c --arg b "$backup" '. + {backup: $b} | del(.tmp)' <<<"$plan"
}

# _steam_enqueue <changes json>: validates with a dry run, then queues the
# changes that would change something (§8.4 option 2).
_steam_enqueue() {
  local plan q now
  plan=$(_steam_plan "$1" --dry-run) || { printf '%s\n' "$plan"; return 1; }
  now=$(now_ms)
  q=$(_steam_queue)
  q=$(jq -c --argjson plan "$plan" --argjson ch "$1" --arg r "$S_ROOT" --arg a "$S_ACCOUNT" --argjson now "$now" '
    ($plan.results | map({(.appid): .}) | add // {}) as $res |
    ($ch | map(select($res[.appid].changed))) as $add |
    map(select((.root == $r and .account == $a and (.appid as $x | $add | map(.appid) | index($x))) | not))
    + [$add[] | {root: $r, account: $a, appid, want, adopt: (.adopt // false), extras: (.extras // {}), queued_at: $now}]' <<<"$q")
  _steam_queue_write "$q"
  jq -c '.' <<<"$plan"
}

# ---------------------------------------------------------------- verbs

steam_roots_verb() {
  local kind p running out='[]'
  while IFS=$'\t' read -r kind p; do
    running=false
    steam_kind_running "$kind" && running=true
    out=$(jq -c --arg k "$kind" --arg r "$p" --argjson run "$running" '. + [{kind: $k, root: $r, running: $run}]' <<<"$out")
  done < <(steam_roots_tsv)
  printf '%s\n' "$out"
}

steam_accounts_verb() {
  _steam_resolve "${OPT_ROOT:-}" "" || return 1
  printf '%s\n' "$S_ACCOUNTS"
}

steam_list() {
  _steam_resolve "${OPT_ROOT:-}" "${OPT_ACCOUNT:-}" || return 1
  _steam_backend
  local games cls ready=false phase running=false
  games=$(steam_games_json "$S_ROOT")
  cls=$(_vdf classify --env "$STEAM_ENV" --extras "$STEAM_EXTRAS" "$S_FILE")
  if jq -e --arg f "$S_FILE" '.[$f].error' <<<"$cls" >/dev/null 2>&1; then
    jq -c --arg f "$S_FILE" --arg a "$S_ACCOUNT" '.[$f] + {account: $a, file: $f}' <<<"$cls"
    return 1
  fi
  phase=$(_steam_phase)
  [[ $phase == ready ]] && ready=true
  steam_kind_running "$S_KIND" && running=true
  jq -cn --argjson games "$games" --argjson cls "$(jq -c --arg f "$S_FILE" '.[$f]' <<<"$cls")" \
    --argjson q "$(_steam_queue)" --arg root "$S_ROOT" --arg kind "$S_KIND" --arg acct "$S_ACCOUNT" \
    --argjson accts "$S_ACCOUNTS" --argjson ready "$ready" --arg phase "$phase" --argjson running "$running" \
    --arg backend "$STEAM_BACKEND" --argjson extras "$STEAM_EXTRAS" '
    ($q | map(select(.root == $root and .account == $acct)) | map({(.appid): .want}) | add // {}) as $pend |
    def shown($st; $p):
      if $p == "on" then "pending_on" elif $p == "off" then "pending_off"
      elif $st == "on" and ($ready | not) then "stale" else $st end;
    {root: $root, kind: $kind, account: $acct,
     persona: ([$accts[] | select(.accountid == $acct) | .persona][0] // null),
     backend: $backend, egpu_ready: $ready, egpu_phase: $phase, steam_running: $running,
     extras: [$extras[] | {id, label}],
     games: [$games[] | . as $g | ($cls.apps[$g.appid] // {state: "off", options: "",
                                     extras: ([$extras[] | {(.id): false}] | add // {})}) as $c |
       {appid: $g.appid, name: $g.name, library: $g.library,
        state: shown($c.state; $pend[$g.appid]), options: $c.options, extras: $c.extras}]}'
}

# Parses the common options; sets OPT_* and leaves the positionals in ARGS.
_steam_opts() {
  OPT_ROOT='' OPT_ACCOUNT='' OPT_QUEUE=0 OPT_NVAPI='' OPT_ADOPT=0 OPT_ONLY_STALE=0 OPT_CLOSE=0 OPT_RELAUNCH=0
  ARGS=()
  while (( $# )); do
    case $1 in
      --root) OPT_ROOT=${2:-}; shift ;;
      --account) OPT_ACCOUNT=${2:-}; shift ;;
      --queue) OPT_QUEUE=1 ;;
      --nvapi) OPT_NVAPI=${2:-}; shift ;;
      --adopt) OPT_ADOPT=1 ;;
      --only-stale) OPT_ONLY_STALE=1 ;;
      --close) OPT_CLOSE=1 ;;
      --relaunch) OPT_RELAUNCH=1 ;;
      --*) json_error usage "$(jq -cn --arg o "$1" '{detail: "unknown option", got: $o}')"; return 1 ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

# _steam_write_or_queue <changes json>: the shared tail of set and set-all.
_steam_write_or_queue() {
  local changes=$1 out rc
  _steam_lock || return $?
  if steam_kind_running "$S_KIND"; then
    if (( OPT_QUEUE )); then
      out=$(_steam_enqueue "$changes") || { printf '%s\n' "$out"; return 1; }
      jq -c '. + {queued: true, backup: null}' <<<"$out"
      return 0
    fi
    json_error steam_running "$(jq -cn --arg k "$S_KIND" \
      '{detail: "Steam rewrites localconfig.vdf when it exits, so it must be closed first.", kind: $k,
        options: ["steam apply --close --relaunch", "--queue"]}')"
    return 1
  fi
  out=$(_steam_apply_changes "$changes")
  rc=$?
  printf '%s\n' "$out" | jq -c '. + {queued: false}' 2>/dev/null || printf '%s\n' "$out"
  return $rc
}

steam_set() {
  local appid=${ARGS[0]:-} want=${ARGS[1]:-}
  if [[ ! $appid =~ ^[0-9]+$ || ! $want =~ ^(on|off)$ || ! ${OPT_NVAPI:-on} =~ ^(on|off)$ ]]; then
    json_error usage '{"detail":"steam set <appid> on|off [--nvapi on|off] [--adopt] [--account A] [--queue]"}'
    return 1
  fi
  _steam_resolve "$OPT_ROOT" "$OPT_ACCOUNT" || return 1
  _steam_backend
  if (( !STEAM_BACKEND_OK )); then
    json_error backend_stub "$(jq -cn --arg b "$STEAM_BACKEND" '{backend: $b}')"
    return 1
  fi
  local extras='{}' changes out rc res phase
  [[ -n $OPT_NVAPI ]] && extras=$(jq -cn --argjson v "$([[ $OPT_NVAPI == on ]] && echo true || echo false)" '{nvapi: $v}')
  changes=$(jq -cn --arg a "$appid" --arg w "$want" --argjson ad "$([[ $OPT_ADOPT == 1 ]] && echo true || echo false)" \
    --argjson x "$extras" '[{appid: $a, want: $w, adopt: $ad, extras: $x}]')
  out=$(_steam_write_or_queue "$changes")
  rc=$?
  if (( rc != 0 )) || jq -e '.error' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return $(( rc ? rc : 1 ))
  fi
  res=$(jq -c '.results[0]' <<<"$out")
  if jq -e '.error' <<<"$res" >/dev/null; then
    json_error "$(jq -r .error <<<"$res")" "$(jq -c --arg acct "$S_ACCOUNT" '{appid, account: $acct, state: .state_before, options: .before}' <<<"$res")"
    return 1
  fi
  # The §8.5 state the panel shows now: queued, stale or as written.
  phase=''
  [[ $(jq -r '.state_after' <<<"$res") == on ]] && phase=$(_steam_phase)
  jq -c --arg acct "$S_ACCOUNT" --arg root "$S_ROOT" --arg phase "$phase" --arg want "$want" '
    .results[0] as $r |
    {root: $root, account: $acct, appid: $r.appid, changed: $r.changed, queued: .queued,
     state: (if .queued and $r.changed then "pending_" + $want
             elif $r.state_after == "on" and $phase != "ready" then "stale"
             else $r.state_after end),
     options: $r.after, before: $r.before, backup: .backup}' <<<"$out"
}

steam_set_all() {
  local want=${ARGS[0]:-}
  if [[ ! $want =~ ^(on|off)$ ]]; then
    json_error usage '{"detail":"steam set-all on|off [--only-stale] [--account A] [--queue]"}'
    return 1
  fi
  _steam_resolve "$OPT_ROOT" "$OPT_ACCOUNT" || return 1
  _steam_backend
  if (( !STEAM_BACKEND_OK )); then
    json_error backend_stub "$(jq -cn --arg b "$STEAM_BACKEND" '{backend: $b}')"
    return 1
  fi
  local games cls changes skipped ready=true out rc
  games=$(steam_games_json "$S_ROOT")
  cls=$(_vdf classify --env "$STEAM_ENV" --extras "$STEAM_EXTRAS" "$S_FILE")
  if jq -e --arg f "$S_FILE" '.[$f].error' <<<"$cls" >/dev/null 2>&1; then
    jq -c --arg f "$S_FILE" '.[$f]' <<<"$cls"
    return 1
  fi
  if (( OPT_ONLY_STALE )); then
    [[ $(_steam_phase) == ready ]] || ready=false
  fi
  # Targets: listed games whose state the change applies to. manual and
  # modified are never touched in bulk; they are reported as skipped.
  local sel
  sel=$(jq -c --arg f "$S_FILE" --argjson games "$games" --arg want "$want" \
    --argjson only "$OPT_ONLY_STALE" --argjson ready "$ready" '
    .[$f].apps as $apps |
    [$games[] | . as $g | ($apps[$g.appid].state // "off") as $st |
      {appid: $g.appid, state: $st}] as $all |
    {changes: [$all[] | select(if $want == "on" then .state == "off"
                                else .state == "on" and (($only == 0) or ($ready | not)) end)
                     | {appid, want: $want}],
     skipped: [$all[] | select(.state == "manual" or .state == "modified")]}' <<<"$cls")
  changes=$(jq -c '.changes' <<<"$sel")
  skipped=$(jq -c '.skipped' <<<"$sel")
  if [[ $changes == '[]' ]]; then
    jq -cn --argjson s "$skipped" --arg a "$S_ACCOUNT" '{account: $a, changed: 0, queued: false, skipped: $s, backup: null}'
    return 0
  fi
  out=$(_steam_write_or_queue "$changes")
  rc=$?
  if (( rc != 0 )) || jq -e '.error' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return $(( rc ? rc : 1 ))
  fi
  jq -c --argjson s "$skipped" --arg a "$S_ACCOUNT" '
    {account: $a, changed: ([.results[] | select(.changed)] | length), queued: .queued,
     skipped: ($s + [.results[] | select(.error) | {appid, state: .state_before, error}]),
     backup: .backup}' <<<"$out"
}

# steam close for one install kind. Prints nothing; returns 1 with the error
# JSON on stdout.
_steam_close_kind() {
  local kind=$1 i limit
  steam_kind_running "$kind" || return 0
  if _steam_game_running; then
    json_error game_running '{"detail":"A game started by Steam is running. Quit it first."}'
    return 1
  fi
  if [[ $kind == flatpak ]]; then
    timeout 15 flatpak run "$STEAM_FLATPAK_APP" -shutdown >/dev/null 2>&1 </dev/null
  else
    timeout 15 steam -shutdown >/dev/null 2>&1 </dev/null
  fi
  limit=$(( ${EGPU_STEAM_CLOSE_TIMEOUT:-30} * 10 ))
  for ((i = 0; i < limit; i++)); do
    steam_kind_running "$kind" || return 0
    sleep 0.1
  done
  json_error steam_close_timeout "$(jq -cn --argjson s "${EGPU_STEAM_CLOSE_TIMEOUT:-30}" '{seconds: $s}')"
  return 1
}

# Reopen Steam detached from this process, as the desktop would.
_steam_relaunch_kind() {
  if [[ $1 == flatpak ]]; then
    (flatpak run "$STEAM_FLATPAK_APP" </dev/null >/dev/null 2>&1 &)
  elif command -v uwsm-app >/dev/null 2>&1; then
    (uwsm-app -- steam </dev/null >/dev/null 2>&1 &)
  else
    (steam </dev/null >/dev/null 2>&1 &)
  fi
}

steam_close() {
  _steam_resolve "$OPT_ROOT" "" || return 1
  local was=false
  steam_kind_running "$S_KIND" && was=true
  _steam_close_kind "$S_KIND" || return 1
  jq -cn --argjson w "$was" --arg k "$S_KIND" '{kind: $k, was_running: $w, closed: $w}'
}

steam_apply() {
  local q n
  q=$(_steam_queue)
  n=$(jq 'length' <<<"$q")
  if (( n == 0 )); then
    echo '{"applied":0,"failed":[],"closed":false,"relaunched":false}'
    return 0
  fi
  _steam_lock || return $?
  # The installs the queue touches, and which of them run.
  local kinds=() roots kind root was_running=() closed=false
  mapfile -t roots < <(jq -r 'map(.root) | unique[]' <<<"$q")
  for root in "${roots[@]}"; do
    kind=$(_steam_root_kind "$root") || continue
    [[ " ${kinds[*]} " == *" $kind "* ]] || kinds+=("$kind")
  done
  for kind in "${kinds[@]}"; do
    steam_kind_running "$kind" || continue
    if (( !OPT_CLOSE )); then
      json_error steam_running '{"detail":"Steam is running; the queue stays until it closes.","queued":true}'
      return 1
    fi
    was_running+=("$kind")
  done
  for kind in "${was_running[@]}"; do
    _steam_close_kind "$kind" || return 1
    closed=true
  done

  local applied=0 failed='[]' acct changes out rc
  while IFS=$'\t' read -r root acct; do
    [[ -n $root ]] || continue
    if ! _steam_resolve "$root" "$acct" >/dev/null; then
      failed=$(jq -c --argjson q "$q" --arg r "$root" --arg a "$acct" \
        '. + [$q[] | select(.root == $r and .account == $a) | {appid, account, error: "account_not_found"}]' <<<"$failed")
      _steam_queue_write "$(jq -c --arg r "$root" --arg a "$acct" 'map(select((.root == $r and .account == $a) | not))' <<<"$(_steam_queue)")"
      continue
    fi
    _steam_backend
    changes=$(jq -c --arg r "$root" --arg a "$acct" \
      '[.[] | select(.root == $r and .account == $a) | {appid, want, adopt, extras}]' <<<"$q")
    out=$(_steam_apply_changes "$changes")
    rc=$?
    if (( rc != 0 )); then
      # steam_running (Steam came back): abort and keep the queue (§8.4).
      printf '%s\n' "$out"
      return 1
    fi
    applied=$(( applied + $(jq '.changed' <<<"$out") ))
    failed=$(jq -c --argjson o "$out" --arg a "$acct" '. + [$o.results[] | select(.error) | {appid, account: $a, error}]' <<<"$failed")
    # Entries that failed or were already in place leave the queue too.
    _steam_queue_drop "$root" "$acct" "$(jq -c '[.results[].appid]' <<<"$out")"
  done < <(jq -r 'map("\(.root)\t\(.account)") | unique[]' <<<"$q")

  local relaunched=false
  if (( OPT_RELAUNCH )); then
    for kind in "${was_running[@]}"; do
      _steam_relaunch_kind "$kind"
      relaunched=true
    done
  fi
  jq -cn --argjson n "$applied" --argjson f "$failed" --argjson c "$closed" --argjson r "$relaunched" \
    '{applied: $n, failed: $f, closed: $c, relaunched: $r}'
}

steam_restore() {
  local acct=${ARGS[0]:-} bk=${ARGS[1]:-} dir path real out backup
  if [[ ! $acct =~ ^[0-9]+$ || -z $bk ]]; then
    json_error usage '{"detail":"steam restore <accountid> <backup>"}'
    return 1
  fi
  _steam_resolve "$OPT_ROOT" "$acct" || return 1
  dir="$STEAM_BACKUPS/$acct"
  if [[ $bk == */* ]]; then path=$bk; else path="$dir/$bk"; fi
  real=$(realpath -e -- "$path" 2>/dev/null)
  if [[ -z $real || $(dirname -- "$real") != "$(realpath -- "$dir" 2>/dev/null)" || ${real##*/} != localconfig-*.vdf ]]; then
    json_error backup_failed "$(jq -cn --arg b "$bk" '{detail: "Not a backup of this account.", backup: $b}')"
    return 1
  fi
  _steam_lock || return $?
  if steam_kind_running "$S_KIND"; then
    json_error steam_running '{"detail":"Close Steam first."}'
    return 1
  fi
  out=$(_vdf stage --from "$real" --file "$S_FILE") || { printf '%s\n' "$out"; return 1; }
  backup=$(_steam_commit "$(jq -r .tmp <<<"$out")" "$(jq -r .sha256 <<<"$out")") || { printf '%s\n' "$backup"; return 1; }
  # What the engine recorded no longer describes the file.
  _steam_backend
  _steam_state_save "$acct" '{}'
  jq -cn --arg r "$real" --arg b "$backup" --arg a "$acct" '{account: $a, restored: $r, backup: $b}'
}

steam_status_verb() {
  local roots def='null' q
  roots=$(steam_roots_verb)
  if _steam_resolve "" "" >/dev/null 2>&1; then
    def=$(jq -cn --arg r "$S_ROOT" --arg a "$S_ACCOUNT" '{root: $r, account: $a}')
  fi
  q=$(_steam_queue)
  jq -cn --argjson roots "$roots" --argjson def "$def" --argjson q "$q" \
    '{roots: $roots, running: any($roots[]; .running), default: $def, pending: $q}'
}

# ---------------------------------------------------------------- health

# steam_health_rows: the steam.* rows of §9, one JSON object per line.
steam_health_rows() {
  local roots
  roots=$(steam_roots_tsv)
  local q n
  q=$(_steam_queue)
  n=$(jq 'length' <<<"$q")
  if (( n )); then
    health_row steam.pending steam info "$n Steam change(s) waiting for Steam to close" \
      "They apply when Steam is closed, or now with Close Steam and apply." user "omarchy-egpu steam apply --close --relaunch"
  else
    health_row steam.pending steam ok "No queued Steam changes" ""
  fi
  if [[ -z $roots ]]; then
    health_row steam.options steam skipped "Steam launch options" "Steam is not installed." none ""
    health_row steam.stale steam skipped "Games set to the eGPU" "Steam is not installed." none ""
    return 0
  fi
  _steam_backend
  local files=() kind root d
  while IFS=$'\t' read -r kind root; do
    for d in "$root"/userdata/*/config/localconfig.vdf; do
      [[ -r $d ]] && files+=("$d")
    done
  done <<<"$roots"
  local cls='{}'
  (( ${#files[@]} )) && cls=$(_vdf classify --env "$STEAM_ENV" --extras "$STEAM_EXTRAS" "${files[@]}")
  local sum
  sum=$(jq -c '
    to_entries |
    {broken: [.[] | select(.value.error) | .key],
     on: [.[] | .value.apps? // {} | to_entries[] | select(.value.state == "on") | .key] ,
     manual: [.[] | .value.apps? // {} | to_entries[] | select(.value.state == "manual") | .key],
     modified: [.[] | .value.apps? // {} | to_entries[] | select(.value.state == "modified") | .key]}' <<<"$cls")
  local broken on manual modified
  broken=$(jq -r '.broken | map(sub("^.*/userdata/"; "") | sub("/config/localconfig.vdf$"; "")) | join(", ")' <<<"$sum")
  on=$(jq '.on | length' <<<"$sum")
  manual=$(jq -r '.manual | unique | join(", ")' <<<"$sum")
  modified=$(jq -r '.modified | unique | join(", ")' <<<"$sum")
  if [[ -n $broken ]]; then
    health_row steam.options steam warn "A localconfig.vdf does not parse" \
      "Account(s) $broken: the eGPU switch is unavailable there. Steam rewrites the file when it next exits; a backup can be restored with omarchy-egpu steam restore." none ""
  elif [[ -n $modified ]]; then
    health_row steam.options steam warn "Edited by hand: app(s) $modified" \
      "The eGPU options of these games were changed outside the panel, so they are left alone. Use Show options in the Games view.${manual:+ Manual GPU options: $manual.}" none ""
  elif [[ -n $manual ]]; then
    health_row steam.options steam info "Manual GPU options: app(s) $manual" \
      "These games set the eGPU variables without the panel's marker. Adopt them in the Games view to manage them here." none ""
  else
    health_row steam.options steam ok "Steam launch options are well formed" "$on game(s) set to the eGPU."
  fi
  if (( on == 0 )); then
    health_row steam.stale steam ok "No game is set to the eGPU" ""
  elif [[ $(_steam_phase) == ready ]]; then
    health_row steam.stale steam ok "$on game(s) set to the eGPU, which is ready" ""
  else
    health_row steam.stale steam info "$on game(s) set to the eGPU while it is not connected" \
      "Vulkan and Proton games should still start on the laptop GPU; native OpenGL games may not (plan §8.6, unverified until E6c)." \
      user "omarchy-egpu steam set-all off --only-stale"
  fi
  if grep -q '^flatpak' <<<"$roots"; then
    _steam_health_flatpak_gl
  fi
}

# steam.flatpak_gl: Flatpak Steam needs the GL extension matching the host
# driver. The backend names it (be_flatpak_gl_ext); a backend without one
# needs nothing.
_steam_health_flatpak_gl() {
  local want have
  if ! declare -F be_flatpak_gl_ext >/dev/null; then
    health_row steam.flatpak_gl steam ok "Flatpak Steam: no GL extension needed" "Backend ${STEAM_BACKEND:-none}."
    return
  fi
  if ! command -v flatpak >/dev/null 2>&1; then
    health_row steam.flatpak_gl steam skipped "Flatpak GL extension" "flatpak is not installed." none ""
    return
  fi
  have=$(timeout 10 flatpak list --runtime --columns=application 2>/dev/null)
  want=$(be_flatpak_gl_ext)
  if [[ -z $want ]]; then
    local any
    any=$(grep -E "^$(be_flatpak_gl_ext --prefix | sed 's/\./\\./g')" <<<"$have" | paste -sd' ')
    if [[ -n $any ]]; then
      health_row steam.flatpak_gl steam info "Flatpak GL extension: $any" \
        "The driver version is read once the driver is loaded; it must match the extension." none ""
    else
      health_row steam.flatpak_gl steam warn "Flatpak Steam has no NVIDIA GL extension" \
        "Install the one matching the host driver: flatpak install flathub $(be_flatpak_gl_ext --prefix)<version>" none "Instructions"
    fi
  elif grep -qxF "$want" <<<"$have"; then
    health_row steam.flatpak_gl steam ok "Flatpak GL extension $want installed" ""
  else
    health_row steam.flatpak_gl steam warn "Flatpak Steam lacks $want" \
      "Games in Flatpak Steam cannot use the eGPU without it: flatpak install flathub $want" none "Instructions"
  fi
}

# ---------------------------------------------------------------- dispatch

steam_main() {
  local verb=${1:-}
  [[ $# -gt 0 ]] && shift
  _steam_opts "$@" || return 1
  mkdir -p -- "$EGPU_STATE" 2>/dev/null
  case $verb in
    roots) steam_roots_verb ;;
    accounts) steam_accounts_verb ;;
    list) steam_list ;;
    set) steam_set ;;
    set-all) steam_set_all ;;
    apply) steam_apply ;;
    close) steam_close ;;
    restore) steam_restore ;;
    status) steam_status_verb ;;
    *)
      json_error usage '{"detail":"steam roots|accounts|list|set|set-all|apply|close|restore|status"}'
      return 1
      ;;
  esac
}
