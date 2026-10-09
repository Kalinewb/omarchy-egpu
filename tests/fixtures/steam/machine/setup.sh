# shellcheck shell=bash  # sourced by tests/steam.sh after tests/lib.sh
# The machine every Steam gate test starts from: healthy, no eGPU attached.
# Each test adds its own Steam roots under $HOME.
fx_base_healthy
