# Requests for omarchy-notch, from the eGPU integration (G8)

The eGPU plugin integrates with the notch through the declared integration
(`entryPoints.surface` + `surface.contract: 1`, `NotchIntegration.qml`) and a
`notch` descriptor on its bar widget (plan-gui.md §7). This repo never edits the
notch. These are the notch-side changes the integration would use, written
against the checkout at `the omarchy-notch checkout`, head `a237a0f`
(2026-09-27), as read on 2026-10-10. Nothing here blocks the plugin. Each item
says how the plugin degrades today.

`dev/g8-offscreen.sh` pins today's behaviour of items 1, 2 and 5 against the
checkout, so when the notch changes, a check fails and points here.

## 1. SURFACE-HOSTING.md §5 says activities are not drawn; the code draws them

- **Doc:** SURFACE-HOSTING.md:268-271: "Activities are accepted and queued today,
  but nothing draws them yet … Don't hide your own cue for one until this note is
  gone." NotchPlatform.qml:497-498 has the same comment.
- **Code:** Bar.qml:2026 sets `activitiesRendered: true`. Bar.qml:2044-2051 picks
  the newest visible claim, and Bar.qml:4676-4690 draws it with
  `ActivityGlance.qml` as glyph, title and detail. A claim the queue shows
  answers `shown` (NotchPlatform.qml:509). The comment above Bar.qml:2026 still
  carries both the old and the new sentence.
- **Ask:** update §5 and the two comments, so plugins know `shown` now means "on
  screen".
- **Plugin today:** keeps the answer (`NotchIntegration.lastAnswer`) but does
  not stand any cue down on it yet. G7 (notifications) decides that, and
  warnings never stand down (rule 2).

## 2. Named `activityViews` are listed but never drawn

- NotchPlatform.qml:78 reports `Object.keys(item.activityViews)`. A claim's
  `view` is validated and stored (platform.js:145, activities.js:30).
  `ActivityGlance` always draws the notch's own glyph-and-title row and never
  instantiates the named Component.
- **Ask:** instantiate `activityViews[claim.view]` in the activity line, handing
  it the claim and the host, or drop `activityViews` from the contract and
  `features`.
- **Plugin today:** declares `{ "egpu": noticeRow }` (a `Glance` showing the
  notice title) and sends `view: "egpu"`. The notch draws its own row from
  `title` and `glyph`, which carry the same words. Nothing is lost.

## 3. A claim's `panelRoute` is stored but nothing opens it

- `panelRoute` is validated (platform.js:147) and kept with the entry
  (activities.js:31, 193). No code in Bar.qml or ActivityGlance.qml opens the
  integration's panel at that route when the activity line is clicked.
- **Ask:** a click on an activity line opens `openPanel(panelRoute, screen)` for
  its owner, as SURFACE-HOSTING.md:283 promises ("clicking it opens your panel
  there").
- **Plugin today:** sends `panelRoute: "main"`, so the plug-in notice would open
  the compact view with Connect. The user reaches it by clicking the widget.

## 4. `available` is read only when the notch refreshes

- NotchPlatform.qml:219 reads `item.available` inside `refresh()`. `refresh()`
  runs on a scan, a loader status change, a layout change or a user switch, never
  on the integration's `availableChanged`.
- An integration whose answer depends on something it reads after loading can be
  stuck either way until something unrelated triggers a refresh.
- **Ask:** connect to `item.availableChanged` (where the property is notifiable)
  and call `refresh()`.
- **Plugin today:** reads `status.json` synchronously when it is created
  (`StatusSource.blockLoading`), so the answer is right at load whenever the
  watcher has already written the file. If no file exists yet (the very first
  seconds of a session), `available` is `true` until the status says otherwise.
  On a machine with no Thunderbolt, the plugin can then be accepted until the
  next refresh. Its panel then honestly says "No eGPU", which is the safe side
  of the race.

## 5. A plugin cannot say why it declined

- With `available: false` the notch shows its own words, "Not available right
  now" (platform.js:27). The plugin has a precise reason: "This machine has no
  Thunderbolt or USB4 port."
- **Ask:** an optional `unavailableReason` string on the integration, shown in
  Settings → Integrations and in `omarchy-shell notch integration <id>` as
  `reasonDetail`. This is additive, so it needs no contract bump.
- **Plugin today:** declares `unavailableReason` already. It is inert until read.
  Gate G8 (a) asks for "declines with the plugin's reason". Today the notch can
  only report `unavailable`.

## 6. SURFACE-HOSTING.md §3: what `closed` from `openPanel` means

- §3's example and NotchHost.qml:66-70 say anything but `opened` is "the
  plugin's cue to open its own UI instead".
- Bar.qml:3288-3290 answers `closed` when the same panel at the same route was
  already open: the click toggled it shut. Following the example literally opens
  the plugin's own popup on the click that closed the notch's panel.
- **Ask:** say in §3 that `closed` means the click was taken (it closed the
  notch's panel), and fix the example to `if (result !== "opened" && result !==
  "closed")`.
- **Plugin today:** treats `opened` and `closed` as taken and everything else as
  "open our own" (`Panel.qml press()`).

## 7. Widget descriptor Components are collected but not drawn

- This is plan-gui.md §7.1, re-checked. Bar.qml:1381-1410 collects each widget's
  `notch` property into the registry. No code instantiates a widget's
  `closedView` or `expandedView` Component: Bar.qml never names `closedView`, and
  every `ExpandedHost` is bound to a `notch.*` descriptor or the integration's
  panel. `priority` and `groupable` are kept but not acted on for widgets;
  `hideable` is (Contract.effectiveHidden).
- **Ask:** none. Noted so the descriptor's role stays clear.
- **Plugin today:** declares the full descriptor. `closedView: "widget"`, the bar
  indicator. `expandedView` is the compact view Component. `priority` is
  transient / persistent / persistent-low by state. The day the notch draws
  Components, `closedView` switches to the plugin's `glanceComponent` (one line
  in Panel.qml).

# UI strings for 0.1.1 (a request to the UI work, not to the notch)

Written by the 0.1.1 engine change (`fix-eject-unload`). This change touched no QML and no `views/`; the migration of
the UI owns those files. What the UI needs for the new eject answer:

## New error code `driver_in_use` (`device eject`)

Safe eject now unloads the driver before it removes the card. If something still holds the driver it answers
`{"error":"driver_in_use", ...}` (exit 1), changes nothing, and leaves the eGPU attached and in service. Fields:

| field | meaning |
|---|---|
| `names` | the holders' process names, unique and sorted (may be empty: only kernel references) |
| `holders` | the same rows as `holders_present`'s `holders` (`pid comm uid nodes role why closeable ...`), but ALL roles: `incidental`, `shell` (quickshell), `compositor` (Hyprland) and `app` |
| `modules` | `[{module, refcnt, expected, foreign}]`: the busy modules; `foreign` names holding modules outside the stack |
| `can_close` | true if `--close` could ask any of them to quit (normally false: apps were closed or reported in the `holders_present` step) |
| `session_holds` | true if the compositor or the shell holds it: only a logout lets go |
| `shared_driver` | true when another NVIDIA GPU in the machine shares the driver, so it can never be unloaded here |
| `display` | what was done to the screens: `touched` false and `off: []` when the check ran first (the usual case: nothing was touched, the screens are as they were); otherwise `off` lists the screens turned off, and `restored` / `restore_failed` (descriptions) say which came back on. Their workspaces stay on the laptop panel |
| `restore` | `{ok, rc, error}` of putting the driver back after an unload done in part (absent or `null` when nothing needed putting back). `ok: false` means the eGPU may not work until a logout; the `detail` says so |
| `detail` | an English sentence already worded by the engine (see below), safe to show |

The error's `phase` is the phase the card is left in (`ready`).

Since the review fixes, `driver_in_use` is answered BEFORE any monitor is touched whenever only the session, incidental holders or kernel references hold the driver (`display.touched: false`). The screens are only turned off, and then back on, when apps had to be closed first. `holders_present` and `hdmi_still_active` still leave the screens off (the answer lists them in `display`).

Done: `common/Errors.js` words `driver_in_use` and `views/EjectFlow.qml` draws its failed step (see "UI work for the
merge" below).

## New use of `modules_held` in `device eject` (do not suspend)

`modules_held` was a rescan answer. An eject now also answers it in two cases (exit 1; the card is gone, the marker stays
if there was one, the phase is `ejected`), the exact state a removed GPU oopses the next suspend in:

1. the card was removed but its driver is loaded again and one more unload did not work (the end of a real eject);
2. (0.1.2) `device eject` was run again with no card on the bus and the driver still loaded: "Try again" after case 1, or
   an eject with the enclosure still connected and its GPU function gone (a real cable pull is phase `absent` and
   answers `not_connected`, so it does not reach this branch). It used to answer `already: true`, which the UI showed as
   "Safe to unplug". The engine
   now asks first whether the modules are loaded; if nothing holds them it unloads once more, and on success answers
   the ordinary `already: true` with `modules: {held_after_eject: false, unloaded: true}`; otherwise `modules_held`
   with `do_not_suspend` again.

Fields: `bdf` (the removed card's address; `null` in case 2), `removed` (`[]` in case 2), `held_by` (process names), `unload`
(the last unload's answer, or `null` when none was tried), `display`, `do_not_suspend: true`, and a `detail` sentence
("... Do not suspend the computer: log out first. Once the driver is unloaded it is safe to suspend and to unplug."). The engine also posts `eject_failed {error:
"modules_held"}`, not `eject_ready`, so no "Safe to unplug" notice is raised for it. `status` for this state is
unchanged: phase `ejected` with `modules.held_after_eject: true`.

`common/Errors.js` now words `modules_held` as "The driver is still loaded without the card. Do not suspend or sleep this
computer: log out first." (0.1.2), which reads right for the eject and for the rescan refusal. `lib/status.sh`'s summary
line for held modules, whatever the phase (`ejected`, or `absent` after a cable pull), is now "Do not suspend · the driver
is still loaded · log out first" (for phase `ejected` it said "Safe to unplug · log out before plugging it in again", for
the others "Log out before plugging the eGPU in again"); `tests/fixtures/ejected-held` and
`dev/fixtures/ejected-held/status.json` carry the new line (only that line was regenerated; the other fixture drift in
`dev/make-fixtures.sh`'s output was left to the UI work).

# UI work for the merge (done: `common/Overview.js`, `common/Errors.js`, `views/EjectFlow.qml`)

The engine and the shared sentences say "do not suspend" for held modules, and the panel now does too:

1. `common/Overview.js`, state `attention` with `modules.held_after_eject`: headline "Log out" (the notch's first row
   holds at most 12 characters, so "Do not suspend" does not fit there), detail the engine's `summary.line` ("Do not
   suspend · the driver is still loaded · log out first"), never "Safe to unplug", in either phase. `Errors.note("held_after_eject")` leads with the warning: "Do not suspend the computer: the driver is still
   loaded. Log out first, then plug the eGPU in again." The Setup-issue branch cannot be reached with held modules (the
   engine and the Overview both test them first) and says "Do not suspend" if it ever is.
2. `views/EjectFlow.qml`, `done` step: with `modules.held_after_eject` (a stale status; the engine answers `modules_held`
   now) it says "Do not suspend", not "Safe to unplug".
3. `views/EjectFlow.qml`, `failed` step, by answer:
   - `driver_in_use`: the sentence, "Still using it: <names>" (at most six), "Your session itself holds the driver;
     logging out lets go of it." when `session_holds`; "Close <apps>" (the confirm row) only when `can_close`; with
     `shared_driver` the sentence is "This computer's own NVIDIA GPU shares the driver, so the eGPU cannot be ejected
     safely. Shut down before unplugging." and there is no retry and no Close;
   - `modules_held` with `do_not_suspend`: `detail`, "Do not suspend. Log out first.", no Try again;
   - `remove_failed`/`busy`/`helper_missing` with `driver_unloaded`: "The driver is unloaded. Open the lid or press
     Connect to bring the eGPU back.", the engine's `detail` under it, and Connect (`device connect`) is the primary
     action, replacing Try again; when Connect works the sheet goes back, the Overview then shows the eGPU ready;
   - any answer whose `display.off` lists monitors that `display.restored` does not: "Turn the screens back on" runs
     `display enable <monitor>` for each (the same verb the engine uses to restore them). Not offered for `smi_hung`
     (a hung driver cannot light them; the text says to open the lid or turn the display back on). The panel's verb list
     (`common/Engine.qml` `builtVerbs`) leaves the monitor verbs out on purpose, so this does not go through
     `engine.can()`.

Not changed: the `holders` step still leaves the screens off when the user cancels (the engine's convention: the next eject
starts from there); it has no "Turn the screens back on".

Also from 0.1.2, `device eject` can answer `driver_unloaded: true` on a `remove_failed`/`busy`/`helper_missing`
answer: see "driver_unloaded" below.

## `driver_unloaded` (0.1.2, `device eject`)

When the driver was unloaded for the eject and the engine then could not ask the helper to remove the card or to put the
driver back (pkexec exit 126 or 127, the helper busy, or helper_missing), the eGPU is still attached but its driver is
gone, so its monitors stay dark. The error answer (`remove_failed` with `pkexec: 126/127`, `busy`, or `helper_missing`)
now carries `driver_unloaded: true` and a `detail` that says so: "The driver was unloaded for the eject, and the system
helper could not be used afterwards (declined, missing or busy), so the driver was not loaded again: the eGPU is
connected but does not work and its monitors stay dark. Press Connect to load the driver again, or open the lid to use
the laptop screen." (appended to the pkexec ones' own detail, "permission declined: ..."). The panel shows it and makes
Connect the primary action. The engine does not try to `load` again in this state (no load was tried: polkit just
refused or the helper was not there), and does not try to turn the screens back on either (nothing can light a monitor on
a card with no driver); the answer's `display` lists what is off.

`helper_missing` also carries a `detail` now ("The system helper is out of date (0.1.1, this plugin needs 0.1.2).
Reinstall the system half..."), and `Errors.sentences.helper_missing` says "not installed or out of date".
