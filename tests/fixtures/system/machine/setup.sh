# shellcheck shell=bash  # sourced by tests/system.sh after tests/lib.sh
# The machine the root-half tests start from: this laptop before the system
# half is installed. The iGPU is boot VGA; the driver package ships
# /usr/lib/modules-load.d/nvidia-580xx-utils.conf (nvidia-uvm) and the only
# /etc mask is the empty, stale nvidia-utils.conf of the old package
# (plan-engine.md §9.2). No helper, no policy, no rule. The directories root
# installs into exist, as on a real system.
fx_igpu
fx_thunderbolt
fx_boot_clean
fx_nvidia_installed
fx_bolt_none
rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
: >"$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"
mkdir -p "$FX_ROOT/usr/local/bin" "$FX_ROOT/usr/share/polkit-1/actions" "$FX_ROOT/etc/udev/rules.d" \
  "$FX_ROOT/run" "$FX_ROOT/var/lib" "$FX_ROOT/var/backups" "$FX_ROOT/boot"
: >"$FX_ROOT/sys/bus/pci/rescan"
