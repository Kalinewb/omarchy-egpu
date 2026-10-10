#!/bin/bash

# status.sh — module: status, watch. plan-engine.md §5.
#
#   omarchy-egpu status [--json|--human]   one document, computed fresh
#   omarchy-egpu status watch              JSON lines: status records + events
#
# The document is the contract with the panel, the notch integration and any
# script (tests/schema/status-1.json). `phase` comes only from sysfs and bolt,
# never from what the engine last did; the exceptions are `ejecting` (the eject
# job's lock) and `ejected` (the marker the eject job leaves while the
# enclosure stays connected). `summary` is computed here so no shell derives
# state on its own (REVISION 4).
#
# Read-only apart from $EGPU_RUN (status.json, the watcher lock) and
# $EGPU_STATE/enclosures (which Thunderbolt devices had an eGPU behind them).

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=lib/health.sh
source "$EGPU_LIB/health.sh"

STATUS_SCHEMA=1

declare -gA _pci_name_cache=()

# The human name of a PCI function from lspci, cached per BDF for the life of
# the process. lspci reads config space, which wakes a runtime-suspended
# device, so it is asked once, not on every heartbeat.
_pci_name() {
  local bdf=$1 out v d
  if [[ -n ${_pci_name_cache[$bdf]+x} ]]; then
    printf '%s\n' "${_pci_name_cache[$bdf]}"
    return 0
  fi
  out=$(timeout 3 lspci -vmm -s "$bdf" 2>/dev/null)
  v=$(sed -n 's/^Vendor:[[:space:]]*//p' <<<"$out" | head -n1)
  d=$(sed -n 's/^Device:[[:space:]]*//p' <<<"$out" | head -n1)
  _pci_name_cache[$bdf]=$(printf '%s %s' "$v" "$d" | sed 's/^ *//; s/ *$//')
  printf '%s\n' "${_pci_name_cache[$bdf]}"
}

# Is the eject job running? It holds $EGPU_RUN/lock and names itself in
# $EGPU_RUN/job (device.sh, phase E5).
_ejecting() {
  [[ -e $EGPU_RUN/lock && $(read_attr "$EGPU_RUN/job") == eject ]] || return 1
  ! flock -n "$EGPU_RUN/lock" true 2>/dev/null
}

# Hyprland's monitor names (enabled or not), one per line.
_compositor_monitor_names() {
  timeout 3 hyprctl monitors all -j 2>/dev/null | jq -r '.[]?.name // empty' 2>/dev/null
}

# The last event, from a watcher's status.json, for one-shot callers.
_last_event_from_file() {
  jq -c '.last_event // null' "$EGPU_RUN/status.json" 2>/dev/null || echo null
}

# The watcher's recent events, likewise. A reader of the file sees one
# document per debounce, and one recompute can raise several events (a
# yank is monitor_removed, yanked, unplugged at once), so last_event alone
# loses all but the last of them. Additive (§5.1; plan-engine.md E9).
_recent_events_from_file() {
  jq -c '.recent_events // [] | if type == "array" then .[-8:] else [] end' "$EGPU_RUN/status.json" 2>/dev/null || echo '[]'
}

# status_collect [health_summary_json] [last_event_json] [seq] [recent_events_json]
# Prints the §5 document. With no health summary it runs the health checks.
status_collect() {
  local health=${1:-} last_event=${2:-} seq=${3:-0} recent=${4:-}

  # ---- bolt
  local devices daemon=false domain=false
  if devices=$(bolt_devices); then daemon=true; else devices='[]'; fi
  # Whether this machine has a Thunderbolt/USB4 domain at all, which `daemon`
  # cannot say: boltd down and no controller both read daemon=false. The
  # notch integration declines on a machine with none (plan-gui.md §7.2).
  compgen -G "$EGPU_SYS/bus/thunderbolt/devices/domain*" >/dev/null && domain=true

  # ---- PCI
  local bdf
  bdf=$(pci_egpu_candidates | head -n1)

  # ---- which bolt device is the enclosure
  # Connected and matched by a profile or remembered first; then, with a GPU
  # present, the only authorized device; then any device waiting for
  # authorization. Stored but disconnected matched/remembered devices are
  # reported with present=false so the panel can still name the enclosure.
  local bolt='null' n i dev uuid status name vendor profile pick_rank best_rank=99
  n=$(jq 'length' <<<"$devices")
  local authorized_count
  authorized_count=$(jq '[.[] | select(.status == "authorized")] | length' <<<"$devices")
  for ((i = 0; i < n; i++)); do
    dev=$(jq -c ".[$i]" <<<"$devices")
    uuid=$(jq -r '.uuid' <<<"$dev")
    status=$(jq -r '.status' <<<"$dev")
    name=$(jq -r '.name' <<<"$dev")
    vendor=$(jq -r '.vendor' <<<"$dev")
    profile=$(profile_match "$vendor" "$name")
    pick_rank=99
    if bolt_connected_status "$status"; then
      if [[ $profile != generic ]] || enclosure_known "$uuid"; then
        pick_rank=0
      elif [[ -n $bdf && $status == authorized && $authorized_count == 1 ]]; then
        pick_rank=1
      elif [[ $status != authorized ]]; then
        pick_rank=2
      fi
    elif [[ $profile != generic ]] || enclosure_known "$uuid"; then
      pick_rank=3
    fi
    if (( pick_rank < best_rank )); then
      best_rank=$pick_rank
      bolt=$(jq -c --arg p "$profile" --argjson present "$(bolt_connected_status "$status" && echo true || echo false)" \
        '. + {present: $present, profile: $p}' <<<"$dev")
    fi
  done
  local bolt_present=false bolt_status='' bolt_uuid='' bolt_profile=generic
  if [[ $bolt != null ]]; then
    bolt_present=$(jq -r '.present' <<<"$bolt")
    bolt_status=$(jq -r '.status' <<<"$bolt")
    bolt_uuid=$(jq -r '.uuid' <<<"$bolt")
    bolt_profile=$(jq -r '.profile' <<<"$bolt")
  fi
  # A GPU behind exactly one authorized enclosure: remember it, so the same
  # enclosure without its GPU later reads as "authorized, no PCI device".
  [[ -n $bdf && $best_rank == 1 ]] && enclosure_remember "$bolt_uuid"

  # ---- backend, driver, gpu
  local backend='' be_status=stub driver='' modules='{}' kms='{"modeset":null,"fbdev":null}'
  local gpu='{"ok":false}' all_loaded=false
  if [[ -n $bdf ]]; then
    driver=$(pci_driver "$bdf")
    if backend_select "$bdf"; then
      backend=$EGPU_BACKEND
      be_status=$BE_STATUS
      if [[ $be_status == implemented ]]; then
        local m mods_json='{}'
        all_loaded=true
        while IFS= read -r m; do
          [[ -n $m ]] || continue
          if module_loaded "$m"; then
            mods_json=$(jq -c --arg m "$m" '. + {($m): true}' <<<"$mods_json")
          else
            mods_json=$(jq -c --arg m "$m" '. + {($m): false}' <<<"$mods_json")
            all_loaded=false
          fi
        done < <(be_kms_modules)
        modules=$mods_json
        kms=$(be_kms_params)
        if [[ -n $driver ]]; then
          gpu=$(be_verify "$bdf") || gpu='{"ok":false}'
        fi
      else
        gpu='{"ok":false,"error":"backend_stub"}'
      fi
    else
      backend=''
    fi
  fi
  local gpu_ok gpu_error
  gpu_ok=$(jq -r '.ok // false' <<<"$gpu")
  gpu_error=$(jq -r '.error // ""' <<<"$gpu")

  # ---- phase
  local phase marker_uuid
  if _ejecting; then
    phase=ejecting
  elif [[ $bolt_status == auth-error ]]; then
    phase=error
  elif [[ -n $bdf ]]; then
    if [[ -z $driver ]]; then
      phase=authorized
    elif [[ $gpu_error == smi_hung ]]; then
      phase=error
    elif [[ $be_status == implemented && $gpu_ok == true && $all_loaded == true ]]; then
      phase=ready
    else
      phase=bound
    fi
  elif [[ $bolt_present == true ]]; then
    marker_uuid=$(jq -r '.uuid // ""' "$EGPU_RUN/ejected" 2>/dev/null)
    if [[ $bolt_status == authorized && -n $marker_uuid && $marker_uuid == "$bolt_uuid" ]]; then
      phase=ejected
    elif [[ $bolt_status == authorized ]]; then
      phase=authorized
    else
      phase=plugged
    fi
  else
    phase=absent
  fi

  # ---- held_after_eject: an unloadable backend's modules are loaded while no
  # device that backend drives exists at all (O2).
  local held=false b any_dev d m2
  if [[ -z $bdf ]]; then
    while IFS= read -r b; do
      [[ -n $b ]] || continue
      backend_load "$b" || continue
      any_dev=0
      while IFS= read -r d; do
        [[ -n $d ]] && be_detect "$d" && { any_dev=1; break; }
      done < <(pci_display_functions)
      (( any_dev )) && continue
      while IFS= read -r m2; do
        [[ -n $m2 ]] && module_loaded "$m2" && { held=true; break; }
      done < <(be_kms_modules)
    done < <(backends_unloadable)
  fi

  # ---- PCI block
  local pci='{"present":false,"bdf":null,"functions":[],"vendor":null,"device":null,"name":null,"removable":false,"link":null}'
  if [[ -n $bdf ]]; then
    pci=$(jq -cn --arg bdf "$bdf" \
      --argjson fns "$(pci_slot_functions "$bdf" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      --arg vendor "$(pci_attr "$bdf" vendor)" --arg device "$(pci_attr "$bdf" device)" \
      --arg name "$(_pci_name "$bdf")" \
      --arg speed "$(pci_attr "$bdf" current_link_speed)" --arg width "$(pci_attr "$bdf" current_link_width)" \
      --arg mspeed "$(pci_attr "$bdf" max_link_speed)" --arg mwidth "$(pci_attr "$bdf" max_link_width)" '
      def n: if . == "" then null else . end;
      {present: true, bdf: $bdf, functions: $fns, vendor: ($vendor | n), device: ($device | n),
       name: ($name | n), removable: true,
       link: (if $speed == "" then null else
         {speed: $speed, width: ($width | n), max_speed: ($mspeed | n), max_width: ($mwidth | n)} end)}')
  fi

  # ---- DRM and the compositor
  local card='' bypath='' link='' comp_pid comp_has=null
  comp_pid=$(compositor_pid)
  if [[ -n $bdf ]]; then
    card=$(pci_drm_card "$bdf")
    bypath=$(drm_bypath_for "$bdf")
    [[ -e $EGPU_DEV/dri/omarchy-egpu-external || -L $EGPU_DEV/dri/omarchy-egpu-external ]] &&
      link=/dev/dri/omarchy-egpu-external
    if [[ -n $comp_pid && -n $card ]]; then
      # Captured first: with pipefail, grep -q closing the pipe early would
      # turn a match into a failure.
      local open_nodes
      open_nodes=$(proc_open_dri "$comp_pid")
      if grep -qxF -- "$card" <<<"$open_nodes"; then comp_has=true; else comp_has=false; fi
    elif [[ -n $comp_pid ]]; then
      comp_has=false
    fi
  fi

  # ---- display: connectors on the eGPU card (kernel view). E4 adds the
  # Hyprland side (names, descriptions, workspaces) to each entry.
  local monitors='[]' needs_relogin=false
  if [[ -n $card && -d $EGPU_PCI/$bdf/drm/$card ]]; then
    local hypr_names='' c cname cstatus cenabled in_comp any_connected=0 any_in_comp=0
    [[ -n $comp_pid ]] && hypr_names=$(_compositor_monitor_names)
    local mons=()
    for c in "$EGPU_PCI/$bdf/drm/$card/$card"-*; do
      [[ -r $c/status ]] || continue
      cname=${c##*/}
      cname=${cname#"$card"-}
      cstatus=$(read_attr "$c/status")
      cenabled=$(read_attr "$c/enabled")
      in_comp=false
      if [[ -n $hypr_names ]] && grep -qxF -- "$cname" <<<"$hypr_names"; then in_comp=true; any_in_comp=1; fi
      [[ $cstatus == connected ]] && any_connected=1
      mons+=("$(jq -cn --arg c "$cname" --arg card "$card" --arg s "$cstatus" --arg e "$cenabled" --argjson ic "$in_comp" \
        '{connector: $c, card: $card, status: $s, enabled: ($e == "enabled"), in_compositor: $ic}')")
    done
    (( ${#mons[@]} )) && monitors=$(printf '%s\n' "${mons[@]}" | jq -s -c '.')
    # O1 fallback: a connected monitor on the eGPU that Hyprland does not list,
    # once the card node is older than the grace period (5 s after connect).
    if [[ -n $comp_pid && ($phase == ready || $phase == bound) ]] && (( any_connected && !any_in_comp )); then
      local mt age grace=${EGPU_RELOGIN_GRACE_S:-5}
      mt=$(stat -c %Y -- "$EGPU_DEV/dri/$card" 2>/dev/null || echo 0)
      age=$(( $(date +%s) - mt ))
      (( age >= grace )) && needs_relogin=true
    fi
  fi

  # ---- steam (native processes, or Flatpak Steam when a Flatpak root exists)
  local steam_running=false
  steam_any_running && steam_running=true

  # ---- hints from the enclosure profile
  local conds=()
  [[ $phase == authorized && -z $bdf ]] && conds+=(authorized_no_pci)
  [[ $phase == plugged ]] && conds+=(plugged_unauthorized)
  [[ $needs_relogin == true ]] && conds+=(needs_relogin)
  [[ $held == true ]] && conds+=(held_after_eject)
  [[ $gpu_error == smi_hung ]] && conds+=(smi_hung)
  local hints='[]'
  if (( ${#conds[@]} )); then
    hints=$(profile_json "$bolt_profile" | jq -c --args '
      [ (.hints // [])[] | select(.when as $w | $ARGS.positional | index($w)) |
        {id: .when, text: .text} ]' "${conds[@]}")
  fi

  # ---- health summary. The steam rows read the phase from here instead of
  # running status again.
  EGPU_STATUS_PHASE=$phase
  if [[ -z $health ]]; then
    health=$(health_rows | jq -c '{errors: map(select(.level == "error")) | length,
                                   warnings: map(select(.level == "warn")) | length}')
  fi
  [[ -n $last_event ]] || last_event=$(_last_event_from_file)
  [[ -n $recent ]] || recent=$(_recent_events_from_file)

  jq -cn \
    --argjson schema "$STATUS_SCHEMA" --argjson seq "$seq" --argjson at "$(now_ms)" \
    --arg phase "$phase" --argjson bolt "$bolt" --argjson daemon "$daemon" \
    --argjson pci "$pci" --arg backend "$backend" --arg be_status "$be_status" \
    --arg driver "$driver" --argjson modules "$modules" --argjson kms "$kms" --argjson gpu "$gpu" \
    --arg card "$card" --arg bypath "$bypath" --arg link "$link" --argjson comp "$comp_has" \
    --argjson monitors "$monitors" --argjson relogin "$needs_relogin" --argjson held "$held" \
    --argjson steam "$steam_running" --argjson hints "$hints" --argjson health "$health" \
    --argjson last_event "$last_event" --argjson recent "$recent" --argjson domain "$domain" '
    def n: if . == "" then null else . end;
    {schema: $schema, seq: $seq, written_at: $at,
     summary: null,
     phase: $phase,
     bolt: (if $bolt == null
            then {present: false, daemon: $daemon, domain: $domain, uuid: null, name: null, vendor: null,
                  status: null, policy: null, stored: false, generation: null, profile: null}
            else {present: $bolt.present, daemon: $daemon, domain: $domain, uuid: $bolt.uuid, name: $bolt.name,
                  vendor: $bolt.vendor, status: $bolt.status, policy: $bolt.policy,
                  stored: $bolt.stored, generation: $bolt.generation, profile: $bolt.profile} end),
     pci: $pci,
     backend: {name: ($backend | n), supported: ($backend != "" and $be_status == "implemented")},
     driver: {bound: ($driver | n), modules: $modules, modeset: $kms.modeset, fbdev: $kms.fbdev},
     gpu: ({ok: false, name: null, version: null, temp_c: null, util_pct: null, mem_used_mb: null, procs: []} + $gpu),
     drm: {card: ($card | n), card_bypath: ($bypath | n), link: ($link | n), compositor_has_card: $comp},
     display: {monitors: $monitors, needs_relogin: $relogin},
     modules: {held_after_eject: $held},
     steam: {running: $steam},
     hints: $hints,
     health_summary: $health,
     last_event: $last_event,
     recent_events: $recent}
    | .summary = (
        . as $s
        | ($s.gpu.procs | length) as $np
        | ([$s.display.monitors[] | select(.enabled)] | length) as $nmon
        | ($s.phase | IN("plugged", "authorized", "bound", "ready")) as $present
        | ($s.backend.name != null and ($s.backend.supported | not)) as $unsupported
        | (if $nmon > 0 then " · HDMI on" else "" end) as $hdmi
        | if $s.phase == "error" then
            {state: "error", needs_action: true,
             line: (if $s.gpu.error == "smi_hung" then "eGPU error · the driver is not answering (nvidia-smi hung); log out or reboot"
                    elif $s.bolt.status == "auth-error" then "eGPU error · Thunderbolt authorization failed"
                    else "eGPU error" end)}
          elif $s.phase == "ejecting" then {state: "ejecting", needs_action: false, line: "Ejecting…"}
          elif $s.display.needs_relogin then
            {state: "attention", needs_action: true, line: "eGPU ready · log out to use the HDMI monitor"}
          elif $s.modules.held_after_eject then
            {state: "attention", needs_action: true,
             line: (if $s.phase == "ejected" then "Safe to unplug · log out before plugging it in again"
                    else "Log out before plugging the eGPU in again" end)}
          elif $present and $unsupported then
            {state: "attention", needs_action: true,
             line: "eGPU detected (\($s.backend.name)) · not supported yet"}
          elif $present and $s.health_summary.errors > 0 then
            {state: "attention", needs_action: true,
             line: ((if $s.phase == "ready" then "eGPU ready" else "eGPU connecting" end)
                    + " · check setup (\($s.health_summary.errors) problem"
                    + (if $s.health_summary.errors == 1 then "" else "s" end) + ")")}
          elif $s.phase == "ejected" then {state: "safe_to_unplug", needs_action: false, line: "Safe to unplug"}
          elif $s.phase == "plugged" then
            {state: "connecting", needs_action: ($s.bolt.status == "connected"),
             line: (if $s.bolt.status == "connected"
                    then "\($s.bolt.name // "Thunderbolt device") needs authorizing"
                    else "eGPU plugged in · connecting…" end)}
          elif $s.phase == "authorized" then
            {state: "connecting", needs_action: ($s.pci.present | not),
             line: (if $s.pci.present then "Connecting… waiting for the driver" else "Connecting… no GPU visible yet" end)}
          elif $s.phase == "bound" then {state: "connecting", needs_action: false, line: "Connecting… loading the driver"}
          elif $s.phase == "ready" then
            (if $np > 0 or $nmon > 0 then
               {state: "in_use", needs_action: false,
                line: ("eGPU in use" + (if $np > 0 then " · \($np) app" + (if $np == 1 then "" else "s" end) else "" end) + $hdmi)}
             else {state: "ready", needs_action: false, line: "eGPU ready · eject before unplugging"} end)
          else {state: "absent", needs_action: false, line: "No eGPU"} end)'
}

# ---------------------------------------------------------------- one-shot

status_human() {
  jq -r '
    "\(.summary.line)",
    "  phase      \(.phase)  (summary: \(.summary.state))",
    "  enclosure  \(if .bolt.name then "\(.bolt.vendor) \(.bolt.name), \(.bolt.status), policy \(.bolt.policy // "-"), profile \(.bolt.profile)" else "none" end)",
    "  pci        \(if .pci.present then "\(.pci.bdf) \(.pci.name // "") link \(.pci.link.speed // "?") x\(.pci.link.width // "?")" else "none" end)",
    "  backend    \(.backend.name // "-")\(if .backend.name and (.backend.supported | not) then " (stub)" else "" end), driver \(.driver.bound // "-")",
    (if .gpu.ok then "  gpu        \(.gpu.name), \(.gpu.temp_c)°C, \(.gpu.util_pct)%, \(.gpu.mem_used_mb) MiB, \(.gpu.procs | length) procs" else empty end),
    (if (.display.monitors | length) > 0 then "  monitors   " + ([.display.monitors[] | "\(.connector) \(.status)\(if .enabled then " on" else "" end)"] | join(", ")) else empty end),
    (.hints[] | "  hint       \(.text)"),
    "  health     \(.health_summary.errors) errors, \(.health_summary.warnings) warnings (omarchy-egpu health)"'
}

# ---------------------------------------------------------------- watch

# The state that matters for "did anything change": everything but the
# record's own bookkeeping.
_status_key() { jq -c 'del(.seq, .written_at, .last_event, .recent_events)' <<<"$1"; }

_phase_rank() {
  case $1 in
    absent) echo 0 ;; plugged) echo 1 ;; authorized) echo 2 ;; bound) echo 3 ;; ready) echo 4 ;;
    *) echo -1 ;;
  esac
}

# _status_events <prev-doc> <new-doc>: event names, in order, with detail JSON
# ("name<TAB>detail"). Derived only from the two documents, so a missed
# intermediate state still yields the steps in between.
_status_events() {
  local prev=$1 cur=$2 p c pr cr
  p=$(jq -r '.phase' <<<"$prev")
  c=$(jq -r '.phase' <<<"$cur")
  pr=$(_phase_rank "$p")
  cr=$(_phase_rank "$c")

  # Monitors that went away come first, so "unplugged" is the last word.
  jq -r --argjson prev "$prev" '
    ([$prev.display.monitors[] | select(.status == "connected") | .connector]) as $was
    | ([.display.monitors[] | select(.status == "connected") | .connector]) as $now
    | ($was - $now)[] | "monitor_removed\t" + ({connector: .} | tojson)' <<<"$cur"

  if [[ $p != "$c" ]]; then
    case $c in
      ejecting) printf 'eject_started\t{}\n' ;;
      ejected) [[ $p == ejecting ]] && printf 'eject_ready\t{}\n' || printf 'eject_ready\t{"external":true}\n' ;;
    esac
    # The GPU vanished while bound, without an eject: yanked. The enclosure
    # may still be listed by bolt for a moment, so this does not wait for
    # `absent`.
    if [[ ($p == ready || $p == bound) && $c != ejecting && $c != ejected ]] &&
      [[ $(jq -r '.pci.present' <<<"$cur") != true ]]; then
      printf 'yanked\t%s\n' "$(jq -cn --arg from "$p" '{from: $from}')"
    fi
    if [[ $c == absent && $p != absent ]]; then
      printf 'unplugged\t%s\n' "$(jq -cn --arg from "$p" '{from: $from}')"
    fi
    if [[ $p == ejecting && ($c == ready || $c == bound) ]]; then
      printf 'eject_failed\t{}\n'
    fi
    # Forward through absent → plugged → authorized → ready, emitting skipped
    # steps too. Leaving `ejected` for the same enclosure is a rescan, not a
    # new plug-in.
    if (( cr > pr )); then
      local from=$pr
      [[ $p == ejected || $p == ejecting || $p == error ]] && from=2
      (( from < 1 && cr >= 1 )) && printf 'plugged\t%s\n' "$(jq -c '{name: .bolt.name, profile: .bolt.profile}' <<<"$cur")"
      (( from < 2 && cr >= 2 )) && printf 'authorized\t{}\n'
      (( cr == 4 )) && printf 'ready\t%s\n' "$(jq -c '{bdf: .pci.bdf, name: .gpu.name}' <<<"$cur")"
    fi
  fi

  jq -r --argjson prev "$prev" '
    ([$prev.display.monitors[] | select(.status == "connected") | .connector]) as $was
    | ([.display.monitors[] | select(.status == "connected") | .connector]) as $now
    | ($now - $was)[] | "monitor_added\t" + ({connector: .} | tojson)' <<<"$cur"

  if [[ $(jq -r '.display.needs_relogin' <<<"$prev") != true && $(jq -r '.display.needs_relogin' <<<"$cur") == true ]]; then
    printf 'relogin_needed\t{}\n'
  fi
}

# status_watch: one per session (flock on $EGPU_RUN/watch.lock; a second
# instance exits 3). Inputs: udevadm, boltctl monitor and Hyprland's event
# socket, each only marking the state dirty; the state itself is always
# re-read from sysfs and bolt. Debounced 300 ms (capped at 1 s of continuous
# input). The status file is rewritten atomically after every record and at
# least every 5 s as a heartbeat; while `ready` the gpu block is refreshed
# every 2 s.
status_watch() {
  local debounce_ms=${EGPU_DEBOUNCE_MS:-300} heartbeat_ms=$(( ${EGPU_HEARTBEAT_S:-5} * 1000 ))
  local gpu_ms=${EGPU_GPU_REFRESH_MS:-2000} health_ms=${EGPU_HEALTH_REFRESH_MS:-60000}
  mkdir -p -- "$EGPU_RUN" || { json_error busy '{"detail":"cannot create runtime dir"}'; return 1; }
  # The first health run comes before the first status: the steam rows must
  # not start a nested `status` for the phase (steam.stale is info only).
  EGPU_STATUS_PHASE=${EGPU_STATUS_PHASE:-unknown}

  local lockfd
  exec {lockfd}>>"$EGPU_RUN/watch.lock"
  if ! flock -n "$lockfd"; then
    json_error busy '{"detail":"another status watch is running"}'
    return 3
  fi

  # Globals, so the EXIT trap still sees them after the function unwinds.
  _WATCH_FIFO="$EGPU_RUN/.watch.$$.fifo"
  _WATCH_PRODUCERS=()
  local infd
  rm -f -- "$_WATCH_FIFO"
  mkfifo -m 600 -- "$_WATCH_FIFO" || return 1
  exec {infd}<>"$_WATCH_FIFO"
  trap '_watch_cleanup' EXIT
  trap 'exit 0' TERM INT HUP PIPE

  # Producers only mark the state dirty. They never inherit the lock fd, so a
  # stray child cannot keep a dead watcher's lock alive.
  if command -v udevadm >/dev/null 2>&1; then
    udevadm monitor --udev -s pci -s drm -s thunderbolt >"$_WATCH_FIFO" 2>/dev/null {lockfd}>&- &
    _WATCH_PRODUCERS+=($!)
  fi
  if command -v boltctl >/dev/null 2>&1; then
    boltctl monitor >"$_WATCH_FIFO" 2>/dev/null {lockfd}>&- &
    _WATCH_PRODUCERS+=($!)
  fi
  # Hyprland's socket. socat writes straight into the fifo (no pipeline), so
  # $! is socat itself and dies with the watcher; its noise (every focus
  # change) is dropped in the loop below.
  local sock="${XDG_RUNTIME_DIR:-}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -S $sock ]] && command -v socat >/dev/null 2>&1; then
    socat -U - "UNIX-CONNECT:$sock" >"$_WATCH_FIFO" 2>/dev/null {lockfd}>&- &
    _WATCH_PRODUCERS+=($!)
  fi

  local seq=0 prev='' prev_key='' prev_phase='' cur cur_key last_event=null recent='[]' health='' health_at=0
  local dirty=1 first_dirty=0 deadline=0 next_beat=0 next_gpu=0 now started due wait_ms line
  local tmp="$EGPU_RUN/.watch.$$.doc"
  local name detail ev

  while true; do
    now=$(now_ms)
    if (( dirty )); then
      due=$deadline
    else
      due=$next_beat
      [[ $prev_phase == ready ]] && (( next_gpu < due )) && due=$next_gpu
    fi
    wait_ms=$(( due - now ))
    if (( wait_ms > 0 )); then
      if IFS= read -r -t "$(printf '%d.%03d' $((wait_ms / 1000)) $((wait_ms % 1000)))" -u "$infd" line; then
        # Hyprland events look like "name>>data"; only monitors and reloads
        # can change eGPU state.
        if [[ $line =~ ^[a-z0-9]+\>\> && ! $line =~ ^(monitoradded|monitorremoved|configreloaded) ]]; then
          continue
        fi
        now=$(now_ms)
        if (( !dirty )); then dirty=1; first_dirty=$now; fi
        deadline=$(( now + debounce_ms ))
        (( deadline > first_dirty + 1000 )) && deadline=$(( first_dirty + 1000 ))
      fi
      continue
    fi

    # Recompute. Health is re-read on every change and once a minute. The
    # next heartbeat counts from the start, so a slow recompute (nvidia-smi)
    # does not stretch the interval.
    started=$now
    if [[ -z $health ]] || (( dirty || now - health_at >= health_ms )); then
      health=$(health_rows | jq -c '{errors: map(select(.level == "error")) | length,
                                     warnings: map(select(.level == "warn")) | length}')
      health_at=$now
    fi
    if ! status_collect "$health" "$last_event" "$seq" "$recent" >"$tmp"; then
      sleep 1
      continue
    fi
    cur=$(<"$tmp")
    cur_key=$(_status_key "$cur")

    if [[ $cur_key != "$prev_key" ]]; then
      if [[ -n $prev ]]; then
        while IFS=$'\t' read -r name detail; do
          [[ -n $name ]] || continue
          [[ -n $detail ]] || detail='{}'
          seq=$((seq + 1))
          ev=$(jq -cn --argjson seq "$seq" --arg e "$name" --argjson at "$(now_ms)" --argjson d "$detail" \
            '{type: "event", seq: $seq, event: $e, at: $at, detail: $d}')
          printf '%s\n' "$ev" || exit 0
          last_event=$(jq -c '{seq, type: .event, at}' <<<"$ev")
          recent=$(jq -c --argjson e "$last_event" '. + [$e] | .[-8:]' <<<"$recent")
        done < <(_status_events "$prev" "$cur")
      fi
      seq=$((seq + 1))
      cur=$(jq -c --argjson seq "$seq" --argjson le "$last_event" --argjson re "$recent" --argjson at "$(now_ms)" \
        '.seq = $seq | .last_event = $le | .recent_events = $re | .written_at = $at' <<<"$cur")
      printf '%s\n' "$(jq -c '{type: "status"} + .' <<<"$cur")" || exit 0
      prev=$cur
      prev_key=$cur_key
      prev_phase=$(jq -r '.phase' <<<"$cur")
    else
      prev=$(jq -c --argjson at "$(now_ms)" '.written_at = $at' <<<"$prev")
    fi
    write_atomic "$EGPU_RUN/status.json" <<<"$prev"

    dirty=0
    next_beat=$(( started + heartbeat_ms ))
    next_gpu=$(( started + gpu_ms ))
  done
}

_watch_cleanup() {
  local p
  for p in "${_WATCH_PRODUCERS[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  rm -f -- "${_WATCH_FIFO:-}" "$EGPU_RUN/.watch.$$.doc"
}

# ---------------------------------------------------------------- dispatch

status_main() {
  case ${1:-} in
    "" | --json)
      status_collect
      ;;
    --human)
      local doc
      doc=$(status_collect) || return 1
      status_human <<<"$doc"
      ;;
    watch)
      status_watch
      ;;
    *)
      json_error usage "$(jq -cn --arg v "$1" '{detail: "status [--json|--human|watch]", got: $v}')"
      return 1
      ;;
  esac
}
