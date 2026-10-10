# omarchy-egpu — engine plan

Status: draft 1, 2026-10-09. Companion: `plan-gui.md` (the panel). Binding inputs:
`scope.md` Decisions 2–3, REVISION 2026-10-09 (external HDMI on the eGPU), the user's
troubleshooting facts (relayed 2026-10-09), REVISION 3 (modularity), and the user's
per-game Steam requirements (relayed 2026-10-09, §8). Decision 1 is superseded where
REVISION 2026-10-09 conflicts with it.

Nothing GPU-side has been verified live: the eGPU was unplugged throughout. Every
claim below about runtime behaviour with the card attached is either cited to a file
on this machine or marked **unverified**, with the gate that settles it.

Citation shorthand: `omarchy:` = `/usr/share/omarchy/`, `face:` =
`/home/user/Work/omarchy-face/`, `profiles:` = `/home/user/Work/omarchy-profiles/`,
`nvdoc:` = `/usr/share/doc/nvidia/README` (580.178.04), `aq:` = `/usr/include/aquamarine/backend/`.

---

## 1. What the engine is

A set of independent shell modules under the plugin's `bin/` and `lib/`, each usable
from a terminal, each emitting one JSON document on stdout and prose on stderr. The
panel (`plan-gui.md`) is a thin layer that runs them. This copies omarchy-profiles,
whose panel "is only the face. Every decision lives in bin/omarchy-profile"
(profiles:Panel.qml:14-17), and face's helper contract (face:system/omarchy-face-admin:11-14).

One root helper, installed from a terminal like face's system half, does the few things
that need root. Nothing else runs as root.

### 1.1 Exit-code contract (all engine verbs and the root helper)

| exit | meaning |
|---|---|
| 0 | ok, JSON result on stdout |
| 1 | refused or failed, stdout is `{"error":"<code>", ...}` |
| 3 | busy (another engine job holds the lock) |
| 126/127 | from pkexec: the user declined, or the helper is not installed |

Same as face:system/omarchy-face-admin:11-14.

**Error codes.** These are the full set. plan-gui.md maps each to a sentence.

| module | codes |
|---|---|
| device | `not_connected`, `no_pci_device`, `modules_failed`, `smi_hung`, `holders_present`, `remove_timeout`, `helper_missing` |
| display | `hdmi_still_active`, `unsafe_name` |
| any backend call | `backend_stub` |
| steam | `steam_not_found`, `account_not_found`, `steam_running`, `game_running`, `steam_close_timeout`, `vdf_parse_failed`, `vdf_check_failed`, `vdf_changed_underneath`, `token_modified`, `manual_offload`, `backup_failed` |

`helper_missing` is reported when `/usr/local/bin/omarchy-egpu-admin` is absent or its
`version` differs from the plugin's. The check happens before pkexec is called.

---

## 2. Open items, resolved or flagged

### O1. Does Hyprland/aquamarine pick up a hot-added GPU and its HDMI output? How is the primary pinned?

**Finding (static, from the installed aquamarine 0.15.0 and Hyprland 0.56.2):**

- Aquamarine has a GPU hot-add path. `CBackend::onNewGpu(std::string path)` is
  declared "called when a new DRM card is hotplugged" (aq:Backend.hpp:146-147), and
  `CSession` exposes an `addDrmCard` signal carrying the card path (aq:Session.hpp:226-233).
  `strings` of `/usr/lib/libaquamarine.so.0.15.0` contains `DRM Backend failed for device {}`
  and `Couldn't start DRM Backend for device {}`, consistent with a per-device start
  on hot-add, and the exported `CDRMBackend::fromGpu(path, backend, primary)` takes the
  existing primary as an argument, so a hot-added card is opened as a secondary.
- Removal is announced per device: `CSessionDevice` has `events.change` and
  `events.remove` (aq:Session.hpp:52-55), and the library logs
  `udev: DRM device {} removed`. What the DRM backend does with its open fd on that
  event is **unverified**; no string in the library says it tears the backend down.
- `AQ_DRM_DEVICES` is read when the backend starts (`drm: Explicit device list {}`,
  `drm: Explicit device {} not found` in the library strings). Whether `onNewGpu`
  filters a hot-added card against that list is **unverified**.

**Design consequence.** The primary is fixed at session start and a hot-added card
can only ever be secondary, so ordering only has to be right at login:

- eGPU absent at login: aquamarine opens the iGPU only. Pinning still matters for a
  login with the eGPU attached, which must also put the iGPU first.
- `AQ_DRM_DEVICES` lists the iGPU first, then the eGPU only if its node exists when
  the config is parsed (computed in Lua, §7.2), so a missing eGPU never puts a dead
  path in the list.
- `AQ_DRM_DEVICES` is colon-separated. `/dev/dri/by-path/pci-0000:00:02.0-card`
  (present on this machine) contains colons, so it **cannot** be put in the list
  directly. Hyprland's Multi-GPU wiki page says the same and recommends udev
  symlinks (not available offline, so this is **unverified here**). The plugin
  therefore installs a udev rule (§10.3) creating colon-free links
  `/dev/dri/omarchy-egpu-primary` and `/dev/dri/omarchy-egpu-external`. The
  rule identifies the primary by its by-path PCI address and the eGPU by
  "display class behind a removable port". It never uses `cardN`. The Health view
  shows both the by-path name and the link (REVISION: "stable by-path symlinks, not
  cardN"). **Doubt:** the scope asks for by-path names in the variable itself. That
  cannot work because of the colons, so the links are derived *from* by-path.
- A `mutter-device-preferred-primary`-style udev tag has no effect: nothing in
  aquamarine's strings reads such a tag.

**If hot-add does not work (gate E1 decides): session-restart fallback.**

- Only external HDMI depends on the compositor opening the card. PRIME offload of
  apps to the laptop panel (REVISION (a)) needs no compositor involvement at all, so
  it works with or without hot-add.
- Fallback: after Connect, if the eGPU's connectors are not in
  `hyprctl monitors all -j` within 5 s while sysfs shows a connected connector on the
  eGPU card, status reports `display.needs_relogin: true`. The panel offers "Log out
  to use the HDMI monitor", which runs `omarchy-system-logout` (it ends the session
  with `uwsm stop`, omarchy:bin/omarchy-system-logout:7), only after confirmation.
  It never restarts on its own.
- How often: once each time the eGPU is plugged in while a session is running and an
  external monitor is wanted. Never when the eGPU is attached before login. If gate E5
  shows that Hyprland keeps the removed card's fd (O2), it is also needed once before
  each re-plug in the same session.

### O2. Unload the modules, or PCI remove + unbind?

**Answer: PCI remove first, then unload if the module refcount allows. A plain module
unload is not a usable eject on its own.**

- Under REVISION 2026-10-09 the compositor deliberately opens the NVIDIA DRM card for
  HDMI scanout. While any process holds `/dev/dri/cardN` or `/dev/nvidia*`, the
  modules' refcount is non-zero and `modprobe -r` fails. The compositor cannot be
  asked to close a card short of ending the session, so "unload while the session
  runs" is impossible by construction once Hyprland has opened the card.
- PCI `remove` runs the driver's remove callback, which unbinds the device and
  unregisters its DRM node. That is the step that makes the hardware safe to unplug.
  The modules can then be unloaded only if nothing still references them.
- NVIDIA does not guarantee stability when an eGPU in use is unplugged
  (nvdoc:7141-7144). The engine therefore removes the device only after holders have
  closed (§6.3). **Unverified:** whether `remove` blocks while a client still holds
  the device, and whether aquamarine drops its fd on the DRM remove uevent. Gate E5
  measures both. The helper runs the sysfs write in a child with a timeout, so a
  hang is reported as `remove_timeout` and never freezes the engine.
- If the modules stay loaded with no device after eject (Hyprland still holds a
  reference), status reports `modules.held_after_eject: true`. The panel then asks
  for a logout before the next plug-in. Loading or keeping nvidia with no card
  present is exactly the condition the user saw hard freezes with (binding fact 1),
  so re-plugging into a held, deviceless module stack is not offered as normal.

### O3. Hotplug when nvidia was never loaded at boot. Is `modeset=1` required?

- `nvidia` autoloads when the PCI device appears: its module aliases include
  `pci:v000010DEd*sv*sd*bc03sc02i00*` (from `modinfo -F alias nvidia`). The stock
  udev rule then runs `nvidia-modprobe` on add/bind to create the device nodes and
  load `nvidia-uvm` (`/usr/lib/udev/rules.d/60-nvidia.rules:6-9`). Both happen
  after the device exists, which satisfies binding fact 3 ("only on connect, after
  the PCI device exists").
- Nothing loads `nvidia_drm` on hotplug. The plugin's udev rule does
  (`modprobe nvidia_drm`, §10.3), gated by the `connect.auto` config key; otherwise
  the Connect button loads it through the helper.
- `modeset=1`: PRIME render offload works without KMS. Scanout of the eGPU's HDMI
  port by Hyprland needs it (nvdoc:7097-7099, "Atomic Modeset … Wayland"). On this
  580.178.04 build it is already the default (`modinfo -F parm nvidia_drm`: "modeset
  … 1 = enable (default)"), and `/etc/modprobe.d/nvidia.conf:4` sets it explicitly.
  Health checks the live value in `/sys/module/nvidia_drm/parameters/modeset`.
- `fbdev`: since the 570 series it defaults on when `modeset=1` is set (nvdoc:262-263,
  nvdoc:2015-2017; `modinfo` agrees: "fbdev … 1 = enable (default)"). REVISION
  2026-10-09 lists fbdev as required, so the plan keeps the default and Health shows it
  as information, not as a Fix. **Doubt:** KMS scanout under a Wayland compositor does
  not need fbdev. fbdev adds an fbcon client on the eGPU, and nvidia-modeset puts the
  console on hot-plugged displays (nvdoc:2493-2499). That is one more client to release
  at eject. Gate E5 records whether `fbdev=1` blocks a clean remove. If it does, the
  user should revisit this decision; the plan does not override it.
- Boot-time loading must not happen (binding fact 1). On this machine
  `/usr/lib/modules-load.d/nvidia-580xx-utils.conf:1` is `nvidia-uvm`, and
  `/etc/modules-load.d/nvidia-utils.conf` is an empty file named after the **old**
  package. So the mask no longer applies, and this boot's journal shows
  `systemd-modules-load: Failed to insert module 'nvidia_uvm': No such device`. It
  failed only because the eGPU was absent; with the eGPU attached at boot it would
  have loaded. Health check `boot.modules_load_mask` (§9) detects this and the
  system-half install fixes it.

### O4. Where plugin scripts live, and how root helpers get installed

- `omarchy plugin add <git-url>` clones the repo into `~/.config/omarchy/plugins/<id>/`
  (omarchy:shell/README.md:104-106). The installer "never runs plugin code, install
  hooks, or sudo" (omarchy:shell/README.md:126-129). So plugin `bin/` scripts run from
  that checkout, as profiles does (profiles:Panel.qml:40), and **nothing root-owned can
  be installed by `omarchy plugin add`.**
- Precedent for the root half is face. The panel copies a command for the owner to run
  in a terminal (face:SetupView.qml:403-411). The command copies `system/install.sh`
  into a root-only place, checks it against a checksum fetched from the release tag,
  and runs it with the plugin dir and account (face:system/install.sh:9-21).
  install.sh then snapshots every system file into a root-owned `/run` directory,
  checks each against SHA-256 pins in its own text, and installs only from the
  snapshot (face:system/install.sh:27-33, 117-178). It refuses a group-writable
  `/usr/local/bin` (face:system/install.sh:180-187) and refuses a caller whose
  `PKEXEC_UID`/`SUDO_UID` is not the owning account (face:system/install.sh:66-74).
  omarchy-egpu copies this mechanism (§10).
- Every write under `~/.config/omarchy/plugins/` reloads plugins, because the
  directory is watched recursively (omarchy:shell/services/PluginRegistry.qml:663-679).
  So all mutable state lives outside it, in the config file (§3) and in
  `${XDG_STATE_HOME:-~/.local/state}/omarchy-egpu/` (profiles:Panel.qml:19-25 gives the
  same reason).

### O5. Suspend/resume with GSP off and PreserveVideoMemoryAllocations=1 (binding fact 4)

- This machine sets `NVreg_EnableGpuFirmware=0`, `NVreg_DynamicPowerManagement=0x00`
  and `NVreg_PreserveVideoMemoryAllocations=1` (`/etc/modprobe.d/nvidia.conf:1-3`). The
  package adds `NVreg_TemporaryFilePath=/var/tmp` (`/usr/lib/modprobe.d/nvidia-sleep.conf:1`).
  `nvidia-suspend`, `nvidia-resume` and `nvidia-hibernate` are enabled (systemctl,
  this machine).
- `nvidia-sleep.sh` exits 0 when `/proc/driver/nvidia/suspend` is absent, i.e. when the
  module is not loaded (`/usr/bin/nvidia-sleep.sh:3-5`). Otherwise it switches to VT 63
  and writes `suspend` into that file (`:38-45`).
- Consequences for the plugin:
  1. **After a clean eject with modules unloaded**, the services are no-ops. That is
     the safe state for sleeping.
  2. **eGPU attached during suspend:** VRAM contents are saved to `/var/tmp`. Hibernate
     needs disk for the used VRAM (up to 12 GB on the 4070 SUPER). Unplugging while
     asleep means resume calls into a driver whose device is gone. Omarchy's own
     sleep hook documents an NVIDIA resume failing with `-EIO` when the dGPU is
     unavailable (omarchy:default/systemd/system-sleep/force-igpu:45-47). The plugin
     takes a `delay` sleep inhibitor while the eGPU is bound. Before sleep it shows
     "eGPU attached — eject first if you will unplug it while asleep". It does not eject
     automatically, because the user may want to resume with it attached.
  3. **Ejected but modules held (O2):** `/proc/driver/nvidia/suspend` exists with no
     device. **Unverified** whether writing `suspend` then succeeds. Gate E8 tests it.
  4. `DynamicPowerManagement=0x00` (no runtime D3) is fine for an eGPU whose power the
     enclosure controls. Health reports it and does not change it.

---

## 3. Configuration (REVISION 3)

One file: `${XDG_CONFIG_HOME:-~/.config}/omarchy-egpu/config.json`. It is absent on a
fresh machine. Every key has an auto-detected default. `omarchy-egpu config show`
prints the effective config with an `origin` per key (`default` | `detected` | `file`).
The engine writes only keys the user changed, through `config set <key> <json>`, using
an atomic write (temp file plus rename). The file is outside the watched plugins
directory.

| key | default | notes |
|---|---|---|
| `backend` | `"auto"` | auto = the backend whose `detect` matches a removable display device |
| `device.match` | `"auto"` | or `{"vendor":"0x10de","device":"0x2783"}` to pin one card |
| `primary.bypath` | detected | by-path name of the boot_vga display device |
| `connect.auto` | `true` | udev loads the KMS module on plug (§10.3) |
| `connect.timeout_s` | `30` | |
| `eject.close_timeout_s` | `10` | SIGTERM grace before asking about SIGKILL |
| `display.policy` | `"extend"` | `extend` \| `mirror` \| `off`, applied on hot-add |
| `display.position` | `"right"` | relative to the primary panel |
| `display.vrr` | `false` | see §11 |
| `display.mgpu_no_explicit` | `false` | sets `AQ_MGPU_NO_EXPLICIT` (§11), relogin |
| `steam.roots` | detected | native and Flatpak installs (§8.1) |
| `steam.account` | detected | `MostRecent` login (§8.1) |
| `steam.on_unplug` | `"leave"` | `leave` \| `remove` (§8.6) |
| `steam.relaunch` | `true` | reopen Steam after a close-and-apply (§8.4) |
| `notify` | `true` | plug/unplug notifications |
| `profile` | `"auto"` | enclosure profile id (§4.3) |
| `gui.hide_when_absent` | `false` | bar indicator hidden while no eGPU was ever seen this session (plan-gui.md §4) |
| `gui.recent_commands` | `[]` | last 8 commands launched via "Run on eGPU" (plan-gui.md §5.1) |

No user name, PCI address or path is hardcoded anywhere in code (REVISION 3).
Machine-specific values are detected at run time or come from this file.

---

## 4. Repo layout and modules

```
omarchy-egpu/
  manifest.json          id kalinewb.egpu, kinds [bar-widget, service], surface contract 1
  LICENSE  README.md  preview.png
  Panel.qml  Service.qml  NotchIntegration.qml  views/  common/   (plan-gui.md)
  bin/
    omarchy-egpu         dispatcher: omarchy-egpu <module> <verb> [args]
    egpu-run             offload wrapper (§7.4)
  lib/
    common.sh            json out, lock, paths (all roots overridable), config
    status.sh            module: status, watch
    device.sh            module: connect, eject, holders
    display.sh           module: Hyprland monitors, toggle file
    steam/               module (§8)
      steam.sh           verbs, Steam process control, pending queue
      vdf.py             KeyValues parse-to-locate / splice editor (python3 stdlib)
      tools.json         non-game appids and name prefixes to hide
    health.sh            module: checks, fix
    backends/
      nvidia.sh          v1, implemented
      amdgpu.sh          documented stub
      intel.sh           documented stub
  profiles/
    generic.json
    minisforum-deg2.json
  system/                root half, installed from a terminal (§10)
    install.sh  install.sh.sha256
    omarchy-egpu-admin   root helper
    no.kalinewb.egpu.policy
    61-omarchy-egpu.rules
    omarchy-egpu-modules.conf   modules-load mask template (§9)
  tests/
    run.sh  lib.sh  fakes/bin/{boltctl,hyprctl,nvidia-smi,pkexec,udevadm,lsinitcpio,vulkaninfo,steam,flatpak}
    schema/status-1.json   JSON Schema of the §5 document
    fixtures/<scenario>/{sys,dev,proc,bolt.json,hypr/*.json,steam/}
  dev/
    lint.sh  check-pins.sh  update-pins.sh  bin/ (stub engine for the GUI, plan-gui.md §9)
  dev-sync.sh            rsync into the plugin dir, as profiles:dev-sync.sh:14-23
```

Each module can be sourced alone with `common.sh` and has its own verbs. The CLI is
`omarchy-egpu status`, `omarchy-egpu device connect`,
`omarchy-egpu display off`, `omarchy-egpu steam set 1234 on`,
`omarchy-egpu health`, `omarchy-egpu health fix <id>`, `omarchy-egpu config show`.
`steam` and `display` work without any eGPU attached. `steam` works without Hyprland.

### 4.1 Overridable roots (the test seam)

`common.sh` reads every system location through a variable:
`EGPU_SYS=/sys`, `EGPU_DEV=/dev`, `EGPU_PROC=/proc`, `EGPU_ETC=/etc`,
`EGPU_USRLIB=/usr/lib`, `EGPU_RUN=$XDG_RUNTIME_DIR/omarchy-egpu`. External tools are
called by bare name, so tests put `tests/fakes/bin` first on `PATH`. Omarchy already
uses this pattern for its GPU detection (`OMARCHY_PCI_DEVICES_PATH`,
omarchy:bin/omarchy-hw-nvidia:7). The root helper honours none of these variables
(§10.1).

### 4.2 Backend interface (REVISION 3)

A backend is a sourced shell file defining these functions. `status`, `device` and
`health` call only these, never vendor names.

| function | contract |
|---|---|
| `be_name` | prints `nvidia` |
| `be_detect <bdf>` | exit 0 if this backend drives that PCI function (vendor id, class 0x03) |
| `be_kms_modules` | modules to load for KMS, in load order. Must be a subset of the helper allowlist (§10.1) |
| `be_unload_modules` | unload order, or empty when unloading is unsupported |
| `be_dev_nodes <bdf>` | device nodes whose holders block eject (beyond the DRM card/render node) |
| `be_verify <bdf>` | JSON `{ok, driver, version, name, temp_c, util_pct, mem_used_mb, procs[]}` with a hard timeout |
| `be_offload_env <bdf>` | `KEY=VALUE` lines for egpu-run and Steam |
| `be_steam_extras` | optional per-game `KEY=VALUE` opt-ins with labels (nvidia: `PROTON_ENABLE_NVAPI=1` "NVAPI (DLSS)"), §8.7 |
| `be_health` | extra check rows in the §9 format |

- **nvidia (v1):** vendor `0x10de`. KMS modules: `nvidia nvidia_modeset nvidia_drm
  nvidia_uvm`. Unload order: the reverse. Nodes: `/dev/nvidia[0-9]*`,
  `/dev/nvidiactl`, `/dev/nvidia-uvm*`, `/dev/nvidia-modeset`.
  - `be_verify` runs `nvidia-smi --query-gpu=... --format=csv,noheader -i <bdf>` under
    `timeout 10`. If the child is in state `D` when the timeout fires
    (`/proc/<pid>/stat` field 3), it reports `{"error":"smi_hung"}` and does not kill
    or retry, because that is the open-module/GSP `rmapiLockAcquire` hang from binding
    fact 1. Vulkan is checked with `vulkaninfo --summary` under the offload env when
    `vulkan-tools` is installed. It is not installed on this machine, so the check is
    reported `skipped` with a Fix that installs it.
  - Offload env: exactly the user's known-working set,
    `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only`
    (scope Hardware; nvdoc:6945-6984). `__NV_PRIME_RENDER_OFFLOAD_PROVIDER` is not
    needed with one NVIDIA GPU.
  - Health rows: modprobe options, modeset/fbdev, driver flavour (§9).
- **amdgpu (stub):** documents the contract it would meet. Detect: vendor `0x1002`.
  Offload env: `DRI_PRIME=pci-<domain>_<bus>_<dev>_<fn>`. KMS module: `amdgpu`.
  **Unload unsupported**, because `amdgpu` also drives AMD iGPUs and unloading it
  could take the laptop panel. Every function returns `{"error":"backend_stub"}`
  except `be_detect` and `be_offload_env`. Status then shows "detected, not supported
  yet".
- **intel (stub):** discrete Arc. Vendor `0x8086` and not the primary. `DRI_PRIME` as
  above. Unload unsupported, because `xe`/`i915` drive the iGPU.

### 4.3 Enclosure profiles (REVISION 3)

`profiles/*.json`, matched against `boltctl info` vendor and name. Matching uses
exact strings only, never code. `generic.json` applies when nothing matches.

```json
{ "id": "minisforum-deg2",
  "match": { "bolt_vendor": "<from gate E0>", "bolt_name": "TBGAA" },
  "hints": [
    { "when": "authorized_no_pci", "text": "Check the dock's mode switch is set to TBT, not OCuLink." } ],
  "log_noise": [
    { "match": "JMicron", "subsystem": "scsi",
      "why": "Empty M.2 slot: its USB bridge logs SCSI errors. Harmless." } ],
  "link": { "note": "2.5 GT/s x4 right after connect is normal for this enclosure." },
  "kernel_params_optional": [ "pcie_ports=native", "pci=assign-busses,hpbussize=0x33,realloc,hpmmiosize=128M,hpmmioprefsize=16G" ]
}
```

- The DEG2 name "TBGAA" comes from scope.md. Its bolt vendor string is **unknown**
  until E0 records `boltctl info`.
- `log_noise` is used only by the diagnostics bundle (§9.3). Matching lines are
  labelled "known harmless (profile)". They are not errors.
- `kernel_params_optional` are shown in Health as an optional diagnostic with the
  note "suggested by the Arch wiki External GPU page, not confirmed necessary". They
  are never a default and never a Fix (binding fact 3).

---

## 5. Status model (`omarchy-egpu status --json`)

One JSON document, the same for every consumer: the standalone panel, the notch
integration (REVISION 4), and scripts. Field names are the contract with
`plan-gui.md`. `--json` is the default; `--human` prints a short text summary for
terminals.

```json
{ "schema": 1, "seq": 42, "written_at": 1791590400123,
  "summary": { "state": "absent|connecting|ready|in_use|ejecting|safe_to_unplug|attention|error",
               "line": "eGPU ready · HDMI on", "needs_action": false },
  "phase": "absent|plugged|authorized|bound|ready|ejecting|ejected|error",
  "bolt": { "present": true, "domain": true, "uuid": "...", "name": "TBGAA", "vendor": "...",
            "status": "authorized", "policy": "iommu", "stored": true, "profile": "minisforum-deg2" },
  "pci": { "bdf": "0000:xx:00.0", "functions": ["0000:xx:00.0","0000:xx:00.1"],
           "vendor": "0x10de", "device": "0x2783", "removable": true,
           "link": { "speed": "2.5 GT/s PCIe", "width": "4", "max_speed": "...", "max_width": "..." } },
  "backend": { "name": "nvidia", "supported": true },
  "driver": { "bound": "nvidia", "modules": {"nvidia":true,"nvidia_drm":true,"nvidia_uvm":true,"nvidia_modeset":true},
              "modeset": true, "fbdev": true },
  "gpu": { "ok": true, "name": "...", "temp_c": 41, "util_pct": 3, "mem_used_mb": 500,
           "procs": [ {"pid":1,"name":"...","mem_mb":1} ] },
  "drm": { "card_bypath": "pci-...-card", "link": "/dev/dri/omarchy-egpu-external",
           "compositor_has_card": true },
  "display": { "monitors": [ /* §7.3 */ ], "needs_relogin": false },
  "modules": { "held_after_eject": false },
  "steam": { "running": false },
  "hints": [ {"id":"authorized_no_pci","text":"..."} ],
  "health_summary": { "errors": 0, "warnings": 1 },
  "last_event": { "seq": 41, "type": "plugged", "at": 1791590399000 },
  "recent_events": [ { "seq": 40, "type": "unplugged", "at": 1791590398900 }, { "seq": 41, "type": "plugged", "at": 1791590399000 } ] }
```

- `phase` comes only from sysfs and bolt, never from what the engine last did, so a
  terminal action and a panel action see the same truth. The one exception is
  `ejecting`, which comes from the eject job's lock in `$EGPU_RUN`.
- `summary` is computed by the engine so that no shell derives state on its own
  (REVISION 4: "neither shell may fork behaviour"):
  - `connecting`: `plugged`/`authorized`/`bound`.
  - `ready`: `ready`, with no eGPU process and no eGPU monitor enabled.
  - `in_use`: `ready`, with `gpu.procs` non-empty or an eGPU monitor enabled.
  - `safe_to_unplug`: `ejected`.
  - `attention`: `needs_relogin`, `held_after_eject`, or health errors > 0 while
    present.
  - `error`: `phase` = `error`.
  - `line` is the one-line text both shells show verbatim.

- `pci.link` is informational. 2.5 GT/s x4 is shown as is, never as an error
  (binding fact 3), from `current_link_speed`/`current_link_width` (these attributes
  exist on this machine's PCI devices).
- `drm.compositor_has_card`: whether a `Hyprland` process owned by the user has the
  eGPU card node open, read from `/proc/<pid>/fd`.

### 5.1 The machine-readable status contract (REVISION 4)

- **`omarchy-egpu status --json`**: one document, computed fresh. This is the
  fallback for any consumer.
- **`omarchy-egpu status watch`**: a JSON-lines stream with two record types:
  - `{"type":"status", ...the full document...}` on every change, debounced 300 ms.
  - `{"type":"event","seq":n,"event":"<name>","at":ms,"detail":{...}}` at the
    moment something happens. Events: `plugged`, `authorized`, `ready`,
    `connect_failed`, `monitor_added`, `monitor_removed`, `eject_started`,
    `eject_ready` (safe to unplug), `eject_failed`, `unplugged`, `yanked`
    (unplugged while `ready`), `relogin_needed`, `steam_applied`, `games_stale`.
  - **Inputs:**
    - `udevadm monitor --udev -s pci -s drm -s thunderbolt`
    - `boltctl monitor`
    - Hyprland's event socket
      `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock`, the same
      socket as omarchy:bin/omarchy-hyprland-monitor-watch:5.
- **Status file `$XDG_RUNTIME_DIR/omarchy-egpu/status.json`**:
  - The running watcher writes it after every `status` record, atomically (temp
    file plus rename), together with `last_event`.
  - **Added in E9 (G8), additive:** `recent_events`, the watcher's last 8 events
    in seq order (same shape as `last_event`). One recompute can raise several
    events (a yank is `monitor_removed`, `yanked`, `unplugged`; a remembered
    enclosure is `plugged` and `authorized` within one debounce), and a file
    reader sees one document per recompute, so `last_event` alone loses all but
    the last. And `bolt.domain`: whether the machine has a Thunderbolt/USB4 domain
    at all, which `bolt.daemon` cannot say (boltd down and no controller both read
    `false`). The notch integration declines on it (plan-gui.md §7.2).
  - It lets a consumer read state without spawning a process or holding a stream.
    The notch integration does exactly that, with a `FileView` (plan-gui.md §7.2).
  - Treat the file as stale when `written_at` is older than 10 s while the watcher
    should be running. A consumer then runs `status --json` once and reports
    "watcher not running". This mirrors the notch's own heartbeat rule
    (`/home/user/Work/omarchy-notch/SURFACE-HOSTING.md:344-345`).
- **One watcher per session.** `status watch` takes a flock on
  `$EGPU_RUN/watch.lock`. A second instance exits 3, so the panel's Service and any
  other caller cannot both run one.
- **Versioning**, the same rule the notch uses for its contract
  (SURFACE-HOSTING.md:416-421):
  - Additive fields and new event names do not bump `schema`.
  - A rename, a removal, or a changed meaning bumps it.
  - Consumers refuse a `schema` newer than they know and show "update the plugin".

- **Refresh.** The watcher rewrites the file at least every 5 s as a heartbeat, so
  `written_at` stays fresh. While `ready` it refreshes the `gpu` block every 2 s
  through `be_verify`, under its hang guard.
- **Without a watcher**, `status --json` calls `be_verify` itself. The hang guard
  bounds that to about 10 s.

---

## 6. Connect and eject (`lib/device.sh`)

### 6.1 Connect (`omarchy-egpu device connect`)

1. Lock `$EGPU_RUN/lock` (flock). If it is held, exit 3.
2. **bolt:** if the device is connected and not authorized, run
   `boltctl authorize <uuid>`. boltd's own polkit action covers this
   (`org.freedesktop.bolt.authorize`, auth_admin_keep,
   `/usr/share/polkit-1/actions/org.freedesktop.bolt.policy:29-37`). With policy
   `iommu`/`auto` and `stored`, boltd authorizes by itself (boltctl(1), "enroll
   --policy auto"), so this step is normally a no-op. An unenrolled device gets
   `boltctl enroll --policy auto` only after the user confirms in the panel.
3. **PCI:** wait up to `connect.timeout_s` for a display-class function that one
   backend's `be_detect` accepts and that is removable (§10.1 rule). On timeout, report
   `{"error":"no_pci_device"}` plus the profile hints (DEG2: "mode switch must be TBT").
4. **Driver:** wait for `driver` → the backend driver. Udev autoloads it (O3).
5. **KMS:** if `be_kms_modules` are not all loaded, run
   `pkexec omarchy-egpu-admin load <backend>` (§10.1). The udev rule usually did this
   already.
6. **Verify:** `be_verify` (nvidia-smi with a hang guard, then Vulkan).
7. **Compositor:** wait up to 5 s for `drm.compositor_has_card`, then apply
   `display.policy` (§7.3). If the card is not opened but a connector on it is
   connected, set `display.needs_relogin` (O1 fallback).
8. Notify "eGPU ready" and print status.

### 6.2 Holders (`omarchy-egpu device holders`)

- Walks `/proc/*/fd` for links to `be_dev_nodes`, the eGPU DRM card and the eGPU
  render node. As the user, only the user's own processes are visible. Holders owned
  by other users (root daemons such as `nvidia-persistenced`, disabled on this
  machine) are listed by the helper's read-only `holders` verb.
- The output marks the compositor separately (`"role":"compositor"`), because it is
  expected to hold the card and cannot be closed.

### 6.3 Safe eject (`omarchy-egpu device eject [--close]`)

Order (REVISION 2026-10-09: display first):

1. Lock. Status must be `bound` or `ready`, or eject exits 0 with nothing to do.
2. **Display off first.** For each monitor on the eGPU (§7.3):
   - Move every workspace on it to the primary panel.
   - Disable it with `hyprctl eval 'hl.monitor({ output = "<name>", disabled = true })'`,
     the same form as omarchy:bin/omarchy-hyprland-monitor-clamshell:173,237.
   - Record it in the toggle file so a reload does not bring it back.
   - Wait until `hyprctl monitors all -j` shows `disabled: true`, with a 3 s timeout
     reported as `{"error":"hdmi_still_active"}`.
3. **Holders.** Without `--close`, any non-compositor holder returns
   `{"error":"holders_present","holders":[...]}`. With `--close` (the panel asks first),
   send SIGTERM and wait `eject.close_timeout_s`. If holders survive, return
   `holders_present` again and let the user decide. The engine never sends SIGKILL on
   its own.
4. **Steam warning.** If Steam is running and owns an eGPU process, it is listed as a
   holder like any other.
5. **Remove.** Run `pkexec omarchy-egpu-admin remove <bdf>`. The helper removes every
   function of the slot (GPU and HDMI audio). On `remove_timeout`, tell the user
   **not** to unplug, and treat logging out as the recovery.
6. **Settle.** Wait for the card node and by-path link to disappear. Then record
   whether the backend modules' refcounts reached 0
   (`/sys/module/<m>/refcnt`).
7. **Unload** if they are all 0: `pkexec omarchy-egpu-admin unload <backend>`.
   Otherwise set `modules.held_after_eject` (O2).
8. Notify "Safe to unplug". Phase becomes `ejected`.

**Crash risk of yanking (documented to the user in the panel and README).**
- NVIDIA does not guarantee stability when an eGPU in use is unplugged
  (nvdoc:7141-7144).
- With an HDMI monitor active, the compositor has scanout buffers and pending page
  flips on that device. Aquamarine's removal handling is unverified (O1), so the
  worst case is a compositor crash, which ends the session and every app in it.
- On this hardware the user has already seen hard freezes involving nvidia module
  state (binding fact 1).
- So: the bar indicator shows "eject before unplugging" whenever the eGPU is bound,
  and the unplug notification says what was lost if it was yanked.

### 6.4 Ejected but not unplugged

`omarchy-egpu device rescan` runs `pkexec omarchy-egpu-admin rescan`, i.e.
`/sys/bus/pci/rescan`, so the user can reuse the device without re-plugging. It is
refused while `modules.held_after_eject` is set, because of the freeze risk (O2).

---

## 7. Display and egpu-run

### 7.1 Which monitors belong to the eGPU

- `hyprctl monitors all -j` has no GPU field (keys checked on this machine:
  `name, description, make, model, serial, disabled, activeWorkspace, mirrorOf, x, y, …`).
- Connector names can collide: the iGPU already has `card0-HDMI-A-1`
  (`/sys/class/drm` on this machine), so the eGPU's HDMI may also be named
  `HDMI-A-1`. How Hyprland disambiguates is **unverified** (gate E4).
- The engine therefore matches by EDID. It reads `/sys/class/drm/<eGPUcard>-*/edid`,
  parses manufacturer, product and serial, and matches them to `make/model/serial` in
  hyprctl. Persistent rules are keyed by `desc:<description>`, which this user's
  `hyprmoncfg-monitors.lua:4` already uses.
- Names and descriptions written into Lua or `hyprctl eval` must match
  `^[A-Za-z0-9 ._()/+-]+$`. Otherwise the result is `{"error":"unsafe_name"}`. The
  clamshell script refuses in the same way, for the same injection reason
  (omarchy:bin/omarchy-hyprland-monitor-clamshell:14-20).

### 7.2 The toggle file (the only Hyprland config the plugin writes)

`${XDG_STATE_HOME:-~/.local/state}/omarchy/toggles/hypr/zz-omarchy-egpu.lua`.

- Omarchy loads every `*.lua` there, sorted, after the user's own config
  (omarchy:default/hypr/toggles.lua:4-17, omarchy:default/hypr/require_all.lua:16-33,
  `~/.config/hypr/hyprland.lua:19-26`). The `zz-` prefix sorts it last, like the
  existing `zz-local-touchpads.lua`. The user's own files are never edited.
- Contents, generated from config, with names validated:
  1. `AQ_DRM_DEVICES`: `/dev/dri/omarchy-egpu-primary`, plus
     `:/dev/dri/omarchy-egpu-external` only if that link exists (Lua `io.open` test).
     **Unverified:** that `hl.env` in the config is applied before aquamarine starts.
     Hyprland's wiki documents `env = AQ_DRM_DEVICES` in the config. Gate E1 checks
     the Hyprland log for `drm: Explicit device list`. Fallback: uwsm's environment
     file for Hyprland (Omarchy sessions run under uwsm,
     omarchy:bin/omarchy-system-logout:7). That is a file in `~/.config`, so it needs
     a visible Fix with a backup (REVISION 3).
  2. **Session-env sanitising.** Omarchy's `nvidia.lua` runs at every config parse.
     If any NVIDIA display device is present then, it sets session-wide
     `__GLX_VENDOR_LIBRARY_NAME=nvidia`, `NVD_BACKEND=direct` and
     `LIBVA_DRIVER_NAME=nvidia` (omarchy:default/hypr/nvidia.lua:10-19). For a 4070
     SUPER the GSP branch is taken, because device id ≥ 0x1e00
     (omarchy:bin/omarchy-hw-nvidia-gsp:14-18). That happens with the eGPU attached at
     login, or on any `hyprctl reload` while it is attached. Every later app would
     then go to the NVIDIA GLX vendor and VA-API driver even though the display is on
     the iGPU, which is a likely glitch source. The toggle file, loaded after it,
     overrides these with the primary backend's values: on Intel
     `__GLX_VENDOR_LIBRARY_NAME=mesa`, `LIBVA_DRIVER_NAME=iHD` (`intel-media-driver`
     is installed here). These are detected per primary vendor, not hardcoded.
     Whether `hl.env` can unset a variable is unknown, so explicit values are used.
  3. Monitor rules for eGPU monitors: `hl.monitor({ output = "desc:…", … })` with
     the chosen mode, position or mirror, `vrr`, or `disabled = true`.
- After writing, the engine runs `hyprctl reload` then `hyprctl configerrors`, the
  validation step from omarchy:default/agents/skills/omarchy/hyprland.md:22-24. If
  config errors appear, the previous file is restored.

### 7.3 Display verbs (`lib/display.sh`)

- `display list`: monitors on the eGPU, each with
  `{name, description, connector, enabled, mode, modes[], position, mirror_of, workspaces[]}`.
  Workspaces come from `hyprctl workspaces -j`, matched on monitor.
- `display enable|disable <desc>`: applied live through `hyprctl eval`, then persisted
  in the toggle file.
- `display set <desc> <json>`: `{mode, position:"left|right|above|below|x,y", scale, mirror:bool, vrr:bool}`.
  - Position is computed from the primary's logical size.
  - Mirror uses `mirror = "<primary name>"`, as
    omarchy:bin/omarchy-hyprland-monitor-internal-mirror:37 does.
- `display off`: the quick kill switch (REVISION: "flip the monitor off quickly").
  - It disables every eGPU monitor with one `hyprctl eval` each, without reloading,
    and persists the result afterwards. Target: under 1 s.
  - The panel binds it to a button. A suggested keybinding goes in the README, not in
    the user's bindings file.
- `display move-workspaces <desc>`: moves each workspace to the primary.
  - `hl.dsp.workspace.move({ monitor = … })` moves the **active** workspace
    (omarchy:default/hypr/bindings/tiling.lua:34-37).
  - Whether it accepts a workspace id is **unverified** (gate E4). The fallback
    focuses each workspace, then moves it.
  - The move is verified by re-reading `hyprctl workspaces -j`.
- Dispatch syntax is Lua (`hyprctl dispatch 'hl.dsp.…'`, as used at
  face:install.sh:110). Hot-add applies `display.policy`.

### 7.4 `egpu-run`

`egpu-run [--check] <cmd…>`:

- Resolves the attached device and backend, exports `be_offload_env`, and `exec`s
  the command.
- If no eGPU is ready, it refuses with exit 1 and a notification. It does not fall
  back silently to the iGPU.
- From the panel, apps are launched through `uwsm-app -- egpu-run <cmd>`, matching
  Omarchy's launch convention (omarchy:default/agents/skills/omarchy/hyprland.md:38).

---

## 8. Steam module (`lib/steam/`)

This is its own module with its own phase (E6), and the user explicitly wants it.
- It works without an eGPU attached and without Hyprland.
- It reads the GPU only through the backend's `be_offload_env`, and the eGPU's state
  only through `status`.
- Files: `lib/steam/steam.sh` (verbs, process control, queue), `lib/steam/vdf.py`
  (the VDF editor, python3 stdlib), and `lib/steam/tools.json` (non-game appids and
  name prefixes to hide).

### 8.1 Finding Steam, accounts and games

- **Installs.** These are probed in order and de-duplicated by `realpath`. Each one
  that exists becomes a `root` with a `kind`:
  - Native: `~/.local/share/Steam`, `~/.steam/steam` (a symlink on this machine; both
    exist), `~/.steam/root`.
  - Flatpak: `~/.var/app/com.valvesoftware.Steam/.local/share/Steam` (absent here).
  - `steam.roots` in config overrides the list.
- **Accounts.**
  - `<root>/config/loginusers.vdf` lists SteamID64s with `AccountName`, `PersonaName`
    and `MostRecent`.
  - The account id is the SteamID64 minus 76561197960265728, which names
    `<root>/userdata/<accountid>/`.
  - The default account is `MostRecent "1"`, or `steam.account` from config if set.
    Every account with a `localconfig.vdf` is listed.
  - This machine has three `userdata/<id>` directories (directory listing only), so
    an account picker is required, not optional.
- **Games.**
  - `<root>/steamapps/libraryfolders.vdf` gives every library `path`.
  - Each `<path>/steamapps/appmanifest_*.acf` gives `appid`, `name`, `installdir`.
    Manifests duplicated across libraries are de-duplicated by appid.
  - Tools are hidden by `tools.json`: the Proton, Steam Linux Runtime and Steamworks
    Common Redistributables name prefixes, plus their appids.
  - Tool filtering is Steam data, not enclosure data, so it is not in `profiles/`.
- The formats were **not inspected** on this machine, because reading Steam's user
  files was denied during planning. Gate E6 starts by building fixtures from copies
  the user makes. The parser targets Valve's text KeyValues: quoted or bare tokens,
  `{}`, `//` comments, `\"` `\\` `\n` `\t` escapes, `[$COND]` suffixes kept verbatim.

### 8.2 Where the option lives and how it is edited

- **Path in the tree.** `UserLocalConfigStore/Software/Valve/Steam/apps/<appid>/LaunchOptions`
  in `userdata/<accountid>/config/localconfig.vdf`. Key lookup is case-insensitive,
  and writes keep the case the file already uses.
- **Decision: parse to locate, splice to edit.** The editor parses the whole file into
  a tree that records the byte span of every token. It then changes only bytes it can
  account for:
  - Existing `LaunchOptions`: replace the bytes of its value token, re-escaped.
  - Missing key in an existing app block: insert one line before that block's closing
    brace, copying the indentation of its sibling lines.
  - Missing app block: insert one under `apps`, the same way.
  - The file is never re-serialised from the tree. Re-serialising would rewrite
    whitespace, ordering and anything the parser does not model in every one of the
    user's settings.
- **Validity check before writing.**
  1. Re-parse the new bytes.
  2. Assert that the new tree equals the old tree except for exactly the intended key.
  3. Assert that the bytes outside the edited span are identical.
  4. Re-read the original file and compare its SHA-256 to the one parsed. If it
     changed, exit with `{"error":"vdf_changed_underneath"}`.
  Any failure gives `{"error":"vdf_parse_failed"}` or `vdf_check_failed`, and nothing
  is written.
- **Backup and write.**
  - Back up first to
    `${XDG_STATE_HOME:-~/.local/state}/omarchy-egpu/backups/steam/<accountid>/localconfig-<UTC>.vdf`,
    keeping 20.
  - Write the new bytes to a temp file in the same directory and `fsync` it.
  - Copy the original mode, then `rename`.
  - `steam restore <accountid> <backup>` puts any backup back (also through the
    closed-Steam rule).
- **Bulk.** `steam set-all on|off` changes every listed game for the account in **one**
  parse, one backup and one write, using the same check (all intended keys, nothing
  else).

### 8.3 The managed option string

- **Source.** The backend supplies it: `be_offload_env` (§4.2). For nvidia it is the
  user's known-working set:
  `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only`.
- **Shape.** `OMARCHY_EGPU=1 <env…> ` goes in front of the user's options, and
  `%command%` is added only if they had none:

  | before | after |
  |---|---|
  | *(empty)* | `OMARCHY_EGPU=1 <env> %command%` |
  | `-novid -fullscreen` | `OMARCHY_EGPU=1 <env> %command% -novid -fullscreen` |
  | `gamemoderun %command% -dx11` | `OMARCHY_EGPU=1 <env> gamemoderun %command% -dx11` |
  | `PROTON_LOG=1 %command%` | `OMARCHY_EGPU=1 <env> PROTON_LOG=1 %command%` |

- **Marker.** `OMARCHY_EGPU=1` is the marker. Off removes the marker and the run of
  tokens after it that equal the backend env set exactly. It removes the added
  `%command%` only if state recorded adding it.
  - If the run no longer matches, the user edited it, and the game shows `modified`.
    Off then refuses with `{"error":"token_modified"}`, and the panel offers "Show
    options" instead of guessing.
  - on→off restores the original string byte-for-byte (gate E6).
- **Never clobber.**
  - Nothing outside the marker run is ever changed.
  - Options that already contain the backend's variables **without** the marker are
    reported as `manual`. Turning such a game on refuses with `manual_offload`, and
    the panel offers "Adopt". Adopt removes exactly those variables and adds the
    marked run, with the before/after strings shown first.
- **Why env tokens and not `egpu-run %command%`.**
  - Env tokens reach Flatpak Steam's sandbox, where the plugin's `bin/` does not exist.
  - They keep working if the plugin is removed.
  - They are the form the user already knows works.

### 8.4 Steam must be closed for the write

- Steam rewrites `localconfig.vdf` from memory on exit, so a write made while it runs
  is lost.
- **Running detection:**
  - Native: a `steam` or `steamwebhelper` process owned by the user under that root.
  - Flatpak: `flatpak ps` lists `com.valvesoftware.Steam`.
- **`steam set` / `set-all` while Steam runs** returns `{"error":"steam_running"}`.
  The panel offers two choices:
  1. **Close Steam, apply, reopen.** `steam apply --close --relaunch`:
     - Shut down with `steam -shutdown` (Flatpak:
       `flatpak run com.valvesoftware.Steam -shutdown`).
     - Wait up to 30 s for every Steam process to exit (`steam_close_timeout`).
     - Apply the change.
     - Relaunch detached through `uwsm-app -- steam` (or `flatpak run …`), only if
       Steam was running before.
     - It refuses while a game process launched by Steam is running
       (`{"error":"game_running"}`).
  2. **Queue it.** The change goes into
     `${XDG_STATE_HOME}/omarchy-egpu/steam-pending.json` as
     `[{account, appid, want:"on|off"}]`.
     - While the queue is non-empty, the Service's watcher checks every 5 s. When
       Steam is not running, it runs `steam apply` and posts a notification ("eGPU
       setting applied to 3 games").
     - Immediately before the rename, `apply` checks Steam again. If Steam started in
       the meantime, it aborts and keeps the queue.
     - Queued games show `pending_on` / `pending_off`.

### 8.5 Per-game state (the panel's column)

| `state` | meaning | panel label |
|---|---|---|
| `off` | no marker | — |
| `on` | marker present, eGPU `phase` = `ready` | "on eGPU" |
| `stale` | marker present, eGPU not ready | "stale (eGPU not connected)" |
| `pending_on` / `pending_off` | queued (§8.4) | "applies when Steam closes" |
| `manual` | backend vars present without marker | "manual GPU options" |
| `modified` | marker present, run edited | "edited by hand" |

### 8.6 What happens to the options when the eGPU is unplugged — recommendation: leave them

- **What the docs say for Vulkan.** `__NV_PRIME_RENDER_OFFLOAD=1` loads
  `VK_LAYER_NV_optimus`. `NVIDIA_only` makes it "sort the GPUs so NVIDIA GPUs are
  enumerated first" (nvdoc:6963-6974). So with no NVIDIA GPU present, the Intel device
  is still enumerated, and Vulkan games, which includes Proton's DXVK/VKD3D-Proton,
  should start on the iGPU.
- **The weak spot is GLX.** `__GLX_VENDOR_LIBRARY_NAME=nvidia` makes GLVND load
  NVIDIA's GLX (nvdoc:6945-6949). Without an NVIDIA device, a native OpenGL/GLX game
  may fail to start. This is **unverified**, and gate E6 tests both cases with the
  eGPU unplugged.
- **Recommendation: leave the options in place (the default `steam.on_unplug =
  "leave"`), show `stale`, and add a bulk "Turn off stale" action.**
- **Why not a wrapper that falls back to the iGPU:**
  - It cannot be seen inside Flatpak Steam's sandbox.
  - It turns every toggled game into "command not found" once the plugin is removed.
    `omarchy plugin remove` only deletes the checkout and runs no hook
    (omarchy:shell/README.md:126-129).
  - It would need a stable path outside the watched plugin directory.
- **Why not auto-removing on unplug:** it rewrites the user's Steam config on every
  unplug and needs Steam closed each time.
- **If E6 shows GLX games fail when stale,** the README and the `stale` tooltip say so,
  and "Turn off stale" is offered from the unplug notification. The default stays
  "leave".

### 8.7 Proton: NVAPI and DXVK/VKD3D device selection — decision

- **Device selection.** DXVK and VKD3D-Proton pick from the Vulkan physical-device
  list. `__VK_LAYER_NV_optimus=NVIDIA_only` puts the NVIDIA GPU first (nvdoc:6970-6974).
  The plan therefore sets **no** `DXVK_FILTER_DEVICE_NAME` / `VKD3D_FILTER_DEVICE_NAME`.
  They match on device-name substrings, which would hardcode a card name. Gate E6
  verifies with `DXVK_HUD=devinfo` on one DX11 and one DX12 title.
- **`PROTON_ENABLE_NVAPI=1`.** It enables DXVK-NVAPI for DLSS and Reflex. It is not
  needed to run on the eGPU, so it is not part of the managed string.
  - The backend may expose optional extras through `be_steam_extras` (nvidia:
    `PROTON_ENABLE_NVAPI=1`). These are a per-game opt-in "NVAPI (DLSS)", off by
    default, placed inside the marked run, so off removes them too.
  - Whether current Proton enables NVAPI by default for this setup is **unverified**.
- **Flatpak.** NVIDIA userspace inside the sandbox needs the matching
  `org.freedesktop.Platform.GL.nvidia-<driver-version>` extension. This is health row
  `steam.flatpak_gl`, shown only when a Flatpak root exists.

### 8.8 Verbs

| verb | output |
|---|---|
| `steam roots` | `[{kind:"native"\|"flatpak", root, running}]` |
| `steam accounts [--root R]` | `[{accountid, persona, most_recent, has_localconfig}]` |
| `steam list [--account A]` | `{account, egpu_ready, games:[{appid, name, library, state, options, extras:{nvapi}}]}` |
| `steam set <appid> on\|off [--nvapi on\|off] [--account A] [--queue]` | result + new state |
| `steam set-all on\|off [--only-stale] [--account A] [--queue]` | `{changed:n}` |
| `steam apply [--close] [--relaunch]` | applies the queue |
| `steam close` | `steam -shutdown`, waits |
| `steam restore <accountid> <backup>` | puts a backup back |

Errors: `steam_not_found`, `account_not_found`, `steam_running`, `game_running`,
`steam_close_timeout`, `vdf_parse_failed`, `vdf_check_failed`, `vdf_changed_underneath`,
`token_modified`, `manual_offload`, `backup_failed`, `backend_stub`.

---

## 9. Setup / health (`lib/health.sh`)

`omarchy-egpu health` prints a list of rows:

```json
{"id":"…","group":"…","level":"ok|info|warn|error|skipped","title":"…","detail":"…",
 "fix":{"kind":"user|system|none","label":"…"}}
```

- `fix.kind: user` is applied by `omarchy-egpu health fix <id>`, which backs up first.
- `fix.kind: system` is applied only by the system-half install command (§10), which
  backs up first.
- The panel lists both kinds, with the action and backup visible (REVISION 3).

On a machine with no eGPU history, every row still answers. Missing pieces show as
`error`/`warn` with an explanation, and the first-run Setup reads this list
(plan-gui.md §5.5).

| id | group | check | fix |
|---|---|---|---|
| `bolt.daemon` | bolt | boltd reachable | none (install bolt) |
| `bolt.device` | bolt | device known, policy, stored | user: enroll (bolt's polkit) |
| `kernel.thunderbolt_early` | boot | `thunderbolt` in an mkinitcpio `MODULES` drop-in (this machine: `/etc/mkinitcpio.conf.d/thunderbolt_module.conf:1`) | system |
| `kernel.modprobe_options` | boot | backend's options present. nvidia: `/etc/modprobe.d/nvidia.conf:1-4` | system |
| `kernel.nouveau_blacklist` | boot | `blacklist nouveau` (`/etc/modprobe.d/blacklist-nouveau.conf:1`) | system |
| `boot.modules_load_mask` | boot | no `modules-load.d` file loads a backend module at boot. Mask name must equal the shipped name | system: empty `/etc/modules-load.d/<shipped name>`, remove the stale one |
| `boot.initramfs_nvidia` | boot | no backend module inside any initramfs (helper `inspect-initramfs`, /boot is root-only here) | none (instructions only) |
| `boot.mkinitcpio_conf` | boot | no `/etc/mkinitcpio.conf.d/nvidia.conf` adding nvidia modules (Omarchy's installer writes one, omarchy:install/hardware/nvidia.sh:24-28) | system: remove with backup |
| `driver.modeset` | driver | live `modeset` = Y when loaded | system |
| `driver.fbdev` | driver | live value, info only (O3) | none |
| `driver.flavour` | driver | closed 580xx vs open. Info: Omarchy would pick `nvidia-open-dkms` for this GPU (omarchy:install/hardware/nvidia.sh:2-3), but the user moved off it after GSP hangs (binding fact 1) | none |
| `driver.persistenced` | driver | `nvidia-persistenced` not enabled | none (instructions) |
| `driver.sleep` | driver | nvidia sleep units state, O5 explanation | none |
| `hypr.links` | display | udev links exist and point at the right by-path nodes | system |
| `hypr.order` | display | `AQ_DRM_DEVICES` in the running Hyprland (log line), primary = boot_vga | user: write toggle file, then relogin |
| `hypr.gpu_list` | display | cards Hyprland has open (`/proc/<pid>/fd`), by-path names | none |
| `hypr.session_env` | display | running session's GLX/VA-API vendor is the primary's | user: toggle file |
| `steam.options` | steam | every marked run well formed; `modified` and `manual` games listed | none (Games view acts per game) |
| `steam.stale` | steam | games `stale` while no eGPU is ready (info) | user: `steam set-all off --only-stale` |
| `steam.pending` | steam | queued changes waiting for Steam to close | user: `steam apply --close` |
| `steam.flatpak_gl` | steam | Flatpak root present → matching NVIDIA GL extension installed | none (instructions) |
| `tools.vulkaninfo` | tools | `vulkaninfo` present | user: `omarchy-pkg-add vulkan-tools` |
| `system.helper` | system | helper installed, version = plugin version, policy present | system |
| `diag.kernel_params` | diag | profile's optional params, info only | none |

### 9.1 Initramfs rule (binding fact 3)

- Never put backend modules in the initramfs. `boot.initramfs_nvidia` lists every
  image the helper finds under `/boot` (`*.img` and UKIs) and checks
  `lsinitcpio -l` for `nvidia*.ko*`.
- UKI support in `lsinitcpio` is **unverified**. The fallback is
  `objcopy --dump-section .initrd=` into the helper's private temp directory.
- The row and the README warn: **do not rebuild the initramfs with the eGPU
  attached.** The user reports that the `kms` hook's autodetect can then bake nvidia
  in. This machine keeps `kms` because it is hybrid
  (`/etc/mkinitcpio.conf.d/omarchy_hooks.conf:1,7-9`).
  - **Doubt:** the dkms modules live outside `drivers/gpu`, so I expected the kms hook
    not to pick them up. The check exists either way.
- The plugin installs a pacman hook. Before `mkinitcpio` runs, it prints a warning
  when an external display device is present. It does not block.

### 9.2 modules-load mask (binding fact 2, verified)

- Today `/etc/modules-load.d/nvidia-utils.conf` is an empty file named after the
  previous package. The shipped file is
  `/usr/lib/modules-load.d/nvidia-580xx-utils.conf`, 11 bytes, content `nvidia-uvm`.
  The mask therefore masks nothing.
- The check compares `/usr/lib/modules-load.d/*.conf` lines naming a backend module
  against `/etc/modules-load.d/` files with the **same basename**.
- The Fix creates the matching empty file and moves the stale one to a backup.

### 9.3 Diagnostics bundle

- `omarchy-egpu health bundle` writes a tarball to `$STATE/diag-<UTC>.tar`. It
  contains status, health, `boltctl list`, `lspci -tv`, the eGPU's link attributes,
  the backend modules' parameters, the Hyprland log lines matching `drm:`, and this
  boot's kernel log for the eGPU's PCI path.
- Lines matching the profile's `log_noise` are labelled harmless.
- Nothing is uploaded.

---

## 10. Root half

### 10.1 `omarchy-egpu-admin` (installed to `/usr/local/bin`)

The helper is minimal, versioned and generic (REVISION 3):

- `PATH=/usr/bin`, `unset IFS BASH_ENV ENV CDPATH`, as face:system/install.sh:38-44.
- It ignores every `EGPU_*` variable.
- It carries a version header and prints it under `version`.

**Fixed module allowlist**, in the helper's text:
`nvidia nvidia_modeset nvidia_drm nvidia_uvm`. Adding a backend's modules means a
helper release and a security review. The amdgpu/intel stubs need no root module
handling, because unload is unsupported for them (§4.2).

| verb | does | refuses unless |
|---|---|---|
| `version` | prints `{"version":"x.y.z"}` | — |
| `load <backend>` | `modprobe` the allowlisted set for that backend, in fixed order | a matching device exists in `/sys/bus/pci/devices` (never load with no card, binding fact 1) |
| `unload <backend>` | `modprobe -r` in fixed reverse order | no matching device exists, and every refcnt is 0 |
| `remove <bdf>` | writes `1` to `remove` for every function in that slot, in a child with a 20 s timeout | BDF matches `^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$`, class 0x03xxxx, not `boot_vga`, `removable` = `removable` |
| `rescan` | writes `1` to `/sys/bus/pci/rescan` | — |
| `holders` | read-only list of pids/comm/uid holding allowlisted nodes | — |
| `inspect-initramfs` | read-only module list per image | — |

- **Unverified:** that USB4/TB-tunnelled functions show `removable` = `removable`. The
  iGPU has no `removable` attribute (checked on this machine). Gate E0 records the
  eGPU's value. If it is absent, the rule becomes "an ancestor port is a Thunderbolt
  downstream port", decided before E7.
- No verb takes a path, a module name or a command line from the caller.

### 10.2 polkit

`/usr/share/polkit-1/actions/no.kalinewb.egpu.policy`, one action
`no.kalinewb.egpu.device`, annotated with
`org.freedesktop.policykit.exec.path=/usr/local/bin/omarchy-egpu-admin`. This copies
face:system/no.user.face.policy:26-35.

- **Proposed defaults:** `allow_active` = `yes`, `allow_inactive`/`allow_any` = `no`.
  - Rationale: every verb either acts on hardware the active seat's user can already
    unplug by hand, or is read-only.
  - udisks treats media eject the same way (`org.freedesktop.udisks2.eject-media`
    in `/usr/share/polkit-1/actions/org.freedesktop.UDisks2.policy:1876`).
  - **This is for the security reviewer to accept or tighten to `auth_admin_keep`.**
    It is the main open security decision.
- Nothing that edits `/etc` goes through this action. Those changes happen only in
  install.sh.

### 10.3 udev rule `/etc/udev/rules.d/61-omarchy-egpu.rules` (generated by install.sh)

- `SUBSYSTEM=="drm", KERNEL=="card[0-9]*"`, with parent PCI `KERNELS==<primary.bypath
  address>`, gets `SYMLINK+="dri/omarchy-egpu-primary"`. The address is detected at
  install from `boot_vga`; this machine's is `0000:00:02.0`, in
  `/dev/dri/by-path/pci-0000:00:02.0-card`.
- `SUBSYSTEM=="drm", KERNEL=="card[0-9]*"`, parent display class, `ATTRS{removable}=="removable"`,
  gets `SYMLINK+="dri/omarchy-egpu-external"`. It matches no vendor, so it is backend
  independent. The TB-tunnelled BDF can change with port or enumeration order, so it
  is not matched.
- `ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x03*", ATTR{removable}=="removable",
  TEST=="/etc/omarchy-egpu/autoconnect"` runs `RUN+="/usr/local/bin/omarchy-egpu-admin load auto"`.
  `connect.auto` toggles that flag file through the helper. **Doubt:** that is a
  write to `/etc` outside install.sh. The alternative is to make it install-time only.
  This is for the reviewer.
- Notifications do **not** come from udev, because root has no session. They come
  from the user-level watcher (§5, plan-gui.md Service).

### 10.4 Install

- `system/install.sh` is face's mechanism, with egpu names: terminal command, fetched
  checksum, pinned snapshot, owner checks (O4).
- It installs: the helper, the policy, the udev rule, the modules-load mask (Fix
  `boot.modules_load_mask`), and the pacman hook (§9.1).
- Optionally, each behind its own confirmation printed in the terminal: the
  modprobe options and removal of `/etc/mkinitcpio.conf.d/nvidia.conf`.
- Every replaced `/etc` file goes first to `/var/backups/omarchy-egpu/<UTC>/`.
- `install.sh --uninstall` restores from backup and removes everything it installed.
- The repo-side `dev-sync.sh` copies face:install.sh:38-67:
  - It validates a dot-named staging copy first, which the watcher ignores
    (PluginRegistry.qml:734-735).
  - Then it rsyncs with `--delete-excluded`.
  - It refuses to restart the shell while the session is locked (face:install.sh:96-106).

---

## 11. Glitch mitigations (REVISION 2026-10-09)

1. **Wrong primary:** pinned by `AQ_DRM_DEVICES` (O1). Health `hypr.order` shows it.
2. **Session env pointing at NVIDIA:** neutralised by the toggle file (§7.2.2).
   Health `hypr.session_env`.
3. **Cross-GPU copy:** the iGPU composites everything, and the HDMI output on the
   eGPU gets a copy. Aquamarine logs `Backend requires blit` and `Buffer is marked as
   multigpu, forcing linear` (library strings). This costs bandwidth over a 4-lane
   link, so v1 does not optimise it. Games meant for the HDMI monitor still run
   through `egpu-run`. That frame then crosses the link twice, eGPU→iGPU→eGPU, which
   is **unverified for smoothness** (gate E4 measures frame pacing on HDMI).
4. **Explicit sync:** aquamarine reads `AQ_MGPU_NO_EXPLICIT` (library strings). This
   is exposed as `display.mgpu_no_explicit`. Off by default; an artifacts-only
   compatibility switch that needs a relogin. Its exact effect is **unverified**.
5. **VRR:** NVIDIA KMS forces VRR on capable displays by default (nvdoc:7119-7122), so
   HDMI rules set `vrr = 0` unless `display.vrr` is true.
6. **Quick off:** `display off` (§7.3). It also persists, so a reload or relogin keeps
   the monitor off until the user turns it back on.

---

## 12. Phases (engine). Each gate must pass before the next phase starts

| phase | delivers | gate |
|---|---|---|
| **E0** live baseline, no code | Recorded facts with the eGPU attached: `boltctl info` (vendor string for the profile), `lspci -tv`, `removable` attr, link speed, which modules autoloaded, nvidia-smi responsiveness, Hyprland log `drm:` lines, whether Hyprland opened the card on hot-add with **no** config, connector names, `/sys/module/*/refcnt` | A facts file committed to `dev/`. O1/O2/O3 "unverified" items listed with observed values |
| **E1** ordering + toggle file + udev links (manual install) | `lib/display.sh` toggle writer, rule file | (a) login with eGPU absent: log shows `Explicit device list` with the primary only. (b) login with eGPU attached: primary = iGPU, both cards open. (c) hot-plug in a running session: HDMI appears **or** `needs_relogin` is set correctly. The result decides whether the fallback is routine |
| **E2** status + health (read-only), status contract, fake-sysfs test suite | `status.sh`, `health.sh`, backends/nvidia + stubs, profiles, tests | `tests/run.sh` green on all fixtures (§13). Every fixture's `status --json` validates against `tests/schema/status-1.json`, and `summary.state` matches the expected value. `status watch` against scripted fakes emits the expected event sequence. `status.json` is written atomically, its heartbeat stays fresh, and a second watcher exits 3. On this machine `boot.modules_load_mask` = error, matching the facts in §9.2 |
| **E3** connect + egpu-run | `device.sh connect`, `egpu-run` | `egpu-run vkcube` (or glxgears) shows in `nvidia-smi` procs and renders on the laptop panel. 20 connect cycles, no hang, `smi_hung` path tested with a fake |
| **E4** display | display verbs | enable/disable/mirror/extend/position work. `display off` < 1 s. Workspaces land on the primary. Reload keeps a disabled monitor off. Connector name collision handled. Frame pacing on HDMI recorded |
| **E5** eject | `device.sh eject`, helper `remove/unload` | 10 cycles plug→use→HDMI on→eject→unplug→replug with no freeze. Recorded whether refcounts drop (decides `held_after_eject` frequency) and whether `fbdev=1` blocks remove |
| **E6** Steam module (§8). Depends only on E2, so it can run in parallel with E3–E5 | `lib/steam/*`, fixtures | **E6a, read-only:** with the user's consent, fixtures are made from copies of their `loginusers.vdf`, `libraryfolders.vdf`, `appmanifest_*.acf` and the three `localconfig.vdf`. `steam list` matches what the Steam client shows for each account, with tools hidden. **E6b, write:** every fixture row of §8.3 round-trips on→off byte-identical. `set-all` makes one backup. The validity check rejects a planted corruption. Refusal while Steam runs and `vdf_changed_underneath` are both exercised. Close-apply-relaunch and the queue each work once for real. **E6c, live:** one Proton DX11 and one DX12 title report the NVIDIA adapter under `DXVK_HUD=devinfo`. Then, with the eGPU unplugged, one Vulkan/Proton game and one native OpenGL game are launched while `stale`, and the result is recorded (decides the §8.6 tooltip) |
| **E7** root half | `system/*`, pins, uninstall | Security reviewer sign-off on helper + policy + rule. `dev/check-pins.sh` passes. Install, uninstall and reinstall work on this machine |
| **E8** sleep | inhibitor, notices | Suspend/resume with eGPU attached, and after eject (modules unloaded, and held). Results go in the README |
| **E9** notch consumers (with plan-gui.md G8) | no new engine logic; any fields the notch glance needs are added under the §5.1 additive rule | the notch integration reads only `status.json` and runs only engine verbs. A grep of the QML for `/sys`, `hyprctl` and `boltctl` finds nothing |

---

## 13. Test strategy (REVISION 3)

- `tests/run.sh` is a plain bash runner; bats is not assumed. For each scenario it
  sets `EGPU_SYS/DEV/PROC/ETC/USRLIB` to `tests/fixtures/<scenario>/…` and puts
  `tests/fakes/bin` first on `PATH`.
- **Fakes:**
  - `boltctl`: reads `bolt.json` and appends invocations to a log the test asserts on.
  - `hyprctl`: returns `hypr/monitors.json`, `workspaces.json`, records `eval`/`dispatch`
    calls, `configerrors` empty or not.
  - `nvidia-smi`: CSV, or sleeps forever to exercise `smi_hung`.
  - `pkexec`: runs a fake helper that edits the fixture tree; `remove` deletes the
    function dirs.
  - `udevadm`, `lsinitcpio`, `vulkaninfo`.
- **Scenarios:** `stranger-no-tb` (no Thunderbolt at all), `absent`,
  `plugged-unauthorized`, `authorized-no-pci` (profile hint fires), `bound-nvidia`,
  `ready-hdmi`, `ejected-held`, `amd-stub`, `intel-arc-stub`, `stale-modules-load`,
  `initramfs-has-nvidia`, and Steam scenarios: native only, Flatpak only, both, three
  accounts, multiple libraries, a duplicate manifest, and every §8.3 option shape. Also
  `manual`, `modified`, quotes and backslashes in options, unicode names, a missing app
  block, a CRLF file, and a planted corruption. A fake `steam` and `flatpak` test the
  running check, close, relaunch and queue.
- **Assertions:** JSON output (via `jq -e`), the fake call logs (e.g. eject calls
  `hyprctl eval … disabled = true` **before** `pkexec … remove`), and file trees after
  Fixes, including backups.
- **The real helper** is tested in a throw-away mount namespace with a fake `/sys` bind
  only in E7. The unit tests never run it as root.
- **Lint:** `dev/lint.sh` as profiles:dev/lint.sh:3-15 does: `bash -n`,
  `shellcheck -S error`, qmllint.

---

## 14. Doubts

- **Namespace.** I chose `kalinewb.egpu` and `no.kalinewb.egpu.device`, not
  `user.*`. The notch's P14 records the decided namespace as `kalinewb.*`, which
  matches the GitHub account. Face stayed `user.face` only because renaming a
  root-owned polkit action is costly
  (`/home/user/Work/omarchy-notch/INTEGRATION-SCOPE.md:346-371`). A new plugin
  has no such cost. The user should confirm.

- The `fbdev` requirement (O3) is implemented as decided, and I doubt it is needed.
- The by-path names cannot go into `AQ_DRM_DEVICES` because of colons (O1).
  Derived links are used instead.
- `allow_active=yes` for the helper and the `/etc` autoconnect flag file (§10.2–10.3)
  are for the security reviewer.
- The Steam VDF editor is in Python, not shell (§8.2). A shell edit of the file that
  holds all the user's Steam settings is the riskier choice.
- "Options are harmless without the card" holds for Vulkan per the docs but is doubtful
  for GLX (§8.6). The recommendation stays "leave", pending E6c.
- Hot-add, removal handling and `hl.env` timing are all unverified until E0/E1/E5. The
  plan's shape survives either outcome, but how often the user must relog does not.
