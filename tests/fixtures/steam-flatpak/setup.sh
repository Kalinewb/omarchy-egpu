# shellcheck shell=bash  # sourced by tests/run.sh after tests/lib.sh
# Flatpak Steam only, running, with the GL extension matching the loaded
# driver (580.178.04).
fx_base_healthy
fx_hypr_links card1
fx_deg2 authorized true
fx_egpu_nvidia nvidia
fx_nvidia_modules
fx_hyprland 1217 yes card0 renderD128 card1
fx_steam_root real "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
fx_flatpak_steam yes org.freedesktop.Platform.GL.nvidia-580-178-04
