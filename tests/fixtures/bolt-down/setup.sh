# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# bolt installed but boltd not answering, eGPU (OCuLink-style) present.
fx_base_healthy
fx_bolt_down
fx_egpu_nvidia nvidia
fx_nvidia_modules
