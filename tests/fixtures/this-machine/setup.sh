# This laptop at E0 (dev/e0-facts.md): DEG2 + 4070 SUPER ready; HDMI-A-2
# connected but Hyprland never lit it (secondary renderer failed) although it
# holds card1; stale modules-load mask; nvidia_drm parameters root-only;
# vulkaninfo missing; no system half; AQ_DRM_DEVICES not set.
fx_igpu
fx_thunderbolt
fx_boot_clean
rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
: >"$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"
fx_write usr/lib/modprobe.d/nvidia-sleep.conf 'options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp'
fx_nvidia_installed
fx_bolt_none
fx_deg2 authorized true iommu
fx_egpu_nvidia nvidia connected:disabled
fx_modules nvidia nvidia_modeset nvidia_drm nvidia_uvm
fx_module_param nvidia_drm modeset Y 000
fx_module_param nvidia_drm fbdev Y 000
fx_hyprland 1217 no card0 renderD128 card1
fx_absent_tool vulkaninfo
fx_absent_tool lsinitcpio
