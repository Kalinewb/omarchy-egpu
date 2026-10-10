# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# After an eject: GPU removed from PCI, enclosure still connected, but the
# compositor kept a reference so the modules stayed loaded (O2).
fx_base_healthy
fx_deg2 authorized true
fx_nvidia_modules
mkdir -p "$EGPU_RUN"
echo "{\"uuid\":\"$FX_DEG2_UUID\",\"bdf\":\"0000:03:00.0\",\"held_by\":[\"quickshell\",\"voxtype-osd-gtk\"]}" >"$EGPU_RUN/ejected"
