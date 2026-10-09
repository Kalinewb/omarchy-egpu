# omarchy-egpu

eGPU manager for [Omarchy](https://omarchy.org): connect and safely eject a Thunderbolt/USB4 eGPU without
rebooting, see its state in the bar, and toggle "run on eGPU" per Steam game.

**Status: work in progress, not installable yet.** The read-only engine (status, health) and the Steam
launch-option module pass their tests against fake hardware and fixtures. The panel shell renders every state
offscreen. Connect, eject, HDMI output, the root helper and the notch integration are not built or not yet
verified on real hardware. First tested hardware: Minisforum DEG2 + RTX 4070 SUPER on an Intel Lunar Lake laptop.

Design: see `docs/` (`scope.md`, `plan-engine.md`, `plan-gui.md`) and `dev/e0-facts.md` for what was observed on
real hardware.

```bash
tests/run.sh      # engine tests, no hardware needed
dev/lint.sh       # shell, Python, JSON and QML checks
```

License: MIT
