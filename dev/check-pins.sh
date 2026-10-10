#!/bin/bash
#
# Is the root half consistent and releasable? A stale pin weakens nothing --
# root refuses the install -- but it breaks installing for everyone on that
# commit, so it is caught here (gate E7, plan-engine.md §12). Checks:
#
#   - every SYSTEM_FILES entry in system/install.sh has a pin, and the pin is
#     the file's SHA-256; nothing else is pinned
#   - system/install.sh.sha256 is system/install.sh's checksum
#   - one version everywhere: manifest.json, install.sh's VERSION, the
#     helper's VERSION, and the version header of every installed file (the
#     engine refuses a helper whose version differs from the plugin's, §1.1)
#   - install.sh's boot-load mask list is the helper's module allowlist
#   - README.md's install command is the one install.sh prints
#   - if the version is tagged, the tag serves a pin that matches its own
#     installer and this tree's

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

bad=0
fail() { echo "check-pins: $*" >&2; bad=1; }

read -r -a names <<<"$(sed -n 's/^SYSTEM_FILES=(\(.*\))$/\1/p' system/install.sh)"
((${#names[@]} > 0)) || fail "no SYSTEM_FILES line in system/install.sh"

declare -A pin=()
while read -r name sum; do
  [[ -n $name ]] && pin[$name]=$sum
done < <(sed -n '/^# pins:begin$/,/^# pins:end$/p' system/install.sh |
  sed -n 's/^[[:space:]]*\[\([^]]*\)\]=\([0-9a-f]*\)$/\1 \2/p')

for name in "${names[@]}"; do
  if [[ -z ${pin[$name]:-} ]]; then
    fail "system/$name has no pin"
    continue
  fi
  got=$(sha256sum -- "system/$name" 2>/dev/null | cut -d' ' -f1)
  [[ $got == "${pin[$name]}" ]] || fail "system/$name does not match its pin"
  unset "pin[$name]"
done
for extra in "${!pin[@]}"; do fail "$extra is pinned but not in SYSTEM_FILES"; done

installer=$(sha256sum -- system/install.sh | cut -d' ' -f1)
if [[ ! -f system/install.sh.sha256 ]]; then
  fail "system/install.sh.sha256 is missing"
elif [[ $(cat system/install.sh.sha256) != "$installer" ]]; then
  fail "system/install.sh.sha256 is not system/install.sh's checksum"
fi

manifest=$(jq -r '.version // empty' manifest.json 2>/dev/null)
inst_v=$(sed -n 's/^VERSION=\([0-9A-Za-z.+-]*\)$/\1/p' system/install.sh)
helper_v=$(sed -n 's/^VERSION=\([0-9A-Za-z.+-]*\)$/\1/p' system/omarchy-egpu-admin)
[[ -n $manifest ]] || fail "no version in manifest.json"
[[ $inst_v == "$manifest" ]] || fail "system/install.sh VERSION is '$inst_v', manifest.json says '$manifest'"
[[ $helper_v == "$manifest" ]] || fail "system/omarchy-egpu-admin VERSION is '$helper_v', manifest.json says '$manifest'"
for name in install.sh "${names[@]}"; do
  header=$(head -n 8 "system/$name" | sed -n 's/^[^[:alnum:]]*omarchy-egpu-version:[[:space:]]*\([0-9A-Za-z.+-]*\).*/\1/p' | head -n1)
  [[ $header == "$manifest" ]] || fail "system/$name has version header '$header', manifest.json says '$manifest'"
done

mask=$(sed -n 's/^MASK_MODULES=(\(.*\))$/\1/p' system/install.sh)
allow=$(sed -n '/^backend_select()/,/^}/p' system/omarchy-egpu-admin | sed -n 's/^[[:space:]]*MODULES=(\(.*\))$/\1/p' | head -n1)
[[ -n $mask && $mask == "$allow" ]] || fail "install.sh MASK_MODULES ($mask) is not the helper's allowlist ($allow)"

command=$(bash system/install.sh --print-command install 2>/dev/null)
readme=$(sed -n '/^### Installing or updating the system half$/,/^```$/p' README.md |
  sed -n '/^```bash$/,/^```$/p' | sed '1d;$d')
if [[ -z $command || -z $readme ]]; then
  fail "the install command is empty in install.sh --print-command or in README.md"
elif [[ $command != "$readme" ]]; then
  fail "README.md's install command is not the one install.sh prints"
fi

# A release the command's URL cannot reach installs for nobody. A note while
# the version is untagged; an error once the tag exists and disagrees.
if [[ -n $manifest ]]; then
  if ! git rev-parse -q --verify "refs/tags/v$manifest" >/dev/null 2>&1; then
    echo "check-pins: note - v$manifest is not tagged yet; the install command's checksum URL 404s until it is" >&2
  else
    tagged_pin=$(git show "v$manifest:system/install.sh.sha256" 2>/dev/null)
    tagged_installer=$(git show "v$manifest:system/install.sh" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [[ -z $tagged_pin ]]; then
      fail "tag v$manifest carries no system/install.sh.sha256"
    elif [[ $tagged_pin != "$tagged_installer" ]]; then
      fail "tag v$manifest serves a pin that is not its own system/install.sh"
    elif [[ $tagged_pin != "$installer" ]]; then
      fail "system/install.sh changed since v$manifest was tagged - bump the version"
    fi
  fi
fi

if ((bad)); then
  echo "check-pins: run dev/update-pins.sh" >&2
  exit 1
fi
echo "check-pins: ok - ${#names[@]} files, the installer checksum, version $manifest and the README command match"
