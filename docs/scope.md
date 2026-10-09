# omarchy-egpu — scope

Plugin id (proposed): `<author>.egpu`, kind `bar-widget` (panel), like omarchy-profiles.

## Hardware / baseline (verified on this machine)
- Laptop: HP, Intel Core Ultra 200V (Lunar Lake), iGPU Arc 130V/140V on driver `xe` (card0, renderD128). Kernel 7.2.5-omarchy.
- eGPU: Minisforum DEG2 (USB4/Thunderbolt enclosure, shows in bolt as "TBGAA", policy iommu, stored) with an NVIDIA RTX 4070 Super.
- Packages: nvidia-580xx-dkms, nvidia-580xx-utils, lib32-nvidia-580xx-utils, bolt, mesa, vulkan-intel. No supergfxctl/envycontrol/prime-run.
- Known-working Steam launch option (user-supplied):
  `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only %command%`
- eGPU was disconnected when scoped, so nothing GPU-side was verified live.

## Decisions (binding)
1. Goal: hotplug WITHOUT reboot. Compositor stays on the iGPU (Xe) always; eGPU is per-app offload only. No "eGPU drives the display" mode in v1.
2. Steam: panel lists installed games and toggles "Run on eGPU" per game, writing/removing the launch option in Steam's `localconfig.vdf`. Must back up first, refuse while Steam is running (or offer to close it), and only touch the managed token so user's other launch options survive (e.g. wrap as prefix to existing options before `%command%`).
3. Reason for prior failure on SteamOS-EGPU-Buddy: artifacts/glitching. Plan must make sure the compositor never binds to the dGPU (check Hyprland `AQ_DRM_DEVICES`, nvidia-drm.modeset/fbdev state) and surface this in a Setup/health view.

## REVISION 2026-10-09 (supersedes Decision 1 where they conflict) — binding
User wants BOTH: (a) apps rendered on the eGPU shown on the LAPTOP screen (PRIME offload, display stays on iGPU), and (b) an external monitor plugged into the eGPU's HDMI port, driven by the NVIDIA card.
- So the compositor MUST be able to open the NVIDIA DRM device for scanout of the HDMI output (needs nvidia-drm modeset=1, fbdev), while the Intel xe card stays PRIMARY/render device (laptop panel eDP-1 on xe). Do not make NVIDIA the compositor's primary renderer.
- Replaces the earlier "never bind compositor to dGPU" rule: instead, health view checks ordering (AQ_DRM_DEVICES=xe-card:nvidia-card, stable /dev/dri/by-path symlinks, not cardN numbers which change with hotplug).
- Plan MUST resolve: does Hyprland/aquamarine pick up a hot-added GPU and its HDMI output without restart, or does the plugin need to restart/relaunch the session? If AQ_DRM_DEVICES is read only at start, design a "session-restart-on-first-connect" fallback and say how often it is needed.
- Safe-eject must first disable the HDMI monitor in Hyprland (hyprctl) and move its windows/workspaces to the laptop panel, then eject. Document the crash risk of yanking a GPU that owns outputs.
- Panel gets a Display section: HDMI monitor detected on eGPU, enable/disable, which workspaces it holds, mirror/extend/position.
- Glitching risk (SteamOS Buddy artifacts) likely from cross-GPU copy / explicit sync / wrong primary: plan must list mitigations and a way to flip the monitor to "off" quickly.

## REVISION 3 — modularity (binding)
Personal use first, but must be publishable later. So:
- No hardcoded hardware, usernames, PCI addresses or paths. DEG2 and the 4070 SUPER are only the first tested profile, not assumptions.
- GPU backends behind one interface (detect, load, verify, unload, offload-env, health-checks). v1 implements `nvidia`; `amdgpu` and `intel` are documented stubs that make the interface honest. Offload env vars (e.g. `__NV_PRIME_RENDER_OFFLOAD`, `DRI_PRIME`) come from the backend.
- Enclosure quirks (like the DEG2 mode switch or the harmless JMicron M.2 bridge noise) live in small data files under `profiles/`, matched by bolt vendor/name, not in code.
- Separate modules: engine/status, connect/eject, display (Hyprland), steam, setup/health. Each independently usable from the CLI; the panel is a thin layer.
- Config in one file under ~/.config, with sane auto-detected defaults; the user's own system files are never edited without a visible Fix and a backup.
- Panel must work with zero eGPU history on a stranger's machine (first-run Setup explains what is missing).
- Packaging: manifest, LICENSE, README, `omarchy plugin add` install path, dev-sync.sh and lint like omarchy-profiles; plan a test suite using fixture/fake sysfs and fake bolt so logic can be tested without hardware.
- Privileged helper stays minimal, versioned, and generic (no per-vendor logic as root beyond a fixed allowlist of modules).

## REVISION 4 — two shells: standalone + notch integration (binding)
- Standalone: a normal Omarchy `bar-widget` plugin with its own panel (like omarchy-profiles). Must work fully with no notch installed.
- Notch integration: same plugin, optional. Sources of truth in /home/user/Work/omarchy-notch: `contract.js` (a widget opts in by exposing a `notch` property: closedView, expandedView, preferredHeight, priority, groupable, hideable), `SURFACE-HOSTING.md`, `INTEGRATION-SCOPE.md` (how face/profiles are hosted; a hosted panel must handle `opened`/back-stack correctly), `companion/` and `bridge/` for precedent.
- The views (status, games, display, setup) are built ONCE as shared QML components used by both shells. The engine CLI is the only logic; neither shell may fork behaviour.
- Notch glance ideas to plan: closedView = small eGPU glyph + state (absent / connecting / ready / in use / error); transient notice on plug-in ("eGPU connected, load driver?") and for the safe-eject-ready moment, using priority "transient"; expandedView = compact panel (status, Connect/Eject, quick HDMI toggle) with a link into the full panel.
- Must degrade cleanly: when no notch is present the `notch` property is inert; when present, behaviour is declared, not detected by hacks.

## Engine (bin/, shell, no root except helper)
- Status: bolt device state, PCI presence of NVIDIA dGPU, driver bound, nvidia-smi processes, Steam running.
- Connect flow: bolt authorize if needed, wait for PCI device, load nvidia modules, verify `nvidia-smi` and Vulkan ICD sees the card.
- Safe disconnect flow: list processes holding /dev/nvidia*, offer to close them, unload modules / unbind, remove the PCI device via sysfs, then tell the user it is safe to unplug.
- udev rule + user notification on plug/unplug.
- `egpu-run <cmd>`: wrapper that sets the offload env vars (also for non-Steam apps/launcher), usable from the panel.
- Privileged parts (modprobe/rmmod, sysfs remove) via a minimal root helper + polkit action; must go through the security-reviewer before install.

## Panel (QML)
- Status card (connected / authorized / driver / temp / util via nvidia-smi).
- Connect / Safe-eject buttons.
- Games view with per-game toggle.
- Setup/health view: bolt policy, driver, modeset, Hyprland GPU list, steam options, each with Fix where safe.

## Open items the plan must resolve (cite /usr/share/omarchy and bolt/nvidia docs)
- Does Hyprland/aquamarine auto-open the NVIDIA card on hotplug, and how to pin it off (AQ_DRM_DEVICES vs. udev tag `mutter-device-preferred-primary`-style, etc.)?
- Is unloading nvidia modules after an app used it reliably possible, or is PCI remove + driver unbind the right sequence on 580xx?
- Hotplug when NVIDIA modules were never loaded at boot (dkms, nvidia-drm.modeset=1 required for offload?).
- Where plugin-owned bin/ scripts live and how omarchy plugin add installs root helpers (see omarchy-face install.sh / system/ for precedent).

## DECISIONS 2026-10-09 (user, binding)
- Namespace: `kalinewb.egpu` (action `no.kalinewb.egpu.device`).
- Connect, eject and rescan run WITHOUT a password for the active local user (polkit allow_active=yes). Security reviewer must still bound the helper (fixed verbs, fixed module allowlist).
- Auto-connect setting: deferred (decide later).
- Steam .vdf copies may be used as test fixtures (sanitize ids/names before they enter any repo).
- Arch wiki hotplug kernel params stay optional diagnostics only.
