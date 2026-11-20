# UI scope: how the plugin looks and works (draft for the owner)

Built on docs/ux.md. Words below are the actual on-screen copy unless marked (note).

## 0. Bugs seen in the first live look (fix first)
1. **Dead end:** the compact notch says "Setup has found a problem." but there is no Setup screen, so nothing to tap. Rule from now on: a message that mentions something must be a button that opens it. Fix = build Setup (section 6), and make the compact view's problem line open it.
2. **Padding:** the full panel's content sits too close to the panel edge and "‹ Back"/the title crowd the corners (screenshot: Details view). Fix = one padding token in `common/Palette.js` (panel inset 16, section gap 12, row gap 6), used by every view; check at the notch's panel size and the standalone popup.
3. A title row repeats "TBGAA" and "No eGPU": headline once, details below.

## 1. The mental model (what the user should understand in 5 seconds)
"My eGPU is **absent / getting ready / ready / in use / safe to unplug**. There is one thing to do next, and it's the big button."
Everything else is optional: games, screens, setup.

## 2. Screens
Navigation: a slim tab row at the top of the full panel: **Overview · Games · Screens · Setup**. Setup carries a red dot when something needs fixing. Back always returns one level; Escape too.

### 2.1 Overview (home)  — same content in the notch's compact view, just smaller
```
 eGPU ready                          <- state headline (a word or two: see "Headlines" below)
 Plug in your eGPU                   <- the same state in a full sentence, where the headline is only a word or two
 RTX 4070 SUPER · 41 °C · idle       <- one line of facts
 [ Safe eject ]                      <- the ONE primary button (changes with state)
 TV and games are set up.            <- one status sentence (or the problem + [Fix])
 Details ›                           <- link to the Details page
```
Primary button by state. The headline is short so that, in the notch, the first row fits beside the back
strip's keep-clear zone (a 180 x 32 area at the top centre; notch SURFACE-HOSTING.md §15); the sentence under it
says the rest. Both views show both, from `common/Overview.js` (`headline`, `detail`):
| state | headline | sentence under it | primary button | note |
|---|---|---|---|---|
| absent, never set up | "No eGPU" | "Plug in your eGPU" | **Set up eGPU support** | goes to Setup |
| absent | "No eGPU" | "Plug in your eGPU" | (none) | shows the remembered enclosure |
| absent, no Thunderbolt or USB4 | "No port" | "No Thunderbolt or USB4 port" | | |
| connecting | "Connecting…" | "Getting your eGPU ready" | (disabled, spinner) | |
| ready | "eGPU ready" | | **Safe eject** | |
| in use | "In use" | "eGPU in use by Cyberpunk" | **Safe eject…** | opens the eject sheet; names the app |
| ejecting | "Ejecting…" | | (disabled) | |
| safe to unplug | "Ejected" | "Safe to unplug" | **Done** | big, green, stays until unplug |
| attention: log out | "Log out" | the reason | | |
| attention: a Setup problem | "Setup issue" | the one-sentence problem | **Fix** | opens Setup on that row (so does the sentence) |
| attention: card not supported | "Unsupported" | "This graphics card is not supported yet" | | |
| error | "Error" | the sentence from Errors.js | **Try again** / **Open Setup** | code under "Details" only |
| enclosure present, no GPU | "No card" | "Enclosure found, no graphics card" | **Show me** | hint text only |

Headlines: at most 12 characters, in the same words in both views (`dev/g8-offscreen.sh` checks the length and that
nothing is cut short). Under the notch the compact page and the tab row are laid out around the zone: the headline
in the left gutter, the glyph in the right one; the tabs split, the first half at the left and the rest at the
right. Nothing is pushed down; `dev/g8-offscreen.sh` runs the notch's `backZone` rule on every route and state.

### 2.2 Details (from Overview)
GPU model, driver version, link (e.g. "PCIe 4.0 ×4, 8 GB/s"; slow link in plain text, never alarming), temperature, power, clocks, VRAM used, apps using the eGPU (named), screens on the eGPU. All read-only, refreshed every 2 s while open.

### 2.3 Games
```
 Games                                   [ Search ]
 Steam account: <name> ▾                 [ All on ] [ All off ]
 ───────────────────────────────────────────────────
 Cyberpunk 2077                          (switch)  on eGPU
 Hades                                   (switch)  off
 Elden Ring       "uses its own GPU options"  [Take over]
 ───────────────────────────────────────────────────
 Steam is running. Changes apply when you close Steam.  [Close Steam and apply]
```
No "launch options" jargon on the surface. States: on, off, "stale" (eGPU not connected: still on, shown dimmed with "will use the laptop GPU until the eGPU is back"), pending, manual (needs Take over). Tools/Proton/runtimes hidden.

### 2.4 Screens (display)
Default: "Your TV and monitors use your laptop's ports. The eGPU is for games." One line + a switch **"Use the eGPU's own ports"** (advanced; says "needs the eGPU plugged in before you log in"). List of screens with name, port, resolution, refresh, and where it is (left/right/above/below/mirror). **Turn off eGPU screens** quick button.

### 2.5 Eject sheet (modal over Overview)
1. Checks ("Turning off the screen on the eGPU… Checking what's using it…").
2. If something uses it: "**Cyberpunk 2077** is using the eGPU." [Close it] [Cancel]. Background helpers that only hold the device are shown under "Also open (harmless)".
3. Done: big "**Safe to unplug**" and a note if modules stayed loaded ("The driver stays loaded until you restart. Plugging in again works.").

### 2.6 Setup (also the first-run screen)
```
 Setup                                    [ Fix all ]
 ✔ Thunderbolt: enclosure found
 ✔ NVIDIA driver installed
 ✖ System helper not installed            [ Install ]   "lets the plugin connect and eject without a password"
 ✖ Driver loads at boot (can freeze)       [ Fix ]
 ✔ Desktop uses the laptop GPU
 ⚠ vulkaninfo missing                      [ Copy command ]
 Auto-connect when plugged in   (switch)
 Advanced ›   (diagnostics, copy report, uninstall)
```
Plain sentence per row; the technical id lives under a "Details" disclosure. **Fix all** runs the one terminal install (sudo prompt visible, plain explanation of what it changes). First run: if the helper isn't installed, the panel opens on Setup with ONE button "Set up eGPU support".

## 3. How it behaves over time
- **First install:** `omarchy plugin add … --enable` → open panel → Setup → one terminal sudo step → "Ready. Plug in your eGPU."
- **Plug in (auto-connect on):** icon pulses → notification "eGPU ready" → Overview shows Safe eject. No clicks.
- **Play:** games with the switch on run on the eGPU; the TV stays on the laptop's port.
- **Unplug properly:** Safe eject → "Safe to unplug".
- **Yank:** warning notification "eGPU was unplugged. Close any games that were using it." Desktop is unaffected.
- **After updates (driver/OS):** Setup dot appears with the one row to fix.

## 4. Surfaces
- **Bar icon:** state glyph + colour; tooltip = headline; click opens panel (or notch compact); right-click = quick menu (Safe eject, Open Setup).
- **Notch closed:** glance icon + one word. **Notch compact:** section 2.1 (headline, facts, primary button, problem line that opens Setup, "Open full panel").
- **Notifications:** plug-in "eGPU ready", eject-ready "Safe to unplug", yank warning, setup problem after update. Never repeated.

## 5. Style
Uses the host theme only (colours/fonts/radii from the shell). 16 px inset, 12 px section gap, rows 36 px high, one accent, red only for real errors, links as text buttons, switches for on/off. No tables of ids. Errors: sentence + next step; code under Details.

## 6. Build order (UI)
1. Fix padding + title duplication (all existing views).  2. Setup view + make every "setup/problem" line open it.  3. Overview rework to the state table (primary button logic).  4. Eject sheet (G3).  5. Games (G5).  6. Screens (G4).  7. Notifications (G7).  8. Notch compact updated to the same primary-button logic.  9. First-run flow end to end on a clean profile.

## 7. Decisions (owner, 2026-10-10)
- Setup install: a button opens an Omarchy terminal with the pinned install command and a plain-language explanation; the user types the sudo password in that terminal. The panel never handles the password.
- Games: Steam only, every game off by default, plus All on / All off. Non-Steam apps are later, via egpu-run.
- Notch compact view when fine: headline + one facts line + one primary button + 'Open full panel' (same words as the main panel).
