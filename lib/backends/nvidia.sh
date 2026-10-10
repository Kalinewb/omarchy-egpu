#!/bin/bash

# nvidia backend (v1, implemented). plan-engine.md §4.2.
#
# Sourced by backend_load in common.sh. status, device and health call only
# these functions and never say "nvidia" themselves.
#
# Interface additions beyond the §4.2 table, both read-only:
#   BE_STATUS        implemented|stub, so status can say "not supported yet"
#   be_kms_params    {"modeset":bool|null,"fbdev":bool|null} from the live
#                    module parameters; null when unloaded or unreadable
#                    (nvidia_drm's are root-only on 580xx, dev/e0-facts.md)
#   be_flatpak_gl_ext  the Flatpak GL extension Flatpak Steam needs for this
#                    driver (health steam.flatpak_gl, §8.7); with --prefix the
#                    id without the version

# shellcheck disable=SC2034
BE_STATUS=implemented

be_name() { echo nvidia; }

be_detect() {
  [[ $(pci_attr "$1" vendor) == 0x10de ]] && pci_is_display "$1"
}

be_kms_modules() { printf '%s\n' nvidia nvidia_modeset nvidia_drm nvidia_uvm; }

be_unload_modules() { printf '%s\n' nvidia_uvm nvidia_drm nvidia_modeset nvidia; }

be_dev_nodes() {
  local n
  for n in "$EGPU_DEV"/nvidia[0-9]* "$EGPU_DEV"/nvidiactl "$EGPU_DEV"/nvidia-uvm* "$EGPU_DEV"/nvidia-modeset; do
    [[ -e $n ]] && printf '/dev/%s\n' "${n#"$EGPU_DEV"/}"
  done
}

# be_offload_env <bdf> [run]
# Exactly the user's known-working set (scope.md, Hardware). One NVIDIA GPU, so
# no __NV_PRIME_RENDER_OFFLOAD_PROVIDER.
#
# With `run` (bin/egpu-run, never Steam's managed string, whose bytes are a
# contract with the games already switched on, §8.3) it also points EGL at
# NVIDIA's vendor file. The toggle file pins the session's
# __EGL_VENDOR_LIBRARY_FILENAMES to Mesa (scope.md DECISIONS 2026-10-10,
# dev/e0-facts.md), and an app started from the session inherits that, so an
# EGL app would never see libEGL_nvidia. The file is found, not assumed: the
# first glvnd vendor file whose library is libEGL_nvidia, in glvnd's own
# search order (EGPU_GLVND_DIRS overrides it for the tests).
be_offload_env() {
  printf '%s\n' __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
  [[ ${2:-} == run ]] || return 0
  local json
  json=$(_nv_egl_vendor_json) && printf '__EGL_VENDOR_LIBRARY_FILENAMES=%s\n' "$json"
  return 0
}

_nv_egl_vendor_json() {
  local dirs d f
  IFS=: read -r -a dirs <<<"${EGPU_GLVND_DIRS:-$EGPU_ETC/glvnd/egl_vendor.d:${EGPU_USRSHARE:-/usr/share}/glvnd/egl_vendor.d}"
  for d in "${dirs[@]}"; do
    for f in "$d"/*.json; do
      [[ -r $f ]] || continue
      [[ $(jq -r '.ICD.library_path // empty' "$f" 2>/dev/null) == libEGL_nvidia.so* ]] &&
        { printf '%s\n' "$f"; return 0; }
    done
  done
  return 1
}

be_steam_extras() {
  jq -cn '[{key: "PROTON_ENABLE_NVAPI", value: "1", label: "NVAPI (DLSS)", id: "nvapi"}]'
}

# org.freedesktop.Platform.GL.nvidia-580-178-04 for driver 580.178.04. The
# version is known only while the module is loaded; then nothing is printed.
be_flatpak_gl_ext() {
  local prefix=org.freedesktop.Platform.GL.nvidia- v
  [[ ${1:-} == --prefix ]] && { echo "$prefix"; return 0; }
  v=$(read_attr "$EGPU_SYS/module/nvidia/version") ||
    v=$(sed -nE 's/.*Kernel Module +([0-9.]+).*/\1/p' "$EGPU_PROC/driver/nvidia/version" 2>/dev/null)
  [[ $v =~ ^[0-9.]+$ ]] || return 0
  echo "$prefix${v//./-}"
}

_nv_bool_param() {
  local v
  v=$(read_attr "$EGPU_SYS/module/nvidia_drm/parameters/$1") || { echo null; return; }
  case $v in Y | y | 1) echo true ;; N | n | 0) echo false ;; *) echo null ;; esac
}

be_kms_params() {
  if ! module_loaded nvidia_drm; then
    echo '{"modeset":null,"fbdev":null}'
    return 0
  fi
  jq -cn --argjson m "$(_nv_bool_param modeset)" --argjson f "$(_nv_bool_param fbdev)" \
    '{modeset: $m, fbdev: $f}'
}

# _nv_smi <outfile> <args...>
# Runs nvidia-smi with the hang guard of §4.2. Returns nvidia-smi's status, or
#   124  timed out and was killed (it was not in D state)
#   125  timed out in D state: left alone, never killed or retried. That is the
#        rmapiLockAcquire hang (binding fact 1); killing does not help and a
#        retry would only add a second stuck process.
# "Never retried" holds across processes too: the stuck pid is remembered in
# $EGPU_RUN/smi-hung, and while it is still an nvidia-smi in D state every
# later call (the watcher's next recompute, `status --json`, connect) answers
# 125 at once instead of starting another one.
_nv_smi() {
  local out=$1 pid waited=0 limit st mark="$EGPU_RUN/smi-hung"
  shift
  if read -r pid 2>/dev/null <"$mark"; then
    if [[ $pid =~ ^[0-9]+$ ]] && _nv_smi_stuck "$pid"; then
      return 125
    fi
    rm -f -- "$mark"
  fi
  limit=$(( ${EGPU_SMI_TIMEOUT:-10} * 10 ))
  nvidia-smi "$@" >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      st=$(proc_state "$pid")
      if [[ $st == D ]]; then
        disown "$pid" 2>/dev/null
        mkdir -p -- "$EGPU_RUN" 2>/dev/null && printf '%s\n' "$pid" >"$mark"
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

# Is <pid> still an nvidia-smi in D state? (A reused pid is something else.)
_nv_smi_stuck() {
  local stat
  stat=$(read_attr "$EGPU_PROC/$1/stat") || return 1
  [[ $stat == *"(nvidia-smi) D "* ]]
}

# be_verify <bdf>: {ok, driver, version, name, temp_c, util_pct, mem_used_mb,
# procs[]}, or {ok:false, error}. procs come from `-q -d PIDS`, which lists
# graphics (G) clients too; --query-compute-apps would miss a PRIME-offloaded
# game or vkcube.
be_verify() {
  local bdf=$1 drv tmp rc csv
  drv=$(pci_driver "$bdf")
  if [[ $drv != nvidia ]]; then
    jq -cn --arg d "$drv" '{ok: false, error: "not_bound", driver: (if $d == "" then null else $d end)}'
    return 0
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo '{"ok":false,"error":"smi_missing","driver":"nvidia"}'
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/omarchy-egpu-smi.XXXXXX") || return 1
  _nv_smi "$tmp" --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used \
    --format=csv,noheader,nounits -i "$bdf"
  rc=$?
  if (( rc == 124 || rc == 125 )); then
    rm -f "$tmp"
    jq -cn --arg s "$([[ $rc == 125 ]] && echo D || echo timeout)" \
      '{ok: false, error: "smi_hung", driver: "nvidia", state: $s}'
    return 0
  fi
  csv=$(head -n1 "$tmp")
  if (( rc != 0 )) || [[ -z $csv ]]; then
    rm -f "$tmp"
    jq -cn --argjson rc "$rc" '{ok: false, error: "smi_failed", driver: "nvidia", rc: $rc}'
    return 0
  fi
  local procs='[]'
  if _nv_smi "$tmp" -q -d PIDS -i "$bdf"; then
    procs=$(awk '
      function flush() {
        if (pid != "") printf "%s\t%s\t%s\t%s\n", pid, type, name, mem
        pid = type = name = mem = ""
      }
      /Process ID[ \t]*:/ { flush(); sub(/.*: */, ""); pid = $0; next }
      /^[ \t]*Type[ \t]*:/ { sub(/.*: */, ""); type = $0; next }
      /^[ \t]*Name[ \t]*:/ { sub(/^[^:]*: */, ""); name = $0; next }
      /Used GPU Memory[ \t]*:/ { sub(/.*: */, ""); mem = $0; next }
      END { flush() }' "$tmp" |
      jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t") |
          {pid: (.[0] | tonumber? // null), type: .[1], name: .[2],
           mem_mb: ((.[3] | capture("(?<n>[0-9]+)")? | .n | tonumber) // null)})')
  fi
  rm -f "$tmp"
  jq -cn --arg csv "$csv" --argjson procs "${procs:-[]}" '
    def num: (gsub("^ +| +$"; "") | tonumber? // null);
    ($csv | split(",")) as $f |
    {ok: true, driver: "nvidia",
     name: ($f[0] | gsub("^ +| +$"; "")),
     version: ($f[1] | gsub("^ +| +$"; "")),
     temp_c: ($f[2] | num), util_pct: ($f[3] | num), mem_used_mb: ($f[4] | num),
     procs: $procs}'
}

# ---------------------------------------------------------------- health

# Lines of every modprobe.d config, in the precedence directories.
_nv_modprobe_lines() {
  local f
  for f in "$EGPU_ETC"/modprobe.d/*.conf "$EGPU_USRLIB"/modprobe.d/*.conf; do
    [[ -r $f ]] || continue
    sed -e 's/#.*//' -e "s|^|${f}:|" "$f"
  done
}

be_health() {
  local lines drm_opts nv_opts level detail
  lines=$(_nv_modprobe_lines)
  local installed=0 kver
  kver=$(uname -r)
  if module_loaded nvidia || compgen -G "$EGPU_USRLIB/modules/$kver/*/nvidia.ko*" >/dev/null ||
    compgen -G "$EGPU_USRLIB/modules/$kver/*/*/nvidia.ko*" >/dev/null; then
    installed=1
  fi

  # kernel.modprobe_options
  drm_opts=$(grep -E ':[[:space:]]*options[[:space:]]+nvidia[-_]drm[[:space:]]' <<<"$lines")
  nv_opts=$(grep -E ':[[:space:]]*options[[:space:]]+nvidia[[:space:]]' <<<"$lines" |
    sed -E 's/^[^:]*:[[:space:]]*options[[:space:]]+nvidia[[:space:]]+//' | tr -s ' \t' '\n\n' | grep -v '^$' |
    awk '!seen[$0]++' | paste -sd' ')
  if grep -qE '(^|[[:space:]])modeset=0' <<<"$drm_opts"; then
    level=error detail="nvidia-drm modeset=0 is set: the HDMI port on the eGPU cannot be used by the compositor."
  elif grep -qE '(^|[[:space:]])modeset=1' <<<"$drm_opts"; then
    level=ok detail="nvidia-drm modeset=1 is set (${drm_opts%%:*})."
  else
    level=warn detail="No 'options nvidia-drm modeset=1'. It is the default on 580xx, but nothing pins it."
  fi
  [[ -n $nv_opts ]] && detail+=" nvidia options: $nv_opts."
  if [[ $level == ok ]]; then
    health_row kernel.modprobe_options boot ok "NVIDIA module options" "$detail"
  else
    health_row kernel.modprobe_options boot "$level" "NVIDIA module options" "$detail" system "Install the system half"
  fi

  # kernel.nouveau_blacklist: nouveau binding the eGPU first would block nvidia.
  if grep -qE ':[[:space:]]*blacklist[[:space:]]+nouveau([[:space:]]|$)' <<<"$lines"; then
    health_row kernel.nouveau_blacklist boot ok "nouveau is blacklisted" \
      "$(grep -E ':[[:space:]]*blacklist[[:space:]]+nouveau' <<<"$lines" | head -n1 | cut -d: -f1)"
  else
    health_row kernel.nouveau_blacklist boot error "nouveau is not blacklisted" \
      "nouveau could claim the eGPU before nvidia on hot-plug." system "Install the system half"
  fi

  # driver.modeset / driver.fbdev: the live values, root-only on this driver.
  local p modeset fbdev
  p=$(be_kms_params)
  modeset=$(jq -r '.modeset' <<<"$p")
  fbdev=$(jq -r '.fbdev' <<<"$p")
  if ! module_loaded nvidia_drm; then
    health_row driver.modeset driver info "nvidia-drm not loaded" \
      "It loads when the eGPU is connected; the live value is checked then." none "" unknown
  else
    case $modeset in
      true) health_row driver.modeset driver ok "KMS (modeset) is on" "/sys/module/nvidia_drm/parameters/modeset = Y" none "" Y ;;
      false) health_row driver.modeset driver error "KMS (modeset) is off" \
        "The compositor cannot drive the eGPU's HDMI port without it." system "Install the system half" N ;;
      *) health_row driver.modeset driver info "KMS (modeset): unknown" \
        "The live parameter is readable by root only. The modprobe options above say what was asked for." none "" unknown ;;
    esac
  fi
  case $fbdev in
    true) health_row driver.fbdev driver info "fbdev is on" "Default since 570 with modeset=1. One more client to release at eject (plan O3)." none "" Y ;;
    false) health_row driver.fbdev driver info "fbdev is off" "Wayland scanout does not need it." none "" N ;;
    *) health_row driver.fbdev driver info "fbdev: unknown" \
      "$(module_loaded nvidia_drm && echo 'The live parameter is readable by root only.' || echo 'nvidia-drm is not loaded.')" none "" unknown ;;
  esac

  # driver.flavour
  local ver
  ver=$(read_attr "$EGPU_PROC/driver/nvidia/version")
  if [[ -n $ver ]]; then
    if [[ $ver == *"Open Kernel Module"* ]]; then
      health_row driver.flavour driver info "NVIDIA open kernel modules" \
        "Open modules need GSP firmware; GSP hangs (rmapiLockAcquire) are what moved this setup to the closed 580xx driver."
    else
      detail=$(sed -E 's/.*Kernel Module +([0-9.]+).*/\1/' <<<"$ver")
      health_row driver.flavour driver info "NVIDIA closed kernel modules $detail" \
        "Omarchy would pick nvidia-open-dkms for this GPU; closed 580xx avoids the GSP hangs seen with it."
    fi
  elif (( installed )); then
    health_row driver.flavour driver info "NVIDIA driver installed, not loaded" "Flavour is read once the eGPU is connected."
  else
    health_row driver.flavour driver info "NVIDIA driver not installed" \
      "Only needed for an NVIDIA eGPU. Install the 580xx (closed) or open dkms package that matches the card."
  fi

  # driver.persistenced
  if compgen -G "$EGPU_ETC/systemd/system/*.wants/nvidia-persistenced.service" >/dev/null; then
    health_row driver.persistenced driver warn "nvidia-persistenced is enabled" \
      "It holds the GPU open as root, so eject cannot release it. Disable it: sudo systemctl disable --now nvidia-persistenced" none "Instructions"
  else
    health_row driver.persistenced driver ok "nvidia-persistenced is not enabled" ""
  fi

  # driver.sleep (O5)
  local units=() u
  for u in nvidia-suspend nvidia-resume nvidia-hibernate; do
    compgen -G "$EGPU_ETC/systemd/system/*.wants/$u.service" >/dev/null && units+=("$u")
  done
  if (( ${#units[@]} )); then
    health_row driver.sleep driver info "NVIDIA sleep units: ${units[*]}" \
      "They do nothing while the driver is unloaded. With the eGPU attached, VRAM is saved to disk on suspend; eject first if you will unplug it while asleep."
  else
    health_row driver.sleep driver info "NVIDIA sleep units not enabled" \
      "With the eGPU attached during suspend, VRAM contents may be lost. They are not needed after an eject."
  fi
}

# ---------------------------------------------------------------- display roles
#
# Called by lib/display.sh only (the toggle file, plan-engine.md §7.2), which
# provides va_driver_installed and glvnd_egl_vendor_file.
#
# Secondary role: what the session needs so it stays on the primary GPU while
# this card is attached, and on any login with it attached. Needs, in file
# order (display.sh renders each with the primary's values):
#   glx_va       GLX vendor and VA-API driver of the primary. Omarchy's
#                nvidia.lua sets NVIDIA's for the whole session whenever an
#                NVIDIA card is present at config load (dev/e0-facts.md, E1b).
#   hypr_config  the be_hypr_config options
#   egl_vendor   only the primary's glvnd EGL vendor: glvnd loads every vendor
#                otherwise, and libEGL_nvidia keeps /dev/nvidia* open
#   qt_decode    Qt Multimedia's hardware decoders limited to the primary's
#                (it probed CUDA/VDPAU and held ~900 MiB, dev/e0-facts.md)
# be_session_note <need|header> prints that block's comment. @PRIMARY@ and
# @DECODE@ become the primary's label and decode API.

be_session_needs() { printf '%s\n' glx_va hypr_config egl_vendor qt_decode; }

be_session_note() {
  case $1 in
    header) cat <<'NOTE' ;;
Omarchy's nvidia.lua points the whole session at the NVIDIA GLX/VA-API drivers
whenever an NVIDIA card is present at login. With an eGPU that makes the shell and
every app render on the eGPU and cross the Thunderbolt link. Keep the session on the
laptop GPU; apps opt in to the eGPU with the offload variables (egpu-run / Steam).
NOTE
    hypr_config) cat <<'NOTE' ;;
With a second GPU driving a monitor, Hyprland's "auto" (2) falls back to a software
cursor that moves only once per frame. Use the hardware cursor plane instead.
NOTE
    egl_vendor) cat <<'NOTE' ;;
glvnd loads every installed EGL vendor, so the shell opens the NVIDIA card even when it
renders on @PRIMARY@. That wastes power and keeps the driver busy, which blocks a safe eject.
Apps that want the eGPU opt in through egpu-run / the Steam launch options.
NOTE
    qt_decode) cat <<'NOTE' ;;
Qt Multimedia probes every hardware video decoder it can find, including CUDA/VDPAU on
the eGPU, and the shell then keeps the card open. Restrict it to @PRIMARY@'s @DECODE@.
NOTE
  esac
}

# Hyprland options as dotted key=value. "auto" (2) gives a software cursor on
# a monitor this card drives (cursor lag on the TV, dev/e0-facts.md).
be_hypr_config() { echo cursor.no_hardware_cursors=0; }

# Primary role: an NVIDIA GPU driving the session (a desktop, not this
# plugin's case). Untested; here so the interface is complete.
be_primary_match() { [[ $(pci_attr "$1" vendor) == 0x10de ]] && pci_is_display "$1"; }

be_primary_session() {
  local va=''
  va_driver_installed nvidia && va=nvidia
  printf '%s\n' label=NVIDIA glx=nvidia "va=$va" "egl=$(glvnd_egl_vendor_file libEGL_nvidia)" \
    qt_decode=cuda decode_label=CUDA
}
