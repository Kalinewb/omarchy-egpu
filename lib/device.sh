#!/bin/bash

# device.sh — module: connect, eject, rescan, holders. plan-engine.md §6.
#
#   omarchy-egpu device connect [--timeout S] [--enroll] [--quiet]
#   omarchy-egpu connect ...                  the same
#   omarchy-egpu device eject [--close] [--quiet]
#   omarchy-egpu device rescan [--timeout S] [--quiet]
#   omarchy-egpu device holders
#
# Eject and rescan are described above device_eject and device_rescan.
#
# Connect takes the eGPU from whatever phase it is in to `ready`:
#   1. the job lock ($EGPU_RUN/lock; held → exit 3)
#   2. bolt: authorize a connected, unauthorized enclosure (boltd's own polkit
#      action; user level, no helper). `--enroll` stores an unenrolled one with
#      policy auto instead, which the panel offers only after asking (§6.1).
#   3. PCI: wait up to connect.timeout_s for a removable display function a
#      backend accepts (no_pci_device, with the profile's hints)
#   4. driver: wait a short grace for the kernel to bind it and udev to load
#      the KMS modules. On the closed 580xx driver both happen by themselves on
#      hot-plug (dev/e0-facts.md); only when they do not is the root helper
#      asked to `load <backend>` (helper_missing when it is not installed)
#   5. verify: be_verify under its hang guard (smi_hung: reported, the stuck
#      process left alone, nothing retried), then Vulkan when vulkaninfo exists
#   6. notify "eGPU ready", print the result
#
# Already `ready` is success with "already": true and touches nothing. The
# display step of §6.1 (apply display.policy) belongs to lib/display.sh (E4);
# with the default policy "igpu" there is nothing to apply, and
# display.needs_relogin is the status document's to report.
#
# Privileged work goes only through _dev_admin: `pkexec $EGPU_ADMIN <verb>`
# with the helper's fixed verb list (§10.1). Nothing here runs sudo, modprobe
# or writes to /sys.
#
# Exit codes (§1.1): 0 ok, 1 refused/failed ({"error":...}), 3 busy, and
# pkexec's own 126 (declined) / 127 (not authorized) passed through.
#
# Errors beyond §1.1's device codes: remove_failed (the helper refused or
# failed a remove, or could not list holders, during eject), modules_held and
# rescan_failed (rescan), holders_failed (the holders verb).
#
# Events: a failed connect or rescan posts `connect_failed` to the running
# watcher (it cannot be derived from two status documents); `authorized` and
# `ready` come from the watcher itself as the phase moves. Eject posts all of
# its own: eject_started, then eject_ready {held, held_by} or eject_failed
# {error, ...}; the watcher no longer derives them (lib/status.sh).

# shellcheck source=lib/status.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/status.sh"

# The helper's verbs (§10.1). Nothing else is ever passed to pkexec.
DEV_ADMIN_VERBS=(version load unload remove rescan holders inspect-initramfs)

# Seconds to wait for the kernel and udev before asking the helper, and the
# poll interval. Environment overrides exist for the tests only.
DEV_GRACE_S=${EGPU_CONNECT_GRACE_S:-5}
DEV_POLL_S=${EGPU_POLL_S:-0.25}

# ---------------------------------------------------------------- lock

# _dev_lock <job>: the engine's one job lock (§6.1 step 1). The job name in
# $EGPU_RUN/job tells status which job holds it (only `eject` changes the
# phase). Returns 3 when another job holds it.
_dev_lock() {
  mkdir -p -- "$EGPU_RUN" || return 1
  exec {_DEV_LOCKFD}>>"$EGPU_RUN/lock" || return 1
  flock -n "$_DEV_LOCKFD" || { exec {_DEV_LOCKFD}>&-; return 3; }
  printf '%s\n' "$1" >"$EGPU_RUN/job"
  return 0
}

# _dev_nolock <cmd...>: runs a command (or function) without the lock's fd.
# Anything that may leave a child behind runs through it: an nvidia-smi stuck
# in D state is disowned, never killed (§4.2), and if it had inherited the
# fd it would hold the job lock until a reboot.
_dev_nolock() {
  if [[ -n ${_DEV_LOCKFD:-} ]]; then
    "$@" {_DEV_LOCKFD}>&-
  else
    "$@"
  fi
}

# _dev_job <name>: the running job renames itself (eject-check → eject).
_dev_job() { printf '%s\n' "$1" >"$EGPU_RUN/job"; }

_dev_unlock() {
  [[ -n ${_DEV_LOCKFD:-} ]] || return 0
  rm -f -- "$EGPU_RUN/job"
  exec {_DEV_LOCKFD}>&-
  _DEV_LOCKFD=''
}

# ---------------------------------------------------------------- helper

# _dev_admin <verb> [arg]: runs the root helper through pkexec. Its stdout is
# left in DEV_ADMIN_OUT and its status returned (pkexec's 126/127 included).
# Before pkexec is called the helper must exist and report the plugin's own
# version (§1.1); otherwise DEV_ADMIN_OUT is a helper_missing error, nothing
# runs, and the status is 2 (the helper itself only exits 0, 1 or 3).
_dev_admin() {
  local verb=$1 v ok=0
  shift
  for v in "${DEV_ADMIN_VERBS[@]}"; do [[ $v == "$verb" ]] && ok=1; done
  if (( !ok )); then
    DEV_ADMIN_OUT=$(json_error usage "$(jq -cn --arg v "$verb" '{detail: "not a helper verb", verb: $v}')")
    return 1
  fi
  _dev_admin_ready || return 2
  DEV_ADMIN_OUT=$(pkexec "$EGPU_ADMIN" "$verb" "$@")
}

# _dev_admin_ready: 0 when the helper is installed at the plugin's version and
# pkexec exists. Otherwise DEV_ADMIN_OUT is the helper_missing error and the
# status 2. Nothing runs with privileges here; eject asks before it changes
# anything, so a missing helper never leaves the monitors off for nothing.
_dev_admin_ready() {
  local want have reason=''
  want=$(plugin_version)
  if [[ ! -x $EGPU_ADMIN ]]; then
    reason=not_installed
  else
    have=$(timeout 5 "$EGPU_ADMIN" version 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    [[ $have == "$want" ]] || reason=version
  fi
  [[ -z $reason ]] && ! command -v pkexec >/dev/null 2>&1 && reason=no_pkexec
  if [[ -n $reason ]]; then
    DEV_ADMIN_OUT=$(json_error helper_missing "$(jq -cn --arg r "$reason" --arg p "$EGPU_ADMIN" \
      --arg have "${have:-}" --arg want "$want" \
      '{reason: $r, helper: $p, want: $want} + (if $have == "" then {} else {have: $have} end)')")
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------- events

# _dev_event <name> <detail-json>: hands an event to the running watcher,
# which numbers it and puts it in the stream and in status.json (§5.1). The
# spool line is one short append; the poke opens the watcher's fifo
# read-write, which never blocks, even on a fifo a killed watcher left
# behind. With no watcher there is nobody to tell, so nothing is written.
_dev_event() {
  local f d=${2:-}
  [[ -n $d ]] || d='{}'
  [[ -e $EGPU_RUN/watch.lock ]] || return 0
  flock -n "$EGPU_RUN/watch.lock" true 2>/dev/null && return 0
  jq -cn --arg e "$1" --argjson d "$d" --argjson at "$(now_ms)" \
    '{event: $e, at: $at, detail: $d}' >>"$EGPU_RUN/events.spool" 2>/dev/null || return 0
  for f in "$EGPU_RUN"/.watch.*.fifo; do
    [[ -p $f ]] && printf 'egpu-event\n' 1<>"$f"
  done
  return 0
}

_dev_notify() {
  (( DEV_QUIET )) && return 0
  [[ $(config_get notify true) == true ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  _dev_nolock notify-send -a eGPU -t 5000 "$1" "${2:-}" >/dev/null 2>&1 &
}

# _dev_fail <code> [extra-json] [exit]: the error on stdout, the job's failure
# event (connect_failed, or DEV_FAIL_EVENT) to the watcher, the exit status
# returned (default 1). Always the job's last word, so the lock goes first:
# the watcher then reads the phase the job leaves behind, not `ejecting`.
_dev_fail() {
  local code=$1 extra=${2:-'{}'} rc=${3:-1}
  extra=$(jq -c --arg p "${DEV_PHASE:-}" '. + {phase: (if $p == "" then null else $p end)}' <<<"$extra")
  json_error "$code" "$extra"
  _dev_unlock
  _dev_event "${DEV_FAIL_EVENT:-connect_failed}" "$(jq -c --arg e "$code" '{error: $e} + .' <<<"$extra")"
  return "$rc"
}

# ---------------------------------------------------------------- waits

_dev_bdf() { pci_egpu_candidates | head -n1; }

# The KMS modules of the loaded backend that are not loaded, one per line.
_dev_missing_modules() {
  local m
  while IFS= read -r m; do
    [[ -n $m ]] && ! module_loaded "$m" && printf '%s\n' "$m"
  done < <(be_kms_modules 2>/dev/null)
  return 0
}

# _dev_wait_driver <bdf> <want> <deadline-ms>: wait until <want> is bound and
# every KMS module is loaded. 0 done, 1 timed out, 2 another driver has the
# device (DEV_OTHER_DRIVER names it; waiting will not change that).
_dev_wait_driver() {
  local bdf=$1 want=$2 deadline=$3 drv
  while :; do
    drv=$(pci_driver "$bdf")
    if [[ -n $drv && $drv != "$want" ]]; then
      DEV_OTHER_DRIVER=$drv
      return 2
    fi
    [[ $drv == "$want" && -z $(_dev_missing_modules) ]] && return 0
    (( $(now_ms) >= deadline )) && return 1
    sleep "$DEV_POLL_S"
  done
}

# _dev_guarded <secs> <outfile> <cmd...>: the backend hang guard, for any
# command. 124 timed out and killed; 125 timed out in D state and left alone.
_dev_guarded() {
  local secs=$1 out=$2 pid waited=0
  shift 2
  "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs * 10 )); then
      if [[ $(proc_state "$pid") == D ]]; then
        disown "$pid" 2>/dev/null
        return 125
      fi
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# _dev_vulkan <bdf> <gpu-name>: does Vulkan, under the offload env, list the
# eGPU? Informational: {state: ok|not_listed|failed|skipped, detail}.
_dev_vulkan() {
  local bdf=$1 name=$2 tmp rc envs=()
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    echo '{"state":"skipped","detail":"vulkaninfo is not installed (vulkan-tools)"}'
    return 0
  fi
  mapfile -t envs < <(be_offload_env "$bdf" run 2>/dev/null)
  tmp=$(mktemp "${TMPDIR:-/tmp}/omarchy-egpu-vk.XXXXXX") || { echo '{"state":"failed","detail":"mktemp"}'; return 0; }
  _dev_guarded "${EGPU_VK_TIMEOUT:-10}" "$tmp" env "${envs[@]}" vulkaninfo --summary
  rc=$?
  if (( rc == 124 || rc == 125 )); then
    echo '{"state":"failed","detail":"vulkaninfo did not answer"}'
  elif (( rc != 0 )); then
    jq -cn --argjson rc "$rc" '{state: "failed", detail: "vulkaninfo exit \($rc)"}'
  elif [[ -n $name ]] && grep -qF -- "$name" "$tmp"; then
    echo '{"state":"ok","detail":""}'
  else
    echo '{"state":"not_listed","detail":"vulkaninfo does not list the eGPU under the offload environment"}'
  fi
  rm -f -- "$tmp"
}

# ---------------------------------------------------------------- connect

device_connect() {
  local timeout_s enroll=0 started
  DEV_QUIET=0
  timeout_s=$(config_get connect.timeout_s 30)
  while (( $# )); do
    case $1 in
      --timeout)
        timeout_s=${2:-}
        shift
        ;;
      --enroll) enroll=1 ;;
      --quiet) DEV_QUIET=1 ;;
      *)
        json_error usage "$(jq -cn --arg v "$1" '{detail: "device connect [--timeout S] [--enroll] [--quiet]", got: $v}')"
        return 1
        ;;
    esac
    shift
  done
  [[ $timeout_s =~ ^[0-9]+$ ]] || timeout_s=30
  started=$(now_ms)

  _dev_lock connect
  case $? in
    0) ;;
    3)
      json_error busy '{"detail":"another eGPU job is running"}'
      return 3
      ;;
    *)
      json_error busy '{"detail":"cannot create the runtime directory"}'
      return 1
      ;;
  esac
  # EXIT, not RETURN: a RETURN trap also fires when a file sourced directly
  # in this function finishes. The lock itself goes with the process anyway.
  trap '_dev_unlock' EXIT

  # Where things stand. The health summary is not needed here, and the last
  # event is not this job's to report, so neither is read.
  local doc bdf profile bolt_uuid bolt_status bolt_stored gpu_error be_name be_supported
  doc=$(_dev_nolock status_collect '{"errors":0,"warnings":0}' null 0 '[]') || doc='{}'
  DEV_PHASE=$(jq -r '.phase // "absent"' <<<"$doc")
  bdf=$(jq -r '.pci.bdf // empty' <<<"$doc")
  profile=$(jq -r '.bolt.profile // "generic"' <<<"$doc")
  bolt_uuid=$(jq -r '.bolt.uuid // empty' <<<"$doc")
  bolt_status=$(jq -r '.bolt.status // empty' <<<"$doc")
  bolt_stored=$(jq -r '.bolt.stored // false' <<<"$doc")
  gpu_error=$(jq -r '.gpu.error // empty' <<<"$doc")
  be_name=$(jq -r '.backend.name // empty' <<<"$doc")
  be_supported=$(jq -r '.backend.supported // false' <<<"$doc")

  # A detected card no backend implements: every device verb is a stub.
  if [[ -n $bdf && $be_supported != true ]]; then
    _dev_fail backend_stub "$(jq -cn --arg b "$be_name" --arg bdf "$bdf" '{backend: (if $b == "" then null else $b end), bdf: $bdf}')"
    return
  fi

  case $DEV_PHASE in
    ready)
      say "eGPU already connected."
      jq -cn --argjson doc "$doc" --argjson ms "$(( $(now_ms) - started ))" '
        {ok: true, phase: "ready", already: true, bdf: $doc.pci.bdf, backend: $doc.backend.name,
         authorized: false, helper_load: false, gpu: $doc.gpu, vulkan: null, elapsed_ms: $ms}'
      return 0
      ;;
    error)
      # The driver is stuck: one more nvidia-smi would only be one more stuck
      # process (§4.2). Nothing is retried.
      if [[ $gpu_error == smi_hung ]]; then
        _dev_fail smi_hung "$(jq -c '{bdf: .pci.bdf, gpu: .gpu}' <<<"$doc")"
        return
      fi
      ;;
    ejecting)
      json_error busy '{"detail":"an eject is running"}'
      return 3
      ;;
    ejected)
      # The functions were removed on purpose; only a rescan (E5) brings them
      # back, and waiting for them here would just time out.
      _dev_fail no_pci_device '{"reason":"ejected","detail":"The eGPU was ejected. Reconnect it (device rescan), or unplug and plug it in again."}'
      return
      ;;
    absent)
      _dev_fail not_connected '{"detail":"No eGPU or Thunderbolt enclosure is connected."}'
      return
      ;;
  esac

  # ---- 2. bolt
  local authorized=false
  if [[ -z $bdf && -n $bolt_uuid && ($bolt_status == connected || $bolt_status == auth-error) ]]; then
    local verb=authorize
    (( enroll )) && [[ $bolt_stored != true ]] && verb=enroll
    say "Authorizing the enclosure ($verb)…"
    local bolt_rc
    if [[ $verb == enroll ]]; then
      timeout 60 boltctl enroll --policy auto "$bolt_uuid" >/dev/null 2>&1
    else
      timeout 60 boltctl authorize "$bolt_uuid" >/dev/null 2>&1
    fi
    bolt_rc=$?
    if (( bolt_rc != 0 )); then
      _dev_fail not_connected "$(jq -cn --arg v "$verb" --argjson rc "$bolt_rc" --arg u "$bolt_uuid" \
        '{reason: "bolt_\($v)_failed", uuid: $u, rc: $rc, detail: "Thunderbolt authorization was refused or failed."}')"
      return
    fi
    authorized=true
    DEV_PHASE=authorized
  fi

  # ---- 3. PCI
  if [[ -z $bdf ]]; then
    say "Waiting for the GPU to appear (up to ${timeout_s} s)…"
    local deadline=$(( $(now_ms) + timeout_s * 1000 ))
    while :; do
      bdf=$(_dev_bdf)
      [[ -n $bdf ]] && break
      (( $(now_ms) >= deadline )) && break
      sleep "$DEV_POLL_S"
    done
    if [[ -z $bdf ]]; then
      local hints
      hints=$(profile_json "$profile" | jq -c '[(.hints // [])[] | select(.when == "authorized_no_pci") | {id: .when, text: .text}]')
      _dev_fail no_pci_device "$(jq -cn --argjson h "$hints" --argjson t "$timeout_s" --arg p "$profile" \
        '{timeout_s: $t, profile: $p, hints: $h}')"
      return
    fi
  fi
  if ! backend_select "$bdf"; then
    _dev_fail backend_stub "$(jq -cn --arg bdf "$bdf" '{backend: null, bdf: $bdf}')"
    return
  fi
  if [[ $BE_STATUS != implemented ]]; then
    _dev_fail backend_stub "$(jq -cn --arg b "$EGPU_BACKEND" --arg bdf "$bdf" '{backend: $b, bdf: $bdf}')"
    return
  fi
  # The driver that binds the card is the first module of the KMS set
  # (nvidia: `nvidia`), so no vendor name is needed here.
  local want_driver
  want_driver=$(be_kms_modules | head -n1)
  enclosure_remember "$bolt_uuid"

  # ---- 4. driver and KMS modules: the kernel and udev first, then the helper
  local rc helper_load=false grace_until
  grace_until=$(( $(now_ms) + DEV_GRACE_S * 1000 ))
  _dev_wait_driver "$bdf" "$want_driver" "$grace_until"
  rc=$?
  if (( rc == 1 )); then
    say "Loading the driver…"
    _dev_admin load "$EGPU_BACKEND"
    local arc=$?
    if (( arc == 2 )); then
      _dev_fail helper_missing "$(jq -c 'del(.error)' <<<"$DEV_ADMIN_OUT")"
      return
    elif (( arc == 126 || arc == 127 )); then
      _dev_fail modules_failed "$(jq -cn --argjson rc "$arc" '{pkexec: $rc, detail: (if $rc == 126 then "permission declined" else "not authorized" end)}')" "$arc"
      return
    elif (( arc == 3 )); then
      json_error busy '{"detail":"the helper is busy"}'
      return 3
    elif (( arc != 0 )); then
      local hout
      hout=$(jq -c . <<<"$DEV_ADMIN_OUT" 2>/dev/null) || hout=null
      _dev_fail modules_failed "$(jq -cn --argjson h "${hout:-null}" --argjson rc "$arc" '{helper: $h, rc: $rc}')"
      return
    fi
    helper_load=true
    _dev_wait_driver "$bdf" "$want_driver" "$(( $(now_ms) + timeout_s * 1000 ))"
    rc=$?
  fi
  if (( rc == 2 )); then
    _dev_fail modules_failed "$(jq -cn --arg d "$DEV_OTHER_DRIVER" --arg w "$want_driver" --arg bdf "$bdf" \
      '{bdf: $bdf, driver: $d, want: $w, detail: "Another driver has the card."}')"
    return
  elif (( rc != 0 )); then
    _dev_fail modules_failed "$(jq -cn --arg d "$(pci_driver "$bdf")" --arg bdf "$bdf" \
      --argjson missing "$(_dev_missing_modules | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      '{bdf: $bdf, driver: (if $d == "" then null else $d end), missing: $missing}')"
    return
  fi
  DEV_PHASE=bound

  # ---- 5. verify
  say "Checking the GPU…"
  local gpu gerr vulkan name
  gpu=$(_dev_nolock be_verify "$bdf") || gpu='{"ok":false,"error":"verify_failed"}'
  gerr=$(jq -r '.error // empty' <<<"$gpu")
  if [[ $gerr == smi_hung ]]; then
    DEV_PHASE=error
    _dev_fail smi_hung "$(jq -cn --arg bdf "$bdf" --argjson g "$gpu" '{bdf: $bdf, gpu: $g}')"
    return
  elif [[ $(jq -r '.ok' <<<"$gpu") != true ]]; then
    _dev_fail modules_failed "$(jq -cn --arg bdf "$bdf" --argjson g "$gpu" '{bdf: $bdf, gpu: $g, detail: "The driver is loaded but the GPU did not answer."}')"
    return
  fi
  name=$(jq -r '.name // empty' <<<"$gpu")
  vulkan=$(_dev_nolock _dev_vulkan "$bdf" "$name")
  [[ $(jq -r '.state' <<<"$vulkan") == ok || $(jq -r '.state' <<<"$vulkan") == skipped ]] ||
    say "Note: $(jq -r '.detail' <<<"$vulkan")"
  DEV_PHASE=ready

  # ---- 6. done
  say "eGPU ready: $name"
  _dev_notify "eGPU ready" "$name"
  jq -cn --arg bdf "$bdf" --arg b "$EGPU_BACKEND" --argjson auth "$authorized" --argjson hl "$helper_load" \
    --argjson gpu "$gpu" --argjson vk "$vulkan" --argjson ms "$(( $(now_ms) - started ))" '
    {ok: true, phase: "ready", already: false, bdf: $bdf, backend: $b,
     authorized: $auth, helper_load: $hl, gpu: $gpu, vulkan: $vk, elapsed_ms: $ms}'
}

# ---------------------------------------------------------------- holders

# The shell's process name. Like the compositor it is never signalled; unlike
# the compositor it blocks an eject while it has memory on the card (then a
# restart of the shell or a logout is the way out, not a SIGTERM from here).
DEV_SHELL_COMMS=(quickshell)

# _dev_family: this process and its ancestors, one pid per line. None of
# them is ever signalled, whatever environment it carries: an eject typed into
# a terminal started with egpu-run must not close that terminal.
_dev_family() {
  local p=$$ n=0 stat rest
  [[ $BASHPID != "$$" ]] && printf '%s\n' "$BASHPID"
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 && n < 64 )); do
    printf '%s\n' "$p"
    stat=$(read_attr "$EGPU_PROC/$p/stat") || break
    rest=${stat##*) }
    read -r _ p _ <<<"$rest"
    n=$((n + 1))
  done
}

# _dev_descends <pid> <family-lines>: is <pid> one of ours or our child?
_dev_descends() {
  local p=$1 n=0 stat rest
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 && n < 64 )); do
    grep -qxF -- "$p" <<<"$2" && return 0
    stat=$(read_attr "$EGPU_PROC/$p/stat") || return 1
    rest=${stat##*) }
    read -r _ p _ <<<"$rest"
    n=$((n + 1))
  done
  return 1
}

# _dev_offload_users <bdf> <family-lines>: the user's own processes that were
# started on the eGPU on purpose, as a JSON array of {pid, comm, why}:
#   steam    the managed Steam marker OMARCHY_EGPU=1 (§8.3): a game switched
#            to the eGPU, and everything its launch started (reaper, Proton)
#   offload  the backend's whole offload set (egpu-run, or prime-run style)
# Only environments this user can read are searched, which are its own.
_dev_offload_users() {
  local bdf=$1 family=$2 env=() steam=() cand=() l f pid comm rows=()
  mapfile -t steam < <(grep -lszxF -e 'OMARCHY_EGPU=1' "$EGPU_PROC"/[0-9]*/environ 2>/dev/null)
  mapfile -t env < <(be_offload_env "$bdf" 2>/dev/null)
  if (( ${#env[@]} )); then
    mapfile -t cand < <(grep -lszxF -e "${env[0]}" "$EGPU_PROC"/[0-9]*/environ 2>/dev/null)
    for l in "${env[@]:1}"; do
      (( ${#cand[@]} )) || break
      mapfile -t cand < <(grep -lszxF -e "$l" "${cand[@]}" 2>/dev/null)
    done
  fi
  for f in "${steam[@]}" "${cand[@]}"; do
    pid=${f%/environ}
    pid=${pid##*/}
    [[ $pid =~ ^[0-9]+$ ]] || continue
    _dev_descends "$pid" "$family" && continue
    comm=$(read_attr "$EGPU_PROC/$pid/comm") || comm=''
    if printf '%s\n' "${steam[@]}" | grep -qxF -- "$f"; then
      rows+=("$(jq -cn --argjson p "$pid" --arg c "$comm" '{pid: $p, comm: $c, why: "steam"}')")
    else
      rows+=("$(jq -cn --argjson p "$pid" --arg c "$comm" '{pid: $p, comm: $c, why: "offload"}')")
    fi
  done
  printf '%s\n' "${rows[@]}" | jq -s -c 'map(select(type == "object")) | unique_by(.pid)'
}

# _dev_classify <helper holders json> <gpu procs json> <offload json> <family-lines>:
# every process that holds the card, uses it, or was started on it, as one
# sorted JSON array of {pid, comm, uid, nodes, role, why, gpu_mem_mb, blocks,
# closeable}. Roles:
#   compositor   Hyprland: expected to hold the card, released at removal.
#                Never blocks, never signalled (§6.2).
#   shell        quickshell: never signalled; blocks only with GPU memory.
#   app          a real user of the eGPU: an nvidia-smi graphics/compute
#                client with memory, or an offload user (Steam game, egpu-run).
#                Blocks. Closeable when it is this user's and not our own.
#   incidental   /dev/nvidia* open without memory on the card (GTK/Electron
#                apps that loaded libEGL_nvidia). Reported, does not block:
#                they keep the modules loaded, not the card (DECISIONS
#                2026-10-10, dev/e0-facts.md).
_dev_classify() {
  local holders=$1 procs=$2 offload=$3 family comp
  family=$(printf '%s\n' "$4" | jq -R -s -c 'split("\n") | map(select(length > 0) | tonumber)')
  comp=$(compositor_pid)
  jq -cn --argjson h "$holders" --argjson procs "$procs" --argjson off "$offload" \
    --argjson comp "${comp:-0}" --argjson family "$family" --argjson uid "$UID" \
    --args '
    $ARGS.positional as $shells
    | ([$h.holders[]?.pid]) as $held
    | ($procs | map(select(.pid != null) | {key: (.pid | tostring), value: .}) | from_entries) as $smi
    | ($off | map({key: (.pid | tostring), value: .}) | from_entries) as $o
    | [ ($h.holders // [])[],
        ($off[] | select(.pid as $p | $held | index($p) | not) | {pid, comm, uid: $uid, nodes: []}),
        ($procs[] | select(.pid != null) | select(.pid as $p | ($held + [$off[].pid]) | index($p) | not)
         | {pid, comm: ((.name // "") | split("/") | last | .[:15]), uid: null, nodes: []}) ]
    | map(. as $x
        | $smi[$x.pid | tostring] as $g
        | $o[$x.pid | tostring] as $m
        | ($g != null and ($g.mem_mb == null or $g.mem_mb > 0)) as $mem
        | (if $x.pid == $comp or $x.comm == "Hyprland" then "compositor"
           elif ($shells | index($x.comm)) then "shell"
           elif $mem or $m != null then "app"
           else "incidental" end) as $role
        | {pid: $x.pid, comm: ($x.comm // ""), uid: $x.uid, nodes: ($x.nodes // []), role: $role,
           why: (if $role == "compositor" then "compositor"
                 elif $m != null then $m.why
                 elif $mem then "gpu_memory"
                 else "open_device" end),
           gpu_mem_mb: (if $g == null then null else $g.mem_mb end),
           blocks: ($role == "app" or ($role == "shell" and $mem)),
           closeable: ($role == "app" and $x.uid == $uid and ($family | index($x.pid) | not))})
    | unique_by(.pid)' "${DEV_SHELL_COMMS[@]}"
}

# _dev_survey <bdf> <family-lines>: who uses the card now, through the helper
# (any user's holders) and nvidia-smi (who has memory on it). Sets DEV_SURVEY
# (classified, as above) and DEV_GPU (be_verify's answer). Status 2 helper
# unusable (DEV_ADMIN_OUT says why, DEV_ADMIN_RC its status), 3 nvidia-smi
# hung, 0 otherwise.
_dev_survey() {
  local bdf=$1 family=$2 holders procs offload
  DEV_GPU=$(_dev_nolock be_verify "$bdf") || DEV_GPU='{"ok":false,"error":"verify_failed"}'
  [[ $(jq -r '.error // empty' <<<"$DEV_GPU") == smi_hung ]] && return 3
  procs=$(jq -c '.procs // []' <<<"$DEV_GPU")
  _dev_admin holders
  DEV_ADMIN_RC=$?
  if (( DEV_ADMIN_RC != 0 )) || ! holders=$(jq -ce 'select(type == "object" and (.holders | type == "array"))' <<<"$DEV_ADMIN_OUT" 2>/dev/null); then
    (( DEV_ADMIN_RC == 0 )) && DEV_ADMIN_RC=1
    return 2
  fi
  offload=$(_dev_offload_users "$bdf" "$family")
  DEV_SURVEY=$(_dev_classify "$holders" "$procs" "$offload" "$family")
  return 0
}

# _dev_gone <pid> <comm>: the process has exited (or is a zombie its parent
# has not reaped), or the pid now belongs to something else.
_dev_gone() {
  kill -0 "$1" 2>/dev/null || return 0
  [[ $(proc_state "$1") == Z ]] && return 0
  [[ -n $2 && $(read_attr "$EGPU_PROC/$1/comm") != "$2" ]] && return 0
  return 1
}

# _dev_close <survey json> <timeout s>: SIGTERM to every closeable blocking
# holder, then wait. Prints {closed: [...], survivors: [...]}. A pid whose
# name changed since the survey is not signalled (it is not the same process).
# Nothing is ever sent SIGKILL: what survives is the user's to decide.
_dev_close() {
  local survey=$1 secs=$2 n i pid comm sent=() deadline left=()
  n=$(jq '[.[] | select(.blocks and .closeable)] | length' <<<"$survey")
  for ((i = 0; i < n; i++)); do
    pid=$(jq -r "[.[] | select(.blocks and .closeable)][$i].pid" <<<"$survey")
    comm=$(jq -r "[.[] | select(.blocks and .closeable)][$i].comm" <<<"$survey")
    [[ $(read_attr "$EGPU_PROC/$pid/comm") == "$comm" ]] || continue
    kill -TERM "$pid" 2>/dev/null && sent+=("$pid")
  done
  deadline=$(( $(now_ms) + secs * 1000 ))
  while :; do
    left=()
    for pid in "${sent[@]}"; do
      _dev_gone "$pid" "$(jq -r --argjson p "$pid" '.[] | select(.pid == $p) | .comm' <<<"$survey")" || left+=("$pid")
    done
    (( ${#left[@]} == 0 )) && break
    (( $(now_ms) >= deadline )) && break
    sleep "$DEV_POLL_S"
  done
  jq -cn --argjson s "$survey" --arg sent "${sent[*]:-}" --arg left "${left[*]:-}" '
    ($sent | split(" ") | map(select(length > 0) | tonumber)) as $sent
    | ($left | split(" ") | map(select(length > 0) | tonumber)) as $left
    | {closed: [$s[] | select(.pid as $p | ($sent | index($p)) and ($left | index($p) | not)) | {pid, comm}],
       survivors: [$s[] | select(.pid as $p | $left | index($p)) | {pid, comm}]}'
}

# ---------------------------------------------------------------- eject

# Every function of the slot is gone, with its DRM card node and by-path link.
_dev_removed() {
  local bdf=$1 card=$2 f
  for f in "${@:3}"; do [[ -e $EGPU_PCI/$f ]] && return 1; done
  [[ -e $EGPU_PCI/$bdf ]] && return 1
  if [[ -n $card ]]; then
    [[ -e $EGPU_DEV/dri/$card ]] && return 1
  fi
  [[ -e $EGPU_DEV/dri/by-path/pci-$bdf-card || -L $EGPU_DEV/dri/by-path/pci-$bdf-card ]] && return 1
  return 0
}

# _dev_modules_free: every unloadable module of the backend is either not
# loaded or referenced only by the stack's own modules: the helper's own
# unload rule (system/omarchy-egpu-admin), read as the user.
_dev_modules_free() {
  local m mods=() h ok refcnt expected
  mapfile -t mods < <(be_unload_modules 2>/dev/null)
  for m in "${mods[@]}"; do
    [[ -n $m ]] || continue
    module_loaded "$m" || continue
    refcnt=$(read_attr "$EGPU_SYS/module/$m/refcnt") || return 1
    [[ $refcnt =~ ^[0-9]+$ ]] || return 1
    expected=0
    for h in "$EGPU_SYS/module/$m/holders"/*; do
      [[ -e $h ]] || continue
      ok=0
      printf '%s\n' "${mods[@]}" | grep -qxF -- "${h##*/}" && ok=1
      (( ok )) || return 1
      expected=$((expected + 1))
    done
    (( refcnt == expected )) || return 1
  done
  return 0
}

_dev_modules_loaded() {
  local m
  while IFS= read -r m; do
    [[ -n $m ]] && module_loaded "$m" && return 0
  done < <(be_unload_modules 2>/dev/null)
  return 1
}

# _dev_display_off: the eGPU's monitors off before anything else (REVISION
# 2026-10-09, §6.3 step 2), through lib/display.sh. Their workspaces go to the
# primary panel first, then `display off` disables them (and records that in
# the toggle file, so a reload does not light them again), then the monitor
# list is read once more: an eGPU monitor still on is hdmi_still_active.
# Under display.policy igpu the compositor normally has no eGPU monitor and
# nothing is touched, not even the toggle file; one that is lit all the same
# (a session started before the policy changed) is still turned off, because
# removing a card that owns an output is the crash case. Sets DEV_DISPLAY.
_dev_display_off() {
  local policy mons match eg on n i mon primary moved=() out rc still
  policy=$(_dsp_policy)
  if ! _dsp_hypr_up || ! mons=$(_dsp_monitors); then
    DEV_DISPLAY=$(jq -cn --arg p "$policy" '{policy: $p, compositor: false, off: [], workspaces: []}')
    return 0
  fi
  match=$(_dsp_egpu_match "$mons")
  eg=$(jq -c .monitors <<<"$match")
  on=$(jq -c '[.[] | select(.disabled | not)]' <<<"$eg")
  n=$(jq 'length' <<<"$on")
  if (( n == 0 )); then
    DEV_DISPLAY=$(jq -cn --arg p "$policy" '{policy: $p, compositor: true, off: [], workspaces: []}')
    return 0
  fi
  primary=$(_dsp_primary "$mons" "$eg")
  if [[ $primary != null ]]; then
    for ((i = 0; i < n; i++)); do
      mon=$(jq -c ".[$i]" <<<"$on")
      moved+=("$(_dsp_move_ws "$mon" "$(jq -r .name <<<"$primary")" |
        jq -c --argjson m "$mon" '{monitor: $m.description} + .')")
    done
  fi
  out=$(display_off)
  rc=$?
  # display_off waited for them itself; this is the one check eject relies on.
  still='[]'
  if mons=$(_dsp_monitors); then
    still=$(jq -c --argjson on "$on" '[.[] | select((.disabled | not) and (.description as $d | [$on[].description] | index($d))) | .description]' <<<"$mons")
  fi
  DEV_DISPLAY=$(jq -cn --arg p "$policy" --argjson on "$on" --argjson still "$still" \
    --argjson moved "$(printf '%s\n' "${moved[@]}" | jq -s -c 'map(select(type == "object"))')" \
    --argjson off "$(jq -ce . <<<"$out" 2>/dev/null || echo null)" --argjson rc "$rc" '
    {policy: $p, compositor: true, off: [$on[] | {name, description}], workspaces: $moved,
     still_on: $still, persisted: (($off // {}).persisted // false),
     display_off: (if $rc == 0 then null else $off end)}')
  [[ $still == '[]' ]] || return 1
  return 0
}

# _dev_lit_connectors <bdf>: the card's connectors the kernel has enabled, one
# per line (card1-HDMI-A-2). Hyprland can say a monitor is off while the
# kernel still scans it out (or the console does, with fbdev=1); the helper
# refuses to remove a card in that state (monitor_active), so eject waits for
# the kernel's word before asking.
_dev_lit_connectors() {
  local f c
  for f in $(pci_slot_functions "$1"); do
    for c in "$EGPU_PCI/$f"/drm/card*/card*-*; do
      [[ -r $c/enabled && $(read_attr "$c/enabled") == enabled ]] && printf '%s\n' "${c##*/}"
    done
  done
  return 0
}

# _dev_wait_dark <bdf>: up to DSP_WAIT_MS for every connector to go dark.
# DEV_LIT names what stayed lit.
_dev_wait_dark() {
  local deadline=$(( $(now_ms) + DSP_WAIT_MS ))
  while :; do
    DEV_LIT=$(_dev_lit_connectors "$1")
    [[ -z $DEV_LIT ]] && return 0
    (( $(now_ms) >= deadline )) && return 1
    sleep "$DEV_POLL_S"
  done
}

# Safe eject (§6.3, with the DECISIONS of 2026-10-10: incidental holders do not
# block, unload is not required):
#   1. the job lock, named eject-check while it only looks: nothing connected
#      is not_connected; already ejected (or an enclosure with no GPU behind
#      it) succeeds with "already": true; a hung driver is smi_hung, a stub
#      backend backend_stub; a missing or outdated helper is helper_missing.
#      Nothing has been changed when any of these answers.
#   2. it is now `eject` (status: ejecting) and posts eject_started
#   3. the eGPU's monitors off (_dev_display_off): hdmi_still_active
#   4. holders (_dev_survey). Real users block: holders_present, listing them,
#      the incidental ones and whether --close can help. --close sends SIGTERM
#      to this user's blocking apps, waits eject.close_timeout_s, and answers
#      holders_present again if any survive. Never SIGKILL, never the shell
#      or the compositor.
#   5. the ejected marker ($EGPU_RUN/ejected), then `pkexec helper remove
#      <bdf>` (every function of the slot), then a wait for the functions,
#      the card node and the by-path link to go: remove_timeout. A failed
#      remove takes the marker back.
#   6. the modules: unloaded through the helper only when nothing holds them;
#      otherwise they stay, modules.held_after_eject is true and the holders'
#      names go into the marker (status shows them as modules.held_by)
#   7. the lock released (status: ejected, safe_to_unplug), eject_ready
#      {held, held_by} posted, "Safe to unplug" notified
# Every failure after step 1 posts eject_failed with its error code.
device_eject() {
  local close=0 started secs
  DEV_QUIET=0
  while (( $# )); do
    case $1 in
      --close) close=1 ;;
      --quiet) DEV_QUIET=1 ;;
      *)
        json_error usage "$(jq -cn --arg v "$1" '{detail: "device eject [--close] [--quiet]", got: $v}')"
        return 1
        ;;
    esac
    shift
  done
  secs=$(config_get eject.close_timeout_s 10)
  [[ $secs =~ ^[0-9]+$ ]] || secs=10
  started=$(now_ms)
  DEV_FAIL_EVENT=eject_failed

  _dev_lock eject-check
  case $? in
    0) ;;
    3)
      json_error busy '{"detail":"another eGPU job is running"}'
      return 3
      ;;
    *)
      json_error busy '{"detail":"cannot create the runtime directory"}'
      return 1
      ;;
  esac
  trap '_dev_unlock' EXIT

  # ---- 1. where things stand
  local doc bdf be_name be_supported bolt_uuid gpu_error held
  doc=$(_dev_nolock status_collect '{"errors":0,"warnings":0}' null 0 '[]') || doc='{}'
  DEV_PHASE=$(jq -r '.phase // "absent"' <<<"$doc")
  bdf=$(jq -r '.pci.bdf // empty' <<<"$doc")
  be_name=$(jq -r '.backend.name // empty' <<<"$doc")
  be_supported=$(jq -r '.backend.supported // false' <<<"$doc")
  bolt_uuid=$(jq -r 'if .bolt.present then .bolt.uuid // empty else empty end' <<<"$doc")
  gpu_error=$(jq -r '.gpu.error // empty' <<<"$doc")
  held=$(jq -r '.modules.held_after_eject // false' <<<"$doc")

  if [[ -z $bdf ]]; then
    case $DEV_PHASE in
      absent)
        _dev_fail not_connected '{"detail":"No eGPU or Thunderbolt enclosure is connected."}'
        return
        ;;
      *)
        # Ejected already, or an enclosure with no GPU function: nothing on
        # the PCI bus to remove, so it is already safe to unplug.
        say "Nothing to eject: no eGPU on the PCI bus."
        jq -cn --argjson doc "$doc" --argjson ms "$(( $(now_ms) - started ))" '
          {ok: true, phase: $doc.phase, already: true, bdf: null,
           modules: {held_after_eject: $doc.modules.held_after_eject, held_by: ($doc.modules.held_by // [])},
           elapsed_ms: $ms}'
        return 0
        ;;
    esac
  fi
  if [[ $DEV_PHASE == error && $gpu_error == smi_hung ]]; then
    # Removing a card whose driver is stuck is how a remove hangs for good.
    _dev_fail smi_hung "$(jq -c '{bdf: .pci.bdf, gpu: .gpu, detail: "The driver is not answering. Do not unplug: save your work, then log out or reboot."}' <<<"$doc")"
    return
  fi
  if [[ $be_supported != true ]] || ! backend_select "$bdf" || [[ $BE_STATUS != implemented ]]; then
    _dev_fail backend_stub "$(jq -cn --arg b "$be_name" --arg bdf "$bdf" '{backend: (if $b == "" then null else $b end), bdf: $bdf}')"
    return
  fi
  if ! _dev_admin_ready; then
    _dev_fail helper_missing "$(jq -c 'del(.error)' <<<"$DEV_ADMIN_OUT")"
    return
  fi

  # ---- 2. ejecting from here on
  local card functions=() family
  card=$(pci_drm_card "$bdf")
  mapfile -t functions < <(pci_slot_functions "$bdf")
  family=$(_dev_family)
  # DEV_PHASE stays what it was: an error document names the phase the
  # card is left in once the job ends, not `ejecting`.
  _dev_job eject
  _dev_event eject_started "$(jq -cn --arg bdf "$bdf" --argjson close "$([[ $close == 1 ]] && echo true || echo false)" '{bdf: $bdf, close: $close}')"

  # ---- 3. monitors
  say "Turning off the eGPU's monitors…"
  if ! _dev_display_off; then
    _dev_fail hdmi_still_active "$(jq -c '{monitors: .still_on, display: .}' <<<"$DEV_DISPLAY")"
    return
  fi
  if ! _dev_wait_dark "$bdf"; then
    _dev_fail hdmi_still_active "$(jq -cn --argjson d "$DEV_DISPLAY" \
      --argjson lit "$(printf '%s\n' "$DEV_LIT" | jq -R -s -c 'split("\n") | map(select(length > 0))')" '
      {monitors: [], connectors: $lit, display: $d,
       detail: "The compositor has no monitor on the eGPU on, but the kernel still drives these outputs (the console, with fbdev=1, can). Unplug the monitor cable from the eGPU, then eject again."}')"
    return
  fi

  # ---- 4. who uses the card
  local rc closed='[]' blocking
  _dev_survey "$bdf" "$family"
  rc=$?
  if (( rc == 3 )); then
    _dev_fail smi_hung "$(jq -cn --arg bdf "$bdf" --argjson g "$DEV_GPU" --argjson d "$DEV_DISPLAY" '{bdf: $bdf, gpu: $g, display: $d}')"
    return
  elif (( rc == 2 )); then
    _dev_eject_helper_fail holders
    return
  fi
  blocking=$(jq -c '[.[] | select(.blocks)]' <<<"$DEV_SURVEY")
  if [[ $blocking != '[]' ]] && (( close )) && [[ $(jq '[.[] | select(.closeable)] | length' <<<"$blocking") != 0 ]]; then
    say "Asking $(jq -r '[.[] | select(.closeable) | .comm] | unique | join(", ")' <<<"$blocking") to quit…"
    local res
    res=$(_dev_close "$DEV_SURVEY" "$secs")
    closed=$(jq -c '.closed' <<<"$res")
    if [[ $(jq '.survivors | length' <<<"$res") != 0 ]]; then
      _dev_fail holders_present "$(jq -cn --argjson s "$DEV_SURVEY" --argjson r "$res" --argjson d "$DEV_DISPLAY" --argjson t "$secs" '
        {holders: [$s[] | select(.blocks)], incidental: [$s[] | select(.blocks | not)],
         closed: $r.closed, survivors: $r.survivors, timed_out: true, close_timeout_s: $t,
         can_close: false, display: $d,
         detail: "Some apps did not quit within \($t) s. Close them yourself, then eject again."}')"
      return
    fi
    # Once more: a closed app may have left a child behind, or another app
    # may have started meanwhile.
    _dev_survey "$bdf" "$family"
    rc=$?
    if (( rc == 3 )); then
      _dev_fail smi_hung "$(jq -cn --arg bdf "$bdf" --argjson g "$DEV_GPU" '{bdf: $bdf, gpu: $g}')"
      return
    elif (( rc == 2 )); then
      _dev_eject_helper_fail holders
      return
    fi
    blocking=$(jq -c '[.[] | select(.blocks)]' <<<"$DEV_SURVEY")
  fi
  if [[ $blocking != '[]' ]]; then
    _dev_fail holders_present "$(jq -cn --argjson s "$DEV_SURVEY" --argjson c "$closed" --argjson d "$DEV_DISPLAY" '
      {holders: [$s[] | select(.blocks)], incidental: [$s[] | select(.blocks | not)],
       closed: $c, can_close: ([$s[] | select(.blocks and .closeable)] | length > 0), display: $d}')"
    return
  fi

  # ---- 5. remove
  local marker="$EGPU_RUN/ejected" arc removed
  jq -cn --arg u "$bolt_uuid" --arg bdf "$bdf" --argjson at "$(now_ms)" \
    '{uuid: (if $u == "" then null else $u end), bdf: $bdf, at: $at, held_by: []}' | write_atomic "$marker"
  say "Removing the card from the PCI bus…"
  _dev_admin remove "$bdf"
  arc=$?
  if (( arc != 0 )); then
    rm -f -- "$marker"
    _dev_eject_helper_fail remove "$arc"
    return
  fi
  removed=$(jq -c '.removed // []' <<<"$DEV_ADMIN_OUT" 2>/dev/null) || removed='[]'
  local deadline=$(( $(now_ms) + ${EGPU_REMOVE_SETTLE_S:-5} * 1000 ))
  until _dev_removed "$bdf" "$card" "${functions[@]}"; do
    if (( $(now_ms) >= deadline )); then
      rm -f -- "$marker"
      _dev_notify "Do not unplug the eGPU" "The driver has not let go of the card. Save your work and log out; unplug after."
      _dev_fail remove_timeout "$(jq -cn --arg bdf "$bdf" --argjson r "$removed" \
        '{bdf: $bdf, removed: $r, detail: "The helper answered, but the card is still on the PCI bus. Do not unplug: save your work and log out."}')"
      return
    fi
    sleep "$DEV_POLL_S"
  done

  # ---- 6. modules
  local after='{"holders":[]}' held_by='[]' unload=null unloaded=false
  if _dev_admin holders && jq -e '.holders | type == "array"' <<<"$DEV_ADMIN_OUT" >/dev/null 2>&1; then
    after=$DEV_ADMIN_OUT
  fi
  if _dev_modules_loaded; then
    if [[ $(jq '.holders | length' <<<"$after") == 0 ]] && _dev_modules_free; then
      say "Unloading the driver…"
      _dev_admin unload "$EGPU_BACKEND"
      arc=$?
      unload=$(jq -c --argjson rc "$arc" '. + {rc: $rc}' <<<"$DEV_ADMIN_OUT" 2>/dev/null) || unload=$(jq -cn --argjson rc "$arc" '{rc: $rc}')
    fi
  fi
  if _dev_modules_loaded; then
    held=true
    held_by=$(jq -c '[.holders[].comm] | map(select(length > 0)) | unique' <<<"$after")
    jq -c --argjson h "$held_by" '.held_by = $h' "$marker" 2>/dev/null | write_atomic "$marker"
  else
    held=false
    [[ $unload != null ]] && unloaded=true
  fi

  # ---- 7. done
  local result
  result=$(jq -cn --arg bdf "$bdf" --arg b "$EGPU_BACKEND" --argjson removed "$removed" --argjson d "$DEV_DISPLAY" \
    --argjson s "$DEV_SURVEY" --argjson closed "$closed" --argjson held "$held" --argjson held_by "$held_by" \
    --argjson unloaded "$unloaded" --argjson unload "$unload" --argjson ms "$(( $(now_ms) - started ))" '
    {ok: true, phase: "ejected", already: false, bdf: $bdf, backend: $b, removed: $removed,
     display: $d, closed: $closed, incidental: [$s[] | select(.blocks | not) | {pid, comm, role}],
     modules: {held_after_eject: $held, held_by: $held_by, unloaded: $unloaded, unload: $unload},
     elapsed_ms: $ms}')
  _dev_unlock
  _dev_event eject_ready "$(jq -c '{bdf, held: .modules.held_after_eject, held_by: .modules.held_by}' <<<"$result")"
  if [[ $held == true ]]; then
    say "Safe to unplug. The driver is still held by: $(jq -r 'join(", ")' <<<"$held_by"); log out before plugging the eGPU in again."
    _dev_notify "Safe to unplug the eGPU" "Log out before plugging it in again."
  else
    say "Safe to unplug."
    _dev_notify "Safe to unplug the eGPU"
  fi
  printf '%s\n' "$result"
}

# _dev_eject_helper_fail <verb> [status]: the helper's answer as eject's error.
# helper_missing as such; pkexec's 126/127 (declined, not authorized) and 3
# (busy) pass through; the helper's own remove_timeout stays remove_timeout;
# anything else is remove_failed with the helper's document attached.
_dev_eject_helper_fail() {
  local verb=$1 arc=${2:-${DEV_ADMIN_RC:-1}} h code
  h=$(jq -c 'select(type == "object")' <<<"$DEV_ADMIN_OUT" 2>/dev/null) || h=''
  [[ -n $h ]] || h=null
  if (( arc == 2 )); then
    _dev_fail helper_missing "$(jq -c 'del(.error)' <<<"$DEV_ADMIN_OUT")"
    return
  fi
  if (( arc == 3 )); then
    _dev_fail busy '{"detail":"the helper is busy"}' 3
    return
  fi
  code=remove_failed
  case $verb:$(jq -r '.error // empty' <<<"$h" 2>/dev/null) in
    remove:remove_timeout) code=remove_timeout ;;
    # Lit between our check and the helper's: the same answer as ours.
    remove:monitor_active) code=hdmi_still_active ;;
  esac
  if [[ $code == remove_timeout ]]; then
    _dev_notify "Do not unplug the eGPU" "The driver has not let go of the card. Save your work and log out; unplug after."
  fi
  _dev_fail "$code" "$(jq -cn --arg v "$verb" --argjson h "$h" --argjson rc "$arc" '
    {step: $v, helper: $h, rc: $rc}
    + (if $rc == 126 then {pkexec: 126, detail: "permission declined"}
       elif $rc == 127 then {pkexec: 127, detail: "not authorized"} else {} end)')" \
    "$( (( arc == 126 || arc == 127 )) && echo "$arc" || echo 1)"
}

# ---------------------------------------------------------------- rescan

# Bring an ejected card back without replugging (§6.4): `pkexec helper
# rescan`, then the ordinary connect (driver, verify) for the card that
# reappears. Refused with modules_held while the modules stayed loaded after
# the eject (O2: the freeze case; the helper refuses it too). Already present
# is success with "already": true; nothing connected is not_connected; an
# enclosure bolt has not authorized yet is not_connected too (connect, not
# rescan, authorizes). The ejected marker goes once the helper has rescanned.
device_rescan() {
  local timeout_s args=() started
  DEV_QUIET=0
  timeout_s=$(config_get connect.timeout_s 30)
  while (( $# )); do
    case $1 in
      --timeout)
        timeout_s=${2:-}
        shift
        ;;
      --quiet) DEV_QUIET=1 ;;
      *)
        json_error usage "$(jq -cn --arg v "$1" '{detail: "device rescan [--timeout S] [--quiet]", got: $v}')"
        return 1
        ;;
    esac
    shift
  done
  [[ $timeout_s =~ ^[0-9]+$ ]] || timeout_s=30
  started=$(now_ms)
  DEV_FAIL_EVENT=connect_failed

  _dev_lock rescan
  case $? in
    0) ;;
    3)
      json_error busy '{"detail":"another eGPU job is running"}'
      return 3
      ;;
    *)
      json_error busy '{"detail":"cannot create the runtime directory"}'
      return 1
      ;;
  esac
  trap '_dev_unlock' EXIT

  local doc bdf held bolt_status
  doc=$(_dev_nolock status_collect '{"errors":0,"warnings":0}' null 0 '[]') || doc='{}'
  DEV_PHASE=$(jq -r '.phase // "absent"' <<<"$doc")
  bdf=$(jq -r '.pci.bdf // empty' <<<"$doc")
  held=$(jq -r '.modules.held_after_eject // false' <<<"$doc")
  bolt_status=$(jq -r '.bolt.status // empty' <<<"$doc")

  if [[ -n $bdf ]]; then
    say "The eGPU is on the PCI bus already."
    jq -cn --argjson doc "$doc" --argjson ms "$(( $(now_ms) - started ))" \
      '{ok: true, phase: $doc.phase, already: true, rescanned: false, bdf: $doc.pci.bdf, elapsed_ms: $ms}'
    return 0
  fi
  case $DEV_PHASE in
    ejected | authorized) ;;
    *)
      _dev_fail not_connected "$(jq -cn --arg s "$bolt_status" '{detail: (if $s == "" then "No eGPU or Thunderbolt enclosure is connected."
        else "The enclosure is not authorized yet: connect it instead (device connect)." end)}')"
      return
      ;;
  esac
  if [[ $held == true ]]; then
    _dev_fail modules_held '{"detail":"The driver is still loaded from before the eject. Log out (or reboot) before reconnecting the eGPU."}'
    return
  fi

  say "Rescanning the PCI bus…"
  _dev_admin rescan
  local arc=$?
  if (( arc != 0 )); then
    local h code=rescan_failed
    h=$(jq -c 'select(type == "object")' <<<"$DEV_ADMIN_OUT" 2>/dev/null) || h=''
    [[ -n $h ]] || h=null
    if (( arc == 2 )); then
      _dev_fail helper_missing "$(jq -c 'del(.error)' <<<"$DEV_ADMIN_OUT")"
    elif (( arc == 3 )); then
      _dev_fail busy '{"detail":"the helper is busy"}' 3
    else
      [[ $(jq -r '.error // empty' <<<"$h" 2>/dev/null) == modules_held ]] && code=modules_held
      _dev_fail "$code" "$(jq -cn --argjson h "$h" --argjson rc "$arc" '{helper: $h, rc: $rc}
        + (if $rc == 126 then {pkexec: 126, detail: "permission declined"}
           elif $rc == 127 then {pkexec: 127, detail: "not authorized"} else {} end)')" \
        "$( (( arc == 126 || arc == 127 )) && echo "$arc" || echo 1)"
    fi
    return
  fi
  rm -f -- "$EGPU_RUN/ejected"
  _dev_unlock

  # The card is back on the bus (or about to be): the rest is a connect.
  args=(--timeout "$timeout_s" --quiet)
  local out rc
  out=$(device_connect "${args[@]}")
  rc=$?
  jq -c --argjson ms "$(( $(now_ms) - started ))" '. + {rescanned: true, elapsed_ms: $ms}' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
  if (( rc == 0 )) && (( !DEV_QUIET )); then
    _dev_notify "eGPU ready" "$(jq -r '.gpu.name // ""' <<<"$out" 2>/dev/null)"
  fi
  return "$rc"
}

# ---------------------------------------------------------------- holders verb

# `device holders`: what step 4 of eject would find, read-only. Needs the
# helper (other users' holders are root-only to see).
device_holders() {
  local bdf family rc
  (( $# == 0 )) || { json_error usage '{"detail":"device holders"}'; return 1; }
  bdf=$(_dev_bdf)
  if [[ -n $bdf ]] && backend_select "$bdf" && [[ $BE_STATUS == implemented ]]; then
    :
  else
    # No card: the holders of the backend's nodes are still worth listing
    # (they are what keeps the modules loaded after an eject).
    backend_load nvidia || true
  fi
  family=$(_dev_family)
  if [[ -n $bdf ]]; then
    _dev_survey "$bdf" "$family"
    rc=$?
  else
    DEV_GPU='{"ok":false}'
    _dev_admin holders
    DEV_ADMIN_RC=$?
    rc=0
    if (( DEV_ADMIN_RC != 0 )) || ! jq -e '.holders | type == "array"' <<<"$DEV_ADMIN_OUT" >/dev/null 2>&1; then
      rc=2
    else
      DEV_SURVEY=$(_dev_classify "$DEV_ADMIN_OUT" '[]' "$(_dev_offload_users "" "$family")" "$family")
    fi
  fi
  if (( rc == 3 )); then
    json_error smi_hung "$(jq -cn --arg bdf "$bdf" --argjson g "$DEV_GPU" '{bdf: $bdf, gpu: $g}')"
    return 1
  elif (( rc == 2 )); then
    if (( DEV_ADMIN_RC == 2 )); then
      printf '%s\n' "$DEV_ADMIN_OUT"
      return 1
    fi
    local h
    h=$(jq -c 'select(type == "object")' <<<"$DEV_ADMIN_OUT" 2>/dev/null) || h=''
    json_error holders_failed "$(jq -cn --argjson h "${h:-null}" --argjson rc "$DEV_ADMIN_RC" '{helper: $h, rc: $rc}')"
    (( DEV_ADMIN_RC == 126 || DEV_ADMIN_RC == 127 )) && return "$DEV_ADMIN_RC"
    return 1
  fi
  jq -cn --arg bdf "$bdf" --argjson s "$DEV_SURVEY" '
    {bdf: (if $bdf == "" then null else $bdf end),
     holders: $s, blocking: ([$s[] | select(.blocks)] | length),
     can_close: ([$s[] | select(.blocks and .closeable)] | length > 0)}'
}

# ---------------------------------------------------------------- dispatch

device_main() {
  local verb=${1:-}
  [[ $# -gt 0 ]] && shift
  case $verb in
    connect) device_connect "$@" ;;
    eject) device_eject "$@" ;;
    rescan) device_rescan "$@" ;;
    holders) device_holders "$@" ;;
    *)
      json_error usage "$(jq -cn --arg v "$verb" '{detail: "device connect [--timeout S] [--enroll] [--quiet] | eject [--close] [--quiet] | rescan [--timeout S] [--quiet] | holders", got: $v}')"
      return 1
      ;;
  esac
}
