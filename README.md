# omarchy-egpu

eGPU manager for [Omarchy](https://omarchy.org): connect and safely eject a Thunderbolt/USB4 eGPU without
rebooting, see its state in the bar, and toggle "run on eGPU" per Steam game.

**Status: work in progress, not installable yet.** The read-only engine (status, health) and the Steam
launch-option module pass their tests against fake hardware and fixtures. The panel shell renders every state
offscreen, and the optional notch integration (for [omarchy-notch](docs/notch-requests.md)) renders and declines
offscreen against the notch's own rules. Connect, eject, HDMI output and the root helper are not built yet, and
nothing is verified under the live shell or on real hardware yet. First tested hardware: Minisforum DEG2 + RTX 4070 SUPER on an Intel Lunar Lake laptop.

Design: see `docs/` (`scope.md`, `plan-engine.md`, `plan-gui.md`) and `dev/e0-facts.md` for what was observed on
real hardware.

```bash
tests/run.sh          # engine tests, no hardware needed
dev/lint.sh           # shell, Python, JSON and QML checks
dev/g1-offscreen.sh   # the bar and Overview, rendered offscreen from fixtures
dev/g8-offscreen.sh   # the notch integration, offscreen, against the notch checkout's rules
dev/check-pins.sh     # the root half's pins, checksum, versions and the command below agree
```

## System half (root)

Connect, eject and rescan need a small root helper, `/usr/local/bin/omarchy-egpu-admin`, with a polkit action
(`no.kalinewb.egpu.device`, no password for the active local session), a udev rule
(`/etc/udev/rules.d/61-omarchy-egpu.rules`: the `/dev/dri/omarchy-egpu-primary` and `-external` links, and
auto-connect) and a boot-load mask in `/etc/modules-load.d/` named after the file the driver package ships.
`omarchy plugin add` never runs sudo, so this half is installed afterwards, from a terminal, from the installed
plugin folder. The helper takes only fixed verbs and loads only `nvidia nvidia_modeset nvidia_drm nvidia_uvm`;
see the header of `system/omarchy-egpu-admin`. It has not been through the security review yet.

### Installing or updating the system half

The command fetches the installer's checksum from this release's tag on GitHub, copies `system/install.sh` into
a root-only directory, checks the copy and runs it. The installer checks every file it installs against
checksums in its own text. Compare what you paste with this:

```bash
d="$HOME/.config/omarchy/plugins/kalinewb.egpu" && sum=$(curl -fsSL https://raw.githubusercontent.com/Kalinewb/omarchy-egpu/v0.1.0/system/install.sh.sha256) && sudo bash -c 't=$(mktemp -d /run/omarchy-egpu-installer.XXXXXX) && cp -- "$1/system/install.sh" "$t/install.sh" && printf "%s  %s\n" "$2" "$t/install.sh" | sha256sum -c --quiet - && bash "$t/install.sh" --expect-sha256 "$2" install "$1" "$3"; s=$?; rm -rf -- "$t"; exit $s' omarchy-egpu "$d" "$sum" "$USER"
```

- `bash system/install.sh --print-command uninstall` (or `reinstall`) prints the same command for removing it.
  Uninstall removes every installed file and puts back what install replaced (saved under
  `/var/backups/omarchy-egpu/`).
- If an empty `/etc/modules-load.d/nvidia-utils.conf` is left from the old driver package, the installer
  explains it and asks before moving it to the backup folder.
- **Auto-connect is off.** With it on, plugging in the eGPU loads its driver through the helper; with it off,
  the panel's Connect does. To turn it on, run the command with `--autoconnect on` added before `install`, or
  create `/etc/omarchy-egpu/autoconnect` as root. Remove the file to turn it off. No reload is needed.
- While the repository is private, the checksum URL needs authentication: fetch it with
  `gh api -H 'Accept: application/vnd.github.raw' 'repos/Kalinewb/omarchy-egpu/contents/system/install.sh.sha256?ref=v0.1.0'`
  instead of `curl`.

License: MIT
