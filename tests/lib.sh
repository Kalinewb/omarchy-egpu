#!/bin/bash

# tests/lib.sh — fixture builders, sourced by fixtures/<scenario>/setup.sh and
# by watch scripts.
#
# A fixture is built at test time under $FX_ROOT (sys, dev, proc, etc, usr/lib,
# boot) plus the fakes' data in $EGPU_FAKE_DIR. Building it here, rather than
# committing trees, keeps symlinks (driver links, by-path, /proc/<pid>/fd) out
# of the repo: `omarchy plugin update` rolls back any update of a repo that
# contains one (plan-gui.md §2).
#
# The shapes copy this machine's real sysfs (dev/e0-facts.md).

: "${FX_ROOT:?}" "${FX_XDG:?}" "${EGPU_FAKE_DIR:?}" "${EGPU_TEST_REPO:?}"

FX_PCI="$FX_ROOT/sys/bus/pci/devices"
FX_KVER=$(uname -r)

# fx_write <path under root> <content>
fx_write() {
  mkdir -p -- "$(dirname -- "$FX_ROOT/$1")"
  printf '%s\n' "$2" >"$FX_ROOT/$1"
}

# fx_pci <bdf> <class> <vendor> <device> [attr=value ...] [driver=name]
fx_pci() {
  local bdf=$1 class=$2 vendor=$3 device=$4 kv k v
  shift 4
  local d="$FX_PCI/$bdf"
  mkdir -p -- "$d"
  printf '%s\n' "$class" >"$d/class"
  printf '%s\n' "$vendor" >"$d/vendor"
  printf '%s\n' "$device" >"$d/device"
  for kv in "$@"; do
    k=${kv%%=*}
    v=${kv#*=}
    if [[ $k == driver ]]; then
      mkdir -p -- "$FX_ROOT/sys/bus/pci/drivers/$v"
      ln -sfn "../../../bus/pci/drivers/$v" "$d/driver"
    else
      printf '%s\n' "$v" >"$d/$k"
    fi
  done
}

fx_pci_remove() { rm -rf -- "${FX_PCI:?}/${1:?}"; }

# fx_lspci <bdf> <vendor name> <device name>: a -vmm block for the lspci fake.
fx_lspci() {
  printf 'Slot:\t%s\nClass:\tVGA compatible controller\nVendor:\t%s\nDevice:\t%s\n\n' \
    "${1#0000:}" "$2" "$3" >>"$EGPU_FAKE_DIR/lspci.txt"
}

# fx_drm <bdf> <card> [connector:status:enabled ...]
# The card's sysfs dir under the PCI device, its /dev node (mtime an hour ago,
# i.e. not a fresh hot-add) and the udev by-path link.
fx_drm() {
  local bdf=$1 card=$2 spec name st en
  shift 2
  mkdir -p -- "$FX_PCI/$bdf/drm/$card" "$FX_ROOT/dev/dri/by-path"
  for spec in "$@"; do
    IFS=: read -r name st en <<<"$spec"
    mkdir -p -- "$FX_PCI/$bdf/drm/$card/$card-$name"
    printf '%s\n' "$st" >"$FX_PCI/$bdf/drm/$card/$card-$name/status"
    printf '%s\n' "$en" >"$FX_PCI/$bdf/drm/$card/$card-$name/enabled"
  done
  : >"$FX_ROOT/dev/dri/$card"
  touch -d '1 hour ago' "$FX_ROOT/dev/dri/$card"
  ln -sfn "../$card" "$FX_ROOT/dev/dri/by-path/pci-$bdf-card"
}

# fx_connector <bdf> <card> <connector> <status> <enabled>
fx_connector() {
  local c="$FX_PCI/$1/drm/$2/$2-$3"
  mkdir -p -- "$c"
  printf '%s\n' "$4" >"$c/status"
  printf '%s\n' "$5" >"$c/enabled"
}

fx_drm_remove() {
  rm -f -- "$FX_ROOT/dev/dri/$2" "$FX_ROOT/dev/dri/by-path/pci-$1-card"
}

# fx_modules <name...>: loaded modules.
fx_modules() {
  local m
  for m in "$@"; do
    mkdir -p -- "$FX_ROOT/sys/module/$m"
    echo live >"$FX_ROOT/sys/module/$m/initstate"
    echo 0 >"$FX_ROOT/sys/module/$m/refcnt"
  done
}

fx_modules_remove() {
  local m
  for m in "$@"; do rm -rf -- "${FX_ROOT:?}/sys/module/$m"; done
}

# fx_module_param <module> <param> <value> [mode]
fx_module_param() {
  local f="$FX_ROOT/sys/module/$1/parameters/$2"
  mkdir -p -- "$(dirname -- "$f")"
  printf '%s\n' "$3" >"$f"
  [[ -n ${4:-} ]] && chmod "$4" "$f"
  return 0
}

# ---------------------------------------------------------------- machine

# The laptop: Intel iGPU, boot VGA, on xe, driving eDP-1. No `removable`
# attribute, exactly like 0000:00:02.0 here.
fx_igpu() {
  fx_pci 0000:00:02.0 0x030000 0x8086 0x64a0 boot_vga=1 driver=xe
  fx_drm 0000:00:02.0 card0 eDP-1:connected:enabled HDMI-A-1:disconnected:disabled
  fx_lspci 0000:00:02.0 "Intel Corporation" "Lunar Lake [Intel Arc Graphics 130V / 140V]"
  fx_modules xe
}

fx_thunderbolt() { mkdir -p -- "$FX_ROOT/sys/bus/thunderbolt/devices/domain0"; }

# Boot configuration as it should be: thunderbolt early, nvidia options,
# nouveau blacklisted, the shipped modules-load file masked by name.
fx_boot_clean() {
  fx_write etc/mkinitcpio.conf.d/thunderbolt_module.conf 'MODULES+=(thunderbolt)'
  fx_write etc/mkinitcpio.conf 'MODULES=()
HOOKS=(base udev autodetect microcode modconf kms keyboard block filesystems fsck)'
  fx_write etc/modprobe.d/nvidia.conf 'options nvidia NVreg_EnableGpuFirmware=0
options nvidia NVreg_DynamicPowerManagement=0x00
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia-drm modeset=1'
  fx_write etc/modprobe.d/blacklist-nouveau.conf 'blacklist nouveau
options nouveau modeset=0'
  fx_write usr/lib/modules-load.d/nvidia-580xx-utils.conf 'nvidia-uvm'
  fx_write usr/lib/modules-load.d/bluez.conf 'crypto_user'
  mkdir -p -- "$FX_ROOT/etc/modules-load.d"
  : >"$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
  fx_write etc/systemd/system/systemd-suspend.service.wants/nvidia-suspend.service ''
  fx_write etc/systemd/system/systemd-suspend.service.wants/nvidia-resume.service ''
  fx_write proc/cmdline 'root=/dev/mapper/root rw quiet splash'
}

fx_nvidia_installed() {
  fx_write "usr/lib/modules/$FX_KVER/updates/dkms/nvidia.ko.zst" ''
}

# The system half (E7) as a fake: the helper answers `version` with the
# plugin's own version; the policy file exists.
fx_helper() {
  local v
  v=$(jq -r .version "$EGPU_TEST_REPO/manifest.json")
  fx_write usr/local/bin/omarchy-egpu-admin "#!/bin/bash
[[ \${1:-} == version ]] && echo '{\"version\":\"$v\"}'"
  chmod +x "$FX_ROOT/usr/local/bin/omarchy-egpu-admin"
  fx_write usr/share/polkit-1/actions/no.kalinewb.egpu.policy '<policyconfig/>'
}

# The udev links of §10.3.
# shellcheck disable=SC2120  # fixtures pass the external card; they are sourced, not followed
fx_hypr_links() {
  mkdir -p -- "$FX_ROOT/dev/dri"
  ln -sfn card0 "$FX_ROOT/dev/dri/omarchy-egpu-primary"
  [[ -n ${1:-} ]] && ln -sfn "$1" "$FX_ROOT/dev/dri/omarchy-egpu-external"
  return 0
}

# fx_hyprland <pid> <explicit:yes|no> <open node...>
# The compositor: a pgrep entry, /proc/<pid>/fd links to the nodes it holds,
# and the aquamarine log lines health reads.
fx_hyprland() {
  local pid=$1 explicit=$2 node i=10
  shift 2
  echo "Hyprland $pid" >>"$EGPU_FAKE_DIR/pgrep.txt"
  mkdir -p -- "$FX_ROOT/proc/$pid/fd"
  for node in "$@"; do
    ln -sfn "/dev/dri/$node" "$FX_ROOT/proc/$pid/fd/$i"
    i=$((i + 1))
  done
  local sig=fakesig_1791207785_1
  mkdir -p -- "$FX_XDG/hypr/$sig"
  {
    echo "DEBUG from aquamarine ]: drm: gpu /dev/dri/card0 becomes primary drm"
    [[ $explicit == yes ]] && echo "DEBUG from aquamarine ]: drm: Explicit device list /dev/dri/omarchy-egpu-primary"
    echo "DEBUG from aquamarine ]: drm: Starting backend for /dev/dri/card0"
  } >"$FX_XDG/hypr/$sig/hyprland.log"
  echo "export HYPRLAND_INSTANCE_SIGNATURE=$sig" >>"$EGPU_FAKE_DIR/env"
  mkdir -p -- "$EGPU_FAKE_DIR/hypr"
  [[ -e $EGPU_FAKE_DIR/hypr/monitors.json ]] ||
    echo '[{"name":"eDP-1","description":"Samsung Display Corp. 0x41AA","disabled":false}]' >"$EGPU_FAKE_DIR/hypr/monitors.json"
}

# fx_hypr_monitors <name...>: what `hyprctl monitors all -j` lists.
fx_hypr_monitors() {
  mkdir -p -- "$EGPU_FAKE_DIR/hypr"
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0) | {name: ., disabled: false})' \
    >"$EGPU_FAKE_DIR/hypr/monitors.json"
}

fx_process() { echo "$1 $2" >>"$EGPU_FAKE_DIR/pgrep.txt"; }

# ---------------------------------------------------------------- bolt

fx_bolt_none() { echo '{"daemon":true,"devices":[]}' >"$EGPU_FAKE_DIR/bolt.json"; }
fx_bolt_down() { echo '{"daemon":false,"devices":[]}' >"$EGPU_FAKE_DIR/bolt.json"; }

# fx_bolt <uuid> <vendor> <name> <status> <stored:true|false> [policy]
# Adds or replaces the device with that uuid.
fx_bolt() {
  local f="$EGPU_FAKE_DIR/bolt.json"
  [[ -s $f ]] || fx_bolt_none
  jq -c --arg u "$1" --arg v "$2" --arg n "$3" --arg s "$4" --argjson st "$5" --arg p "${6:-iommu}" '
    .devices = ([.devices[] | select(.uuid != $u)] +
      [{uuid: $u, vendor: $v, name: $n, status: $s, stored: $st, policy: $p, generation: "USB4"}])' \
    "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}

FX_DEG2_UUID=ba7e8780-0085-dcfa-ffff-ffffffffffff
fx_deg2() { fx_bolt "$FX_DEG2_UUID" "Micro Computer (HK) Tech. Ltd." TBGAA "$1" "${2:-true}" "${3:-iommu}"; }

# ---------------------------------------------------------------- eGPU

# fx_egpu_nvidia [driver] [hdmi status:enabled]
# The 4070 SUPER as E0 saw it: 0000:03:00.0 + HDMI audio 03:00.1, removable,
# 16 GT/s x4, card1 with DP-3..5 and HDMI-A-2.
fx_egpu_nvidia() {
  local driver=${1:-nvidia} hdmi=${2:-disconnected:disabled}
  local drv_attr=()
  [[ $driver != none ]] && drv_attr=("driver=$driver")
  fx_pci 0000:03:00.0 0x030000 0x10de 0x2783 removable=removable boot_vga=0 \
    "current_link_speed=16.0 GT/s PCIe" current_link_width=4 \
    "max_link_speed=16.0 GT/s PCIe" max_link_width=16 "${drv_attr[@]}"
  fx_pci 0000:03:00.1 0x040300 0x10de 0x22bc removable=removable driver=snd_hda_intel
  fx_lspci 0000:03:00.0 "NVIDIA Corporation" "AD104 [GeForce RTX 4070 SUPER]"
  if [[ $driver == nvidia ]]; then
    fx_drm 0000:03:00.0 card1 DP-3:disconnected:disabled DP-4:disconnected:disabled \
      DP-5:disconnected:disabled "HDMI-A-2:$hdmi"
    fx_write proc/driver/nvidia/version 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.178.04  Tue Jul  7 12:38:21 UTC 2026'
    echo 'NVIDIA GeForce RTX 4070 SUPER, 580.178.04, 29, 0, 33' >"$EGPU_FAKE_DIR/smi.csv"
  fi
}

fx_nvidia_modules() {
  fx_modules nvidia nvidia_modeset nvidia_drm nvidia_uvm
  fx_module_param nvidia_drm modeset Y
  fx_module_param nvidia_drm fbdev Y
}

fx_egpu_unplug() {
  fx_drm_remove 0000:03:00.0 card1
  fx_pci_remove 0000:03:00.0
  fx_pci_remove 0000:03:00.1
  rm -f -- "$EGPU_FAKE_DIR/smi.csv" "$FX_ROOT/proc/driver/nvidia/version"
}

# smi-pids.txt in `nvidia-smi -q -d PIDS` format.
fx_gpu_proc() {
  cat >>"$EGPU_FAKE_DIR/smi-pids.txt" <<EOF
        GPU instance ID                   : N/A
        Compute instance ID               : N/A
        Process ID                        : $1
            Type                          : $2
            Name                          : $3
            Used GPU Memory               : $4 MiB
EOF
}

# ---------------------------------------------------------------- bundles

# A machine with nothing wrong and no eGPU: every health row ok/info, apart
# from bolt.device (no enclosure seen yet), so summary tests are not coloured
# by unrelated setup problems.
fx_base_healthy() {
  fx_igpu
  fx_thunderbolt
  fx_boot_clean
  fx_nvidia_installed
  fx_helper
  fx_hypr_links
  fx_bolt_none
  fx_hyprland 1217 yes card0 renderD128
}

# Absent tools for this scenario (names of fakes not to put on PATH).
fx_absent_tool() { echo "$1" >>"$EGPU_FAKE_DIR/absent-tools"; }

# Background processes the runner kills after the scenario.
fx_bg() { echo "$1" >>"$EGPU_FAKE_DIR/bg.pids"; }
