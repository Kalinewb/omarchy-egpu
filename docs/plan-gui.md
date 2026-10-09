# omarchy-egpu — panel plan

Status: draft 1, 2026-10-09. Companion: `plan-engine.md`, which owns every decision; this
file owns only presentation. Section references written `E§n` point into
plan-engine.md. Binding inputs are the same as the engine's: scope.md Decisions 2–3,
REVISION 2026-10-09, the troubleshooting facts, REVISION 3, the per-game Steam
requirements, and REVISION 4 (standalone bar widget **and** notch integration).

Citation shorthand as in plan-engine.md (`omarchy:`, `face:`, `profiles:`), plus
`notch:` = `/home/user/Work/omarchy-notch/`.

---

## 1. Principle: a thin layer

- The panel decides nothing. Every button runs one engine verb and renders its JSON;
  every state shown comes from `omarchy-egpu status` / `status watch`
  (E§5). This is omarchy-profiles' split ("This file is only the face. Every decision
  lives in bin/…", profiles:Panel.qml:14-17), and it is what makes each engine
  module usable from a terminal (REVISION 3).
- The panel never reads sysfs, never parses VDF, never builds a `hyprctl` string.
- **Two shells, one set of views (REVISION 4).**
  - The standalone popup (§5) and the notch (§7) both instantiate the **same** view
    components from `views/`, and both run the same engine verbs. Neither has logic
    of its own.
  - Even the one-line state text and the glance state come from the engine's
    `summary` (E§5), so the two cannot disagree.
- Errors are shown from the engine's `error` code through one table of user-facing
  strings (§6), so a code the panel does not know still renders ("Something went
  wrong: <code>") rather than nothing.

## 2. Plugin shape

`manifest.json`:

```json
{ "schemaVersion": 1, "id": "kalinewb.egpu", "name": "eGPU", "version": "0.1.0",
  "author": "kalinewb", "license": "MIT",
  "description": "Connect, use and safely eject an external GPU: apps on the eGPU, a monitor on its HDMI port, and per-game Steam switches.",
  "kinds": ["bar-widget", "service"],
  "entryPoints": { "barWidget": "Panel.qml", "service": "Service.qml", "surface": "NotchIntegration.qml" },
  "surface": { "contract": 1 },
  "barWidget": { "displayName": "eGPU", "description": "External GPU state; click to connect, eject, set up the monitor and choose games.",
                 "category": "System", "allowMultiple": false, "defaultSection": "right" } }
```

**How kinds, entry points and the notch fit together:**

- **Kinds are Omarchy's only.** `bar-widget` gives the standalone shell and
  `service` gives the watcher. There is no `notch` kind; the notch is not something
  Omarchy loads.
- **`entryPoints.surface` + `surface.contract: 1`** is the notch's declared
  integration (notch:SURFACE-HOSTING.md:38-62).
  - `omarchy plugin validate` accepts it, because every entry point only has to be a
    safe relative path (notch:SURFACE-HOSTING.md:60-62;
    omarchy:shell/services/PluginRegistry.qml:82-85).
  - Omarchy itself ignores it.
  - The notch loads that file once, and only when it is the bar and has accepted the
    integration (notch:SURFACE-HOSTING.md:160-161).
- **The `notch` property** lives on the bar widget's root item (`Panel.qml`). It is
  the per-widget descriptor of notch:contract.js:24-28, read by the notch's registry
  only if `"notch" in item` (notch:Bar.qml:1389). Under `omarchy.bar` nothing reads
  it, so it is inert by construction (REVISION 4: "declared, not detected").
- **`Panel.qml` is a Ui `Panel`** (a `KeyboardPanel` plus `PanelController`). It
  therefore also has the shape the notch can host unmodified
  (notch:SURFACE-HOSTING.md:440-451). With a declared integration, though, the
  integration's panel wins (notch:SURFACE-HOSTING.md:120-121). So inside the notch
  the user sees `NotchPanel`, never the standalone popup reparented.
- **No symlinks** anywhere in the repo, test fixtures included. Otherwise
  `omarchy plugin update` rolls back every future update
  (notch:SURFACE-HOSTING.md:64-68).

- Required fields and the `entryPoints` object follow
  omarchy:shell/services/PluginRegistry.qml:52-70; the kinds and the bar-widget block
  follow omarchy:shell/README.md:46-83 and face:manifest.json:9-24.
- `keepLoaded` is **not** set in v1: a keepLoaded service keeps its old code until a
  shell restart (omarchy:shell/README.md:87-94), which slows development. Gate G1
  checks that a third-party `service` entry mounts at startup without it; if not, set
  `keepLoaded: true` as face does (face:manifest.json:13).
- Files:
  - `Panel.qml`: the standalone shell. Bar button, popup, tab switcher, and the
    `notch` property.
  - `Service.qml`: the watcher, notifications, the sleep notice, and the Steam
    queue poll.
  - `NotchIntegration.qml` and `NotchPanel.qml`: the notch shell (§7).
  - `views/`: the shared components (§5.0). `StatusView.qml`, `EjectFlow.qml`,
    `DisplayView.qml`, `GamesView.qml`, `SetupView.qml`, `Glance.qml`,
    `CompactView.qml`.
  - `common/`: `Engine.qml` (the `Process` pool, §3), `StatusSource.qml` (§3),
    `Errors.js` (§6), `Palette.js` (§5.0).

## 3. Running the engine

- Engine path: resolved from the plugin's own directory
  (`Qt.resolvedUrl("bin/omarchy-egpu")` → local path), not hardcoded.
  - profiles builds it from `$HOME` plus a fixed plugin path (profiles:Panel.qml:40).
    That breaks under a custom `XDG_CONFIG_HOME`, so REVISION 3 rules it out.
  - In dev mode `OMARCHY_EGPU_DEV_BIN` overrides it (§9).
- One-shot verbs run through `Quickshell.Io` `Process` objects declared statically,
  as the Power panel does (omarchy:shell/plugins/panels/power/Panel.qml:208-226).
  - profiles notes that a Process created at call time can be garbage-collected while
    still running (profiles:Panel.qml:1990-1991). So `Engine.qml` holds a small fixed
    pool of four, like profiles' `AskProcess` pool (profiles:Panel.qml:1225-1228).
  - Each call is `run(argv, onDone)`. `onDone({ok, json, code})` maps exit 0/1/3/126/127
    per E§1.1.
- **The single status stream.** `Service.qml` runs `omarchy-egpu status watch` for
  the session (E§5.1), which also keeps `$XDG_RUNTIME_DIR/omarchy-egpu/status.json`
  fresh. Every consumer reads state through one small component,
  `common/StatusSource.qml`:
  - **Standalone:** the panel gets the live object through the plugin's own-service
    lookup, which third-party plugins are allowed (omarchy:shell/README.md:96).
  - **Notch, or any context without that lookup:** a `FileView` with `watchChanges` on
    `status.json`, with the staleness rule from E§5.1. If the file is stale, it runs
    `status --json` once and shows "watcher not running".
  - Both expose the same `status` object and an `event(record)` signal, raised when
    `last_event.seq` advances. Views never know which source they have.
- While the popup is closed nothing else runs.
- All mutable state lives with the engine, in the config file or under
  `~/.local/state/omarchy-egpu/`, never in the plugin folder: any write there reloads
  every plugin (omarchy:shell/services/PluginRegistry.qml:663-679;
  profiles:Panel.qml:19-25).

## 4. Bar indicator

`BarIndicator` from the Ui kit (omarchy:shell/Ui/qmldir:3) shows one glyph and an
optional dot. It is driven by status `summary.state` (E§5), and its tooltip is
`summary.line`. The table below shows how those values read:

| phase / flag | look | tooltip |
|---|---|---|
| `absent` | dim glyph (hidden if `gui.hide_when_absent`) | "No eGPU" |
| `plugged`, `authorized`, `bound` (connecting) | pulsing glyph | "Connecting…" |
| `ready` | accent glyph | "eGPU ready — eject before unplugging" |
| `ready` + an eGPU monitor enabled | accent glyph + monitor badge | "+ HDMI monitor" |
| `ejecting` | pulsing | "Ejecting…" |
| `ejected` | green glyph | "Safe to unplug" |
| `display.needs_relogin` or `modules.held_after_eject` | warn dot | the matching sentence from §6 |
| `error` / health errors > 0 | red dot | first error title |

- Left click opens the popup on the Overview.
- Right click runs `display off` when an eGPU monitor is enabled. This is the second
  fast path to "monitor off" (REVISION 2026-10-09); the first is the Display button.
  It works because `BarIndicator` is a `BarIconButton` (omarchy:shell/Ui/BarIndicator.qml:4),
  which is a `WidgetButton` (omarchy:shell/Ui/BarIconButton.qml:5). `WidgetButton`
  emits `pressed(int button)` and accepts the right button
  (omarchy:shell/Ui/WidgetButton.qml:32,98).

## 5. Views

### 5.0 Shared components (REVISION 4)

Every view in §5.1–5.5, plus `Glance` and `CompactView` (§7), is one QML component
in `views/` that both shells instantiate. They share one interface:

| member | what |
|---|---|
| `status` (in) | the E§5 document from `StatusSource` |
| `engine` (in) | the `Engine.qml` runner |
| `palette` (in) | `{foreground, secondary, accent, good, warn, bad, background, radius, fontFamily}` |
| `density` (in) | `"full"` (standalone popup, notch full route) or `"compact"` |
| `maxWidth`, `maxHeight` (in) | space the shell can give. Views size by `implicitWidth/Height` and never animate their own container |
| `active` (in) | true only while on screen. Timers and any looping animation run on `active` alone |
| `requestRoute(name)` (signal) | ask the shell to show another view: `overview`, `display`, `games`, `setup`, `eject`, `full` |
| `requestClose()` (signal) | ask the shell to close |
| `popView()` (function) | pop one level of the view's own sub-stack. Returns false at its root (§7.6) |

**Rules that make one component work in both shells:**

- **Colours come only from `palette`.** No view reads Omarchy's `Color`/`Style`
  directly.
  - Standalone fills the palette from `Color`/bar colours, as profiles does
    (profiles:Panel.qml:32-35).
  - The notch fills it from `surfaceHost.foreground/secondary/accent`, sets
    `background: null`, and sets `radius` via `surfaceHost.radiusFor()`.
  - The notch forbids own backgrounds, non-host colours and own radii in hosted
    panels (notch:SURFACE-HOSTING.md:229-235). A view that read `Color.accent` would
    arrive as "dark blue on black", the problem recorded as P5
    (notch:INTEGRATION-SCOPE.md:196-211).
- **Ui-kit controls.** `ToggleSwitch`, `Button`, `Dropdown` and the others are used
  where they accept colour overrides. Where one paints from `Color` itself, the view
  wraps a minimal local control. Gate G1 lists which controls need it.
- **Behaviour.** Each view is a pure function of `status` plus engine calls. There are
  no `Process` objects in views; they all live in `Engine.qml`, which each shell owns
  once.
- **Imports.** Only `QtQuick`, `Quickshell`, `Quickshell.Io`, `qs.Commons`, `qs.Ui`
  and relative paths, the set a notch integration may use
  (notch:SURFACE-HOSTING.md:150-152).

The standalone popup is a `Panel` (omarchy:shell/Ui/qmldir:17) with a header row of four tabs:
**Overview · Display · Games · Setup**. Building blocks come from the Ui kit:
`PanelHero`, `PanelSectionHeader`, `ToggleSwitch`, `Button`, `ButtonGroup`,
`Dropdown`, `TextField`, `ConfirmDialog`, `PanelToolTip`
(omarchy:shell/Ui/qmldir:8-34).

### 5.1 Overview (status card)

- **Hero:** enclosure name (bolt `name`, profile id), GPU name, phase sentence.
- **Rows:**
  - bolt status and policy.
  - Driver bound and modules.
  - Temperature, utilisation and VRAM (`gpu.*`).
  - Link `speed × width`, styled as plain information. It is never coloured as a
    warning, and 2.5 GT/s x4 is normal (binding fact 3).
  - Processes on the eGPU (`gpu.procs`).
- **Buttons:**
  - **Connect** while phase is `plugged`/`authorized`/`bound`, or when `ready` is
    missing its KMS modules.
  - **Safe eject** while `bound`/`ready`. Opens §5.2.
  - **Reconnect** while `ejected` (engine `device rescan`). Disabled with the
    held-modules sentence while `modules.held_after_eject` is set.
- **Hints:** `status.hints` render as a callout. Example, DEG2 profile: "Check the
  dock's mode switch is set to TBT, not OCuLink."
- **Run on eGPU:** a `TextField` for a command plus the last 8 commands from
  `gui.recent_commands`. It launches `uwsm-app -- <plugin>/bin/egpu-run <cmd>`
  (E§7.4). The plugin is not a `menu` plugin, so it gets no app-library facade
  (omarchy:shell/README.md:96), and v1 offers no app picker.
- **Banners:**
  - `display.needs_relogin`: "The HDMI monitor needs a new session to appear.
    Offloading apps works now." with a **Log out** button. A `ConfirmDialog` lists
    that every open app closes, then runs `omarchy-system-logout`.
  - `modules.held_after_eject`: "Log out before plugging the eGPU in again."

### 5.2 Eject flow (`EjectFlow.qml`)

A four-step sheet over the Overview that mirrors E§6.3. Each step shows its own
result and nothing is hidden:

1. **Monitor.**
   - "Turning off <desc> and moving workspaces 2, 5 to the laptop screen…".
   - Then `display` results.
   - On `hdmi_still_active`, stop with **Try again** / **Cancel**.
2. **Apps.** `device eject` without `--close`:
   - On `holders_present`, list each holder (name, pid). The compositor row is
     labelled "the desktop — released at removal".
   - **Close these apps** asks via `ConfirmDialog`, then re-runs with `--close`.
   - Survivors are listed again, and SIGKILL is never offered silently.
3. **Removing.** Spinner on `pkexec … remove`.
   - Exit 126 says "Not ejected — permission was declined."
   - `remove_timeout` shows a red, non-dismissable step: "**Do not unplug.** The
     driver has not let go of the card. Save your work and log out; unplug after."
4. **Done.**
   - "Safe to unplug." The bar goes green.
   - Or "Safe to unplug — log out before plugging it in again" when
     `held_after_eject`.

The sheet also carries the yank warning from E§6.3, shown once per session above
step 1: "Unplugging without ejecting can crash the desktop and lose unsaved work."

### 5.3 Display (REVISION 2026-10-09)

- **Empty state:** "No monitor on the eGPU." With phase `ready` and
  `needs_relogin`, the relogin banner from §5.1 shows here too.
- **Per monitor** (from `display list`, E§7.3):
  - **Header:** description, connector, current mode, and an enabled `ToggleSwitch`.
  - **Workspaces:** chips for every workspace it holds. Clicking a chip runs
    `display move-workspaces` for that one.
  - **Arrangement:** `ButtonGroup` Extend / Mirror. Under Extend, a `ButtonGroup` for
    Left / Right / Above / Below.
  - **Mode:** `Dropdown` from `modes[]`.
  - **VRR:** `ToggleSwitch`, off by default, with the tooltip "NVIDIA turns VRR on
    by default; off avoids flicker on some monitors" (E§11.5).
  - **Turn off now:** a large button. It runs `display off` with no confirmation,
    because it is the glitch escape hatch.
- **Advanced (collapsed):** "Compatibility: disable explicit sync between GPUs"
  writes `display.mgpu_no_explicit` and states "takes effect after logging out"
  (E§11.4).
- **Footer:** "Primary renderer: <primary by-path> (laptop GPU)". This is the
  ordering fact from E§2 O1, shown so the user can see the compositor is not on the
  eGPU.

### 5.4 Games (its own view; E§8)

- **Top bar:**
  - Account `Dropdown` from `steam accounts`, labelled with persona name and
    "(most recent)".
  - Install badge "Steam" / "Steam (Flatpak)" when both exist, with a root switch.
  - Search `TextField`.
  - Bulk buttons **All on**, **All off**, and **Turn off stale**. The last is
    visible only when any game is `stale`.
- **Steam-running banner** (when `steam.running`): "Steam is open. It overwrites
  launch options when it quits." Two buttons:
  - **Close Steam, apply, reopen** runs `steam apply --close --relaunch`.
  - **Apply when Steam closes** sends the change with `--queue`.
  - A pending count shows once anything is queued.
- **Rows:** game name; a state chip using the E§8.5 labels (`on` → "on eGPU",
  `stale` → "stale (eGPU not connected)", `pending_*` → "applies when Steam closes",
  `manual` → "manual GPU options", `modified` → "edited by hand"); a `ToggleSwitch`.
  - The toggle is disabled for `manual`/`modified`. Those rows get **Show options**
    (read-only text of the full launch options) and, for `manual`, **Adopt**.
  - Adopt opens a `ConfirmDialog` with the exact before and after strings from the
    engine's dry run.
  - Row expander: **NVAPI (DLSS)** `ToggleSwitch` when the backend offers it (E§8.7),
    and the game's full current launch options.
- **Footer:**
  - "Backups: n · Restore…" lists backups for the account; restoring goes through
    the same closed-Steam rule.
  - A one-line note: "Switched games keep their setting when the eGPU is unplugged;
    they show as stale." This is the E§8.6 default.
- **Errors:** `vdf_parse_failed`, `vdf_check_failed` and `vdf_changed_underneath`
  render as "Nothing was changed" plus the reason. A failed check never leaves a
  half-applied row.

### 5.5 Setup / health (first run included)

- **Rows** from `omarchy-egpu health` (E§9), grouped by `group` with a
  `PanelSectionHeader` each. Each row shows a level icon, title, detail, and its Fix.
  - **`fix.kind: user`:** a **Fix** button. A `ConfirmDialog` names exactly what
    changes and where the backup goes, then runs `health fix <id>`.
  - **`fix.kind: system`:** **Copy the install command**, face's pattern. It claims
    "copied" only after `wl-copy` succeeds, and otherwise points to the README
    section (face:SetupView.qml:403-411).
    - All system Fixes share one command, the system-half install (E§10.4), so the
      dialog lists every system row it will change.
  - **`fix.kind: none`:** detail text only, with a "Learn more" anchor into the
    README.
- **First run.** This applies when no config file exists and bolt has no stored eGPU,
  i.e. a stranger's machine (REVISION 3). The view opens on Setup with a short
  ordered explainer generated from the error rows:
  1. Install the driver for your card (`driver.*`).
  2. Install the system half (`system.helper`).
  3. Make sure the driver will not load at boot (`boot.*`).
  4. Plug in and authorize the enclosure (`bolt.*`).
  It names nothing about the author's hardware. On a machine with no Thunderbolt at
  all, it says so and stops.
- **Warnings shown verbatim from engine detail text:**
  - "Do not rebuild the initramfs with the eGPU attached" (E§9.1).
  - The optional kernel parameters, labelled "optional — not confirmed necessary"
    (E§4.3).
- **Diagnostics:** **Save diagnostics** runs `health bundle` and shows the file path.
  Lines marked harmless by the enclosure profile are labelled so in the summary
  (E§9.3).

## 6. Error strings (`common/Errors.js`)

One map from engine error code to sentence.

- **Codes that must be present** (from plan-engine.md): `not_connected`,
  `no_pci_device`, `modules_failed`, `smi_hung`, `holders_present`,
  `hdmi_still_active`, `remove_timeout`, `unsafe_name`, `backend_stub`,
  `steam_not_found`, `account_not_found`, `steam_running`, `game_running`,
  `steam_close_timeout`, `vdf_parse_failed`, `vdf_check_failed`,
  `vdf_changed_underneath`, `token_modified`, `manual_offload`, `backup_failed`,
  `helper_missing`.
- **Exit codes:** exit 3 → "Busy — another eGPU action is running". Exit 126 →
  "Permission declined". Exit 127 → "The system half is not installed" (links to
  Setup).

## 7. Notch integration (REVISION 4)

Optional, declared, and built after the standalone panel (G8). Everything in §5
works with no notch installed. The notch documents three routes in
(notch:SURFACE-HOSTING.md:24-34). The plugin uses two of them and stays off the
third:

- the **declared integration**: the manifest `surface` key and `NotchIntegration.qml`
- the **`notch` descriptor** on the bar widget (notch:contract.js)
- **not** the menu bridge, which is private and "not an extension point"
  (notch:SURFACE-HOSTING.md:503-527). The `companion/` plugins
  (notch:companion/kalinewb.notch-osd/manifest.json) are clones of Omarchy built-ins
  routed through that bridge. That is not this plugin's situation, so the plugin
  ships no companion.

### 7.1 What the notch renders today

- I read this notch checkout (head `a237a0f`):
  - Its registry collects every bar widget's `notch` descriptor
    (notch:Bar.qml:1381-1410).
  - Its expanded-view hosts are instantiated for its own built-ins and for a declared
    integration's panel only: `notch.settings`, `notch.menu`, `notch.plugins`,
    `notch.setup`, `notch.integration` (notch:Bar.qml:4662-4762).
  - I found no code that draws a third-party widget's declared `closedView` or
    `expandedView` Component.
- Activity claims are "accepted and queued … but nothing draws them yet"
  (notch:SURFACE-HOSTING.md:268-271).
- So in v1 the plugin's visible notch experience is:
  - the bar widget itself as the resting glance (closedView `"widget"`, the contract
    default, notch:contract.js:36-43)
  - the integration's panel for the compact and full views
  - claims made now, which will render once the notch draws them
- The descriptor below is still declared in full, as REVISION 4 asks. It costs
  nothing and is inert where unread. **Flag for the user:** if the notch is meant to
  draw widget Components already, this checkout does not show it.

### 7.2 `NotchIntegration.qml` (loaded once by the notch)

Per notch:SURFACE-HOSTING.md:123-161:

- **`surfaceHost: null`.** Until the notch sets it, there is no notch.
- **`available`.** True when `status.json` exists and health does not report "no
  Thunderbolt" (E§9 `bolt.daemon`). On a machine with no USB4/TB, the plugin declines
  honestly (notch:SURFACE-HOSTING.md:132-134, 158) and keeps its standalone widget.
- **`panel: Component { NotchPanel {} }`**, with routes `main` (compact), `full`,
  `display`, `games`, `setup`, `eject`.
- **`activityViews`.** `{ "egpu": noticeRow }`, a one-line row that reuses `Glance`.
- **It owns the costs.** It holds the one `StatusSource` (a `FileView` on
  `status.json`, §3) and one `Engine` pool. The file "exists once", so anything with a
  cost belongs there, not in the per-screen panel (notch:SURFACE-HOSTING.md:147-149).
- **It does not:**
  - register an `IpcHandler` (notch:SURFACE-HOSTING.md:153-154)
  - open windows (notch:SURFACE-HOSTING.md:81-86, 155)
  - write under the plugins folder (notch:SURFACE-HOSTING.md:156-157)
- **The bar widget side.** `Panel.qml` declares `surfaceHost` and `surfaceScreen` too,
  so a click can go into the notch on the right screen
  (notch:SURFACE-HOSTING.md:190-207). `press()` calls
  `surfaceHost.openPanel("main", surfaceScreen)`. If the answer is not `opened`, the
  widget opens its own popup. That is the per-event rule
  (notch:SURFACE-HOSTING.md:316-319).

### 7.3 The `notch` descriptor on the bar widget

```qml
// Panel.qml (root). Inert unless a notch reads it (notch:Bar.qml:1389).
readonly property var notch: ({
  closedView: "widget",              // the BarIndicator, which already renders Glance (§7.4)
  expandedView: compactComponent,    // CompactView; drawn when the notch hosts widget views (§7.1)
  priority: noticeLive ? "transient"
          : (["in_use","ejecting","attention"].indexOf(status.summary.state) !== -1 ? "persistent" : "persistent-low"),
  groupable: !noticeLive,
  hideable: true
})
```

- All values are within notch:contract.js:97-121: `closedView` is `"widget"` or a
  Component, `expandedView` is a Component or null, `priority` is one of
  `PRIORITIES` (notch:contract.js:34), and the flags are booleans. Invalid values fall
  back to defaults (notch:contract.js:28), so a mistake cannot break the notch.
- **`priority`** is declared, not detected:
  - `transient` while a notice is live (§7.5)
  - `persistent` while the eGPU is in use, ejecting, or needs attention, because
    unplugging then matters
  - `persistent-low` otherwise
- **`preferredHeight`** is omitted, so the resting height applies.
- **`closedView` moves to `glanceComponent` the day the notch draws widget
  Components.** That is a one-line change, gated by G8's re-check of §7.1.

### 7.4 Glance (closed view) states

`views/Glance.qml`, used by the bar widget, the notice row and the compact header. It
shows one glyph and a short word or two, from `summary.state`:

| `summary.state` | glyph | text | notes |
|---|---|---|---|
| `absent` | dim eGPU glyph | — | hidden entirely if `gui.hide_when_absent` |
| `connecting` | eGPU glyph, slow pulse | "connecting" | pulse runs only while `active` |
| `ready` | accent glyph | "ready" | |
| `in_use` | accent glyph + dot | "in use" (`gpu.util_pct`% when > 0), monitor mark if HDMI on | |
| `ejecting` | pulse | "ejecting" | |
| `safe_to_unplug` | `good` glyph | "unplug" | |
| `attention` | `warn` dot | "log out" / "check setup" | from `summary.line` |
| `error` | `bad` dot | "error" | |

Pulses are gated on visibility. A looping animation drawn at zero opacity still
repaints the host every frame (notch:SURFACE-HOSTING.md:490-492).

### 7.5 Transient notices

- **Two moments get notices:**
  - **Plugged in** (event `plugged`).
    - If `connect.auto` will load the driver: "eGPU connected — getting it ready".
    - Otherwise: "eGPU connected — load driver?". Its `panelRoute: "main"` opens the
      compact view with **Connect** focused.
  - **Safe to unplug** (event `eject_ready`): "Safe to unplug the eGPU".
- **Mechanics.** Each moment does three things at once:
  1. Sets `noticeLive` for 8 s, so the descriptor's `priority` is `transient` (§7.3)
     and the glance shows the notice text.
  2. Calls `surfaceHost.claim({ key: "kalinewb.egpu.notice", priority: "transient",
     title, ttlMs: 8000, glyph, view: "egpu", panelRoute: "main" })`.
     - The same key replaces in place (notch:SURFACE-HOSTING.md:294-295).
     - A transient older than 10 s in the queue is dropped
       (notch:SURFACE-HOSTING.md:296-297), which is correct for these.
  3. Lets the Service send its `notify-send` (§8) **unless** the claim answered
     `shown`. Today claims answer `queued` (notch:SURFACE-HOSTING.md:268-271), so the
     notification always fires.
- **Warnings never stand down.** The eject "Do not unplug" state (`remove_timeout`)
  and the "unplugged without ejecting" notice are warnings. Under the notch's rule 2
  (notch:SURFACE-HOSTING.md:321-329) they appear as claims **and** always as the
  plugin's own notification and panel state, whatever the claim answers.
- **Claims carry only state words.** No process names and no Steam account names
  (notch:SURFACE-HOSTING.md:301-302, 383).

### 7.6 Compact expanded view (`CompactView`, route `main`)

- **Content**, one column, sized by `implicitHeight` within `maxHeight`:
  - `Glance` header plus `summary.line`.
  - Temperature, utilisation and VRAM in one line when `ready`.
  - One primary button: **Connect** / **Safe eject** / **Reconnect** (as §5.1).
  - **HDMI quick toggle** when an eGPU monitor exists: a `ToggleSwitch` for the first
    monitor plus **Turn off now** (E§7.3 `display off`).
  - `attention` sentences from §6.
  - **Open full panel** → `requestRoute("full")`.
- **Route `full`** renders the four standalone tabs (§5.1–5.5) at `density: "full"`
  inside the notch's `maxPanelWidth/Height` (notch:SURFACE-HOSTING.md:182). These are
  the same components, so nothing is forked.
- **Route `eject`** is `EjectFlow`. Long steps continue in the engine, so the user can
  close the notch and watch the glance (§7.7, focus grab).

### 7.7 Hosted-panel pitfalls and how the plan handles them

| pitfall | evidence | handling |
|---|---|---|
| **`opened` / being told it is open.** Live work hung off "open" never ran in a hosted panel (wifi listed no networks) | notch:INTEGRATION-SCOPE.md:29-75. Now fixed: a hosted panel sees `opened` true (notch:SURFACE-HOSTING.md:101) | Views key all live work on `active`. Standalone binds `active: opened`. `NotchPanel` sets `active` in `open(route)` / `close()`, which the notch calls (notch:SURFACE-HOSTING.md:222-223). Nothing keys on window `visible`, geometry or screen (notch:SURFACE-HOSTING.md:483-485) |
| **Given back at any moment** | notch:SURFACE-HOSTING.md:493-494, 366-375 | `close()` is a real close: `active` false, `Engine` calls are left to finish, and no view keeps state the engine does not have. Reopening re-derives everything from `status` (an eject in progress shows as `ejecting`) |
| **Back stack.** The notch's back strip is "never over a hosted panel or an integration, which own their surface" | notch:INTEGRATION-SCOPE.md:79-81 | `NotchPanel` keeps its own route stack: `main → full → games`, and `eject` pushed over anything. A small "‹ Back" text button at the top right of its header, matching the notch's own pages (`‹ Settings`, `‹ Setup`; notch:INTEGRATION-SCOPE.md:93-94). **Escape** first asks the current view to `popView()`, which closes a dialog or sub-sheet; then pops a route; and at the root emits `closeRequested()` (notch:SURFACE-HOSTING.md:235). Standalone uses the same `popView()` chain before `close()` |
| **Keyboard focus** | The notch gives an integration panel focus when shown (notch:Bar.qml:2924). A hosted unmodified panel gets its `focusTarget` (notch:SURFACE-HOSTING.md:103) | `NotchPanel` and the standalone root set `focus: true` and forward keys to the current view. Games: typing filters the list, arrows pick a row, Return toggles it (the "typing should search, Return runs the picked row" rule, notch:SURFACE-HOSTING.md:235-236). Dialogs (`ConfirmDialog` is an `Item`, omarchy:shell/Ui/ConfirmDialog.qml:4) take focus and give it back |
| **Focus grab.** While any notch panel is open, the app behind receives no keyboard or pointer | notch:INTEGRATION-SCOPE.md:109-142 ("Still open underneath it") | Do not make the user hold the notch open: Connect and Eject return immediately, progress shows in the glance, and the eject sheet says "you can close this" |
| **Colours and backgrounds** | notch:SURFACE-HOSTING.md:229-235. P5, notch:INTEGRATION-SCOPE.md:196-211 | `palette` only (§5.0). `background: null` in the notch |
| **Popups** | No windows (notch:SURFACE-HOSTING.md:81-86) | No `PanelToolTip` at `density: "compact"`. `PanelToolTip` is a Controls `ToolTip` (omarchy:shell/Ui/PanelToolTip.qml:18), and whether it stays in-scene inside the notch is unverified (G8). Detail text goes inline instead |

### 7.8 Degrading cleanly

| situation | behaviour |
|---|---|
| no notch installed, or another bar | `surfaceHost` never set (notch:SURFACE-HOSTING.md:190-192); `notch` never read; integration file never loaded. Standalone only |
| notch present, integration switched off by the user | `accepted` false. Click opens the own popup. Claims are released (notch:SURFACE-HOSTING.md:370) |
| notch reloads (any plugin install/update) | Integration destroyed and reloaded (notch:SURFACE-HOSTING.md:372). `StatusSource` re-reads `status.json`. A notice lost in the gap still went out as a notification |
| bar hidden (`omarchy toggle bar`) | `openPanel`/`claim` answer `declined:hidden` (notch:SURFACE-HOSTING.md:375). The own popup and notifications are used |
| notch contract newer than 1 | `contract-newer` → standalone (notch:SURFACE-HOSTING.md:422-424) |

## 8. Notifications (Service)

- **What triggers them.** The watcher's event records (E§5.1) drive `notify-send`
  (installed), gated by `notify`. Under the notch, the per-event rule of §7.5 decides
  whether to skip one; warnings are never skipped:
  - eGPU plugged
  - ready
  - "unplugged without eject" — if it happened while phase was `ready`, with the yank
    sentence
  - "safe to unplug"
  - the Steam queue applied
  - "N games are stale" once per unplug, with a "Turn off stale" action
- **Sleep notice.** While the eGPU is bound, the Service shows the notice from E§2 O5
  when logind reports `PrepareForSleep`.
  - The inhibitor itself is held by the engine's watcher process.
  - Gate E8 decides whether the inhibitor stays in the engine. **Doubt:** the plan puts
    it there.

## 9. Development mode

- **Stub engine.** Copies face's arrangement: `dev/bin/omarchy-egpu` is a stub that
  answers from `dev/fixtures/<name>/*.json`.
  - `./dev-sync.sh --dev` restarts the shell with `OMARCHY_EGPU_DEV_BIN` and
    `OMARCHY_EGPU_DEV_FIXTURE` set (face:install.sh:14-16, 77-110).
  - It refuses while the session is locked (face:install.sh:96-106).
- **Fixtures.** They mirror the engine test scenarios (E§13): absent, connecting,
  ready, ready-hdmi, needs-relogin, ejecting-holders, remove-timeout, ejected-held,
  stranger-first-run, steam-running, steam-mixed-states. The panel can therefore be
  built before any engine phase lands.
- **Lint.** `dev/lint.sh` runs qmllint against `qs.*` (profiles:dev/lint.sh:3-15).
- **Notch harness.** The integration is tested in a throwaway Quickshell, with the
  notch pointed at a fixture plugins folder (`NOTCH_FORCE_PLATFORM=1
  NOTCH_PLUGINS_DIR=… quickshell -p /tmp/root -n`, notch:SURFACE-HOSTING.md:395-406).
  - The notch's `acme.demo` fixture is the reference (notch:SURFACE-HOSTING.md:408-409).
  - `omarchy-shell notch integration kalinewb.egpu` reports accepted or declined,
    with the reason (notch:SURFACE-HOSTING.md:387-393).
  - Symlinks for that root are created in a temp dir at test time and never committed
    (notch:SURFACE-HOSTING.md:64-68).
- **Standalone regression.** Every notch test run ends with the same checks under
  `omarchy.bar` (notch:SURFACE-HOSTING.md:411-412).

## 10. Phases (GUI), each gated

| phase | delivers | gate |
|---|---|---|
| **G1** shell + indicator | manifest, Panel/Service skeleton, Engine pool, BarIndicator, dev stub | `omarchy plugin validate` passes on the staging copy. Lint clean. All phases of §4 render from fixtures. The Service mounts at startup without `keepLoaded` (or the manifest is switched) |
| **G2** Overview | §5.1 with Connect / Run on eGPU | Matches engine E3 on real hardware: Connect drives phase to `ready`, and Run on eGPU starts `vkcube` on the eGPU |
| **G3** Eject flow | §5.2 | Every step and failure renders from fixtures. On hardware, with E5: an eject with the HDMI monitor on and a holder open ends at "Safe to unplug" |
| **G4** Display | §5.3 | With E4: toggle, mirror/extend, position, mode and VRR each change Hyprland. "Turn off now" and right click both blank the monitor in < 1 s |
| **G5** Games | §5.4 | With E6: per-game toggle, bulk, account switch, close-apply-reopen, queue, Adopt and Restore each work once against the user's real Steam (after E6b passes on fixtures). All six state chips render |
| **G6** Setup | §5.5 | On this machine the stale modules-load mask shows as an error with a system Fix. The first-run fixture reads correctly to someone who has never seen the plugin. The copy-command path works and fails honestly without `wl-copy` |
| **G7** notifications + polish | §8, README screenshots | Plug, unplug, yank and sleep notices observed once each on hardware |
| **G8** notch integration (after G1–G7, i.e. after the standalone panel ships) | `NotchIntegration.qml`, `NotchPanel.qml`, `Glance`/`CompactView`, `notch` descriptor, claims | (a) `omarchy-shell notch integration kalinewb.egpu` says accepted, and on a fixture machine with no Thunderbolt it declines with the plugin's reason. (b) Clicking the widget under the notch opens `main` on the clicked screen. Compact Connect, Eject and the HDMI toggle work. "Open full panel" shows the same four views with no forked code: a grep finds no view file outside `views/` in NotchPanel's imports. (c) Escape pops eject sheet → full → main → closed. Typing in Games filters. No colour in the notch comes from `Color.*` (checked with the notch's mono shader off). (d) Plug-in and safe-to-unplug fire claims with the right keys and priorities (`omarchy-shell notch activities`), and notifications still fire. (e) §7.1 re-checked against the notch's current head: if widget Components are drawn, `closedView` switches to `Glance` and is verified. (f) The whole G1–G7 checklist passes again under `omarchy.bar` with the notch removed |

## 11. Doubts

- **The notch's widget descriptor is not drawn yet** (§7.1). I may be misreading
  Bar.qml. If not, the descriptor is declared for the future, and the notch experience
  in v1 rests on the surface integration.
- **Transient notices are not drawn yet either** (claims are queued). Until the notch
  draws them, plug-in and eject-ready reach the user as notifications, and the glance
  only shows them through the bar widget.

- The service without `keepLoaded` (§2) is untested for third-party plugins.
- No app picker for "Run on eGPU", because the app-library facade is for `menu`
  plugins only (omarchy:shell/README.md:96).
- I have not checked whether the bar host forwards right clicks on a third-party
  widget (§4). G1 checks it. If it does not, the README suggests a keybinding for
  `omarchy-egpu display off`.
