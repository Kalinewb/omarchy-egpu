import QtQuick
import Quickshell.Io
import "common"

// The eGPU service: the one status stream of the session (plan-gui.md §3).
//
// It runs `omarchy-egpu status watch` for as long as the shell runs. The engine
// writes JSON lines here and, as a side effect, keeps
// $XDG_RUNTIME_DIR/omarchy-egpu/status.json fresh for every other reader
// (plan-engine.md §5.1). The bar widget follows this object through the
// own-service lookup; the notch reads the file. Neither runs a watcher of its
// own, so there is never more than one, and the engine's flock enforces that
// anyway: a second `status watch` exits 3.
//
// It decides nothing. It holds the last status document and re-raises events;
// what they mean is the engine's, and how they look is the views'.
//
// Later phases add here, per §2: notifications from events (G7), the sleep
// notice and the Steam queue poll.
//
// Not keepLoaded (plan-gui.md §2): a write under the plugins folder destroys
// this object, its Process is terminated with it, and the rebuilt Service
// starts a new watcher on the released lock. Shell.qml mounts an enabled
// plugin's service whether or not it is keepLoaded (shell.qml _syncServices);
// keepLoaded only decides whether it survives a hot-reload.
Item {
  id: root

  // Injected by the host when the service is created (shell.qml ensureService).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Where this plugin is checked out, from where this file was loaded (as
  // omarchy-face's Service.qml does): the shell strips __sourceDir from
  // third-party manifests, and $HOME-built paths break under XDG_CONFIG_HOME.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  // ---------------------------------------------- what StatusSource follows

  // running   our watcher is up and has sent a status
  // starting  our watcher is up, nothing received yet
  // busy      another watcher holds the lock (exit 3): read its file instead
  // waiting   our watcher died; restarting after a back-off
  property string watchState: "starting"
  property var liveStatus: null
  property string liveOutcome: "waiting"

  readonly property bool ownWatcher: watchState === "running" || watchState === "starting"
  readonly property var status: ownWatcher ? root.liveStatus : fallback.status
  readonly property string outcome: ownWatcher ? root.liveOutcome : fallback.outcome
  readonly property bool watcherRunning: ownWatcher ? root.liveStatus !== null : fallback.watcherRunning

  signal event(var record)

  Engine {
    id: engine
    pluginDir: root.pluginDir
  }

  // The fallback is the notch's source: the file another watcher writes, and a
  // one-shot `status --json` when that goes stale. Parked while ours runs.
  StatusSource {
    id: fallback
    engine: engine
    reading: !root.ownWatcher
    onEvent: function (record) { if (!root.ownWatcher) root.event(record) }
  }

  // ------------------------------------------------------------- the stream

  property string lastKey: ""
  property real startedAt: 0
  property int failures: 0
  property bool stopping: false

  function line(text) {
    var rec
    try { rec = JSON.parse(String(text)) } catch (e) { return }
    if (!rec || typeof rec !== "object") return
    if (rec.type === "event") {
      root.event({ seq: Number(rec.seq) || 0, event: String(rec.event || ""), at: Number(rec.at) || 0,
                   detail: rec.detail || null })
      return
    }
    if (rec.type !== "status" || !rec.summary) return
    if (Number(rec.schema) > fallback.knownSchema) {
      root.liveStatus = null
      root.liveOutcome = "schema_newer"
      return
    }
    var doc = {}
    var key = {}
    for (var k in rec) {
      if (k === "type") continue
      doc[k] = rec[k]
      if (k !== "written_at" && k !== "seq") key[k] = rec[k]
    }
    // Same guard as StatusSource: an unchanged document is not reassigned.
    var keyText = JSON.stringify(key)
    if (keyText !== root.lastKey) {
      root.lastKey = keyText
      root.liveStatus = doc
    }
    root.liveOutcome = ""
    root.watchState = "running"
  }

  function start() {
    if (root.stopping || watcher.running) return
    root.watchState = "starting"
    root.liveOutcome = "waiting"
    root.startedAt = Date.now()
    watcher.command = engine.argv(["status", "watch"])
    watcher.running = true
  }

  function exited(code) {
    if (root.stopping) return
    root.liveStatus = null
    root.lastKey = ""
    if (code === 3) {
      // Someone else is the watcher (a terminal, a second shell). Their file
      // is as good as ours; try to take over now and then, in case they stop.
      root.watchState = "busy"
      retry.interval = 60000
    } else {
      // A watcher that ran for a minute was healthy; its death starts the
      // back-off from the bottom. One that keeps dying waits longer each time,
      // up to a minute, so a broken engine is not respawned in a tight loop.
      if (Date.now() - root.startedAt > 60000) root.failures = 0
      root.failures = root.failures + 1
      root.watchState = "waiting"
      var steps = [2000, 5000, 15000, 30000, 60000]
      retry.interval = steps[Math.min(root.failures, steps.length) - 1]
      console.warn("kalinewb.egpu", "status watch exited", code, "- restarting in", retry.interval, "ms")
    }
    retry.restart()
  }

  Process {
    id: watcher
    running: false
    stdout: SplitParser {
      onRead: function (data) { root.line(data) }
    }
    onExited: function (code, status) { root.exited(code) }
  }

  Timer {
    id: retry
    repeat: false
    onTriggered: root.start()
  }

  Component.onCompleted: root.start()

  // Terminated, not orphaned: an orphan would keep the lock, and the Service
  // rebuilt after a plugin reload would find itself "busy" for a session.
  Component.onDestruction: {
    root.stopping = true
    retry.stop()
    if (watcher.running) watcher.signal(15)
  }
}
