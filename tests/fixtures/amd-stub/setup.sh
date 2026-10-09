# An AMD card in an unknown enclosure: detected by the amdgpu stub.
fx_base_healthy
fx_bolt aaaaaaaa-0000-0000-0000-000000000002 "Razer" "Core X" authorized true iommu
fx_pci 0000:05:00.0 0x030000 0x1002 0x744c removable=removable boot_vga=0 driver=amdgpu \
  "current_link_speed=8.0 GT/s PCIe" current_link_width=4 "max_link_speed=16.0 GT/s PCIe" max_link_width=16
fx_lspci 0000:05:00.0 "Advanced Micro Devices, Inc. [AMD/ATI]" "Navi 31 [Radeon RX 7900 XT/7900 XTX]"
fx_modules amdgpu
