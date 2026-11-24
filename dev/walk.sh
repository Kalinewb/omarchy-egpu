#!/bin/bash

# The consistency walk (dev/harness/ui-walk.qml) on one root, in one mode.
#
#   ./dev/walk.sh [--root dev/gallery.qml] [--mode standalone|hosted|styled] [--host black|white] [--reduced] [--theme current]
#
# Prints the `WALK` lines and exits 1 if any check failed. Used by check-ui.sh.
#
# The root may use types from the repo's other folders (views/, common/, a singleton with a
# qmldir): Quickshell builds a qmldir only for the folders its shell file imports, so a root
# loaded at run time otherwise fails with "X is not a type". The temp shell file is made with
# one `import "repo/<dir>" as DirN` per folder of the repo that holds a QML type (a file named
# with a capital: Qt cannot import a folder of lowercase-named files, so those are left out;
# ui/, dev/, docs/, upstream/, node_modules and dot-folders too), plus the folder of --root itself
# when it holds one; the import is only there so the folder is scanned, the names it brings are
# not used.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SHELL_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

rootfile=dev/gallery.qml; mode=standalone; host=black; reduced=0; theme=current
while (($#)); do
  case $1 in
    --root) rootfile=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --host) host=$2; shift 2 ;;
    --theme) theme=$2; shift 2 ;;
    --reduced) reduced=1; shift ;;
    *) echo "walk: unknown argument $1" >&2; exit 2 ;;
  esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-ui-walk.XXXXXX")
trap 'rm -rf "$work"' EXIT
ln -s "$SHELL_PATH/shell/Commons" "$work/Commons"
ln -s "$SHELL_PATH/shell/Ui" "$work/Ui"
ln -s "$REPO" "$work/repo"
cp "$REPO/dev/harness/walk.js" "$work/"

imports=""; n=0
while IFS= read -r d; do
  [[ $d =~ ^[A-Za-z0-9_./-]+$ ]] || continue          # a folder name that is not safe in a QML string is skipped
  [[ $d == . ]] && target=repo || target=repo/${d#./}
  imports+="import \"$target\" as Dir$n"$'\n'; n=$((n + 1))
done < <({ (cd "$REPO" && find . -name '[A-Z]*.qml' -not -path './ui/*' -not -path './dev/*' -not -path './docs/*' -not -path '*/upstream/*' -not -path '*/node_modules/*' -not -path '*/.*/*' -printf '%h\n')
           rd=$(dirname -- "./${rootfile#./}"); compgen -G "$REPO/$rd/[A-Z]*.qml" >/dev/null && echo "$rd"; } | sort -u)
awk -v imports="$imports" '{ print } /^import "repo\/ui"$/ { printf "%s", imports }' "$REPO/dev/harness/ui-walk.qml" >"$work/shell.qml"

UI_WALK_ROOT=$rootfile UI_WALK_MODE=$mode UI_WALK_HOST=$host UI_WALK_THEME=$theme UI_WALK_REDUCED=$reduced \
  QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
  timeout 60 quickshell -p "$work" -n >"$work/log" 2>&1
sed 's/\x1b\[[0-9;]*m//g' "$work/log" | sed -n 's/^.*WALK //p'
sed 's/\x1b\[[0-9;]*m//g' "$work/log" | grep -E 'WARN scene|WARN qml|ERROR|ui: ' | head -10 | sed 's/^/  ! /'
sed 's/\x1b\[[0-9;]*m//g' "$work/log" | grep -q '^ *DEBUG qml: WALK done failures=0$'
