# shellcheck shell=bash  # sourced by tests/device.sh after tests/lib.sh
# The machine every connect / egpu-run test starts from: healthy, helper
# installed, no eGPU attached. glvnd's EGL vendor files are this machine's two
# (dev/e0-facts.md), so egpu-run's EGL override has something to find.
fx_base_healthy
fx_write usr/share/glvnd/egl_vendor.d/10_nvidia.json '{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_nvidia.so.0" } }'
fx_write usr/share/glvnd/egl_vendor.d/50_mesa.json '{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_mesa.so.0" } }'
