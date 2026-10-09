import QtQuick
import Quickshell.Io
import "Errors.js" as Errors

// The one way anything in this plugin reads eGPU state (plan-gui.md §3).
//
// Two sources, one interface. Views get `status` and never learn which:
//
//   service   the plugin's own Service, which runs `omarchy-egpu status watch`
//             for the session. The standalone bar widget gets it through the
//             own-service lookup third-party plugins are allowed
//             (omarchy:shell/README.md:96).
//   file      no service to ask (the notch, a replacement bar, or the Service
//             itself when another watcher already holds the lock): a FileView
//             on $XDG_RUNTIME_DIR/omarchy-egpu/status.json, which the watcher
//             rewrites atomically at least every 5 s. Older than 10 s, or not
//             there at all, means no watcher is running (plan-engine.md §5.1):
//             then `status --json` is run once and the answer is shown with
//             "watcher not running" beside it.
//
// Exposed: status (the E§5 document, or null), outcome (why it is null or
// stale; "" when live), outcomeText (the same as a sentence), watcherRunning,
// and event(record), raised once per new last_event.seq — never for the event
// already in the first document read, which happened before anyone was
// looking. A record is {seq, event, at, detail} from either source: the
// watcher's event line and status.json's last_event name the event
// differently (`event` / `type`), and a consumer should not have to know.
Item {
  id: root

  // Set to the Service to follow it; null for the file source.
  property var service: null
  // Runs the one-shot fallback. Without one the file is all there is.
  property var engine: null
  // Whether a watcher is meant to be running. False only for a consumer that
  // knows there is none, so a stale file is not reported as a fault.
  property bool expectWatcher: true
  // False parks the file source entirely (no watch, no timer). The Service
  // sets it while its own watcher is the source.
  property bool reading: true

  // The newest schema this plugin understands (plan-engine.md §5.1: a consumer
  // refuses a newer one and says "update the plugin").
  readonly property int knownSchema: 1
  readonly property int staleMs: 10000

  readonly property bool following: root.service !== null && root.service !== undefined
  readonly property var status: following ? root.service.status : root.fileStatus
  readonly property string outcome: following ? String(root.service.outcome || "") : root.fileOutcome
  readonly property string source: following ? "service" : root.fileSource
  readonly property bool watcherRunning: following ? !!root.service.watcherRunning : root.fileOutcome === ""
  readonly property string outcomeText: root.describe(root.outcome)

  signal event(var record)

  function describe(o) {
    if (o === "") return ""
    if (o === "waiting") return "waiting for the first status"
    if (o === "stale") return "watcher not running"
    if (o === "schema_newer") return "status from a newer engine; update the plugin"
    if (o === "no_runtime_dir") return "no runtime directory (XDG_RUNTIME_DIR unset)"
    if (o.indexOf("engine:") === 0) return Errors.message(o.substring(7))
    return o
  }

  // ------------------------------------------------------------ file source

  property var fileStatus: null
  property string fileOutcome: "waiting"
  property string fileSource: ""
  // The document minus its clock: a heartbeat rewrites written_at every 5 s,
  // and reassigning `status` for that alone would rebuild every Repeater in
  // every view (and drop the hover under a still pointer,
  // profiles:Panel.qml:1249-1257).
  property string lastKey: ""
  property real writtenAt: 0
  property int lastEventSeq: -1
  property bool oneShotRunning: false
  property string oneShotError: ""
  property bool schemaNewer: false
  // Whether the file has been read (or found missing) at least once.
  property bool fileTried: false
  property real lastOneShot: 0

  readonly property string path: root.engine && root.engine.runDir !== "" ? root.engine.runDir + "/status.json" : ""

  // Takes one document from the file or a one-shot run. Returns false for
  // anything that is not a status document this plugin can read.
  //
  // Only the file's written_at ages the source: a one-shot answer is computed
  // fresh but nothing will refresh it, so it must not make a dead watcher look
  // alive.
  function accept(doc, from) {
    if (!doc || typeof doc !== "object" || !doc.summary) return false
    if (from === "file") root.writtenAt = Number(doc.written_at) || 0
    if (Number(doc.schema) > root.knownSchema) {
      root.schemaNewer = true
      root.fileStatus = null
      root.lastKey = ""
      return false
    }
    root.schemaNewer = false
    var copy = {}
    for (var k in doc) if (k !== "written_at" && k !== "seq" && k !== "type") copy[k] = doc[k]
    var key = JSON.stringify(copy)
    if (key !== root.lastKey) {
      root.lastKey = key
      root.fileStatus = doc
    }
    root.fileSource = from
    var ev = doc.last_event
    if (ev && ev.seq !== undefined) {
      if (root.lastEventSeq >= 0 && Number(ev.seq) > root.lastEventSeq)
        root.event({ seq: Number(ev.seq), event: String(ev.type || ""), at: Number(ev.at) || 0,
                     detail: ev.detail || null })
      root.lastEventSeq = Math.max(root.lastEventSeq, Number(ev.seq))
    } else if (root.lastEventSeq < 0) {
      root.lastEventSeq = 0
    }
    return true
  }

  function checkFresh() {
    if (root.following || !root.reading) return
    // Not before the file has been tried once: at start-up "not read yet"
    // would otherwise look like "no watcher" and cost a needless one-shot.
    if (root.path !== "" && !root.fileTried) return
    var fresh = root.path !== "" && root.writtenAt > 0 && Date.now() - root.writtenAt <= root.staleMs
    // A newer engine: a one-shot would answer in the same newer schema, so
    // there is nothing to retry until the plugin is updated.
    if (root.schemaNewer) { root.fileOutcome = "schema_newer"; return }
    if (fresh || (!root.expectWatcher && root.fileStatus)) { root.fileOutcome = ""; return }
    if (!root.fileStatus && root.oneShotError !== "") root.fileOutcome = "engine:" + root.oneShotError
    else if (root.path === "") root.fileOutcome = root.fileStatus ? "stale" : "no_runtime_dir"
    else root.fileOutcome = "stale"
    root.oneShot()
  }

  // `status --json` computes everything fresh, bounded to ~10 s by the
  // engine's hang guard (plan-engine.md §5.1). Once on going stale, then no
  // more often than every 30 s while it stays stale: without a watcher this is
  // the only way the bar learns anything, but it is a whole recompute.
  function oneShot() {
    if (!root.engine || root.oneShotRunning) return
    if (root.lastOneShot > 0 && Date.now() - root.lastOneShot < 30000) return
    root.oneShotRunning = true
    root.lastOneShot = Date.now()
    root.engine.run(["status", "--json"], function (result) {
      root.oneShotRunning = false
      if (root.following || !root.reading) return
      // A watcher came back while this ran: its file is newer than this answer.
      if (root.path !== "" && root.writtenAt > 0 && Date.now() - root.writtenAt <= root.staleMs) return
      if (result.ok && root.accept(result.json, "oneshot")) root.oneShotError = ""
      else if (!result.ok) root.oneShotError = result.error
      root.checkFresh()
    })
  }

  FileView {
    id: file
    path: root.following || !root.reading ? "" : root.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    property string lastText: ""
    onLoaded: {
      root.fileTried = true
      var t = text()
      if (t === file.lastText) return
      file.lastText = t
      try {
        root.accept(JSON.parse(t), "file")
        root.checkFresh()
      } catch (e) {
        // A torn read cannot happen with the watcher's rename, so this is
        // something else writing there. Keep the last good document.
        console.warn("kalinewb.egpu", "Ignoring unreadable status file", root.path, e)
      }
    }
    onLoadFailed: { root.fileTried = true; root.checkFresh() }
  }

  // The watch cannot announce a file whose directory did not exist when it
  // began (the first watcher creates it), and the atomic rename replaces the
  // inode it watches. So the file is also re-read on a timer: cheap, and the
  // text comparison above makes an unchanged read free. The same tick ages the
  // document, which is how a watcher that died is noticed.
  Timer {
    interval: 1000
    repeat: true
    running: !root.following && root.reading
    triggeredOnStart: true
    onTriggered: {
      if (root.path !== "") file.reload()
      root.checkFresh()
    }
  }

  Connections {
    target: root.following ? root.service : null
    ignoreUnknownSignals: true
    function onEvent(record) { root.event(record) }
  }
}
