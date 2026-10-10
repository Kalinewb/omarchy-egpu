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
```

License: MIT
