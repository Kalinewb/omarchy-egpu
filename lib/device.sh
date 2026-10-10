#!/bin/bash

# device.sh — module: connect. plan-engine.md §6.1.
#
#   omarchy-egpu device connect [--timeout S] [--enroll] [--quiet]
#   omarchy-egpu connect ...                  the same
#
# eject, holders and rescan are phase E5; until then they answer "usage" like
# any verb the engine does not have.
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
# Events: a failure posts `connect_failed` to the running watcher (it cannot
# be derived from two status documents); `authorized` and `ready` come from
# the watcher itself as the phase moves.

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
  local verb=$1 v want have reason='' ok=0
  shift
  for v in "${DEV_ADMIN_VERBS[@]}"; do [[ $v == "$verb" ]] && ok=1; done
  if (( !ok )); then
    DEV_ADMIN_OUT=$(json_error usage "$(jq -cn --arg v "$verb" '{detail: "not a helper verb", verb: $v}')")
    return 1
  fi
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
  DEV_ADMIN_OUT=$(pkexec "$EGPU_ADMIN" "$verb" "$@")
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

# _dev_fail <code> [extra-json] [exit]: the error on stdout, connect_failed
# to the watcher, the exit status returned (default 1).
_dev_fail() {
  local code=$1 extra=${2:-'{}'} rc=${3:-1}
  extra=$(jq -c --arg p "${DEV_PHASE:-}" '. + {phase: (if $p == "" then null else $p end)}' <<<"$extra")
  json_error "$code" "$extra"
  _dev_event connect_failed "$(jq -c --arg e "$code" '{error: $e} + .' <<<"$extra")"
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

# ---------------------------------------------------------------- dispatch

device_main() {
  local verb=${1:-}
  [[ $# -gt 0 ]] && shift
  case $verb in
    connect) device_connect "$@" ;;
    *)
      json_error usage "$(jq -cn --arg v "$verb" '{detail: "device connect [--timeout S] [--enroll] [--quiet]", got: $v}')"
      return 1
      ;;
  esac
}
