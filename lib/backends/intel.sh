#!/bin/bash

# intel backend (discrete Arc) — documented stub. plan-engine.md §4.2.
#
# What a real implementation would do:
#   detect        vendor 0x8086, display class, and not the primary (boot_vga)
#                 device, so the laptop's own iGPU is never taken for an eGPU
#   KMS module    xe (or i915 on older parts)
#   unload        unsupported: xe/i915 drive the iGPU as well
#   offload env   DRI_PRIME=pci-<domain>_<bus>_<dev>_<fn>
#   verify        DRM fdinfo engine counters and hwmon; no vendor tool needed
# Every function other than be_name, be_detect and be_offload_env prints
# {"error":"backend_stub"} and returns 1.

# shellcheck disable=SC2034
BE_STATUS=stub

_be_stub() { echo '{"error":"backend_stub"}'; return 1; }

be_name() { echo intel; }

be_detect() {
  [[ $(pci_attr "$1" vendor) == 0x8086 ]] && pci_is_display "$1" && ! pci_is_boot_vga "$1"
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
