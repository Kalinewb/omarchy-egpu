# A discrete Arc in an enclosure, next to the Intel iGPU: the intel stub
# takes the removable one and never the boot VGA iGPU.
fx_base_healthy
fx_bolt bbbbbbbb-0000-0000-0000-000000000003 "Sonnet" "eGFX Breakaway" authorized true iommu
fx_pci 0000:07:00.0 0x030000 0x8086 0x56a0 removable=removable boot_vga=0 driver=xe
fx_lspci 0000:07:00.0 "Intel Corporation" "DG2 [Arc A770]"
