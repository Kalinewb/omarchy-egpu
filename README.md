# omarchy-egpu

eGPU manager for [Omarchy](https://omarchy.org): connect and safely eject a Thunderbolt/USB4 eGPU without
rebooting, see its state in the bar, and toggle "run on eGPU" per Steam game.

**Status: work in progress, not installable yet.** The engine (status, health, connect, safe eject, rescan),
the root helper and the Steam launch-option module are tested against fake hardware and fixtures. The
panel's Overview, Details, Setup and safe-eject sheet render every state offscreen, and the optional notch
integration (for [omarchy-notch](docs/notch-requests.md)) renders and declines offscreen against the notch's own
rules. The panel is drawn with the suite's shared UI kit (see "The panel's UI" below). Games, Screens and
notifications have no panel yet, and nothing is verified under the live shell or on real hardware yet. First
tested hardware: Minisforum DEG2 + RTX 4070 SUPER on an Intel Lunar Lake laptop.

Design: see `docs/` (`scope.md`, `plan-engine.md`, `plan-gui.md`) and `dev/e0-facts.md` for what was observed on
real hardware.

```bash
dev/test.sh           # everything below but check-pins (--quick: lint only; --no-engine: skip tests/run.sh)
tests/run.sh          # engine tests, no hardware needed
dev/lint.sh           # shell, Python, JSON and QML checks
dev/g1-offscreen.sh   # the bar, Overview, Details, Setup and eject sheet, offscreen from fixtures
dev/g8-offscreen.sh   # the notch integration, offscreen, against the notch checkout's rules
dev/keys.sh           # real key presses (Esc, Tab, Enter, Space, arrows) in the notch panel and the popup
dev/check-ui.sh --score --walk dev/walk-root.qml   # the UI kit's gate: ui/ is the kit, no literals, one Esc, the walk
dev/render.sh --all docs/screens/after   # every state, hosted black and white and standalone, to PNG
dev/check-pins.sh     # the root half's pins, checksum, versions and the command below agree
```

## System half (root)

Connect, eject and rescan need a small root helper, `/usr/local/bin/omarchy-egpu-admin`, with polkit actions
(`no.kalinewb.egpu.policy`, one per helper verb), a udev rule (`/etc/udev/rules.d/61-omarchy-egpu.rules`: the
`/dev/dri/omarchy-egpu-primary` and `-external` links, and auto-connect), a boot-load mask in
`/etc/modules-load.d/` named after the file the driver package ships, the auto-connect flag
`/etc/omarchy-egpu/autoconnect`, and (0.1.1) the sleep guard with its three systemd drop-ins. `omarchy plugin add` never runs sudo, so this half is installed afterwards, from
a terminal, from the installed plugin folder. The helper takes only fixed verbs and loads only
`nvidia nvidia_modeset nvidia_drm nvidia_uvm`; see the header of `system/omarchy-egpu-admin`. It passed a
security review with conditions; the changes made for it (auto-connect switch, eject latch) await a re-review.
0.1.1 changes the helper's `unload` (it may now run with the eGPU still on the bus) and adds a second root
script, the sleep guard (below): both await a security review before they are installed.

- Connect, eject and rescan ask for no password at the active local session (polkit `allow_active=yes`). Turning
  auto-connect on or off from the panel asks for your own password.
- Safe eject refuses while a monitor on the eGPU is still lit, and after it the eGPU is left alone by
  auto-connect until you unplug it or press Connect.
- Safe eject unloads the NVIDIA driver **before** it removes the card, and refuses while anything still holds
  the driver: it answers `driver_in_use`, names what holds it, and leaves the eGPU attached and working. (A
  removed GPU with the driver left loaded oopses `nvidia_uvm` at the next suspend and then freezes the
  machine.) Nothing is killed to free the driver; `--close` still asks only your own GPU apps to quit. A
  session that holds the card for its whole life (the compositor, the shell, `nvidia-persistenced`) makes the
  eject say so until you log out or close it. It checks that before it touches a monitor, and if it fails after it
  turned the eGPU's monitors off it turns them back on (their workspaces stay on the laptop panel). If the driver
  is loaded again after the card was removed it unloads once more, and if that fails it says **do not suspend,
  log out first** (`modules_held`), never "Safe to unplug"; so does an eject run again with no card and the driver
  still loaded (it unloads once more if nothing holds the driver). This is a change from 0.1.0, which removed first and
  left the driver loaded. From 0.1.2 the helper's own `remove` also refuses (`modules_loaded`) while any of the
  four NVIDIA modules is loaded, so another program of yours cannot remove the card under a loaded driver by
  calling the helper directly; the engine unloads first, so a normal eject never meets it.
- The **sleep guard** (`/usr/local/bin/omarchy-egpu-sleep-guard`, run before the NVIDIA sleep actions of
  `nvidia-suspend.service`, `nvidia-hibernate.service` and `nvidia-suspend-then-hibernate.service` by a drop-in
  in `/etc/systemd/system/`) is a **partial** net for a card that left without a safe eject (a cable pull, a
  crash). If the NVIDIA modules are loaded and no NVIDIA GPU is on the PCI bus, it first tries to unload them,
  which works **only if nothing holds them**. On a desktop session something usually does (the shell, Electron
  apps and the like keep `/dev/nvidia*` open all session), so the unload often fails. When it fails the guard
  makes systemd **skip the NVIDIA suspend/hibernate actions** for that sleep (nothing is written to
  `/proc/driver/nvidia/suspend`, which is what oopses the kernel with no GPU), and logs it; the computer still
  suspends, without them. Log out and unload the modules (`sudo modprobe -r nvidia_uvm nvidia_drm
  nvidia_modeset nvidia`) when it says so. With an NVIDIA GPU on the bus the guard does nothing; so on a hybrid
  laptop with a working NVIDIA GPU it never acts, and ejecting an eGPU there answers `shared_driver` (the
  driver is shared, so it cannot be unloaded). It bounds the delay it adds to a sleep (about 15 s in the typical
  worst case, 23 s measured when the guard ignores SIGTERM, about 32 s if a process stuck in the kernel costs two
  5 s stop phases, which was not tested); a signal that kills it fails the NVIDIA unit, not the sleep. Not
  covered: the suspend-then-hibernate path in `/usr/lib/systemd/system-sleep/nvidia`, which writes to the driver
  outside any unit; a user who sets `HandleLidSwitch=suspend-then-hibernate` reaches it and is not protected.
  (A rare false "no NVIDIA GPU" at the instant of the check would skip the NVIDIA suspend of a working GPU, and
  with `NVreg_PreserveVideoMemoryAllocations=1` the kernel then aborts that sleep: an abort, not a hang.) The guard does not take the helper's lock, and `modprobe -r` also removes dependencies nothing
  else uses (`video`, `drm_ttm_helper`). Its log lines carry the tag `omarchy-egpu-sleep-guard`; the journal
  does not authenticate a tag, so read them with `journalctl -t omarchy-egpu-sleep-guard _UID=0`. Threat
  model and what was and was not verified: `docs/plan-engine.md` §10.5.

### Installing or updating the system half

The engine refuses a helper whose version differs from the plugin's, so after updating the plugin to 0.1.1 the
system half must be installed again (`reinstall`, below) before eject, connect or rescan work; until then they
answer `helper_missing`.

The command fetches the installer's checksum from this release's tag on GitHub, copies `system/install.sh` into
a root-only directory, checks the copy and runs it. The installer checks every file it installs against
checksums in its own text. Compare what you paste with this:

```bash
d="$HOME/.config/omarchy/plugins/kalinewb.egpu" && sum=$(curl -fsSL https://raw.githubusercontent.com/Kalinewb/omarchy-egpu/v0.1.1/system/install.sh.sha256) && sudo /usr/bin/bash -c 'PATH=/usr/bin; t=$(/usr/bin/mktemp -d /run/omarchy-egpu-installer.XXXXXX) && /usr/bin/cp -- "$1/system/install.sh" "$t/install.sh" && printf "%s  %s\n" "$2" "$t/install.sh" | /usr/bin/sha256sum -c --quiet - && /usr/bin/bash -p "$t/install.sh" --expect-sha256 "$2" install "$1" "$3"; s=$?; /usr/bin/rm -rf -- "$t"; exit $s' omarchy-egpu "$d" "$sum" "$USER"
```

- `bash system/install.sh --print-command uninstall` (or `reinstall`) prints the same command for removing it.
  Uninstall removes every installed file (the sleep guard and its drop-ins included), the auto-connect flag
  included, and puts back what install replaced
  (saved under `/var/backups/omarchy-egpu/`). **Removing the boot-load mask means the driver package loads
  `nvidia-uvm` at boot again**; with no eGPU attached at boot, that is what froze this machine. Uninstall says so.
- A refused install or reinstall changes nothing: every check runs before the first file is touched.
- If an empty `/etc/modules-load.d/nvidia-utils.conf` is left from the old driver package, the installer
  explains it and asks before moving it to the backup folder.
- **Auto-connect is on after a first install.** Plugging in the eGPU then loads its driver through the helper; with
  it off, the panel's Connect does. Add `--autoconnect off` before `install` in the command to start with it off,
  or switch it later with `pkexec /usr/local/bin/omarchy-egpu-admin autoconnect off` (or `on`; asks for your
  password), which the panel's Setup switch will run. Later installs keep whatever you chose. No reload is needed.
- The terminal Setup opens first asks GitHub whether the release the command points at is published, before
  any `sudo`. If it is not (HTTP 404, e.g. the tag `v0.1.1` was never pushed, or the repository is private) it
  says so, changes nothing and stops, instead of the command's own `curl: (22) ... 404`.
- While the repository is private, the checksum URL needs authentication: fetch it with
  `gh api -H 'Accept: application/vnd.github.raw' 'repos/Kalinewb/omarchy-egpu/contents/system/install.sh.sha256?ref=v0.1.1'`
  instead of `curl`.

## The panel's UI

The panel (Overview, Details, Setup, the eject sheet, the header) is built on the suite's shared UI kit,
[omarchy-ui](https://github.com/Kalinewb/omarchy-ui): one set of tokens, motion and controls, so every kalinewb
plugin looks and behaves the same. **External dependencies: none at run time.** `ui/` is vendored (copied,
never linked) from omarchy-ui with `dev/sync-ui.sh --from ../omarchy-ui --only ...`, and `ui/KIT` records the
kit's commit and a hash per file; `dev/check-ui.sh` fails if one was edited, so a fix goes to the kit and comes
back through a re-sync. Only the parts the panel uses are copied. The old private controls (`views/ui/`: `Action`,
`Link`, `Sentence`, `Spinner`, `Switch`) and the private palette in `common/Palette.js` are gone; `Palette.js`
keeps the glyphs, `look()` (the one state-to-look mapping the bar, the glance and the panels share) and `tone()`.

- **One theme.** Each shell makes one `UTheme` (`NotchPanel.qml` over the notch's `surfaceHost`, `Panel.qml`'s popup
  standalone, from Omarchy's own palette) and hands it down as `theme`. Under the notch every colour is a solid
  worked out from the colours the notch hands over; text is held to 4.5:1 and every mark to 3:1.
- **One of each control.** `UButton` (one primary per page, quiet buttons, a destructive verb with its object),
  `USwitch`, `USegmented` (the tabs), `URow`, `USection`, `UNotice` (info, warning, error: a glyph and a spoken word
  as well as a colour; a code only under Details), `URing` (something under way), `UConfirmSheet` (the one inline
  confirm: closing the apps that hold the eGPU), `UTip` (the foot line, one reserved line under the page), `UBack`
  (standalone only), `UClose`, `UEmpty`. Three text levels (primary, secondary, metadata) and a named spacing scale
  (`theme.sp.xs` to `xxl`).
- **One back, one close.** Under the notch the strip at the top centre is the one way back (see below), so the panel
  draws no back control there; the standalone popup draws the kit's `‹`. The one close is the `✕` at the top right of
  every page.
- **Keys** (all through the kit's `UKeys`, the one Esc handler). Esc closes, in order: a tip, a confirm that is asking
  (it cancels), Setup's Advanced, then one route back (Details and the eject sheet to the Overview, Setup to where it
  was opened from), then, with nowhere to go back to, the panel. Tab and Shift+Tab walk every control (the `✕`, the
  primary, the notice's link, the rows that open a page, Setup's Fix buttons); Enter or Space press the focused one;
  Left and Right on the tabs switch tab; Enter with nothing focused presses the page's one primary button. A Fix from
  the Overview opens Setup on its row, marks the row with an accent bar at its left edge (the selection, apart from the
  keyboard's focus ring) and leaves the keyboard on its Fix. In the standalone popup Up and Down still scroll.
- **Destructive.** Closing the apps that hold the eGPU is the one destructive action. Its button names what it closes
  (`Close vkcube`, `Close 2 apps`), is never the default, and asks first, inline: `Save your work first.` with Cancel
  and the verb. Enter on the question's Cancel (where the keyboard starts) closes nothing. Safe eject itself is not
  destructive: it checks, refuses while anything uses the eGPU, and never kills.
- **Reduced motion.** `OMARCHY_REDUCED_MOTION=1` in the environment turns reduced motion on; `NOTCH_REDUCED_MOTION=1`
  is an alias that the notch and the kit both read; a host may provide `reducedMotion` instead. (`OMARCHY_` is only a
  prefix: it is not an Omarchy variable, and this paragraph and the kit's README are its only definition.) When on:
  springs are off, loops stop and show their final frame (the ring is a steady half arc; the bar glyph stops pulsing
  and stays at full strength), fades stay.

### Changes since 0.1.0 (the UI migration; no engine, service, manifest or helper change)

The manifest stays at 0.1.0: the version is pinned in `system/` (the helper's and the installer's `VERSION`, their
checksums and `install.sh.sha256`), which a UI-only change does not touch, so a bump would break `dev/check-pins.sh`
and root's refusal to install. Bump them together at release.

- **Standalone Esc** was already back one step in 0.1.0 (`back()`), and still is; it now goes through the kit's `UKeys`.
  PanelKeyCatcher is gone from the popup (it took Tab, Enter and Space before a control could), so **Tab now walks the
  popup's controls instead of switching to the next bar panel**.
- The read-only auto-connect **switch is a value** (`Auto-connect`, `On · set by the installer`, or `Needs the system
  helper`); the long caption under it is gone.
- **Back and close.** The notch's `‹ Back` link (shown only without a strip) is the kit's chevron, and every page has the
  `✕`. In the notch the pages with a header (the tabs, a title) start **below the strip's zone** instead of splitting
  the tab row around it; the compact page is unchanged (headline left, glyph and `✕` right, the zone clear).
- **Words.** `Details ›`, `Open full panel` and `Advanced` are rows that open a page (a `›` or `▸`); `Close it` /
  `Close them` is `Close <app>` / `Close N apps` behind a confirm; the Overview's `Setup has found a problem` and the
  relogin lines are warning notices; an engine error is an error notice with its code under Details, and `Try again`
  where Setup could not be read. `Done`, `Cancel`, `Try again` are the three words and the one recovery.
- **Progress** is a ring (`URing`) with its words in place of a dimmed button; the pulsing glyph is a ring beside it in
  the glance. Both hold still under reduced motion.
- Sizes are the kit's: titles of 14 px, a body of 12 (notch) or 13 (standalone) at the default scale, 11 px footnotes and
  an 11 px floor for everything, in place of 10 px captions; "Safe to unplug" is a title, not a 26 px display line.
- New tips on the foot line (what a button does) and a Tab-reachable `Open Setup` / `Fix` / `Details` everywhere.

## In the notch

Under the notch the strip at the top centre is the one way back (and Esc its invisible alias): the panel draws no back control and answers the strip through `goBackInside()` (confirm, then Setup's Advanced, then the route, then the notch goes back to where it was opened from). The strip's 180 x 32 zone is kept clear of controls and text by the layout. The compact page keeps its first row in the gutters beside the zone, so headlines are a word or two (`No eGPU`, `In use`, `Ejected`, `Setup issue`) with the full sentence on the line under, and the glyph and the `✕` sit in the right gutter. The pages with a header (the tabs, a title, the `✕`) start below the zone, as the kit says for a header narrower than three zones. Without a notch strip (the standalone popup, an older notch) the header draws the kit's back chevron. `dev/g8-offscreen.sh` checks both, and runs the notch's `backZone` rule on every route and state.

License: MIT
