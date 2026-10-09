#!/bin/bash

# health.sh — module: setup/health checks. plan-engine.md §9.
#
#   omarchy-egpu health [--json|--human]   the rows, as one JSON array
#
# Every row answers on any machine, including one that has never seen an eGPU
# (first-run Setup reads this list). Read-only: nothing here changes a file.
# `health fix` and `health bundle` arrive with the phases that own the files
# they touch. Steam rows (steam.*) arrive with the Steam module (E6).
#
# Row: {id, group, level: ok|info|warn|error|skipped, title, detail,
#       fix: {kind: user|system|none, label}, value?}
# `value` is additive: the raw reading where there is one (Y, N, unknown).

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

SYSTEM_FIX="Install the system half"

# MODULES words from every mkinitcpio config, as "file<TAB>module" lines.
_mkinitcpio_modules() {
  local f
  for f in "$EGPU_ETC"/mkinitcpio.conf "$EGPU_ETC"/mkinitcpio.conf.d/*.conf; do
    [[ -r $f ]] || continue
    sed -e 's/#.*//' "$f" | tr '\n' ' ' |
      grep -oE 'MODULES\+?=\([^)]*\)' |
      sed -E 's/^MODULES\+?=\(//; s/\)$//' | tr ' ' '\n' | tr -d "\"'" |
      grep -v '^$' | sed "s|^|${f}\t|"
  done
}

# Backend modules that must never load at boot: the KMS modules of every
# backend that supports unloading.
_boot_forbidden_modules() {
  local b
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    backend_load "$b" && be_kms_modules
  done < <(backends_unloadable) | while IFS= read -r m; do module_norm "$m"; done | sort -u
}

_check_bolt() {
  local domains=0 devs
  compgen -G "$EGPU_SYS/bus/thunderbolt/devices/domain*" >/dev/null && domains=1
  if (( !domains )); then
    health_row bolt.daemon bolt error "No Thunderbolt/USB4 controller" \
      "This machine has no Thunderbolt or USB4 domain, so a Thunderbolt eGPU cannot attach. An OCuLink eGPU still shows up as a removable PCI device." \
      none ""
    return
  fi
  if ! command -v boltctl >/dev/null 2>&1; then
    health_row bolt.daemon bolt error "bolt is not installed" \
      "boltd authorizes Thunderbolt devices. Install the bolt package." none "Install bolt"
    health_row bolt.device bolt skipped "Enclosure" "Needs bolt." none ""
    return
  fi
  if ! devs=$(bolt_devices); then
    health_row bolt.daemon bolt error "boltd does not answer" \
      "boltctl list failed. Is bolt.service running?" none ""
    health_row bolt.device bolt skipped "Enclosure" "Needs boltd." none ""
    return
  fi
  health_row bolt.daemon bolt ok "boltd is running" "$(jq 'length' <<<"$devs") device(s) known."

  # The enclosure: a profile match first, then any stored device, then any.
  local pick='' i n dev
  n=$(jq 'length' <<<"$devs")
  for ((i = 0; i < n; i++)); do
    dev=$(jq -c ".[$i]" <<<"$devs")
    if [[ $(profile_match "$(jq -r .vendor <<<"$dev")" "$(jq -r .name <<<"$dev")") != generic ]] ||
      enclosure_known "$(jq -r .uuid <<<"$dev")"; then
      pick=$dev
      break
    fi
  done
  [[ -n $pick ]] || pick=$(jq -c 'map(select(.status == "connected" or .status == "authorizing")) | .[0] // empty' <<<"$devs")
  [[ -n $pick ]] || pick=$(jq -c 'map(select(.stored)) | .[0] // empty' <<<"$devs")
  if [[ -z $pick ]]; then
    health_row bolt.device bolt warn "No enclosure seen yet" \
      "Plug in the eGPU enclosure. bolt will ask to authorize it the first time." none ""
    return
  fi
  local label status stored policy
  label="$(jq -r '"\(.vendor) \(.name)"' <<<"$pick")"
  status=$(jq -r .status <<<"$pick")
  stored=$(jq -r .stored <<<"$pick")
  policy=$(jq -r '.policy // "-"' <<<"$pick")
  if [[ $status == auth-error ]]; then
    health_row bolt.device bolt error "$label: authorization failed" "bolt status auth-error." user "Enroll (bolt asks for permission)"
  elif [[ $stored != true ]]; then
    health_row bolt.device bolt warn "$label is not enrolled" \
      "Without enrolling, it has to be authorized on every plug-in. Enroll with policy auto." user "Enroll (bolt asks for permission)"
  elif [[ $policy == iommu || $policy == auto ]]; then
    health_row bolt.device bolt ok "$label enrolled, policy $policy" "Status: $status."
  else
    health_row bolt.device bolt warn "$label enrolled, policy $policy" \
      "With policy $policy it is not authorized automatically on plug-in." user "Enroll with policy auto"
  fi
}

_check_boot() {
  local mods forbidden_re
  mods=$(_mkinitcpio_modules)

  # kernel.thunderbolt_early
  if awk -F'\t' '$2 == "thunderbolt" { found = 1 } END { exit !found }' <<<"$mods"; then
    health_row kernel.thunderbolt_early boot ok "thunderbolt loads early" \
      "$(awk -F'\t' '$2 == "thunderbolt" { print $1; exit }' <<<"$mods")"
  else
    health_row kernel.thunderbolt_early boot warn "thunderbolt is not in the initramfs" \
      "Loading it early lets an enclosure attached at boot come up before the desktop." system "$SYSTEM_FIX"
  fi

  local forbidden
  forbidden=$(_boot_forbidden_modules)
  if [[ -z $forbidden ]]; then
    health_row boot.modules_load_mask boot skipped "Boot-time module loading" "No backend with unloadable modules." none ""
    health_row boot.initramfs_nvidia boot skipped "eGPU driver in the initramfs" "No backend with unloadable modules." none ""
    health_row boot.mkinitcpio_conf boot skipped "eGPU driver in mkinitcpio" "No backend with unloadable modules." none ""
    return
  fi
  forbidden_re="^($(paste -sd'|' <<<"$forbidden"))$"

  # boot.modules_load_mask (§9.2): a shipped modules-load.d file naming a
  # backend module must be masked by an /etc file of the same basename. Any
  # /etc file that names one itself is an error too.
  local f line base bad=() masked=() stale=() d
  for f in "$EGPU_USRLIB"/modules-load.d/*.conf; do
    [[ -r $f ]] || continue
    base=${f##*/}
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n $line ]] || continue
      if [[ $(module_norm "$line") =~ $forbidden_re ]]; then
        if [[ -e $EGPU_ETC/modules-load.d/$base || -L $EGPU_ETC/modules-load.d/$base ]] &&
          ! grep -qE "^[[:space:]]*($(paste -sd'|' <<<"$forbidden" | sed 's/_/[-_]/g'))[[:space:]]*$" "$EGPU_ETC/modules-load.d/$base" 2>/dev/null; then
          masked+=("$base")
        else
          bad+=("/usr/lib/modules-load.d/$base loads $line at boot; /etc/modules-load.d/$base does not mask it")
        fi
        break
      fi
    done <"$f"
  done
  d="$EGPU_ETC/modules-load.d"
  for f in "$d"/*.conf; do
    [[ -r $f && ! -L $f ]] || continue
    base=${f##*/}
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n $line ]] || continue
      if [[ $(module_norm "$line") =~ $forbidden_re ]]; then
        bad+=("/etc/modules-load.d/$base loads $line at boot")
        break
      fi
    done <"$f"
    # An empty file with no shipped counterpart masks nothing: usually the
    # mask of a package that was renamed (nvidia-utils → nvidia-580xx-utils).
    if [[ ! -s $f && ! -e $EGPU_USRLIB/modules-load.d/$base ]]; then
      stale+=("$base")
    fi
  done
  local detail
  if (( ${#bad[@]} )); then
    detail=$(printf '%s; ' "${bad[@]}")
    detail="${detail%; }."
    (( ${#stale[@]} )) && detail+=" Stale mask that masks nothing: $(printf '/etc/modules-load.d/%s\n' "${stale[@]}" | paste -sd' ')."
    detail+=" Loading the driver with no card present is the condition that froze this setup before."
    health_row boot.modules_load_mask boot error "eGPU driver loads at boot" "$detail" system "$SYSTEM_FIX"
  else
    detail="No modules-load.d file loads a backend module."
    (( ${#masked[@]} )) && detail+=" Masked: $(printf '%s\n' "${masked[@]}" | paste -sd' ')."
    (( ${#stale[@]} )) && detail+=" Stale empty file: $(printf '%s\n' "${stale[@]}" | paste -sd' ')."
    health_row boot.modules_load_mask boot ok "eGPU driver does not load at boot" "$detail"
  fi

  # boot.mkinitcpio_conf: no MODULES entry adds a backend module.
  local hits
  hits=$(awk -F'\t' -v re="$forbidden_re" '{ m = $2; gsub("-", "_", m); if (m ~ re) print $1 ": " $2 }' <<<"$mods")
  if [[ -n $hits ]]; then
    health_row boot.mkinitcpio_conf boot error "mkinitcpio adds the eGPU driver" \
      "$(tr '\n' ';' <<<"$hits" | sed 's/;$//; s/;/; /g'). The initramfs must not carry it; the driver loads on connect. Remove it (with a backup)." \
      system "$SYSTEM_FIX"
  else
    health_row boot.mkinitcpio_conf boot ok "mkinitcpio does not add the eGPU driver" ""
  fi

  # boot.initramfs_nvidia (§9.1). /boot is root-only on many machines; then
  # this needs the helper's inspect-initramfs verb (E7).
  local imgs=() img found=() readable=0
  for img in "$EGPU_BOOT"/*.img "$EGPU_BOOT"/EFI/Linux/*.efi; do
    [[ -e $img ]] && imgs+=("$img")
  done
  local warn_rebuild="Do not rebuild the initramfs with the eGPU attached."
  if ! command -v lsinitcpio >/dev/null 2>&1; then
    health_row boot.initramfs_nvidia boot skipped "eGPU driver in the initramfs" \
      "lsinitcpio is not installed. $warn_rebuild" none ""
  elif [[ ! -r $EGPU_BOOT || ! -x $EGPU_BOOT ]] || (( ${#imgs[@]} == 0 )); then
    health_row boot.initramfs_nvidia boot skipped "eGPU driver in the initramfs" \
      "$EGPU_BOOT is readable by root only; the system helper checks it once installed. $warn_rebuild" none ""
  else
    for img in "${imgs[@]}"; do
      [[ -r $img ]] || continue
      readable=1
      local listing
      listing=$(timeout 30 lsinitcpio -l "$img" 2>/dev/null | sed 's|.*/||; s|\.ko.*||' | tr '-' '_')
      if grep -qE "$forbidden_re" <<<"$listing"; then
        found+=("${img##*/}")
      fi
    done
    if (( ${#found[@]} )); then
      health_row boot.initramfs_nvidia boot error "The initramfs carries the eGPU driver" \
        "$(printf '%s ' "${found[@]}")contain(s) it, so it loads at boot. Rebuild with the eGPU unplugged. $warn_rebuild" none "Instructions"
    elif (( readable )); then
      health_row boot.initramfs_nvidia boot ok "The initramfs does not carry the eGPU driver" "$warn_rebuild"
    else
      health_row boot.initramfs_nvidia boot skipped "eGPU driver in the initramfs" \
        "The images are readable by root only; the system helper checks them once installed. $warn_rebuild" none ""
    fi
  fi
}

# The backend rows: the detected device's backend, else the configured one,
# else every implemented backend.
_check_backend() {
  local bdf b want
  bdf=$(pci_egpu_candidates | head -n1)
  if [[ -n $bdf ]] && backend_select "$bdf"; then
    b=$EGPU_BACKEND
    if [[ $BE_STATUS != implemented ]]; then
      health_row backend.supported driver warn "$(pci_attr "$bdf" vendor) eGPU: backend '$b' is a stub" \
        "The card is detected, but connect, eject and offload are not supported for it yet." none ""
      return
    fi
    be_health
    return
  fi
  want=$(config_str backend auto)
  if [[ $want != auto ]] && backend_load "$want" && [[ $BE_STATUS == implemented ]]; then
    be_health
    return
  fi
  for b in "${EGPU_BACKENDS[@]}"; do
    backend_load "$b" && [[ $BE_STATUS == implemented ]] && be_health
  done
}

_check_hypr() {
  local pid primary pcard log sig
  pid=$(compositor_pid)
  primary=$(pci_primary)
  pcard=$( [[ -n $primary ]] && pci_drm_card "$primary")

  # hypr.links (§10.3)
  local plink="$EGPU_DEV/dri/omarchy-egpu-primary" elink="$EGPU_DEV/dri/omarchy-egpu-external" bdf ecard
  bdf=$(pci_egpu_candidates | head -n1)
  ecard=$( [[ -n $bdf ]] && pci_drm_card "$bdf")
  if [[ ! -L $plink && ! -e $plink ]]; then
    health_row hypr.links display warn "GPU links are not installed" \
      "/dev/dri/omarchy-egpu-primary and -external pin the GPU order without cardN numbers (${primary:+primary is pci-$primary-card}). They come with the udev rule." \
      system "$SYSTEM_FIX"
  elif [[ -n $pcard && $(readlink -- "$plink") != *"$pcard" ]]; then
    health_row hypr.links display error "omarchy-egpu-primary points at the wrong card" \
      "It points at $(readlink -- "$plink"); the primary (pci-$primary-card) is $pcard." system "$SYSTEM_FIX"
  elif [[ -n $ecard && ! -e $elink && ! -L $elink ]]; then
    health_row hypr.links display warn "omarchy-egpu-external is missing" \
      "The eGPU ($ecard, pci-$bdf-card) is present but has no link." system "$SYSTEM_FIX"
  else
    health_row hypr.links display ok "GPU links installed" "primary → ${pcard:-?}${ecard:+, external → $ecard}"
  fi

  if [[ -z $pid ]]; then
    health_row hypr.order display skipped "Compositor GPU order" "Hyprland is not running." none ""
    health_row hypr.gpu_list display skipped "GPUs the compositor has open" "Hyprland is not running." none ""
    health_row hypr.session_env display skipped "Session GPU vendor" "Hyprland is not running." none ""
    return
  fi

  # hypr.order: what aquamarine logged at start.
  sig=${HYPRLAND_INSTANCE_SIGNATURE:-}
  log="${XDG_RUNTIME_DIR:-}/hypr/$sig/hyprland.log"
  if [[ -z $sig || ! -r $log ]]; then
    health_row hypr.order display skipped "Compositor GPU order" "Hyprland's log is not readable." none ""
  else
    local explicit at_primary
    explicit=$(grep -m1 -oE 'drm: Explicit device list .*' "$log")
    at_primary=$(grep -m1 -oE 'drm: gpu /dev/dri/[^ ]+ becomes primary' "$log" | awk '{print $3}')
    at_primary=${at_primary#/dev/dri/}
    if [[ -n $pcard && -n $at_primary && $at_primary != "$pcard" ]]; then
      health_row hypr.order display error "The compositor's primary GPU is not the laptop's" \
        "Hyprland made /dev/dri/$at_primary primary; the boot GPU is $pcard (pci-$primary-card). Pin the order, then log out and in." \
        user "Write the GPU order, then log out"
    elif [[ -n $explicit ]]; then
      health_row hypr.order display ok "GPU order pinned" "${explicit#drm: }; primary /dev/dri/${at_primary:-?}."
    elif [[ -n $at_primary ]]; then
      health_row hypr.order display warn "GPU order not pinned" \
        "Hyprland chose /dev/dri/$at_primary (pci-$primary-card) by itself. That is right now, but nothing keeps an eGPU attached at login from being picked. AQ_DRM_DEVICES is not set." \
        user "Write the GPU order, then log out"
    else
      health_row hypr.order display skipped "Compositor GPU order" "No 'becomes primary' line in Hyprland's log." none ""
    fi
  fi

  # hypr.gpu_list
  local cards c names=()
  cards=$(proc_open_dri "$pid" | grep '^card')
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    names+=("$c ($(drm_bypath_of_card "$c" || echo 'no by-path'))")
  done <<<"$cards"
  health_row hypr.gpu_list display info "Compositor has ${#names[@]} GPU(s) open" \
    "$( (( ${#names[@]} )) && printf '%s, ' "${names[@]}" | sed 's/, $//')"

  # hypr.session_env: GLX / VA-API vendor of the session, from the activation
  # environment uwsm exports (apps launched from the desktop get this).
  local env glx va want_glx pvendor
  if command -v systemctl >/dev/null 2>&1 && env=$(timeout 3 systemctl --user show-environment 2>/dev/null); then
    glx=$(sed -n 's/^__GLX_VENDOR_LIBRARY_NAME=//p' <<<"$env" | tail -n1)
    va=$(sed -n 's/^LIBVA_DRIVER_NAME=//p' <<<"$env" | tail -n1)
    pvendor=$( [[ -n $primary ]] && pci_attr "$primary" vendor)
    want_glx=mesa
    [[ $pvendor == 0x10de ]] && want_glx=nvidia
    if [[ -n $glx && $glx != "$want_glx" ]]; then
      health_row hypr.session_env display warn "Session GL vendor is $glx" \
        "__GLX_VENDOR_LIBRARY_NAME=$glx${va:+, LIBVA_DRIVER_NAME=$va} for every app, while the display runs on the primary GPU ($want_glx). A likely source of glitches." \
        user "Override in the toggle file"
    else
      health_row hypr.session_env display ok "Session GPU vendor matches the primary" \
        "__GLX_VENDOR_LIBRARY_NAME=${glx:-unset}, LIBVA_DRIVER_NAME=${va:-unset}."
    fi
  else
    health_row hypr.session_env display skipped "Session GPU vendor" "systemctl --user show-environment is not available." none ""
  fi
}

_check_tools_system() {
  if command -v vulkaninfo >/dev/null 2>&1; then
    health_row tools.vulkaninfo tools ok "vulkaninfo is installed" ""
  else
    health_row tools.vulkaninfo tools warn "vulkaninfo is not installed" \
      "Connect uses it to check that Vulkan sees the eGPU; without it that check is skipped." \
      user "omarchy-pkg-add vulkan-tools"
  fi

  local want have
  want=$(plugin_version)
  if [[ ! -x $EGPU_ADMIN ]]; then
    health_row system.helper system error "The system half is not installed" \
      "Connect, eject and rescan need $EGPU_ADMIN and its polkit action." system "$SYSTEM_FIX"
  else
    have=$(timeout 5 "$EGPU_ADMIN" version 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [[ $have != "$want" ]]; then
      health_row system.helper system error "The system half is out of date" \
        "Helper ${have:-unknown}, plugin $want." system "$SYSTEM_FIX"
    elif [[ ! -r $EGPU_POLICY ]]; then
      health_row system.helper system error "The polkit action is missing" "$EGPU_POLICY" system "$SYSTEM_FIX"
    else
      health_row system.helper system ok "System half $have installed" ""
    fi
  fi
}

_check_diag() {
  local devs profile='' i n dev params
  devs=$(bolt_devices 2>/dev/null) || devs='[]'
  n=$(jq 'length' <<<"$devs")
  for ((i = 0; i < n; i++)); do
    dev=$(jq -c ".[$i]" <<<"$devs")
    profile=$(profile_match "$(jq -r .vendor <<<"$dev")" "$(jq -r .name <<<"$dev")")
    [[ $profile != generic ]] && break
  done
  params=$(profile_json "${profile:-generic}" | jq -r '(.kernel_params_optional // []) | join(" ")')
  [[ -n $params ]] || return 0
  local cmdline active=()
  cmdline=$(read_attr "$EGPU_PROC/cmdline")
  local p
  for p in $params; do
    [[ " $cmdline " == *" $p "* ]] && active+=("$p")
  done
  health_row diag.kernel_params diag info "Optional kernel parameters ($profile)" \
    "Suggested by the Arch wiki External GPU page, not confirmed necessary: $params. Set now: ${active[*]:-none}."
}

# health_rows: every row, as one JSON array.
health_rows() {
  {
    _check_bolt
    _check_boot
    _check_backend
    _check_hypr
    _check_tools_system
    _check_diag
  } | jq -s -c '.'
}

health_human() {
  jq -r '.[] | "\(.level | ascii_upcase | . + (" " * (8 - length)))\(.id)  \(.title)\(if .detail != "" then "\n        \(.detail)" else "" end)\(if .fix.kind != "none" then "\n        fix (\(.fix.kind)): \(.fix.label)" else "" end)"'
}

health_main() {
  case ${1:-} in
    "" | --json) health_rows ;;
    --human) health_rows | health_human ;;
    *)
      json_error usage "$(jq -cn --arg v "$1" '{detail: "health [--json|--human]", got: $v}')"
      return 1
      ;;
  esac
}
