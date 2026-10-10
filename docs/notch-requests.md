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
