#!/bin/bash

# Render the panel to PNGs, offscreen, from the fixtures: every state the plugin has a fixture for, on a
# stand-in notch host (black, white) and in the standalone popup.
#
#   ./dev/render.sh --all <dir>                       every picture the docs use
#   ./dev/render.sh --out <png> --fixture <name> [--route <route>] [--mode hosted|standalone]
#                   [--host black|white] [--adv] [--zone] [--panel <dir>] [--reduced]
#
# `--panel <dir>` renders the plugin in another checkout (the "before" pictures come from a checkout of the
# commit before the kit). The harness (dev/qml-harness/render.qml) is always this repo's. Offscreen with the
# OpenGL RHI, as dev/g1-offscreen.sh and the kit's gallery.sh; no real window opens, the engine is the dev
# stub, and nothing touches the running shell, the live plugin or the machine's own eGPU state.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SHELL_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
[[ -d $SHELL_PATH/shell/Ui ]] || { echo "render: no Omarchy shell at $SHELL_PATH/shell" >&2; exit 1; }
command -v quickshell >/dev/null || { echo "render: quickshell is not installed" >&2; exit 1; }

panel=$REPO; out=""; fixture=ready; route=overview; mode=hosted; host=black; adv=0; zone=0; all=""; reduced=0
while (($#)); do
  case $1 in
    --out) out=$2; shift 2 ;;
    --fixture) fixture=$2; shift 2 ;;
    --route) route=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --host) host=$2; shift 2 ;;
    --adv) adv=1; shift ;;
    --zone) zone=1; shift ;;
    --reduced) reduced=1; shift ;;
    --panel) panel=$(cd "$2" && pwd) || exit 2; shift 2 ;;
    --all) all=$2; shift 2 ;;
    *) echo "render: unknown argument $1" >&2; exit 2 ;;
  esac
done
FIX="$panel/dev/fixtures"
[[ -d $FIX ]] || FIX="$REPO/dev/fixtures"

# The config root, as dev/g1-offscreen.sh builds it: qs.Commons and qs.Ui from the installed shell, except
# KeyboardPanel (layer-shell), and the plugin under test as ./egpu. Symlinks live only in this temp dir.
root=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-egpu-render.XXXXXX")
trap 'pkill -f -- "$root/" 2>/dev/null; rm -rf "$root"' EXIT
mkdir -p "$root/qs/Ui" "$root/run"
ln -s "$SHELL_PATH/shell/Commons" "$root/qs/Commons"
for f in "$SHELL_PATH"/shell/Ui/*; do
  case ${f##*/} in KeyboardPanel.qml | qmldir) ;; *) ln -s "$f" "$root/qs/Ui/${f##*/}" ;; esac
done
cp "$SHELL_PATH/shell/Ui/qmldir" "$root/qs/Ui/qmldir"
cp "$REPO/dev/qml-harness/KeyboardPanel.qml" "$root/qs/Ui/KeyboardPanel.qml"
ln -s "$panel" "$root/qs/egpu"
cp "$REPO/dev/qml-harness/render.qml" "$root/qs/shell.qml"
RUN="$root/run"

render() { # render <fixture> <route> <mode> <host> <adv> <zone> <png>
  local fx=$1 log="$root/log.$$"
  [[ -d $FIX/$fx ]] || { echo "render: no fixture $fx" >&2; return 1; }
  jq --argjson at "$(date +%s%3N)" '.written_at = $at' "$FIX/$fx/status.json" >"$RUN/status.json"
  rm -f "$7"
  local rm=(); ((reduced)) && rm=(OMARCHY_REDUCED_MOTION=1)
  env -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl \
    "${rm[@]}" \
    EGPU_RUN="$RUN" OMARCHY_EGPU_DEV_BIN="$panel/dev/bin" OMARCHY_EGPU_DEV_FIXTURE="$fx" OMARCHY_EGPU_DEV_FIXTURES="$FIX" \
    UI_RENDER_ROUTE=$2 UI_RENDER_MODE=$3 UI_RENDER_HOST=$4 UI_RENDER_ADV=$5 UI_RENDER_ZONE=$6 UI_RENDER_OUT=$7 \
    timeout 60 quickshell -p "$root/qs" -n >"$log" 2>&1
  sed 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^.*RENDER //p'
  sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'TypeError|ReferenceError|is not a function|Unable to assign|WARN scene|ERROR' | grep -v 'Could not\|portal' | head -5 | sed 's/^/  ! /'
  [[ -s $7 ]]
}

if [[ -n $all ]]; then
  mkdir -p "$all"
  status=0
  # name | fixture | route | extra: every state the fixtures cover. "main" is the notch's compact page (the
  # standalone popup has none: its root is the Overview).
  while IFS='|' read -r name fx r extra; do
    [[ -n $name ]] || continue
    a=0; z=0
    [[ $extra == *adv* ]] && a=1
    [[ $extra == *zone* ]] && z=1
    for spec in "hosted black" "hosted white" "standalone black"; do
      read -r m h <<<"$spec"
      label=$m; [[ $m == hosted ]] && label=$m-$h
      [[ $m == standalone && $r == main ]] && continue
      render "$fx" "$r" "$m" "$h" "$a" "$z" "$all/$name-$label.png" || { echo "render: $name $label FAILED" >&2; status=1; }
    done
  done <<'STATES'
no-egpu-compact|absent|main|zone
no-egpu|absent|overview
no-port-compact|stranger-no-tb|main|zone
first-run-setup|stranger-no-tb|setup
connecting|plugged-unauthorized|overview
connected-compact|ready|main|zone
connected|ready|overview
in-use|in-use-procs|overview
in-use-hdmi-compact|ready-hdmi|main
busy-ejecting-compact|ejecting|main
busy-ejecting|ejecting|overview
ejected|ejected-clean|overview
attention|this-machine|overview
error|smi-hung|overview
error-setup|auth-error|overview
details|in-use-procs|details
setup-problems|this-machine|setup
setup-ready|ready|setup
setup-advanced|ready|setup|adv
eject-holders|in-use-procs|eject
eject-done|ready|eject
eject-failed|ready-hdmi|eject
held-ejected|ejected-held|overview
held-no-card|held-no-device|overview
eject-in-use|eject-in-use|eject
eject-in-use-session|eject-in-use-session|eject
eject-in-use-close|eject-in-use-closeable|eject
eject-in-use-shared|eject-in-use-shared|eject
eject-in-use-screens|eject-in-use-screens|eject
eject-modules-held|eject-modules-held|eject
eject-unloaded|eject-unloaded|eject
eject-hung-screens|eject-hung-screens|eject
STATES
  exit $status
fi

[[ -n $out ]] || { echo "render: --out <png> or --all <dir> is required" >&2; exit 2; }
render "$fixture" "$route" "$mode" "$host" "$adv" "$zone" "$out"
