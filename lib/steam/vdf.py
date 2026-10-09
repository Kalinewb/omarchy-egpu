#!/usr/bin/env python3
"""vdf.py — Valve KeyValues (text) reader and surgical editor. plan-engine.md §8.2-8.3.

Called by lib/steam/steam.sh. Every command prints one JSON document on stdout;
failures print {"error": code, "detail": ...} and exit 1.

    vdf.py dump [--lower] <file>...         files as JSON trees ({path: tree|{error}})
    vdf.py classify --env E --extras X [--state S] <localconfig>...
                                            per-app LaunchOptions and §8.5 state
    vdf.py plan --env E --extras X --state S --changes C [--dry-run] <localconfig>
                                            compute the edit, check it, write a temp
                                            file next to the original (not renamed);
                                            --dry-run only reports what would change
    vdf.py commit --file F --tmp T --sha H --backup B
                                            re-check the original's SHA-256, back it
                                            up, rename the temp file over it
    vdf.py stage --from B --file F          parse-check a backup and stage it as a
                                            temp file next to F (for restore)

E/X/S/C are JSON strings: E the backend env tokens ["K=V", ...], X the optional
extras [{"id": "nvapi", "token": "PROTON_ENABLE_NVAPI=1"}], S the per-app state
the engine keeps ({appid: {added_command, inserted, adopted}}), C the changes
[{"appid": "123", "want": "on|off", "adopt": bool, "extras": {"nvapi": bool}}].

Design (§8.2): parse the whole file into a tree that records the byte span of
every token, then change only bytes that can be accounted for. The file is
never re-serialised from the tree. Before anything is written the new bytes are
re-parsed and must equal the old tree with exactly the intended edits applied,
and every byte outside the edited spans must be unchanged.

Python 3 standard library only.
"""

import hashlib
import json
import os
import re
import sys
import tempfile

MARKER = "OMARCHY_EGPU=1"
LAUNCH_KEY = "LaunchOptions"
APPS_PATH = ("UserLocalConfigStore", "Software", "Valve", "Steam", "apps")
TMP_PREFIX = ".localconfig.vdf.omarchy-egpu."

WS = b" \t\r\n\f\v"
LINE_WS = b" \t\r"
COND_RE = re.compile(rb"^\[!?\$[A-Za-z0-9_|&!$ ]+\]$")


class VdfError(Exception):
    def __init__(self, code, detail, **extra):
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.extra = extra


# ---------------------------------------------------------------- tokens


def tokenize(b):
    """Tokens as (kind, start, end): '{', '}', 's' quoted (span includes the
    quotes), 'b' bare. Whitespace and // comments are skipped, never lost: the
    editor only ever splices, so they stay in the bytes."""
    out = []
    i, n = 0, len(b)
    while i < n:
        c = b[i]
        if c in WS:
            i += 1
        elif c == 0x2F and b[i + 1:i + 2] == b"/":
            j = b.find(b"\n", i)
            i = n if j < 0 else j
        elif c == 0x7B:
            out.append(("{", i, i + 1))
            i += 1
        elif c == 0x7D:
            out.append(("}", i, i + 1))
            i += 1
        elif c == 0x22:
            j = i + 1
            while True:
                if j >= n:
                    raise VdfError("vdf_parse_failed", "unterminated string", offset=i, line=line_of(b, i))
                if b[j] == 0x5C:
                    j += 2
                    continue
                if b[j] == 0x22:
                    break
                j += 1
            out.append(("s", i, j + 1))
            i = j + 1
        else:
            j = i
            while j < n and b[j] not in WS and b[j] not in b'{}"':
                j += 1
            out.append(("b", i, j))
            i = j
    return out


def line_of(b, off):
    return b.count(b"\n", 0, off) + 1


ESCAPES = {"n": "\n", "t": "\t", "v": "\v", "b": "\b", "r": "\r", "f": "\f", "a": "\a",
           "\\": "\\", "?": "?", "'": "'", '"': '"'}


def unescape(raw):
    """Decoded text of a token's raw bytes, plus the raw index of every decoded
    character (so word spans found in the text map back to raw bytes)."""
    try:
        s = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise VdfError("vdf_parse_failed", f"not UTF-8: {e}")
    out, idx = [], []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in ESCAPES:
            out.append(ESCAPES[s[i + 1]])
            idx.append(i)
            i += 2
        else:
            out.append(s[i])
            idx.append(i)
            i += 1
    idx.append(len(s))
    return "".join(out), idx, s


class Node:
    """One key: a value (vs..ve is the value token) or a section (ob/cb are the
    braces). ks..ke is the key token. Spans include quotes."""

    __slots__ = ("key", "ks", "ke", "vs", "ve", "quoted", "children", "ob", "cb", "cond")

    def __init__(self, key, ks, ke):
        self.key, self.ks, self.ke = key, ks, ke
        self.vs = self.ve = self.ob = self.cb = None
        self.quoted = True
        self.children = None
        self.cond = None

    @property
    def end(self):
        e = self.cb + 1 if self.children is not None else self.ve
        return self.cond[1] if self.cond else e

    def raw_value(self, b):
        return b[self.vs + 1:self.ve - 1] if self.quoted else b[self.vs:self.ve]

    def find(self, name):
        """First child with this key, case-insensitively (Steam's FindKey)."""
        low = name.lower()
        for c in self.children or ():
            if c.key.lower() == low:
                return c
        return None


def token_text(b, t):
    kind, s, e = t
    raw = b[s + 1:e - 1] if kind == "s" else b[s:e]
    return unescape(raw)[0]


def parse(b):
    """The whole file as a root Node whose children are the top-level keys.
    Raises VdfError(vdf_parse_failed) on anything it cannot account for."""
    if b.startswith(b"\xef\xbb\xbf"):
        raise VdfError("vdf_parse_failed", "byte-order mark: not a file Steam wrote")
    if b"\x00" in b:
        raise VdfError("vdf_parse_failed", "NUL byte", offset=b.index(b"\x00"), line=line_of(b, b.index(b"\x00")))
    toks = tokenize(b)
    root = Node("", 0, 0)
    root.children = []
    stack = [root]
    i, n = 0, len(toks)

    def is_cond(k):
        return k < n and toks[k][0] == "b" and COND_RE.match(b[toks[k][1]:toks[k][2]])

    while i < n:
        kind, s, e = toks[i]
        top = stack[-1]
        if kind == "}":
            if len(stack) == 1:
                raise VdfError("vdf_parse_failed", "unexpected '}'", offset=s, line=line_of(b, s))
            top.cb = s
            stack.pop()
            if is_cond(i + 1):
                top.cond = (toks[i + 1][1], toks[i + 1][2])
                i += 1
            i += 1
            continue
        if kind == "{":
            raise VdfError("vdf_parse_failed", "section without a key", offset=s, line=line_of(b, s))
        node = Node(token_text(b, toks[i]), s, e)
        i += 1
        if i < n and is_cond(i) and i + 1 < n and toks[i + 1][0] == "{":
            node.cond = (toks[i][1], toks[i][2])
            i += 1
        if i >= n:
            raise VdfError("vdf_parse_failed", f"key '{node.key}' has no value", offset=s, line=line_of(b, s))
        vkind, vs, ve = toks[i]
        if vkind == "{":
            node.children = []
            node.ob = vs
            top.children.append(node)
            stack.append(node)
            i += 1
            continue
        if vkind == "}":
            raise VdfError("vdf_parse_failed", f"key '{node.key}' has no value", offset=s, line=line_of(b, s))
        node.vs, node.ve, node.quoted = vs, ve, vkind == "s"
        unescape(node.raw_value(b))  # UTF-8 check
        i += 1
        if is_cond(i):
            node.cond = (toks[i][1], toks[i][2])
            i += 1
        top.children.append(node)
    if len(stack) > 1:
        open_ = stack[-1]
        raise VdfError("vdf_parse_failed", f"section '{open_.key}' is not closed",
                       offset=open_.ks, line=line_of(b, open_.ks))
    return root


def model(b, node):
    """Comparable form of a tree: [(key, raw value bytes | [children], cond)]."""
    out = []
    for c in node.children:
        cond = b[c.cond[0]:c.cond[1]] if c.cond else None
        if c.children is not None:
            out.append([c.key, model(b, c), cond, c])
        else:
            out.append([c.key, c.raw_value(b), cond, c])
    return out


def strip(m):
    return [(k, strip(v) if isinstance(v, list) else v, cond) for k, v, cond, _ in m]


def to_json(b, node, lower=False):
    """A tree as a JSON object; the first of duplicate keys wins (FindKey)."""
    out = {}
    for c in node.children:
        k = c.key.lower() if lower else c.key
        if k in out:
            continue
        out[k] = to_json(b, c, lower) if c.children is not None else unescape(c.raw_value(b))[0]
    return out


def path_find(root, path):
    node = root
    for name in path:
        nxt = node.find(name)
        if nxt is None or nxt.children is None:
            return node, None
        node = nxt
    return node, node


# ---------------------------------------------------------------- options


def words(text):
    """Shell-like words of an options string as (start, end) spans in text.
    Quotes and backslashes keep spaces inside one word."""
    spans = []
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i] in " \t\n":
            i += 1
        if i >= n:
            break
        s, q = i, None
        while i < n:
            c = text[i]
            if q:
                if c == "\\" and q == '"' and i + 1 < n:
                    i += 2
                    continue
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
            elif c == "\\" and i + 1 < n:
                i += 2
                continue
            elif c in " \t\n":
                break
            i += 1
        spans.append((s, i))
    return spans


class Options:
    """One LaunchOptions value. Edits work on the raw (escaped) bytes so that
    everything outside the marked run keeps its exact bytes."""

    def __init__(self, raw, env, extras):
        self.raw = raw
        self.env = env
        self.extras = extras  # [{"id", "token"}]
        self.env_keys = {t.split("=", 1)[0] for t in env}
        self.text, idx, self.rawstr = unescape(raw)
        self.words = [(self.text[s:e], idx[s], idx[e]) for s, e in words(self.text)]

    def run(self):
        """(start word, end word exclusive) of the marked run, or None; plus
        whether it is well formed."""
        marks = [i for i, w in enumerate(self.words) if w[0] == MARKER]
        if not marks:
            return None, False
        if len(marks) > 1:
            return (marks[0], marks[0] + 1), False
        m = marks[0]
        allowed = set(self.env) | {x["token"] for x in self.extras}
        seen = set()
        j = m + 1
        while j < len(self.words) and self.words[j][0] in allowed and self.words[j][0] not in seen:
            seen.add(self.words[j][0])
            j += 1
        return (m, j), set(self.env) <= seen

    def state(self):
        rng, ok = self.run()
        if rng is not None:
            return "on" if ok else "modified"
        for w, _, _ in self.words:
            if "=" in w and w.split("=", 1)[0] in self.env_keys:
                return "manual"
        return "off"

    def extras_on(self):
        rng, ok = self.run()
        have = {w for w, _, _ in self.words[rng[0]:rng[1]]} if rng and ok else set()
        return {x["id"]: x["token"] in have for x in self.extras}

    def run_text(self, extras_want):
        toks = [MARKER] + list(self.env) + [x["token"] for x in self.extras if extras_want.get(x["id"])]
        return " ".join(toks)

    def has_command(self):
        return "%command%" in self.text


def opt_on(raw, env, extras, extras_want):
    """(new raw, added_command). raw is bytes; the run has no escapes."""
    o = Options(raw, env, extras)
    run = o.run_text(extras_want).encode()
    if raw == b"":
        return run + b" %command%", True
    if not o.has_command():
        return run + b" %command% " + raw, True
    return run + b" " + raw, False


def opt_set_extras(raw, env, extras, extras_want):
    o = Options(raw, env, extras)
    (a, z), _ = o.run()
    s = o.words[a][1]
    e = o.words[z - 1][2]
    rs = o.rawstr
    return (rs[:s] + o.run_text(extras_want) + rs[e:]).encode()


def _cut(rs, s, e):
    """Remove rs[s:e] and one adjoining space (after it, else before it)."""
    if e < len(rs) and rs[e] == " ":
        e += 1
    elif s > 0 and rs[s - 1] == " ":
        s -= 1
    return rs[:s] + rs[e:], s


def opt_off(raw, env, extras, added_command):
    o = Options(raw, env, extras)
    (a, z), _ = o.run()
    s = o.words[a][1]
    e = o.words[z - 1][2]
    rs, at = _cut(o.rawstr, s, e)
    if added_command:
        rest = rs[at:]
        if rest == "%command%" or rest.startswith("%command% "):
            rs, _ = _cut(rs, at, at + len("%command%"))
    return rs.encode()


def opt_adopt(raw, env, extras, extras_want):
    """Remove exactly the backend's variables (any value), then turn on."""
    o = Options(raw, env, extras)
    rs = o.rawstr
    for w, s, e in reversed(o.words):
        if "=" in w and w.split("=", 1)[0] in o.env_keys:
            rs, _ = _cut(rs, s, e)
    return opt_on(rs.encode(), env, extras, extras_want)


# ---------------------------------------------------------------- editing


def line_start(b, off):
    return b.rfind(b"\n", 0, off) + 1


def only_ws(chunk):
    return all(c in LINE_WS for c in chunk)


def eol_of(b, section):
    at = section.ob + 1 if section.ob is not None else 0
    nl = b.find(b"\n", at)
    if nl > 0 and b[nl - 1:nl] == b"\r":
        return b"\r\n"
    return b"\r\n" if section.ob is None and b"\r\n" in b else b"\n"


def indent_of(b, node):
    ls = line_start(b, node.ks)
    chunk = b[ls:node.ks]
    return chunk if only_ws(chunk) else None


def separator(b, section, root):
    for c in list(section.children or ()) + list(root.children):
        if c.children is None and c.vs is not None:
            sep = b[c.ke:c.vs]
            if sep and only_ws(sep) and b"\n" not in sep:
                return sep
    return b"\t\t"


def render(key, value, indent, unit, sep, eol):
    if isinstance(value, bytes):
        return indent + b'"' + key + b'"' + sep + b'"' + value + b'"' + eol
    out = indent + b'"' + key + b'"' + eol + indent + b"{" + eol
    for k, v in value:
        out += render(k, v, indent + unit, unit, sep, eol)
    return out + indent + b"}" + eol


def insertion(b, section, key, value, root):
    """(offset, bytes) that add key/value as the last child of section,
    copying the indentation and separator of its siblings."""
    cb = section.cb
    ls = line_start(b, cb)
    close_indent = b[ls:cb]
    eol = eol_of(b, section)
    unit = b"\t" if (b"\t" in close_indent or close_indent == b"") else b"    "
    indent = None
    if section.children:
        indent = indent_of(b, section.children[0])
    if indent is None:
        indent = (close_indent if only_ws(close_indent) else b"") + unit
    sep = separator(b, section, root)
    text = render(key, value, indent, unit, sep, eol)
    if only_ws(close_indent):
        return ls, text
    return cb, eol + text


def removal(b, node):
    """(start, end) that remove a key with its whole line when it has one."""
    s, e = node.ks, node.end
    ls = line_start(b, s)
    if only_ws(b[ls:s]):
        nl = b.find(b"\n", e)
        if nl >= 0 and only_ws(b[e:nl]):
            return ls, nl + 1
        if nl < 0 and only_ws(b[e:]):
            return ls, len(b)
    return s, e


def quote_value(raw):
    return b'"' + raw + b'"'


class Editor:
    def __init__(self, data):
        self.b = data
        self.root = parse(data)
        top = self.root.find(APPS_PATH[0])
        if top is None or top.children is None:
            raise VdfError("vdf_parse_failed", "no UserLocalConfigStore section: not a localconfig.vdf")
        self.splices = []  # (start, end, bytes)
        self.m = model(data, self.root)
        self.index = {}
        self._index(self.m)
        self.pending = {}  # id(section) -> [(key, value)] to append

    def _index(self, m):
        for entry in m:
            self.index[id(entry[3])] = entry
            if isinstance(entry[1], list):
                self._index(entry[1])

    def apps(self):
        """(deepest existing section on the apps path, apps section or None)."""
        return path_find(self.root, APPS_PATH)

    def app(self, appid):
        _, apps = self.apps()
        if apps is None:
            return None
        n = apps.find(appid)
        return n if n is not None and n.children is not None else None

    # Each edit records its splice and applies the same change to the model.

    def set_value(self, node, raw):
        if node.quoted:
            self.splices.append((node.vs + 1, node.ve - 1, raw))
        else:
            self.splices.append((node.vs, node.ve, quote_value(raw)))
        self.index[id(node)][1] = raw

    def add(self, section, key, value):
        """Append key → value (bytes, or nested [(k, v)]) to a section."""
        self.pending.setdefault(id(section), [section, []])[1].append((key, value))

        def mk(v):
            return [[k.decode(), mk(x) if isinstance(x, list) else x, None, None] for k, x in v] \
                if isinstance(v, list) else v
        target = self.m if section is self.root else self.index[id(section)][1]
        target.append([key.decode(), mk(value), None, None])

    def remove(self, parent, node):
        s, e = removal(self.b, node)
        self.splices.append((s, e, b""))
        target = self.m if parent is self.root else self.index[id(parent)][1]
        for k, entry in enumerate(target):
            if entry[3] is node:
                del target[k]
                return
        raise VdfError("vdf_check_failed", "internal: removed node not in model")

    def result(self):
        for section, items in self.pending.values():
            text = b""
            at = None
            for key, value in items:
                at, t = insertion(self.b, section, key, value, self.root)
                text += t
            self.splices.append((at, at, text))
        sp = sorted(self.splices, key=lambda x: (x[0], x[1]))
        for (s1, e1, _), (s2, _, _) in zip(sp, sp[1:]):
            if s2 < e1:
                raise VdfError("vdf_check_failed", "internal: overlapping edits")
        out = bytearray(self.b)
        for s, e, t in reversed(sp):
            out[s:e] = t
        return bytes(out), sp

    def verify(self, new, sp):
        verify(self.b, new, sp, strip(self.m))


def verify(old, new, sp, want_model):
    """§8.2 checks 1-3: the new bytes parse, the tree equals the intended one,
    and every byte outside the edited spans is unchanged."""
    try:
        tree = parse(new)
    except VdfError as e:
        raise VdfError("vdf_check_failed", f"edited file does not parse: {e.detail}")
    if strip(model(new, tree)) != want_model:
        raise VdfError("vdf_check_failed", "edited tree differs from the intended change")
    delta = 0
    prev = 0
    for s, e, t in sp:
        if old[prev:s] != new[prev + delta:s + delta]:
            raise VdfError("vdf_check_failed", "bytes outside the edited span changed")
        delta += len(t) - (e - s)
        prev = e
    if old[prev:] != new[prev + delta:] or len(new) != len(old) + delta:
        raise VdfError("vdf_check_failed", "bytes outside the edited span changed")


# ---------------------------------------------------------------- commands


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        raise VdfError("vdf_parse_failed", f"cannot read {path}: {e.strerror}")


def launch_node(app):
    return app.find(LAUNCH_KEY) if app is not None else None


def classify_file(path, env, extras, state):
    data = read(path)
    ed = Editor(data)
    _, apps = ed.apps()
    games = {}
    for app in (apps.children if apps is not None else ()):
        if app.children is None:
            continue
        lo = launch_node(app)
        if lo is None or lo.children is not None:
            raw = b""
            has_key = False
        else:
            raw = lo.raw_value(data)
            has_key = True
        o = Options(raw, env, extras)
        if app.key in games:
            continue
        games[app.key] = {"state": o.state(), "options": o.text, "has_key": has_key,
                          "extras": o.extras_on()}
    return {"sha256": sha256(data), "apps_key": apps.key if apps is not None else None, "apps": games}


def plan_file(path, env, extras, state, changes, dry_run=False):
    data = read(path)
    sha = sha256(data)
    ed = Editor(data)
    results = []
    new_state = {k: dict(v) for k, v in state.items()}
    apps_parent, apps = ed.apps()
    new_blocks = []
    for ch in changes:
        appid = str(ch["appid"])
        if not appid.isdigit():
            raise VdfError("vdf_check_failed", f"bad appid {appid!r}")
        want = ch["want"]
        extras_want = ch.get("extras") or {}
        st = new_state.get(appid, {})
        app = ed.app(appid)
        lo = launch_node(app)
        if lo is not None and lo.children is not None:
            results.append({"appid": appid, "error": "vdf_check_failed", "detail": "LaunchOptions is a section"})
            continue
        raw = lo.raw_value(data) if lo is not None else b""
        o = Options(raw, env, extras)
        before = o.state()
        res = {"appid": appid, "before": o.text, "state_before": before, "changed": False}
        new_raw = None
        if want == "on":
            if before == "modified":
                res["error"] = "token_modified"
            elif before == "manual" and not ch.get("adopt"):
                res["error"] = "manual_offload"
            elif before == "manual":
                new_raw, added = opt_adopt(raw, env, extras, extras_want)
                st = {"added_command": added, "adopted": True}
            elif before == "off":
                new_raw, added = opt_on(raw, env, extras, extras_want)
                st = {"added_command": added}
            elif before == "on":
                # Already on: only the extras inside the run can change.
                cur = o.extras_on()
                merged = {k: (bool(extras_want[k]) if extras_want.get(k) is not None else v)
                          for k, v in cur.items()}
                if merged != cur:
                    new_raw = opt_set_extras(raw, env, extras, merged)
        elif want == "off":
            if before == "modified":
                res["error"] = "token_modified"
            elif before == "on":
                new_raw = opt_off(raw, env, extras, bool(st.get("added_command")))
        else:
            res["error"] = "usage"
        if "error" in res:
            results.append(res)
            continue
        if new_raw is None:
            res["after"] = o.text
            res["state_after"] = before
            results.append(res)
            continue

        # Splice. Remove what the engine inserted when the value goes back to
        # empty, so on→off is byte-identical (§8.3).
        if want == "off" and new_raw == b"" and st.get("inserted") and lo is not None:
            only = len(app.children) == 1
            if st.get("inserted") == "block" and only:
                ed.remove(apps, app)
            else:
                ed.remove(app, lo)
            new_state.pop(appid, None)
        elif lo is not None:
            ed.set_value(lo, new_raw)
            if want == "off":
                new_state.pop(appid, None)
        elif app is not None:
            ed.add(app, LAUNCH_KEY.encode(), new_raw)
            st["inserted"] = "key"
        else:
            new_blocks.append((appid, new_raw))
            st["inserted"] = "block"
        if want == "on":
            new_state[appid] = st
        after = Options(new_raw, env, extras)
        res.update({"changed": True, "after": after.text, "state_after": after.state()})
        results.append(res)

    if new_blocks:
        items = [(a.encode(), [(LAUNCH_KEY.encode(), r)]) for a, r in new_blocks]
        if apps is not None:
            for k, v in items:
                ed.add(apps, k, v)
        else:
            # Build whatever is missing of Software/Valve/Steam/apps.
            depth = 0
            node = ed.root
            for name in APPS_PATH:
                nxt = node.find(name)
                if nxt is None or nxt.children is None:
                    break
                node = nxt
                depth += 1
            nested = items
            for name in reversed(APPS_PATH[depth + 1:]):
                nested = [(name.encode(), nested)]
            ed.add(node, APPS_PATH[depth].encode(), nested)

    changed = sum(1 for r in results if r.get("changed"))
    out = {"sha256": sha, "results": results, "state": new_state, "changed": changed, "tmp": None}
    if not changed:
        return out
    new, sp = ed.result()
    ed.verify(new, sp)
    if dry_run:
        return out
    # §8.2 check 4: the original must still be the bytes that were parsed.
    if sha256(read(path)) != sha:
        raise VdfError("vdf_changed_underneath", "localconfig.vdf changed while it was being edited")
    out["tmp"] = write_tmp(path, new)
    out["sha256_new"] = sha256(new)
    return out


def write_tmp(path, data):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=TMP_PREFIX, dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise VdfError("vdf_check_failed", f"cannot write temp file: {e.strerror}")
    return tmp


def fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def commit(path, tmp, sha, backup):
    def drop():
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if os.path.basename(tmp)[:len(TMP_PREFIX)] != TMP_PREFIX or \
            os.path.dirname(os.path.abspath(tmp)) != os.path.dirname(os.path.abspath(path)):
        raise VdfError("vdf_check_failed", "temp file is not next to the original")
    try:
        data = read(path)
    except VdfError:
        drop()
        raise
    if sha256(data) != sha:
        drop()
        raise VdfError("vdf_changed_underneath", "localconfig.vdf changed while it was being edited")
    try:
        os.makedirs(os.path.dirname(backup), exist_ok=True)
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if sha256(read(backup)) != sha:
            raise OSError(0, "backup does not read back")
    except (OSError, VdfError) as e:
        drop()
        raise VdfError("backup_failed", f"cannot write {backup}: {getattr(e, 'strerror', None) or e}")
    try:
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
    except OSError as e:
        drop()
        raise VdfError("vdf_check_failed", f"cannot replace {path}: {e.strerror}")
    fsync_dir(os.path.dirname(os.path.abspath(path)))
    return {"ok": True, "backup": backup}


def stage(src, path):
    data = read(src)
    ed = Editor(data)  # must be a localconfig.vdf that parses
    del ed
    cur = read(path)
    return {"tmp": write_tmp(path, data), "sha256": sha256(cur), "sha256_new": sha256(data)}


def main(argv):
    import argparse
    p = argparse.ArgumentParser(prog="vdf.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dump")
    d.add_argument("--lower", action="store_true")
    d.add_argument("files", nargs="*")
    for name in ("classify", "plan"):
        c = sub.add_parser(name)
        c.add_argument("--env", required=True)
        c.add_argument("--extras", default="[]")
        c.add_argument("--state", default="{}")
        if name == "plan":
            c.add_argument("--changes", required=True)
            c.add_argument("--dry-run", action="store_true")
            c.add_argument("file")
        else:
            c.add_argument("files", nargs="*")
    c = sub.add_parser("commit")
    for a in ("--file", "--tmp", "--sha", "--backup"):
        c.add_argument(a, required=True)
    s = sub.add_parser("stage")
    s.add_argument("--from", dest="src", required=True)
    s.add_argument("--file", required=True)
    a = p.parse_args(argv)

    if a.cmd == "dump":
        out = {}
        for f in a.files:
            try:
                data = read(f)
                out[f] = to_json(data, parse(data), a.lower)
            except VdfError as e:
                out[f] = {"error": e.code, "detail": e.detail, **e.extra}
        return out
    if a.cmd == "classify":
        env, extras, state = json.loads(a.env), json.loads(a.extras), json.loads(a.state)
        out = {}
        for f in a.files:
            try:
                out[f] = classify_file(f, env, extras, state)
            except VdfError as e:
                out[f] = {"error": e.code, "detail": e.detail, **e.extra}
        return out
    if a.cmd == "plan":
        return plan_file(a.file, json.loads(a.env), json.loads(a.extras), json.loads(a.state),
                         json.loads(a.changes), a.dry_run)
    if a.cmd == "commit":
        return commit(a.file, a.tmp, a.sha, a.backup)
    if a.cmd == "stage":
        return stage(a.src, a.file)
    return None


if __name__ == "__main__":
    try:
        result = main(sys.argv[1:])
    except VdfError as e:
        print(json.dumps({"error": e.code, "detail": e.detail, **e.extra}))
        sys.exit(1)
    print(json.dumps(result, ensure_ascii=False))
