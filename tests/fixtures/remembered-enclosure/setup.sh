# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# The same unknown enclosure later, without its GPU: recognised from state.
fx_base_healthy
fx_bolt 99999999-0000-0000-0000-000000000001 "Acme" "GPU Box" authorized true iommu
mkdir -p "$EGPU_STATE"
echo 99999999-0000-0000-0000-000000000001 >"$EGPU_STATE/enclosures"
