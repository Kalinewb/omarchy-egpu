# As this-machine's display state, but the card node was just created: within
# 5 s of hot-add the compositor may still be opening it, so no relogin yet.
fx_base_healthy
fx_hypr_links card1
fx_deg2 authorized true
fx_egpu_nvidia nvidia connected:disabled
fx_nvidia_modules
fx_hyprland 1217 yes card0 renderD128
touch "$FX_ROOT/dev/dri/card1"
