# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# nvidia-smi stuck in D state (open-module/GSP rmapiLockAcquire hang): the
# guard reports smi_hung after its timeout and leaves the process alone.
fx_base_healthy
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
touch "$EGPU_FAKE_DIR/smi-hang"
echo 'export EGPU_SMI_TIMEOUT=1' >>"$EGPU_FAKE_DIR/env"
