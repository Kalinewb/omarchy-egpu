#!/bin/bash -p
#
# omarchy-egpu system half
# omarchy-egpu-version: 0.1.0
#
# Installs, reinstalls or removes the root half of omarchy-egpu (plan-engine.md
# §10.4), the only way root ever receives files from the plugin folder:
#
#   /usr/local/bin/omarchy-egpu-admin                    the root helper
#   /usr/share/polkit-1/actions/no.kalinewb.egpu.policy  its polkit actions
#   /etc/udev/rules.d/61-omarchy-egpu.rules              links + auto-connect
#   /etc/modules-load.d/<shipped name>                   boot-load mask (§9.2)
#   /etc/omarchy-egpu/                                   the flag's directory
#   /etc/omarchy-egpu/autoconnect                        the auto-connect flag
#
# `omarchy plugin add` never runs plugin code or sudo, so this is run from a
# terminal afterwards, by the command `install.sh --print-command` prints
# (README.md, "System half"). That command fetches system/install.sh.sha256
# from this release's tag on GitHub -- the trust anchor, the one thing not read
# from the plugin folder -- copies this file into a directory only root can
# write, checks the copy against the fetched checksum and only then runs it:
#
#   /usr/bin/bash -p <root-only copy> --expect-sha256 <fetched> install "$PLUGIN_DIR" "$USER"
#
# (bash -p, as the first line here asks: no function imported from the
# environment, no BASH_ENV read; both would happen before line 1 runs.)
#
# The plugin folder is writable by the account and by anything running as it,
# so nothing about it is trusted. This script refuses to run as root from
# anywhere but such a copy (bash reads a script while it runs it), checks its
# own bytes against --expect-sha256, copies every file it installs into a
# root-only snapshot under /run, checks each copied byte against a SHA-256
# pinned below in this authorised text, and installs only from the snapshot.
# The udev rule is a template; the boot VGA address is filled into the
# snapshot copy after its pin is checked, from a value that must match the PCI
# address regex. dev/update-pins.sh writes the pins and install.sh.sha256,
# and dev/check-pins.sh refuses stale ones.
#
# Every /etc file replaced or removed is first saved under
# /var/backups/omarchy-egpu/<UTC>/ and recorded in /var/lib/omarchy-egpu/installed;
# `uninstall` removes what was installed and puts those files back.
#
# Everything that can refuse (the plugin folder, the snapshot and its pins,
# the primary GPU, the rule) is checked before anything is changed, so a
# refused install or reinstall leaves the machine as it was: a reinstall never
# uninstalls first and fails after, which would drop the boot-load mask.
#
# Usage:
#   install.sh [options] install|reinstall PLUGIN_DIR ACCOUNT
#   install.sh [options] uninstall
#   install.sh --print-command [install|reinstall|uninstall]   (no root needed)
# Options:
#   --expect-sha256 HEX   this file's checksum, as fetched by the command
#   --autoconnect on|off  the udev auto-connect flag. Default: on for a first
#                         install (scope.md DECISION 2026-10-10); later
#                         installs keep what the user chose in the panel
#   --primary BDF         the primary GPU's PCI address, if boot_vga cannot tell
#   --yes                 answer yes to the stale-mask question (§9.2)
#   --root DIR            test seam: install under DIR instead of /, may run
#                         unprivileged, and runs no udevadm and no logger. As
#                         root only with OMARCHY_EGPU_INSTALL_TEST=1: it skips
#                         the root-copy check
#
# Output: prose on stderr, one JSON document on stdout. Exit 0 ok, 1 refused
# or failed ({"error":code}), 3 busy (another install holds the lock).

# Under bash -p, as the printed command runs it, no shell function is
# imported. Run otherwise (the tests), drop any that were. That is best effort
# only, since an imported function can shadow the very builtins this loop
# uses; it is why the command uses -p (and sudo strips BASH_FUNC_* as well).
while IFS= read -r _f; do
  [[ -n $_f ]] && unset -f -- "$_f"
done <<<"$(compgen -A function)"
unset _f
set -uo pipefail
unset IFS BASH_ENV ENV CDPATH GLOBIGNORE
shopt -u expand_aliases
shopt -s nullglob
umask 022
export LC_ALL=C

VERSION=0.1.0
RAW_URL=https://raw.githubusercontent.com/Kalinewb/omarchy-egpu
PLUGIN_ID=kalinewb.egpu
BDF_RE='^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$'

# The files root installs, by their name in system/. Each must hash to its pin
# below; there is no other list, so a name missing here is never copied.
SYSTEM_FILES=(omarchy-egpu-admin no.kalinewb.egpu.policy 61-omarchy-egpu.rules omarchy-egpu-modules.conf)

# pins:begin
declare -A PINS=(
  [omarchy-egpu-admin]=997627524c10ed790ee25865defcb89745fe9ba8c431b432d5b3f4cd4e4284fd
  [no.kalinewb.egpu.policy]=f6a9b4fdcfdf0c1fda682179add22bcfddb55751e76f5006e55847e8e7864e08
  [61-omarchy-egpu.rules]=2cbed591334bad87ed3ce0656756ef1660b0fd67b2321be26feee0a896e2899f
  [omarchy-egpu-modules.conf]=320dd82349c86f8727806b0b27ce8439568dd9b61c85db48365ee79233684704
)
# pins:end

# The modules a shipped modules-load.d file may not load at boot: the helper's
# allowlist (system/omarchy-egpu-admin, backend_select). dev/check-pins.sh
# checks that the two lists agree.
MASK_MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)

# An empty /etc mask named after a package that no longer ships the file masks
# nothing (nvidia-utils.conf after the move to nvidia-580xx-utils, §9.2). Only
# names of this shape are ever offered for removal.
STALE_RE='^nvidia[a-z0-9-]*-utils\.conf$'

# ---------------------------------------------------------------- output

say() { printf '%s\n' "$*" >&2; }

json_string() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  # Under LC_ALL=C, [:print:] is printable ASCII: control bytes and any
  # non-UTF-8 byte (a process name can hold anything) cannot break the JSON.
  v=${v//[^[:print:]]/?}
  printf '"%s"' "$v"
}

json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    ((first)) || printf ','
    first=0
    json_string "$item"
  done
  printf ']'
}

die() { # die <code> [prose]
  [[ -n ${2:-} ]] && say "install.sh: $2"
  printf '{"error":%s}\n' "$(json_string "$1")"
  exit "${3:-1}"
}

# ---------------------------------------------------------------- arguments

SELF=${BASH_SOURCE[0]}
R=''
ROOT_GIVEN=0
# Never from the environment: it decides who may own the directories root
# installs into.
OWNER_UID=''
EXPECT=''
AUTOCONNECT=''
PRIMARY=''
YES=0
PRINT=''
while (($#)); do
  case $1 in
    --expect-sha256) EXPECT=${2:-}; shift 2 || die bad_arguments ;;
    --autoconnect) AUTOCONNECT=${2:-}; shift 2 || die bad_arguments ;;
    --primary) PRIMARY=${2:-}; shift 2 || die bad_arguments ;;
    --yes) YES=1; shift ;;
    --root) R=${2:-}; ROOT_GIVEN=1; shift 2 || die bad_arguments ;;
    --print-command) PRINT=${2:-install}; shift; (($#)) && shift ;;
    --) shift; break ;;
    -*) die bad_arguments "unknown option $1" ;;
    *) break ;;
  esac
done

# The command for README.md and the panel: fetch the pin, copy this file
# somewhere only root can write, check the copy, run the copy. One line, so it
# pastes into any shell; $USER and $HOME are expanded by the user's shell.
# Root's part names every tool by its absolute path under PATH=/usr/bin, so
# nothing the user's environment or shell puts first is ever run as root.
if [[ -n $PRINT ]]; then
  [[ $PRINT =~ ^(install|reinstall|uninstall)$ ]] || die bad_arguments
  # shellcheck disable=SC2016  # printed for the user's shell to expand
  args=' "$1" "$3"'
  [[ $PRINT == uninstall ]] && args=''
  # shellcheck disable=SC2016
  printf '%s\n' 'd="$HOME/.config/omarchy/plugins/'"$PLUGIN_ID"'" && sum=$(curl -fsSL '"$RAW_URL"'/v'"$VERSION"'/system/install.sh.sha256) && sudo /usr/bin/bash -c '\''PATH=/usr/bin; t=$(/usr/bin/mktemp -d /run/omarchy-egpu-installer.XXXXXX) && /usr/bin/cp -- "$1/system/install.sh" "$t/install.sh" && printf "%s  %s\n" "$2" "$t/install.sh" | /usr/bin/sha256sum -c --quiet - && /usr/bin/bash -p "$t/install.sh" --expect-sha256 "$2" '"$PRINT$args"'; s=$?; /usr/bin/rm -rf -- "$t"; exit $s'\'' omarchy-egpu "$d" "$sum" "$USER"'
  exit 0
fi

MODE=${1:-}
case $MODE in
  install | reinstall)
    (($# == 3)) || die bad_arguments "usage: install.sh [options] $MODE PLUGIN_DIR ACCOUNT"
    PLUGIN_DIR=$2 ACCOUNT=$3
    ;;
  uninstall)
    (($# == 1)) || die bad_arguments "usage: install.sh [options] uninstall"
    PLUGIN_DIR='' ACCOUNT=''
    ;;
  *) die bad_arguments "usage: install.sh [options] install|reinstall PLUGIN_DIR ACCOUNT | uninstall" ;;
esac
[[ -z $AUTOCONNECT || $AUTOCONNECT == on || $AUTOCONNECT == off ]] || die bad_arguments "--autoconnect takes on or off"
[[ -z $PRIMARY || $PRIMARY =~ $BDF_RE ]] || die bad_arguments "--primary takes a PCI address like 0000:00:02.0"

# ---------------------------------------------------------------- who and where

if ((ROOT_GIVEN)); then
  # --root skips the root-copy check below, so as root it would install from
  # the plugin folder unchecked (`--root /`). Only the tests may.
  ((EUID != 0)) || [[ ${OMARCHY_EGPU_INSTALL_TEST:-} == 1 ]] ||
    die test_root_as_root "--root is a test seam; as root it needs OMARCHY_EGPU_INSTALL_TEST=1"
  [[ $R == /* && $R != *..* && -d $R && ! -L $R ]] || die bad_arguments "--root needs an existing absolute directory"
  R=${R%/}
  ((EUID == 0)) || OWNER_UID=$EUID
else
  ((EUID == 0)) || die not_root "run it with sudo, using the command from install.sh --print-command"
fi
# Files root installs belong to root; in an unprivileged --root run, to us.
OWNER_UID=${OWNER_UID:-0}

if ((EUID == 0)); then
  PATH=/usr/bin
  cd / || exit 1
fi

# As root, only from a root-only copy: bash reads a script as it runs it, so
# running the plugin folder's file would run whatever is written there next.
if ((EUID == 0 && !ROOT_GIVEN)); then
  self_dir=$(dirname -- "$SELF")
  [[ $self_dir =~ ^/(run|tmp)/[A-Za-z0-9._-]+$ && ! -L $self_dir && ! -L $SELF ]] ||
    die not_a_root_copy "run this from a root-only copy, as the command from --print-command does"
  [[ $(stat -c '%u %a' -- "$self_dir" 2>/dev/null) == "0 700" ]] || die not_a_root_copy "$self_dir is not root's own 0700 directory"
  [[ $(stat -c '%u' -- "$SELF" 2>/dev/null) == 0 ]] || die not_a_root_copy "$SELF is not owned by root"
  [[ -n $EXPECT ]] || die no_expected_checksum "pass --expect-sha256 with the checksum fetched from the release tag"
fi
if [[ -n $EXPECT ]]; then
  [[ $EXPECT =~ ^[0-9a-f]{64}$ ]] || die bad_arguments "--expect-sha256 takes 64 hex digits"
  got=$(sha256sum -- "$SELF" 2>/dev/null) || die self_check_failed
  [[ ${got%% *} == "$EXPECT" ]] || die self_check_failed "this installer is not the one the checksum describes"
fi

BIN_DIR=$R/usr/local/bin
HELPER=$BIN_DIR/omarchy-egpu-admin
POLICY_DIR=$R/usr/share/polkit-1/actions
POLICY=$POLICY_DIR/no.kalinewb.egpu.policy
RULES_DIR=$R/etc/udev/rules.d
RULES=$RULES_DIR/61-omarchy-egpu.rules
MLD_ETC=$R/etc/modules-load.d
# Where else systemd-modules-load reads, by precedence after /etc: one file
# per name, the first found wins (modules-load.d(5)).
MLD_OTHERS=("$R/run/modules-load.d" "$R/usr/local/lib/modules-load.d" "$R/usr/lib/modules-load.d")
CONF_DIR=$R/etc/omarchy-egpu
FLAG=$CONF_DIR/autoconnect
STATE_DIR=$R/var/lib/omarchy-egpu
RECORD=$STATE_DIR/installed
BACKUP_ROOT=$R/var/backups/omarchy-egpu
PCI=$R/sys/bus/pci/devices

# Children never get the install lock (fd 8): one left behind would hold it.
audit() {
  ((ROOT_GIVEN)) && return 0
  timeout -k 2 10 logger -t omarchy-egpu -p auth.notice -- "$*" </dev/null >/dev/null 2>&1 8>&- || true
}

# ---------------------------------------------------------------- small tools

attr() {
  local line=''
  [[ -f $1 && -r $1 ]] || return 1
  IFS= read -r line <"$1" || [[ -n $line ]] || return 1
  printf '%s' "$line"
}

sha_of() { local s; s=$(sha256sum -- "$1" 2>/dev/null) || return 1; printf '%s' "${s%% *}"; }

# A file carries our version header in its first lines.
is_ours() { [[ -f $1 && ! -L $1 ]] && head -n 8 -- "$1" 2>/dev/null | grep -q 'omarchy-egpu-version:'; }

file_version() {
  head -n 8 -- "$1" 2>/dev/null | sed -n 's/^[^[:alnum:]]*omarchy-egpu-version:[[:space:]]*\([0-9A-Za-z.+-]*\).*/\1/p' | head -n1
}

# assert_dir_safe <dir> [check]: a directory root installs into is ours
# (root's) and writable by nobody else. A missing one is created, or with
# `check` passed as missing (the preflight changes nothing).
assert_dir_safe() {
  local d=$1 info mode
  if [[ ${2:-} == check && ! -e $d && ! -L $d ]]; then
    return 0
  fi
  if [[ ! -d $d ]]; then
    install -d -m 0755 -- "$d" || die install_failed "cannot create $d"
  fi
  [[ ! -L $d ]] || die install_dir_unsafe "$d is a symlink"
  info=$(stat -Lc '%u %a' -- "$d" 2>/dev/null) || die install_dir_unsafe "$d"
  [[ ${info%% *} == "$OWNER_UID" ]] || die install_dir_unsafe "$d is not owned by root"
  mode=${info##* }
  (((8#$mode & 8#022) == 0)) || die install_dir_unsafe "$d is writable by others"
}

# ---------------------------------------------------------------- the record

# One line per thing done, tab separated:
#   file   <path>  <sha256>   a file this installed
#   backup <path>  <saved>    a file that was there before, and where it went
# Rewritten (atomically) after every change, so an install that stops half way
# still leaves a record uninstall can follow.
REC_FILES=()
REC_BACKUPS=()
record_load() {
  REC_FILES=() REC_BACKUPS=()
  [[ -f $RECORD && ! -L $RECORD ]] || return 0
  local kind a b
  while IFS=$'\t' read -r kind a b; do
    [[ -n $a && -n $b && $a == "$R"/* ]] || continue
    case $kind in
      file) REC_FILES+=("$a"$'\t'"$b") ;;
      backup) [[ $b == "$BACKUP_ROOT"/* ]] && REC_BACKUPS+=("$a"$'\t'"$b") ;;
    esac
  done <"$RECORD"
}
record_save() {
  local e tmp
  [[ -d $STATE_DIR ]] || install -d -m 0755 -- "$STATE_DIR" || die install_failed "cannot create $STATE_DIR"
  tmp=$STATE_DIR/.installed.tmp
  {
    printf '# omarchy-egpu-version: %s\n' "$VERSION"
    for e in "${REC_FILES[@]}"; do printf 'file\t%s\n' "$e"; done
    for e in "${REC_BACKUPS[@]}"; do printf 'backup\t%s\n' "$e"; done
  } >"$tmp" || die install_failed "cannot write $RECORD"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$RECORD" || die install_failed "cannot write $RECORD"
}
record_file() { # record_file <path> <sha>
  local e keep=()
  for e in "${REC_FILES[@]}"; do [[ ${e%%$'\t'*} == "$1" ]] || keep+=("$e"); done
  REC_FILES=("${keep[@]}" "$1"$'\t'"$2")
  record_save
}
record_forget() { # record_forget <path>
  local e keep=()
  for e in "${REC_FILES[@]}"; do [[ ${e%%$'\t'*} == "$1" ]] || keep+=("$e"); done
  REC_FILES=("${keep[@]}")
}

BACKUP_DIR=''
# backup <path> <move|copy>: saves the file under this run's backup dir,
# mirroring its path. Only the first backup of a path is recorded for
# uninstall to restore, because that one is the user's original; a later one
# is still saved, just not restored automatically.
backup() {
  local src=$1 how=$2 rel dest e first=1
  for e in "${REC_BACKUPS[@]}"; do [[ ${e%%$'\t'*} == "$src" ]] && first=0; done
  if [[ -z $BACKUP_DIR ]]; then
    install -d -m 0700 -- "$BACKUP_ROOT" || die backup_failed "cannot create $BACKUP_ROOT"
    BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXX") || die backup_failed "cannot create a backup folder"
  fi
  rel=${src#"$R"}
  dest=$BACKUP_DIR$rel
  install -d -m 0700 -- "$(dirname -- "$dest")" || die backup_failed "cannot create a backup of $src"
  [[ ! -e $dest && ! -L $dest ]] || die backup_failed "$dest already exists"
  cp -a --no-dereference -- "$src" "$dest" || die backup_failed "cannot back up $src"
  if ((first)); then
    REC_BACKUPS+=("$src"$'\t'"$dest")
    record_save
  fi
  if [[ $how == move ]]; then
    rm -f -- "$src" || die install_failed "cannot remove $src"
  fi
  say "  saved $rel to ${dest#"$R"}"
}

# put <snapshot file> <dest> <mode>: atomic install (beside it, then rename;
# install(1) alone unlinks and rewrites in steps), then checks the bytes that
# landed. A file that is not ours is backed up first.
INSTALLED=()
put() {
  local src=$1 dest=$2 mode=$3 want tmp
  want=$(sha_of "$src") || die install_failed "cannot read $src"
  if [[ -e $dest || -L $dest ]] && ! is_ours "$dest"; then
    backup "$dest" copy
  fi
  tmp=$(dirname -- "$dest")/.$(basename -- "$dest").omarchy-egpu-tmp
  rm -f -- "$tmp"
  if ((EUID == 0)); then
    install -o root -g root -m "$mode" -- "$src" "$tmp" || die install_failed "cannot write $tmp"
  else
    install -m "$mode" -- "$src" "$tmp" || die install_failed "cannot write $tmp"
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die install_failed "cannot install $dest"; }
  [[ $(sha_of "$dest") == "$want" ]] || die install_failed "$dest does not hold the verified bytes"
  record_file "$dest" "$want"
  INSTALLED+=("${dest#"$R"}")
  say "  installed ${dest#"$R"}"
}

# fixed_cards: the sysfs card nodes of every display device that is not
# removable (the laptop's own). EXTERNAL_CARD is set when a removable one has
# a card node too.
EXTERNAL_CARD=0
fixed_cards() {
  local d c
  EXTERNAL_CARD=0
  for d in "$PCI"/*; do
    [[ ${d##*/} =~ $BDF_RE && $(attr "$d/class") == 0x03* ]] || continue
    for c in "$d"/drm/card*; do
      [[ ${c##*/} =~ ^card[0-9]+$ ]] || continue
      if [[ $(attr "$d/removable") == removable ]]; then
        EXTERNAL_CARD=1
      else
        printf '%s\n' "$c"
      fi
    done
  done
}

# udev_reload <link note>: reload the rules, then re-run them for the laptop's
# own card nodes so the primary link appears (or goes) now, not at the next
# boot. Never for the eGPU's card: a change event on a card the compositor may
# have open is not something an installer should provoke. Its external link
# follows at its next plug-in; <link note> says so in the warnings.
udev_reload() {
  local cards=()
  ((ROOT_GIVEN)) && return 0
  timeout 30 udevadm control --reload </dev/null >/dev/null 2>&1 8>&- || WARNINGS+=("udevadm control --reload failed")
  mapfile -t cards < <(fixed_cards)
  if ((${#cards[@]})); then
    timeout 30 udevadm trigger --action=change -- "${cards[@]}" </dev/null >/dev/null 2>&1 8>&- ||
      WARNINGS+=("udevadm trigger failed")
  fi
  fixed_cards >/dev/null
  ((EXTERNAL_CARD)) && WARNINGS+=("$1")
  return 0
}

ask() { # ask <question>: yes with --yes, or an interactive yes; no otherwise
  local answer=''
  ((YES)) && return 0
  [[ -t 0 ]] || return 1
  printf '%s [Y/n] ' "$1" >&2
  IFS= read -r answer || return 1
  [[ -z $answer || $answer == [Yy]* ]]
}

# ---------------------------------------------------------------- install

WARNINGS=()
MASKED=()
ALREADY_MASKED=()
STALE_REMOVED=()

SNAP_MAX=262144
snapshot() {
  local name src f shape links size uid got
  SNAP=$(mktemp -d "$R/run/omarchy-egpu-install.XXXXXX" 2>/dev/null) || die snapshot_failed "cannot create a snapshot under $R/run"
  chmod 0700 -- "$SNAP" || die snapshot_failed
  # Cheap early refusal of anything that could never match a pin.
  for name in "${SYSTEM_FILES[@]}"; do
    src=$PLUGIN_DIR/system/$name
    [[ -f $src && ! -L $src ]] || die snapshot_unsafe "system/$name is missing or not a plain file"
    size=$(stat -c %s -- "$src" 2>/dev/null) || die snapshot_incomplete
    ((size <= SNAP_MAX)) || die snapshot_unsafe "system/$name is too large"
  done
  # The plugin folder is the user's, so the file checked above may be swapped
  # for a link, a FIFO or an endless device before it is read. Read at most one
  # byte more than allowed, within a deadline, into a file root creates in the
  # snapshot: an endless source stops at the byte limit, one that never opens
  # or never ends stops at the deadline, and either way the size check below
  # or the pin refuses what was read. No -a: root's own copies, root's mode.
  for name in "${SYSTEM_FILES[@]}"; do
    timeout -k 2 20 head -c $((SNAP_MAX + 1)) -- "$PLUGIN_DIR/system/$name" >"$SNAP/$name" 2>/dev/null </dev/null 8>&- ||
      die snapshot_incomplete "cannot copy system/$name"
  done
  for name in "${SYSTEM_FILES[@]}"; do
    f=$SNAP/$name
    [[ -f $f && ! -L $f ]] || die snapshot_unsafe "system/$name"
    shape=$(stat -c '%h %s %u' -- "$f" 2>/dev/null) || die snapshot_unsafe
    read -r links size uid <<<"$shape"
    [[ $links == 1 && $uid == "$OWNER_UID" ]] || die snapshot_unsafe "system/$name"
    ((size <= SNAP_MAX)) || die snapshot_unsafe "system/$name is too large"
  done
  # The bytes, not a header: from here on the snapshot is the reviewed release.
  for name in "${SYSTEM_FILES[@]}"; do
    got=$(sha_of "$SNAP/$name") || die snapshot_incomplete
    [[ $got == "${PINS[$name]:-}" ]] || die snapshot_modified "system/$name does not match its pin; reinstall the plugin, or run dev/update-pins.sh in a checkout you changed"
  done
  for name in "${SYSTEM_FILES[@]}"; do
    [[ $(file_version "$SNAP/$name") == "$VERSION" ]] || die snapshot_mixed_versions "system/$name is not version $VERSION"
  done
}

# The primary GPU: --primary, or the one display device that is boot VGA and
# not removable. Its address goes into the rule, so it must be exactly one.
detect_primary() {
  local d n found=()
  if [[ -n $PRIMARY ]]; then
    [[ -d $PCI/$PRIMARY ]] || die no_primary "--primary $PRIMARY is not a PCI device here"
    [[ $(attr "$PCI/$PRIMARY/removable") != removable ]] || die no_primary "--primary $PRIMARY is removable"
    return 0
  fi
  for d in "$PCI"/*; do
    n=${d##*/}
    [[ $n =~ $BDF_RE ]] || continue
    [[ $(attr "$d/class") == 0x03* && $(attr "$d/boot_vga") == 1 ]] || continue
    [[ $(attr "$d/removable") == removable ]] && continue
    found+=("$n")
  done
  ((${#found[@]} == 1)) || die no_primary "found ${#found[@]} boot VGA display devices; pass --primary BDF"
  PRIMARY=${found[0]}
}

render_rules() {
  local f=$SNAP/61-omarchy-egpu.rules out=$SNAP/61-omarchy-egpu.rules.out changed
  [[ $PRIMARY =~ $BDF_RE ]] || die no_primary
  sed "s/@PRIMARY_BDF@/$PRIMARY/g" -- "$f" >"$out" || die install_failed "cannot render the udev rule"
  ! grep -q '@PRIMARY_BDF@' -- "$out" || die install_failed "the udev rule kept a placeholder"
  changed=$(diff -- "$f" "$out" | grep -c '^>')
  [[ $changed == 1 ]] || die install_failed "rendering changed $changed lines of the udev rule, expected 1"
  RULES_SRC=$out
}

# Effective module names in a modules-load.d file, - folded to _.
mld_modules() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%[#;]*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] && printf '%s\n' "${line//-/_}"
  done <"$1"
}
is_mask_module() { local m; for m in "${MASK_MODULES[@]}"; do [[ $1 == "$m" ]] && return 0; done; return 1; }

# shipped_names: every .conf name in the non-/etc directories, once each.
shipped_names() {
  local d f
  for d in "${MLD_OTHERS[@]}"; do
    for f in "$d"/*.conf; do printf '%s\n' "${f##*/}"; done
  done | sort -u
}

# shipped_file <name>: a file of that name in /run, /usr/local/lib or
# /usr/lib, the first by precedence. Status 1 when none has one.
shipped_file() {
  local d
  for d in "${MLD_OTHERS[@]}"; do
    [[ -e $d/$1 || -L $d/$1 ]] && { printf '%s\n' "$d/$1"; return 0; }
  done
  return 1
}

# shipped_loaders: "name<TAB>file" for each name some non-/etc file of which
# loads a backend module. Any of them, not only the one that wins today: /run
# is gone at the next boot, so an empty /run file shadowing a /usr/lib one
# that loads nvidia-uvm protects nothing then.
shipped_loaders() {
  local base d f m
  while IFS= read -r base; do
    [[ -n $base ]] || continue
    for d in "${MLD_OTHERS[@]}"; do
      f=$d/$base
      [[ -f $f && -r $f ]] || continue
      while IFS= read -r m; do
        is_mask_module "$m" && { printf '%s\t%s\n' "$base" "$f"; continue 3; }
      done <<<"$(mld_modules "$f")"
    done
  done <<<"$(shipped_names)"
}

install_masks() {
  local f base dest m hit others target line extra
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    base=${line%%$'\t'*}
    f=${line#*$'\t'}
    dest=$MLD_ETC/$base
    say "  ${f#"$R"} loads the eGPU driver at boot; masking it by name"
    if [[ -L $dest ]]; then
      target=$(readlink -- "$dest")
      if [[ $target == /dev/null ]]; then
        ALREADY_MASKED+=("${dest#"$R"}")
        say "  ${dest#"$R"} already masks it (a link to /dev/null); left alone"
      else
        WARNINGS+=("${dest#"$R"} is a symlink to $target; not touched")
      fi
      continue
    fi
    if [[ -e $dest && ! -f $dest ]]; then
      WARNINGS+=("${dest#"$R"} is not a regular file; not touched")
      continue
    fi
    if [[ -f $dest ]] && ! is_ours "$dest"; then
      others=0 hit=0
      while IFS= read -r m; do
        [[ -n $m ]] || continue
        if is_mask_module "$m"; then hit=1; else others=1; fi
      done <<<"$(mld_modules "$dest")"
      if ((!hit && !others)); then
        ALREADY_MASKED+=("${dest#"$R"}")
        say "  ${dest#"$R"} already masks it (loads nothing); left alone"
        continue
      fi
      if ((others)); then
        WARNINGS+=("${dest#"$R"} also loads other modules; not replaced, edit it by hand")
        continue
      fi
    fi
    # The mask stops the whole file, not only the eGPU's modules.
    extra=()
    while IFS= read -r m; do
      [[ -n $m ]] && ! is_mask_module "$m" && extra+=("$m")
    done <<<"$(mld_modules "$f")"
    ((${#extra[@]})) &&
      WARNINGS+=("${f#"$R"} also loads ${extra[*]}; the mask stops that at boot too (list them in a file of your own in /etc/modules-load.d/ if you need them)")
    put "$SNAP/omarchy-egpu-modules.conf" "$dest" 0644
    MASKED+=("${dest#"$R"}")
  done <<<"$(shipped_loaders)"
}

# §9.2: an empty /etc file masks nothing when no other directory systemd
# reads has a file of that name.
remove_stale_masks() {
  local f base size
  for f in "$MLD_ETC"/*.conf; do
    base=${f##*/}
    [[ $base =~ $STALE_RE ]] || continue
    [[ -f $f && ! -L $f ]] || continue
    shipped_file "$base" >/dev/null && continue
    is_ours "$f" && continue
    size=$(stat -c %s -- "$f" 2>/dev/null) || continue
    if ((size != 0)); then
      WARNINGS+=("${f#"$R"} is not empty; left alone")
      continue
    fi
    say ""
    say "  ${f#"$R"} is an empty file. An empty file in /etc/modules-load.d masks"
    say "  the file of the same name in /run, /usr/local/lib or /usr/lib, but none"
    say "  of them has a $base any more (the driver package was renamed), so it"
    say "  masks nothing and does nothing. It will be moved to the backup folder;"
    say "  uninstall puts it back."
    if ask "  Remove ${f#"$R"}?"; then
      backup "$f" move
      STALE_REMOVED+=("${f#"$R"}")
    else
      WARNINGS+=("${f#"$R"} is a stale empty mask; left in place (run again with --yes to remove it)")
    fi
  done
}

# The flag's bytes; the helper's `autoconnect on` writes the same ones.
flag_text() {
  printf '# omarchy-egpu-version: %s\n' "$VERSION"
  printf '# Auto-connect is on: the udev rule loads the eGPU driver on plug-in.\n'
  printf "# Turn it off in the panel's Setup, or remove this file as root.\n"
}

# decide_autoconnect: --autoconnect, else on for a first install (no record),
# else what is there now: a later install or reinstall keeps the user's
# choice from the panel. Before anything changes, as reinstall removes the flag.
decide_autoconnect() {
  [[ -n $AUTOCONNECT ]] && return 0
  if [[ -f $RECORD && ! -L $RECORD ]]; then
    AUTOCONNECT=off
    [[ -f $FLAG ]] && AUTOCONNECT=on
  else
    AUTOCONNECT=on
  fi
}

set_autoconnect() {
  local want=$AUTOCONNECT
  [[ -n $want ]] || return 0
  if [[ $want == on ]]; then
    flag_text >"$SNAP/autoconnect" || die install_failed "cannot write the flag"
    put "$SNAP/autoconnect" "$FLAG" 0644
  elif [[ -e $FLAG || -L $FLAG ]]; then
    rm -f -- "$FLAG" || die install_failed "cannot remove $FLAG"
    record_forget "$FLAG"
    record_save
    say "  removed ${FLAG#"$R"} (auto-connect off)"
  fi
}

# preflight: everything that can refuse, before anything is changed. A
# refusal here leaves the machine exactly as it was, whatever the mode.
preflight() {
  local owner account_uid d
  [[ $PLUGIN_DIR == /* && $PLUGIN_DIR != *..* ]] || die plugin_missing "PLUGIN_DIR must be an absolute path"
  PLUGIN_DIR=${PLUGIN_DIR%/}
  [[ ! -L $PLUGIN_DIR && ! -L $PLUGIN_DIR/system ]] || die plugin_unsafe "the plugin folder or its system/ is a symlink"
  [[ -d $PLUGIN_DIR/system ]] || die plugin_missing "no system/ in $PLUGIN_DIR"
  [[ $ACCOUNT != root && $ACCOUNT =~ ^[a-z_][a-z0-9_.-]*[$]?$ ]] || die unknown_account
  account_uid=$(id -u -- "$ACCOUNT" 2>/dev/null) || die unknown_account
  # Whoever typed sudo installs for their own account and their own folder.
  [[ -z ${SUDO_UID:-} || ${SUDO_UID:-} == "$account_uid" ]] || die not_owner "SUDO_UID is not $ACCOUNT"
  [[ -z ${PKEXEC_UID:-} || ${PKEXEC_UID:-} == "$account_uid" ]] || die not_owner "PKEXEC_UID is not $ACCOUNT"
  owner=$(stat -Lc %u -- "$PLUGIN_DIR/system" 2>/dev/null) || die plugin_missing
  [[ $owner == 0 || $owner == "$account_uid" ]] || die plugin_not_owned "$PLUGIN_DIR/system belongs to uid $owner"

  say "omarchy-egpu $VERSION: installing the system half from $PLUGIN_DIR"
  audit "$MODE $VERSION requested by uid ${SUDO_UID:-${PKEXEC_UID:-0}} for $ACCOUNT from $PLUGIN_DIR"
  snapshot
  detect_primary
  render_rules
  say "  primary GPU: $PRIMARY (boot VGA)"
  # Checked, not created: a directory that is missing is made by apply.
  for d in "$BIN_DIR" "$POLICY_DIR" "$RULES_DIR" "$MLD_ETC" "$CONF_DIR"; do assert_dir_safe "$d" check; done
  decide_autoconnect
}

# apply: installs from the checked snapshot.
apply() {
  local d auto=off
  for d in "$BIN_DIR" "$POLICY_DIR" "$RULES_DIR" "$MLD_ETC" "$CONF_DIR"; do assert_dir_safe "$d"; done
  record_load

  # The helper before the two files that name it, the rule last.
  put "$SNAP/omarchy-egpu-admin" "$HELPER" 0755
  put "$SNAP/no.kalinewb.egpu.policy" "$POLICY" 0644
  put "$RULES_SRC" "$RULES" 0644
  install_masks
  remove_stale_masks
  set_autoconnect
  udev_reload "the eGPU is attached now: its /dev/dri/omarchy-egpu-external link appears when it is next plugged in, or at the next boot"

  [[ -e $FLAG ]] && auto=on
  audit "installed $VERSION: ${INSTALLED[*]}"
  say "done. Auto-connect is $auto."
  printf '{"ok":true,"version":%s,"primary":%s,"installed":%s,"masked":%s,"already_masked":%s,"stale_removed":%s,"autoconnect":%s,"backup":%s,"warnings":%s}\n' \
    "$(json_string "$VERSION")" "$(json_string "$PRIMARY")" "$(json_array "${INSTALLED[@]}")" \
    "$(json_array "${MASKED[@]}")" "$(json_array "${ALREADY_MASKED[@]}")" "$(json_array "${STALE_REMOVED[@]}")" \
    "$([[ $auto == on ]] && echo true || echo false)" "$(json_string "${BACKUP_DIR#"$R"}")" "$(json_array "${WARNINGS[@]}")"
}

# ---------------------------------------------------------------- uninstall

REMOVED=()
KEPT=()
RESTORED=()

# unput <path> [sha]: removes a file this installed, if it is still ours.
unput() {
  local f=$1 sha=${2:-}
  [[ -e $f || -L $f ]] || return 0
  if [[ ! -L $f ]] && { [[ -n $sha && $(sha_of "$f") == "$sha" ]] || is_ours "$f"; }; then
    rm -f -- "$f" || die uninstall_failed "cannot remove $f"
    REMOVED+=("${f#"$R"}")
    say "  removed ${f#"$R"}"
  else
    KEPT+=("${f#"$R"}")
    say "  ${f#"$R"} was changed since it was installed; left in place"
  fi
}

do_uninstall() {
  say "omarchy-egpu: removing the system half"
  audit "uninstall requested by uid ${SUDO_UID:-${PKEXEC_UID:-0}}"
  record_load
  local e path sha f
  declare -A sha_of_path=()
  for e in "${REC_FILES[@]}"; do sha_of_path[${e%%$'\t'*}]=${e#*$'\t'}; done

  # The rule first, so no udev event runs a helper that is gone; the flag,
  # whatever it holds (it is a switch, and the panel rewrites it); what names
  # the helper; the helper; then everything else recorded.
  unput "$RULES" "${sha_of_path[$RULES]:-}"
  unset 'sha_of_path[$RULES]'
  if [[ -L $FLAG || -f $FLAG ]]; then
    rm -f -- "$FLAG" || die uninstall_failed "cannot remove $FLAG"
    REMOVED+=("${FLAG#"$R"}")
    say "  removed ${FLAG#"$R"}"
  fi
  unset 'sha_of_path[$FLAG]'
  for path in "$POLICY" "$HELPER"; do
    unput "$path" "${sha_of_path[$path]:-}"
    unset 'sha_of_path[$path]'
  done
  udev_reload "the eGPU is attached now: its /dev/dri/omarchy-egpu-external link goes when it is unplugged, or at the next boot"
  for path in "${!sha_of_path[@]}"; do
    unput "$path" "${sha_of_path[$path]}"
  done
  # Without a record (an install from before records, or a lost one), our own
  # masks are still recognisable by their header.
  for f in "$MLD_ETC"/*.conf; do
    is_ours "$f" && unput "$f"
  done

  # Put back what was replaced, unless something new is in its place.
  local orig saved
  for e in "${REC_BACKUPS[@]}"; do
    orig=${e%%$'\t'*}
    saved=${e#*$'\t'}
    if [[ ! -e $saved && ! -L $saved ]]; then
      WARNINGS+=("the backup of ${orig#"$R"} is missing (${saved#"$R"})")
    elif [[ -e $orig || -L $orig ]]; then
      WARNINGS+=("${orig#"$R"} exists again; its backup stays at ${saved#"$R"}")
    else
      install -d -m 0755 -- "$(dirname -- "$orig")" 2>/dev/null
      mv -- "$saved" "$orig" || die uninstall_failed "cannot restore $orig"
      RESTORED+=("${orig#"$R"}")
      say "  restored ${orig#"$R"}"
    fi
  done

  rm -f -- "$RECORD"
  rmdir -- "$STATE_DIR" "$CONF_DIR" 2>/dev/null
  [[ -d $BACKUP_ROOT ]] && find "$BACKUP_ROOT" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
  rmdir -- "$BACKUP_ROOT" 2>/dev/null
  REC_FILES=() REC_BACKUPS=()
  ((REINSTALLING)) || warn_boot_loading
  audit "uninstalled: ${REMOVED[*]:-nothing}"
  say "done."
}

# warn_boot_loading: after an uninstall, say plainly when a shipped file loads
# the eGPU's driver at boot again. With no card at boot that is the condition
# that froze this setup (§9.2), so it is said loudly, not only in the JSON.
warn_boot_loading() {
  local line base f m mods
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    base=${line%%$'\t'*}
    f=${line#*$'\t'}
    [[ -e $MLD_ETC/$base || -L $MLD_ETC/$base ]] && continue
    mods=()
    while IFS= read -r m; do is_mask_module "$m" && mods+=("$m"); done <<<"$(mld_modules "$f")"
    WARNINGS+=("${f#"$R"} loads ${mods[*]} at boot again; with no eGPU attached at boot this can freeze the machine")
    say ""
    say "  WARNING: ${f#"$R"} loads ${mods[*]} (the eGPU driver) at boot again."
    say "  Loading it with no eGPU attached is what froze this machine before."
    say "  Install the system half again, or mask it yourself:"
    say "    sudo ln -s /dev/null ${MLD_ETC#"$R"}/$base"
  done <<<"$(shipped_loaders)"
}

# ---------------------------------------------------------------- main

[[ -d $R/run ]] || die install_failed "$R/run does not exist"
# Root's alone (0600): flock works on a read-only descriptor, so a lock anyone
# could open is one anyone could hold. An older release made it 0644.
_umask=$(umask)
umask 077
exec 8>>"$R/run/omarchy-egpu-install.lock" || die install_failed "cannot open the install lock"
umask "$_umask"
chmod 0600 -- "$R/run/omarchy-egpu-install.lock" 2>/dev/null
flock -n 8 || die busy "another install is running" 3

SNAP=''
REINSTALLING=0
trap '[[ -n $SNAP && -d $SNAP ]] && rm -rf -- "$SNAP"' EXIT

case $MODE in
  install)
    preflight
    apply
    ;;
  reinstall)
    # Everything that can refuse first: a reinstall that fails half way must
    # not leave the machine uninstalled, without its boot-load mask.
    preflight
    REINSTALLING=1
    do_uninstall
    REMOVED=() KEPT=() RESTORED=() WARNINGS=()
    apply
    ;;
  uninstall)
    do_uninstall
    printf '{"ok":true,"removed":%s,"kept":%s,"restored":%s,"warnings":%s}\n' \
      "$(json_array "${REMOVED[@]}")" "$(json_array "${KEPT[@]}")" "$(json_array "${RESTORED[@]}")" "$(json_array "${WARNINGS[@]}")"
    ;;
esac
exit 0
