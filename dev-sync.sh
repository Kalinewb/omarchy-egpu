#!/bin/bash

# Sync this working tree into the live plugin directory.
#
# Development cannot happen in ~/.config/omarchy/plugins: that tree is watched
# recursively, and every write there triggers a GLOBAL shell reload — every
# panel, service and bar widget torn down and re-mounted. Editing in place makes
# the desktop flicker continuously, and running git there is worse, because
# .git churns on every command. So the repo lives outside it and this pushes a
# copy in: one write burst, one reload, instead of one per keystroke
# (profiles:dev-sync.sh:3-12).
#
#   ./dev-sync.sh               lint, validate a staging copy, install, restart the shell
#   ./dev-sync.sh --no-restart  install only (non-entry QML will render stale)
#   ./dev-sync.sh --dev         restart the shell with the stub engine (dev/bin)
#                               answering from dev/fixtures/$OMARCHY_EGPU_DEV_FIXTURE
#                               (default "ready"; a comma list steps through them)
#                               instead of the real engine (plan-gui.md §9)
#
# It installs nothing outside the plugin folder. The root half (helper, polkit
# action, udev rule) is installed from a terminal by system/install.sh (E7),
# never from here.

set -euo pipefail

ID="kalinewb.egpu"
PLUGINS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
DEST="$PLUGINS/$ID"
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}

# A QML error in a third-party plugin reaches no journal: the plugin just fails
# to appear in the bar. Catch it here rather than from a screenshot.
"$SRC/dev/lint.sh" || exit 1
"$SRC/dev/lint-qml.sh" || exit 1

# Validate a staging copy BEFORE anything lands in the watched folder:
# validating $DEST afterwards is validating the damage (face:install.sh:37-41).
# A dot-named directory is ignored by the plugin watcher, so building it costs
# no reload.
mkdir -p "$PLUGINS"
STAGE=$(mktemp -d "$PLUGINS/.$ID.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# Only what the plugin runs. dev/ (the stub engine and its fixtures) stays in
# the repo and is reached through $OMARCHY_EGPU_DEV_BIN; tests/ and docs/ are
# the repo's. --delete-excluded below, not bare --exclude: a bare exclude also
# protects a stale dev/ at the destination from --delete (face:install.sh:46-52).
RSYNC_EXCLUDES=(--exclude '.git' --exclude 'dev-sync.sh' --exclude 'dev' --exclude 'tests'
                --exclude 'docs' --exclude '*.bak' --exclude '*.bak.*')

rsync -a "${RSYNC_EXCLUDES[@]}" "$SRC/" "$STAGE/"
chmod +x "$STAGE/bin/omarchy-egpu"

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$STAGE" || { echo "dev-sync.sh: plugin failed validation" >&2; exit 1; }
fi

mkdir -p "$DEST"
rsync -a --delete --delete-excluded "${RSYNC_EXCLUDES[@]}" "$STAGE/" "$DEST/"
rm -rf "$STAGE"
trap - EXIT
echo "installed $ID -> $DEST"

if [[ $MODE == --no-restart ]]; then
  echo "(shell not restarted — edits to any .qml but the entry points will render stale)"
  exit 0
fi

command -v omarchy >/dev/null || exit 0

if [[ $MODE == --dev ]]; then
  # The shell is spawned by Hyprland and inherits Hyprland's environment, not
  # this terminal's. To give it variables for one session, stop it the way the
  # restart script does and ask Hyprland to exec the launcher with them in
  # front (face:install.sh:77-110).
  FIXTURE=${OMARCHY_EGPU_DEV_FIXTURE:-ready}
  SHELL_PATH=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
  : "${SHELL_PATH:=${OMARCHY_PATH:-}}"
  [[ -f $SHELL_PATH/shell/shell.qml ]] || {
    echo "dev-sync.sh: Omarchy shell config not found: ${SHELL_PATH:-<unset>}/shell" >&2
    exit 1
  }

  # Never restart a shell that is holding the lock screen: killing a live
  # locker strands the session behind Hyprland's failsafe.
  if command -v omarchy-hyprland-session-locked >/dev/null && omarchy-hyprland-session-locked; then
    echo "dev-sync.sh: refusing while the session is locked" >&2
    exit 1
  fi

  # EGPU_RUN points the stub's status.json away from the real watcher's, so a
  # development session can never be mistaken for the hardware.
  RUN_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/omarchy-egpu-dev"
  echo "restarting the shell with OMARCHY_EGPU_DEV_BIN=$SRC/dev/bin (fixture: $FIXTURE)"
  while timeout 5 quickshell kill -p "$SHELL_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  hyprctl dispatch "hl.dsp.exec_cmd(\"env OMARCHY_EGPU_DEV_BIN=$SRC/dev/bin OMARCHY_EGPU_DEV_FIXTURE=$FIXTURE EGPU_RUN=$RUN_DIR omarchy-launch-shell\")" >/dev/null

  # Only claim the restart worked when the new shell answers.
  for _ in $(seq 1 40); do
    if omarchy-shell shell ping >/dev/null 2>&1; then
      echo "shell restarted in development mode"
      exit 0
    fi
    sleep 0.25
  done
  echo "dev-sync.sh: the shell did not answer within 10 s of the restart" >&2
  exit 1
fi

# The watcher reload re-instantiates the entry points but does not recompile
# the other QML types in the folder (views/, common/), which then render stale
# (profiles:dev-sync.sh:35-44). A restart is one blip and always tells the truth.
omarchy restart shell >/dev/null 2>&1 && echo "restarted the shell"
