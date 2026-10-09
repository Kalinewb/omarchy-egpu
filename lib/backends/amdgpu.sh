#!/bin/bash

# amdgpu backend — documented stub. plan-engine.md §4.2.
#
# It exists so the backend interface is honest: an AMD eGPU is detected and
# shown as "detected, not supported yet" instead of being invisible. What a
# real implementation would do:
#   detect        vendor 0x1002, display class
#   KMS module    amdgpu
#   unload        unsupported: amdgpu also drives AMD iGPUs, and unloading it
#                 could take the laptop panel with it
#   offload env   DRI_PRIME=pci-<domain>_<bus>_<dev>_<fn>
#   verify        /sys/class/drm/cardN/device/gpu_busy_percent, hwmon temp,
#                 mem_info_vram_used; no vendor tool needed
# Every function other than be_name, be_detect and be_offload_env prints
# {"error":"backend_stub"} and returns 1.

# shellcheck disable=SC2034
BE_STATUS=stub

_be_stub() { echo '{"error":"backend_stub"}'; return 1; }

be_name() { echo amdgpu; }

be_detect() {
  [[ $(pci_attr "$1" vendor) == 0x1002 ]] && pci_is_display "$1"
}

be_offload_env() {
  local b=${1//[:.]/_}
  printf 'DRI_PRIME=pci-%s\n' "$b"
}

be_kms_modules() { _be_stub; }
be_unload_modules() { _be_stub; }
be_dev_nodes() { _be_stub; }
be_verify() { _be_stub; }
be_steam_extras() { _be_stub; }
be_health() { _be_stub; }
be_kms_params() { _be_stub; }
