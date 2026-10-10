# shellcheck shell=bash  # sourced by tests/display.sh after tests/lib.sh
# The machine every display test starts from: this laptop (Intel primary on
# xe, eDP-1), healthy, Hyprland running, no udev links yet (the root half is
# E7), and the userspace the primary backend reads: glvnd's Mesa and NVIDIA
# EGL vendor files and intel-media-driver's VA-API driver, as installed here.
fx_base_healthy
rm -f -- "$FX_ROOT/dev/dri/omarchy-egpu-primary" "$FX_ROOT/dev/dri/omarchy-egpu-external"
fx_write usr/share/glvnd/egl_vendor.d/10_nvidia.json '{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_nvidia.so.0" } }'
fx_write usr/share/glvnd/egl_vendor.d/50_mesa.json '{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_mesa.so.0" } }'
fx_write usr/lib/dri/iHD_drv_video.so ''
fx_write usr/lib/dri/radeonsi_drv_video.so ''
