# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# /boot readable (some machines), one image carrying nvidia, and an
# mkinitcpio drop-in that adds it (Omarchy's installer writes one).
fx_base_healthy
fx_write boot/initramfs-linux.img "usr/lib/modules/$FX_KVER/kernel/drivers/thunderbolt/thunderbolt.ko.zst
usr/lib/modules/$FX_KVER/updates/dkms/nvidia.ko.zst
usr/lib/modules/$FX_KVER/updates/dkms/nvidia-drm.ko.zst"
fx_write boot/initramfs-linux-fallback.img "usr/lib/modules/$FX_KVER/kernel/drivers/thunderbolt/thunderbolt.ko.zst"
fx_write etc/mkinitcpio.conf.d/nvidia.conf 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)'
