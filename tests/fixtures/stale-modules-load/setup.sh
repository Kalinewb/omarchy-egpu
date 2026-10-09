# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Only the modules-load problem (§9.2), on an otherwise healthy machine, with
# the eGPU ready: one health error turns ready into attention.
fx_base_healthy
fx_hypr_links card1
rm -f "$FX_ROOT/etc/modules-load.d/nvidia-580xx-utils.conf"
: >"$FX_ROOT/etc/modules-load.d/nvidia-utils.conf"
fx_write etc/modules-load.d/my-gpu.conf '# loaded by hand once
nvidia_drm'
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
