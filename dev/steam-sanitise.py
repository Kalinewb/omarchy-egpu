#!/usr/bin/env python3
"""Turn copies of a user's Steam files into test fixtures (plan-engine.md §8.1, gate E6a).

    dev/steam-sanitise.py <raw dir> <out dir>       write sanitised copies
    dev/steam-sanitise.py --verify <raw dir> <dir>  check nothing personal leaked

<raw dir> holds copies the user made, laid out like a Steam root:
config/libraryfolders.vdf, steamapps/appmanifest_*.acf,
userdata/<accountid>/config/localconfig.vdf. It must never be inside the repo.

Every token is rewritten in place, so the layout (tabs, line lengths, escapes,
section order, the quirks the editor must survive) is kept and the content is
not:
  - account ids and SteamID64s become fake ones (100000001, ... by sorted id);
  - library paths become @ROOT@ (the tests substitute a temp dir);
  - every other value is scrambled character by character with a random salt
    that is not stored: digits stay digits, hex stays hex, letters stay
    letters, escapes and punctuation stay, non-ASCII keeps its byte length;
  - long digit runs in keys (friend ids, appids) are scrambled too, except the
    appids the fixtures need (manifests and every app with LaunchOptions);
  - kept verbatim: LaunchOptions, game names and installdirs in manifests, and
    values of two characters or less.

--verify fails when an account id, a SteamID64, the home directory's user name,
a persona or friend name, or any other value of 8+ characters from the raw
files appears anywhere under <dir> (except the kept values above).
"""

import os
import random
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in lib/ (the plugin dir is watched)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "steam"))
import vdf  # noqa: E402

STEAMID_BASE = 76561197960265728
KEEP_VALUE_KEYS = {"launchoptions"}
KEEP_MANIFEST_KEYS = {"appid", "name", "installdir", "stateflags", "universe"}
NAME_KEYS = {"personaname", "name", "tag", "accountname"}


def raw_files(raw):
    out = []
    for dirpath, _, files in os.walk(raw):
        for f in files:
            if f.endswith((".vdf", ".acf")):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def account_map(raw):
    ids = sorted(int(d) for d in os.listdir(os.path.join(raw, "userdata")) if d.isdigit())
    m = {}
    for k, real in enumerate(ids):
        fake = 100000001 + k
        m[str(real)] = str(fake)
        m[str(real + STEAMID_BASE)] = str(fake + STEAMID_BASE)
    return m


def keep_appids(raw):
    keep = set()
    for f in raw_files(raw):
        data = open(f, "rb").read()
        m = re.search(rb"appmanifest_(\d+)\.acf$", f.encode())
        if m:
            keep.add(m.group(1).decode())
        if f.endswith("localconfig.vdf"):
            ed = vdf.Editor(data)
            _, apps = ed.apps()
            for app in apps.children if apps else ():
                if app.children is not None and app.find("LaunchOptions") is not None:
                    keep.add(app.key)
    return keep


class Scrambler:
    def __init__(self, ids, keep):
        self.ids = ids
        self.keep = keep
        self.salt = os.urandom(16).hex()

    def rng(self, s):
        return random.Random(self.salt + s)

    def digits(self, run, min_len):
        if run in self.ids:
            return self.ids[run]
        if len(run) < min_len or run in self.keep:
            return run
        r = self.rng(run)
        return "".join(r.choice("123456789") if k == 0 else r.choice("0123456789") for k in range(len(run)))

    def text(self, s, min_digits=3):
        r = self.rng(s)
        out = []
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\\" and i + 1 < len(s):
                out.append(s[i:i + 2])
                i += 2
                continue
            if c.isdigit() and c.isascii():
                j = i
                while j < len(s) and s[j].isdigit() and s[j].isascii():
                    j += 1
                out.append(self.digits(s[i:j], min_digits))
                i = j
                continue
            if c.isascii() and c.isalpha():
                if c in "abcdef":
                    out.append(r.choice("abcdef"))
                elif c in "ABCDEF":
                    out.append(r.choice("ABCDEF"))
                elif c.islower():
                    out.append(r.choice("ghijklmnopqrstuvwxyz"))
                else:
                    out.append(r.choice("GHIJKLMNOPQRSTUVWXYZ"))
            elif not c.isascii():
                out.append({2: "é", 3: "™", 4: "\U0001F3AE"}[len(c.encode())])
            else:
                out.append(c)
            i += 1
        return "".join(out)

    def key(self, k):
        # Keys are structure: keep words, map ids, scramble long digit runs.
        return re.sub(r"\d+", lambda m: self.digits(m.group(0), 5), k)


def sanitise(data, path, sc):
    """Rewrite each token's bytes in place. Returns the new file bytes."""
    root = vdf.parse(data)
    edits = []
    manifest = path.endswith(".acf")
    libraryfolders = path.endswith("libraryfolders.vdf")

    def walk(node, trail):
        for c in node.children:
            ks, ke = c.ks + 1, c.ke - 1
            k = data[ks:ke].decode()
            edits.append((ks, ke, sc.key(k).encode()))
            if c.children is not None:
                walk(c, trail + [c.key])
                continue
            raw = c.raw_value(data).decode()
            s = c.vs + 1 if c.quoted else c.vs
            e = c.ve - 1 if c.quoted else c.ve
            low = c.key.lower()
            if libraryfolders and low == "path":
                new = "@ROOT@"
            elif low in KEEP_VALUE_KEYS or (manifest and low in KEEP_MANIFEST_KEYS) or len(raw) <= 2:
                new = re.sub(r"\d+", lambda m: sc.ids.get(m.group(0), m.group(0)), raw)
            else:
                new = sc.text(raw)
            edits.append((s, e, new.encode()))

    walk(root, [])
    out = bytearray(data)
    for s, e, t in sorted(edits, reverse=True):
        out[s:e] = t
    new = bytes(out)
    vdf.parse(new)
    return new


def out_path(raw, f, out, ids):
    rel = os.path.relpath(f, raw)
    parts = rel.split(os.sep)
    if parts[0] == "userdata" and parts[1] in ids:
        parts[1] = ids[parts[1]]
    return os.path.join(out, *parts)


def personal_strings(raw):
    """Strings that must never appear in a fixture."""
    found = set()
    home_user = os.path.basename(os.path.expanduser("~"))
    if home_user:
        found.add(home_user)
    for f in raw_files(raw):
        data = open(f, "rb").read()
        root = vdf.parse(data)
        manifest = f.endswith(".acf")

        def walk(node, trail):
            for c in node.children:
                if c.children is not None:
                    walk(c, trail + [c.key.lower()])
                    continue
                v = vdf.unescape(c.raw_value(data))[0]
                low = c.key.lower()
                kept = low in KEEP_VALUE_KEYS or (manifest and low in KEEP_MANIFEST_KEYS)
                if kept:
                    continue
                if low in NAME_KEYS or "namehistory" in trail:
                    if len(v) >= 3:
                        found.add(v)
                elif len(v) >= 8:
                    found.add(v)
        walk(root, [])
    return found


def verify(raw, out):
    ids = account_map(raw)
    bad = []
    needles = set(ids) | personal_strings(raw)
    for dirpath, _, files in os.walk(out):
        if "/.git" in dirpath:
            continue
        for f in files:
            p = os.path.join(dirpath, f)
            try:
                data = open(p, "rb").read()
            except OSError:
                continue
            low = data.lower()
            for n in needles:
                nb = n.encode()
                if nb in data or (len(n) < 12 and nb.lower() in low and not n.isdigit()):
                    bad.append((p, n if len(n) < 24 else n[:20] + "..."))
    return bad


def main(argv):
    if argv[:1] == ["--verify"] and len(argv) == 3:
        bad = verify(argv[1], argv[2])
        for p, n in bad:
            print(f"LEAK {p}: {n!r}")
        print(f"{len(bad)} leak(s)")
        return 1 if bad else 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    raw, out = argv
    ids = account_map(raw)
    sc = Scrambler(ids, keep_appids(raw))
    for f in raw_files(raw):
        data = open(f, "rb").read()
        new = sanitise(data, f, sc)
        dest = out_path(raw, f, out, ids)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(new)
        print(f"{os.path.relpath(dest, out)}: {len(data)} -> {len(new)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
