# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Ready with the HDMI monitor lit by the compositor.
fx_base_healthy
fx_hypr_links card1
fx_deg2 authorized true
fx_egpu_nvidia nvidia connected:enabled
fx_nvidia_modules
fx_hyprland 1217 yes card0 renderD128 card1
fx_hypr_monitors eDP-1 HDMI-A-2
