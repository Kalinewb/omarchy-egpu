# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# An authorized Thunderbolt dock with no GPU and no profile: not an eGPU.
fx_base_healthy
fx_bolt 11111111-2222-3333-4444-555555555555 "Some Vendor" "TB4 Dock" authorized true auto
