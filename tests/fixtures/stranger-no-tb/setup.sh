# A stranger's laptop: Intel iGPU only, no Thunderbolt controller, no bolt,
# no NVIDIA driver, no system half, no Hyprland running. Every row must still
# answer (first-run Setup, plan-gui.md §5.5).
fx_igpu
fx_write proc/cmdline 'root=/dev/sda2 rw'
fx_absent_tool boltctl
fx_absent_tool vulkaninfo
fx_absent_tool lsinitcpio
fx_absent_tool systemctl
