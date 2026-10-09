# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Healthy machine, the DEG2 enrolled but unplugged.
fx_base_healthy
fx_deg2 disconnected true iommu
