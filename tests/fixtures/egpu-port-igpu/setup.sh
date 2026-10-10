# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# A monitor plugged into the eGPU's own HDMI port under the default
# display.policy igpu: the compositor is kept off the eGPU on purpose, so the
# port stays dark and a new session would not change that. No needs_relogin,
# no "log out to use the HDMI monitor" (that is egpu-hdmi's, fixtures/this-machine).
fx_base_healthy
fx_hypr_links
fx_deg2 authorized true
fx_egpu_nvidia nvidia connected:disabled
fx_nvidia_modules
