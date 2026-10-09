# GPU bound to nvidia, but nvidia_drm not loaded yet (udev rule not run).
fx_base_healthy
fx_hypr_links card1
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_modules nvidia nvidia_modeset nvidia_uvm
echo '__GLX_VENDOR_LIBRARY_NAME=nvidia
LIBVA_DRIVER_NAME=nvidia
PATH=/usr/bin' >"$EGPU_FAKE_DIR/session-env.txt"
