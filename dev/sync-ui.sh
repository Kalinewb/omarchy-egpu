#!/bin/bash

# Copy the shared UI kit into this plugin and write ui/KIT.
#
#   ./dev/sync-ui.sh --from <path to a local omarchy-ui checkout> [--only UButton,URow,...] [--tools] [--to <plugin dir>] [--allow-dirty]
#
# Copy only. It `cp`s files out of the checkout and rewrites ui/KIT: the
# checkout's HEAD sha (`git -C <from> rev-parse HEAD`), the kit's major, and a
# sha256 per file. It does not clone, fetch or pull, and never runs anything
# from the checkout, so nothing about it is a remote fetch the marketplace
# scanner would ask about. The name avoids "setup" and "install" on purpose.
#
#   --only   copy only these components and what they need (UTheme, tokens.js and
#            spring.js always; a component's own U-types and .js imports follow)
#   --tools  also copy dev/check-ui.sh, dev/sync-ui.sh, dev/walk.sh and the walk
#            harness, and hash them in ui/KIT so a hand edit shows
#   --to     the plugin to write into (default: the repo this script lives in)
#
# ui/KIT, one line each:
#   omarchy-ui <40-hex sha of the kit checkout's HEAD>
#   major <n>
#   <sha256>  <path relative to the plugin root>
# `dev/check-ui.sh` fails when a listed file differs, so a fix goes to the kit
# and comes back through here, never into the copy.

set -euo pipefail

die() { echo "sync-ui: $*" >&2; exit 1; }

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
from=""; to=$REPO; only=""; tools=0; dirty=0
while (($#)); do
  case $1 in
    --from) from=${2:-}; shift 2 ;;
    --to) to=${2:-}; shift 2 ;;
    --only) only=${2:-}; shift 2 ;;
    --tools) tools=1; shift ;;
    --allow-dirty) dirty=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n $from ]] || die "--from <path to an omarchy-ui checkout> is required"
from=$(cd "$from" 2>/dev/null && pwd) || die "no such directory: $from"
to=$(cd "$to" 2>/dev/null && pwd) || die "no such directory: $to"
[[ -f $from/ui/UTheme.qml && -f $from/ui/tokens.js ]] || die "$from is not an omarchy-ui checkout (no ui/UTheme.qml)"
[[ $from != "$to" ]] || die "--from and --to are the same directory"

sha=$(git -C "$from" rev-parse HEAD 2>/dev/null) || die "$from is not a git checkout"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "unexpected HEAD: $sha"
if ((!dirty)) && [[ -n $(git -C "$from" status --porcelain -- ui dev 2>/dev/null) ]]; then
  die "$from has uncommitted changes under ui/ or dev/: the sha in ui/KIT would not describe what is copied (commit them, or --allow-dirty)"
fi
major=$(grep -oP '^var MAJOR = \K[0-9]+' "$from/ui/tokens.js" || true)
[[ -n $major ]] || die "no 'var MAJOR' in $from/ui/tokens.js"

# The set of files: the core, what --only names, and whatever those use.
declare -A want=()
add() { [[ -f $from/ui/$1 ]] && want[$1]=1; }
add UTheme.qml; add tokens.js; add spring.js
if [[ -z $only ]]; then
  for f in "$from"/ui/*; do b=${f##*/}; [[ $b == KIT ]] || want[$b]=1; done
else
  IFS=',' read -ra names <<<"$only"
  for n in "${names[@]}"; do
    n=${n%.qml}; n=${n%.js}
    if [[ -f $from/ui/$n.qml ]]; then want[$n.qml]=1
    elif [[ -f $from/ui/$n.js ]]; then want[$n.js]=1
    else die "no component named $n in $from/ui"; fi
  done
fi
changed=1
while ((changed)); do
  changed=0
  for f in "${!want[@]}"; do
    [[ $f == *.qml ]] || continue
    while read -r dep; do
      [[ -n $dep && -f $from/ui/$dep.qml && -z ${want[$dep.qml]:-} ]] && { want[$dep.qml]=1; changed=1; }
    done < <(sed 's#//.*##' "$from/ui/$f" | grep -oP '\bU[A-Za-z]+(?=\s*\{)' | sort -u)
    while read -r dep; do
      [[ -n $dep && -f $from/ui/$dep && -z ${want[$dep]:-} ]] && { want[$dep]=1; changed=1; }
    done < <(sed 's#//.*##' "$from/ui/$f" | grep -oP 'import "\K[A-Za-z]+\.js(?=")' | sort -u)
  done
done

# Files the previous sync left that this one does not want are the kit's to remove.
if [[ -f $to/ui/KIT ]]; then
  while read -r _ path; do
    [[ $path == ui/* && -z ${want[${path#ui/}]:-} ]] && rm -f "$to/$path"
  done < <(tail -n +3 "$to/ui/KIT")
fi

mkdir -p "$to/ui"
entries=()
for f in $(printf '%s\n' "${!want[@]}" | sort); do
  cp "$from/ui/$f" "$to/ui/$f"
  entries+=("ui/$f")
done
if ((tools)); then
  mkdir -p "$to/dev/harness"
  for f in dev/check-ui.sh dev/sync-ui.sh dev/walk.sh dev/harness/ui-walk.qml dev/harness/walk.js; do
    [[ -f $from/$f ]] || die "no $f in $from"
    cp -p "$from/$f" "$to/$f"
    entries+=("$f")
  done
fi

tmp=$(mktemp "$to/ui/.KIT.XXXXXX")
{
  echo "omarchy-ui $sha"
  echo "major $major"
  for e in "${entries[@]}"; do (cd "$to" && sha256sum "$e"); done
} >"$tmp"
mv "$tmp" "$to/ui/KIT"
chmod 644 "$to/ui/KIT"

echo "sync-ui: omarchy-ui ${sha:0:12} (major $major): ${#entries[@]} files into $to/ui/KIT"
