# UX principles (binding, from the user: "the plugin is very important, it's easy to use")

Inspiration: SteamOS-EGPU-Buddy (Decky plugin). What it gets right, and what we do with it:

| EGPU Buddy | omarchy-egpu |
|---|---|
| Two screens: a Main page with status and one or two big buttons, and a Details page | **Main** = state word + ONE primary button that changes with the state (Connect / Safe eject / Fix setup) and, when relevant, the TV/monitor switch. **Details** = GPU, driver, link, monitors, telemetry. Everything else (Games, Display, Setup) is one tap away, never in the way. |
| Plug and play: eGPU is picked up automatically | After a one-time setup, plugging in just works: authorize, load, ready, notification "eGPU ready". Auto-connect is the recommended default once the system half is installed (decision pending from the user). |
| Safe Detach: one button | **Safe eject**: one button. It handles monitors, tells you plainly which app is using the card, and ends with a big "Safe to unplug". |
| Cable-pull resilience: recovers within seconds | Under the default igpu policy the desktop never depends on the eGPU, so a yank only produces a warning notice. Must be tested (yank scenario). |
| Self-repair after OS updates | Setup/health notices drift (driver update, new modules-load file, missing links) and offers one **Fix** per row and a single **Fix all** that asks for the password once. |
| One-step install, three paths | One command to add the plugin from GitHub; the first panel open lands on Setup with a single "Set up eGPU support" button that runs the system half (terminal sudo prompt, shown clearly). No manual file editing, ever. |
| Details page with telemetry (temp, power, clocks, VRAM) | Details view shows live telemetry from nvidia-smi (read-only). Power limit / clock offset are optional later. |
| Per-screen choice | Display view: choose where the TV/monitor lives; defaults are right (laptop ports, eGPU for games). |
| Plain disclaimer | README states what the system half changes and how to remove it (uninstall). |

Rules for every screen:
1. The first thing visible is the state in plain words ("eGPU ready", "Plug in your eGPU", "Safe to unplug") and what to do next.
2. At most one primary button per screen. Dangerous or rare actions are secondary and explained.
3. Never show an error code to the user without a plain sentence and a next step. Codes go in a "Details" disclosure.
4. First run: if anything is missing, the panel opens on Setup with ONE button; a stranger's machine must reach "ready" without reading docs.
5. Games: a plain list with a switch per game, a search box, and "All on / All off". No jargon ("launch options") on the surface.
6. The notch shows the same words and the same single action.
