import QtQuick
import Quickshell
import Quickshell.Io

// Every one-shot call either shell makes to the engine (plan-gui.md §3).
//
// One place that knows where bin/omarchy-egpu is, how it is launched and what
// its exit codes mean (plan-engine.md §1.1), so a view never builds a command
// line and never reads an exit code. Each shell owns exactly one of these; the
// views are handed it as `engine` and call run().
//
//   run(args, onDone)   args is the argv AFTER the engine path, e.g.
//                       ["status", "--json"]. Never a joined string: a monitor
//                       or game name with a space must arrive as one argument.
//
//   onDone({ok, json, code, error, text})
//     ok     exit 0
//     json   stdout parsed, or null (prose-only verbs succeed with null)
//     text   stdout as it came
//     code   the exit code: 0 ok, 1 refused/failed, 3 busy, 126 declined,
//            127 helper not installed; 2 is this file's "engine missing"
//     error  "" on success, else the engine's {"error": …} code, or "busy",
//            or "exit <n>" when it printed none. common/Errors.js turns it into
//            a sentence.
//
// Long-running streams (`status watch`) are not run here: the Service owns that
// one process for the session, and reads it line by line.
//
// Three calls that are not the engine, for Setup (ui-scope.md §2.6, §7), all
// through the same pool so no view ever holds a Process:
//   installCommand(mode, onDone)  the pinned command system/install.sh
//                                 --print-command prints (no root; it only
//                                 prints). onDone({ok, command, …})
//   openTerminal(script, onDone)  Omarchy's floating terminal running
//                                 `script` (common/Install.js), detached.
//                                 127: the launcher is not there
//   copy(text, onDone)            wl-copy; ok only once wl-copy said so
// In development (OMARCHY_EGPU_DEV_BIN) the last two run dev/bin/egpu-launch-stub
// instead, which records what it was given: no gate ever opens a terminal,
// asks for a password, or touches the clipboard.
Item {
  id: root

  // Where the plugin is checked out. The shells pass Qt.resolvedUrl's answer,
  // never a path built from $HOME: under a custom XDG_CONFIG_HOME that is wrong
  // (plan-gui.md §3, against profiles:Panel.qml:40).
  property string pluginDir: ""

  // Development (plan-gui.md §9): the stub engine in dev/bin answers from
  // fixtures instead.
  readonly property string devBin: Quickshell.env("OMARCHY_EGPU_DEV_BIN") || ""
  readonly property bool dev: devBin !== ""
  readonly property string path: dev ? devBin + "/omarchy-egpu"
                                     : (pluginDir !== "" ? pluginDir + "/bin/omarchy-egpu" : "")

  // The verbs the engine in this checkout answers, as "<module> <verb>". A
  // view draws a button only for a verb that exists: the status contract has
  // no field that says one does, and a button that can only answer "usage" is
  // worse than none (views/StatusView.qml). The engine ships in this same
  // folder, so the list cannot drift from it; each engine phase adds its own
  // (E3 `device connect`, E5 `device eject`/`device rescan`/`device holders`,
  // E4 `display …`).
  readonly property var builtVerbs: ["status", "status watch", "health",
    "steam roots", "steam accounts", "steam list", "steam status", "steam set", "steam set-all",
    "steam apply", "steam close", "steam restore",
    "device connect", "device eject", "device rescan", "device holders",
    // lib/display.sh (E4). Only the verb Setup's Fix runs is listed: the
    // monitor verbs arrive with the Screens view (G4), and listing them now
    // would draw the compact view's HDMI toggle before it is checked.
    "display apply"]
  // Development only: OMARCHY_EGPU_DEV_VERBS="device connect,display off"
  // pretends more exist, so a gated button can be rendered (dev/g8-offscreen.sh)
  // before its phase lands. The stub engine still answers them "usage".
  readonly property var verbs: {
    var extra = dev ? String(Quickshell.env("OMARCHY_EGPU_DEV_VERBS") || "") : ""
    return extra === "" ? builtVerbs : builtVerbs.concat(extra.split(",").map(function (v) { return v.trim() }))
  }
  function can(verb) { return root.verbs.indexOf(String(verb)) !== -1 }

  // Where the watcher keeps status.json: the engine's own rule, $EGPU_RUN or
  // $XDG_RUNTIME_DIR/omarchy-egpu (plan-engine.md §4.1, §5.1). The stub's
  // default is a separate directory so it can never overwrite the real file.
  readonly property string runDir: {
    var e = Quickshell.env("EGPU_RUN") || ""
    if (e !== "") return e
    var x = Quickshell.env("XDG_RUNTIME_DIR") || ""
    return x === "" ? "" : x + (dev ? "/omarchy-egpu-dev" : "/omarchy-egpu")
  }

  // The argv that runs the engine with these arguments. The wrapper answers
  // for a missing engine itself, in the engine's own JSON shape, so "the file
  // is not there" is told apart from pkexec's 127 ("the helper is not").
  function argv(args) {
    return ["bash", "-c", "[ -x \"$1\" ] || { printf '{\"error\":\"engine_missing\"}\\n'; exit 2; }; exec \"$@\"",
            "--", root.path].concat(args || [])
  }

  function run(args, onDone) {
    root.exec(root.argv(args), onDone)
  }

  // Any argv, through the pool. Only this file builds one.
  function exec(argv, onDone) {
    var job = { argv: argv, done: onDone || null }
    for (var i = 0; i < root.pool.length; i++) {
      if (!root.pool[i].busy) { root.start(root.pool[i], job); return }
    }
    // Four at once is more than any view needs; a fifth waits rather than
    // letting a stuck engine call spawn processes without bound.
    root.queue = root.queue.concat([job])
  }

  property var queue: []

  function start(proc, job) {
    proc.busy = true
    proc.job = job
    proc.collected = ""
    proc.command = job.argv
    proc.running = true
  }

  function finished(proc, code) {
    var job = proc.job
    var out = String(proc.collected || "")
    proc.busy = false
    proc.job = null

    var json = null
    if (out.trim() !== "") {
      try { json = JSON.parse(out) } catch (e) { json = null }
    }
    var err = ""
    if (code !== 0) {
      if (json && typeof json === "object" && json.error !== undefined) err = String(json.error)
      else err = code === 3 ? "busy" : "exit " + code
    }

    // The slot is handed on before the callback runs: a callback that throws
    // must not strand whatever was queued behind it.
    if (root.queue.length > 0) {
      var next = root.queue[0]
      root.queue = root.queue.slice(1)
      root.start(proc, next)
    }
    if (job && job.done) job.done({ ok: code === 0, json: json, code: code, error: err, text: out })
  }

  // ------------------------------------------------- Setup's outside calls

  // The repository root: the plugin folder, or in development the checkout
  // dev/bin sits in.
  readonly property string repoDir: dev ? devBin.replace(/\/+$/, "") + "/../.." : pluginDir
  readonly property string launchStub: devBin + "/egpu-launch-stub"

  function installCommand(mode, onDone) {
    var m = String(mode || "install")
    root.exec(["bash", root.repoDir + "/system/install.sh", "--print-command", m], function (result) {
      var cmd = String(result.text || "").replace(/\n+$/, "")
      onDone({ ok: result.ok && cmd !== "", command: cmd, code: result.code, error: result.error })
    })
  }

  // Detached (setsid -f): the terminal outlives this call and the pool slot
  // is free at once. `command -v` first, so a missing launcher answers 127
  // instead of a terminal that never appears.
  function openTerminal(script, onDone) {
    if (root.dev) { root.exec([root.launchStub, "terminal", String(script)], onDone); return }
    root.exec(["bash", "-c", "command -v \"$1\" >/dev/null 2>&1 || exit 127; setsid -f \"$@\" >/dev/null 2>&1 </dev/null",
               "--", "omarchy-launch-floating-terminal-with-presentation", String(script)], onDone)
  }

  function copy(text, onDone) {
    if (root.dev) { root.exec([root.launchStub, "copy", String(text)], onDone); return }
    // wl-copy forks to serve the selection; its child must not keep the
    // pool's stdout pipe open, or the call would end only when the selection
    // is replaced.
    root.exec(["bash", "-c", "wl-copy -- \"$1\" >/dev/null 2>&1 </dev/null", "--", String(text)], onDone)
  }

  EngineProcess { id: proc0 }
  EngineProcess { id: proc1 }
  EngineProcess { id: proc2 }
  EngineProcess { id: proc3 }
  readonly property var pool: [proc0, proc1, proc2, proc3]

  // Declared, never created per call: a Process built at call time can be
  // collected while it is still running (profiles:Panel.qml:1990-1991).
  component EngineProcess: Process {
    id: p
    property bool busy: false
    property var job: null
    property string collected: ""

    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: p.collected = text
    }
    onExited: function (code, status) { root.finished(p, code) }
  }
}
