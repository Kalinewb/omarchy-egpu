#!/usr/bin/env python3
"""apps.py — desktop entries and their "Run on eGPU" override. Used by lib/apps.sh.

  apps.py list     --user-dir D --sys-dirs A:B --run PATH
  apps.py enable   ID --user-dir D --sys-dirs A:B --run PATH
  apps.py disable  ID --user-dir D
  apps.py disable-all --user-dir D
  apps.py client status|enable|disable --user-dir D --sys-dirs A:B --args '["-cef-disable-gpu"]'

Every command prints one JSON document on stdout and exits 0, or prints
{"error": code, ...} and exits 1.

An app is "on" when <user-dir>/<id> exists and carries the marker line
X-Omarchy-eGPU=managed: a copy of the system entry whose Exec lines (the
main one and every action's) are prefixed with `egpu-run --quiet --`, so the
app starts on the eGPU from any launcher, and on the laptop GPU when the eGPU
is not there. Only files with the marker are ever changed or removed; a user's
own override of the same id is reported as "manual" and left alone.
"""

import argparse
import json
import os
import re
import sys
import tempfile

MARK_KEY = "X-Omarchy-eGPU"
MARK = MARK_KEY + "=managed"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*\.desktop$")


def fail(code, **extra):
    print(json.dumps({"error": code, **extra}))
    sys.exit(1)


def read_entry(path):
    """The [Desktop Entry] keys of a file (first locale-free value wins), or None."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    group = None
    keys = {}
    names = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line[1:-1]
            continue
        if group != "Desktop Entry" or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if "[" in k:  # a localized key: Name[de]; the plain one is enough
            continue
        keys.setdefault(k, v)
    return keys, text


def is_true(v):
    return str(v).lower() == "true"


def shown(keys):
    if keys.get("Type", "Application") != "Application":
        return False
    if not keys.get("Exec"):
        return False
    if is_true(keys.get("NoDisplay", "")) or is_true(keys.get("Hidden", "")):
        return False
    # Steam games have their own switches (omarchy-egpu steam), and the Steam
    # client's own window is Setup's (the `client` command below).
    if "steam://rungameid" in keys["Exec"]:
        return False
    return True


STEAM_ID = "steam.desktop"
CLIENT_MARK = MARK_KEY + "=steam-client"
CLIENT_ARGS_KEY = MARK_KEY + "-Args"


def scan(user_dir, sys_dirs):
    """{id: (source, path, keys, text)}, the first directory that has an id wins."""
    found = {}
    for source, d in [("user", user_dir)] + [("system", x) for x in sys_dirs]:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            if not ID_RE.match(n) or n in found:
                continue
            p = os.path.join(d, n)
            if not os.path.isfile(p):
                continue
            r = read_entry(p)
            if r is None:
                continue
            found[n] = (source, p, r[0], r[1])
    return found


def quote_exec(path):
    """A desktop-entry Exec word for a path: quoted when it has anything odd."""
    if re.fullmatch(r"[A-Za-z0-9_./+:@-]+", path):
        return path
    esc = path.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")
    return '"' + esc.replace("%", "%%") + '"'


def prefix_for(run):
    return quote_exec(run) + " --quiet --"


def wrap_text(text, prefix):
    """The entry's text with every Exec= prefixed, the marker added, DBus
    activation off (a launcher would otherwise skip Exec), and only once."""
    out = []
    in_entry = False
    marked = False
    for raw in text.split("\n"):
        s = raw.strip()
        if s.startswith("[") and s.endswith("]"):
            in_entry = s == "[Desktop Entry]"
            out.append(raw)
            if in_entry and not marked:
                out.append(MARK)
                marked = True
            continue
        if re.match(r"^Exec\s*=", raw):
            val = raw.split("=", 1)[1].strip()
            if not val.startswith(prefix):
                raw = "Exec=" + prefix + " " + val
        elif in_entry and re.match(r"^DBusActivatable\s*=", raw):
            raw = "DBusActivatable=false"
        elif re.match(r"^" + re.escape(MARK_KEY) + r"\s*=", raw):
            continue
        out.append(raw)
    return "\n".join(out)


def write_atomic(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".egpu-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def managed(path):
    r = read_entry(path)
    return r is not None and r[0].get(MARK_KEY) == "managed"


def state_of(user_dir, app_id, source):
    p = os.path.join(user_dir, app_id)
    if source == "user":
        return "on" if managed(p) else "manual"
    return "off"


def cmd_list(a):
    found = scan(a.user_dir, a.sys_dirs)
    apps = []
    for app_id, (source, path, keys, text) in found.items():
        if not shown(keys) or app_id == STEAM_ID:
            continue
        # A managed copy is a system entry in the user's directory. The user
        # dir wins in `found`, so a managed file is source "user" but still
        # has a system original; one without an original is the user's own.
        orig = next((x for x in a.sys_dirs if os.path.isfile(os.path.join(x, app_id))), None)
        if source == "user" and managed(path):
            state = "on"
        elif source == "user" and orig is not None:
            state = "manual"  # their own override of a system entry
        elif source == "user":
            continue  # the user's own entry (web apps, shortcuts): not ours to wrap
        else:
            state = "off"
        cats = [c for c in keys.get("Categories", "").split(";") if c]
        apps.append({
            "id": app_id,
            "name": keys.get("Name", app_id[:-8]),
            "icon": keys.get("Icon", ""),
            "comment": keys.get("Comment", ""),
            "state": state,
            "game": "Game" in cats,
            "terminal": is_true(keys.get("Terminal", "")),
        })
    apps.sort(key=lambda x: (x["name"].casefold(), x["id"]))
    print(json.dumps({"apps": apps, "on": sum(1 for x in apps if x["state"] == "on"), "run": a.run}))


def cmd_enable(a):
    if not ID_RE.match(a.id):
        fail("invalid_value", detail="That is not a desktop entry name.")
    # The original is the system entry; the user's own override is not touched.
    orig = None
    for d in a.sys_dirs:
        p = os.path.join(d, a.id)
        if os.path.isfile(p):
            orig = p
            break
    target = os.path.join(a.user_dir, a.id)
    if os.path.lexists(target) and not managed(target):
        fail("app_manual", id=a.id, detail="This app has its own settings file; it is left alone.")
    if orig is None:
        fail("app_not_found", id=a.id)
    r = read_entry(orig)
    if r is None or not shown(r[0]):
        fail("app_not_found", id=a.id)
    if not os.access(a.run, os.X_OK):
        fail("run_missing", detail="egpu-run is not where the plugin expects it.")
    write_atomic(target, wrap_text(r[1], prefix_for(a.run)))
    print(json.dumps({"id": a.id, "state": "on"}))


def cmd_disable(a):
    if not ID_RE.match(a.id):
        fail("invalid_value", detail="That is not a desktop entry name.")
    target = os.path.join(a.user_dir, a.id)
    if not os.path.lexists(target):
        print(json.dumps({"id": a.id, "state": "off"}))
        return
    if not managed(target):
        fail("app_manual", id=a.id, detail="This app has its own settings file; it is left alone.")
    os.unlink(target)
    print(json.dumps({"id": a.id, "state": "off"}))


def cmd_disable_all(a):
    removed = []
    try:
        names = sorted(os.listdir(a.user_dir))
    except OSError:
        names = []
    for n in names:
        p = os.path.join(a.user_dir, n)
        if ID_RE.match(n) and os.path.isfile(p) and not os.path.islink(p) and managed(p):
            os.unlink(p)
            removed.append(n)
    print(json.dumps({"removed": removed}))


def client_args_text(args):
    return " ".join(args)


def wrap_client(text, args):
    """Steam's entry with `args` after the steam command in every Exec line
    (the main one and the actions'), and the two marker lines."""
    joined = client_args_text(args)
    out = []
    marked = False
    for raw in text.split("\n"):
        s = raw.strip()
        if s.startswith("[") and s.endswith("]"):
            out.append(raw)
            if s == "[Desktop Entry]" and not marked:
                out.append(CLIENT_MARK)
                out.append(CLIENT_ARGS_KEY + "=" + joined)
                marked = True
            continue
        if re.match(r"^" + re.escape(MARK_KEY) + r"(-Args)?\s*=", raw):
            continue
        m = re.match(r"^(Exec\s*=\s*)(\S+)(.*)$", raw)
        if m and os.path.basename(m.group(2)) == "steam":
            rest = m.group(3)
            if not rest.lstrip().startswith(joined):
                raw = m.group(1) + m.group(2) + " " + joined + rest
        out.append(raw)
    return "\n".join(out)


def client_state(a):
    """(state, original path or None, user path). state: on | off | stale |
    manual | missing."""
    user = os.path.join(a.user_dir, STEAM_ID)
    orig = next((os.path.join(d, STEAM_ID) for d in a.sys_dirs if os.path.isfile(os.path.join(d, STEAM_ID))), None)
    if os.path.lexists(user):
        r = read_entry(user)
        if r is not None and r[0].get(MARK_KEY) == "steam-client":
            return ("on" if r[0].get(CLIENT_ARGS_KEY, "") == client_args_text(a.args) else "stale"), orig, user
        return "manual", orig, user
    if orig is None:
        return "missing", None, user
    return "off", orig, user


def cmd_client(a):
    a.args = json.loads(a.args)
    if not isinstance(a.args, list) or not all(isinstance(x, str) and re.fullmatch(r"-[A-Za-z0-9-]+", x) for x in a.args):
        fail("invalid_value", detail="Steam's options are words that start with a dash.")
    state, orig, user = client_state(a)
    if a.action == "status":
        print(json.dumps({"state": state, "args": a.args}))
        return
    if state == "manual":
        fail("app_manual", detail="Steam has its own settings file for the launcher; it is left alone.")
    if a.action == "disable":
        if state in ("on", "stale"):
            os.unlink(user)
        print(json.dumps({"state": "off"}))
        return
    if state == "missing" or orig is None:
        fail("steam_not_found")
    r = read_entry(orig)
    if r is None:
        fail("steam_not_found")
    if not a.args:
        fail("invalid_value", detail="No options to apply.")
    write_atomic(user, wrap_client(r[1], a.args))
    print(json.dumps({"state": "on", "args": a.args}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, with_sys=True):
        p.add_argument("--user-dir", required=True)
        if with_sys:
            p.add_argument("--sys-dirs", default="")
            p.add_argument("--run", default="")

    p = sub.add_parser("list")
    common(p)
    p = sub.add_parser("enable")
    p.add_argument("id")
    common(p)
    p = sub.add_parser("disable")
    p.add_argument("id")
    common(p, False)
    p = sub.add_parser("disable-all")
    common(p, False)
    p = sub.add_parser("client")
    p.add_argument("action", choices=["status", "enable", "disable"])
    p.add_argument("--args", default="[]")
    common(p)
    a = ap.parse_args()
    if hasattr(a, "sys_dirs"):
        a.sys_dirs = [x for x in a.sys_dirs.split(":") if x]
    {"list": cmd_list, "enable": cmd_enable, "disable": cmd_disable, "disable-all": cmd_disable_all,
     "client": cmd_client}[a.cmd](a)


if __name__ == "__main__":
    main()
