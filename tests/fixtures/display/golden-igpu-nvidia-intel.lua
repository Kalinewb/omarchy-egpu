-- Managed by omarchy-egpu. Delete this file to undo.
-- Omarchy's nvidia.lua points the whole session at the NVIDIA GLX/VA-API drivers
-- whenever an NVIDIA card is present at login. With an eGPU that makes the shell and
-- every app render on the eGPU and cross the Thunderbolt link. Keep the session on the
-- laptop GPU; apps opt in to the eGPU with the offload variables (egpu-run / Steam).
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
hl.env("LIBVA_DRIVER_NAME", "iHD")

-- With a second GPU driving a monitor, Hyprland's "auto" (2) falls back to a software
-- cursor that moves only once per frame. Use the hardware cursor plane instead.
hl.config({ cursor = { no_hardware_cursors = 0 } })

-- glvnd loads every installed EGL vendor, so the shell opens the NVIDIA card even when it
-- renders on Intel. That wastes power and keeps the driver busy, which blocks a safe eject.
-- Apps that want the eGPU opt in through egpu-run / the Steam launch options.
hl.env("__EGL_VENDOR_LIBRARY_FILENAMES", "/usr/share/glvnd/egl_vendor.d/50_mesa.json")

-- Qt Multimedia probes every hardware video decoder it can find, including CUDA/VDPAU on
-- the eGPU, and the shell then keeps the card open. Restrict it to Intel's VA-API.
hl.env("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", "vaapi")
