# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Flatpak Steam, not running, no NVIDIA GL extension, no eGPU (so the driver
# version is unknown).
fx_base_healthy
fx_steam_root real "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
fx_flatpak_steam no
