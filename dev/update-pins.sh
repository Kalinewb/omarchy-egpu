#!/bin/bash
#
# Rewrite the SHA-256 pins in system/install.sh from the files they describe,
# then system/install.sh.sha256 and the install command in README.md. Run
# after changing anything root installs (the helper, the policy, the udev rule
# template, the modules-load mask); commit the pins with the files.
#
# The pins are what make installing from a user-writable plugin folder safe:
# root installs only a snapshot whose bytes hash to these values, and the pins
# are part of the installer text whose own checksum the install command
# fetches from the release tag (plan-engine.md §10.4, as omarchy-face does).
#
# The file list is install.sh's own SYSTEM_FILES, so the two cannot disagree.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

read -r -a names <<<"$(sed -n 's/^SYSTEM_FILES=(\(.*\))$/\1/p' system/install.sh)"
((${#names[@]} > 0)) || { echo "update-pins: no SYSTEM_FILES line in system/install.sh" >&2; exit 1; }

block="declare -A PINS=("$'\n'
for name in "${names[@]}"; do
  [[ -f system/$name ]] || { echo "update-pins: system/$name is missing" >&2; exit 1; }
  block+="  [$name]=$(sha256sum -- "system/$name" | cut -d' ' -f1)"$'\n'
done
block+=")"

python3 - "$block" <<'PY'
import re, sys
block = sys.argv[1]
p = "system/install.sh"
s = open(p).read()
new, n = re.subn(r"(# pins:begin\n).*?(\n# pins:end)", lambda m: m.group(1) + block + m.group(2), s, flags=re.S)
if n != 1:
    sys.exit("update-pins: pins markers not found exactly once in system/install.sh")
open(p, "w").write(new)
PY

# After the pins, because the pins are part of the installer.
installer=$(sha256sum -- system/install.sh | cut -d' ' -f1)
printf '%s\n' "$installer" >system/install.sh.sha256

# The README's command is generated, never typed: it is what a careful reader
# compares the copied command against.
command=$(bash system/install.sh --print-command install)
python3 - "$command" <<'PY'
import re, sys
command = sys.argv[1]
p = "README.md"
s = open(p).read()
new, n = re.subn(r"(### Installing or updating the system half\n.*?```bash\n).*?(\n```)",
                 lambda m: m.group(1) + command + m.group(2), s, flags=re.S)
if n != 1:
    sys.exit("update-pins: the install command block was not found exactly once in README.md")
open(p, "w").write(new)
PY

echo "pins updated for ${#names[@]} files; installer checksum $installer -> system/install.sh.sha256"
echo "install command regenerated into README.md"
