#!/bin/bash
# Run by the fake `udevadm monitor` inside the watcher's producer. Edits the
# fixture like the kernel and boltd would, printing udev-style lines.
# shellcheck source=tests/lib.sh
source "$EGPU_TEST_LIB"
ev() { echo "UDEV  [$(date +%s.%N)] $1 $2 ($3)"; }

sleep 2
fx_deg2 connected false
ev add /devices/pci0000:00/0000:00:0d.2/domain0/0-0/0-1 thunderbolt

sleep 3
fx_deg2 authorized true iommu
ev change /devices/pci0000:00/0000:00:0d.2/domain0/0-0/0-1 thunderbolt

sleep 3
fx_egpu_nvidia nvidia disconnected:disabled
fx_nvidia_modules
ev add /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.0 pci
ev add /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.0/drm/card1 drm

sleep 3
fx_connector 0000:03:00.0 card1 HDMI-A-2 connected disabled
ev change /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.0/drm/card1 drm

sleep 3
fx_deg2 disconnected true iommu
fx_egpu_unplug
fx_modules_remove nvidia_uvm nvidia_drm nvidia_modeset nvidia
ev remove /devices/pci0000:00/0000:00:07.0/0000:01:00.0/0000:02:00.0/0000:03:00.0 pci
ev remove /devices/pci0000:00/0000:00:0d.2/domain0/0-0/0-1 thunderbolt
