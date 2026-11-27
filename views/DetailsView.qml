import QtQuick
import "../ui"
import "../common/Errors.js" as Errors
import "../common/Facts.js" as Facts
import "../common/Overview.js" as Overview

// Details: everything the Overview leaves out, read-only (ui-scope.md §2.2,
// plan-gui.md §5.1's rows). Pushed over the Overview by its "Details ›";
// Back returns to it.
//
// The enclosure, the card, its driver and link, what it is doing now, the
// apps on it and the screens on it. The link is plain information, never a
// warning: 2.5 GT/s x4 right after connect is normal (binding fact 3). An
// error's engine code lives here, and only here (ux.md rule 3).
//
// It refreshes as the status does (the watcher, at least every 5 s).
// ui-scope.md asks for 2 s while open; that needs a faster telemetry read
// from the engine, which is a follow-up, not something to poll from here.
//
// A shared view (plan-gui.md §5.0), as views/StatusView.qml.
Column {
  id: view

  // ----------------------------------------------------- shared interface
  property var status: null
  property var engine: null
  required property var theme
  property string density: "full"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }
  readonly property bool canPop: false
  function activatePrimary() { return false }

  readonly property string title: "Details"

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property var sp: view.theme.sp

  readonly property var bolt: view.s && view.s.bolt ? view.s.bolt : ({})
  readonly property var pci: view.s && view.s.pci ? view.s.pci : ({})
  readonly property var gpu: view.s && view.s.gpu ? view.s.gpu : ({})
  readonly property var driver: view.s && view.s.driver ? view.s.driver : ({})
  readonly property bool cardPresent: !!view.pci.present
  readonly property string cardName: view.gpu.name ? String(view.gpu.name) : (view.pci.name ? String(view.pci.name) : "")
  readonly property var procs: Facts.list(view.gpu.procs)
  readonly property var screens: {
    var m = Facts.list(view.s && view.s.display ? view.s.display.monitors : null)
    return m.filter(function (x) { return x && x.status === "connected" })
  }
  readonly property string errorCode: view.s && view.s.summary && view.s.summary.state === "error"
    ? (view.gpu.error ? String(view.gpu.error) : (view.bolt.status === "auth-error" ? "auth_error" : "")) : ""

  // What is installed: read from the health rows, so it is filled even with nothing plugged in.
  readonly property var healthRows: view.health && view.health.rows ? view.health.rows : []
  function healthTitle(id) {
    for (var i = 0; i < view.healthRows.length; i++)
      if (view.healthRows[i] && view.healthRows[i].id === id) return String(view.healthRows[i].title || "")
    return ""
  }
  // The row's title without the words the label already says ("System half 0.1.3 installed" -> "0.1.3 installed").
  function healthShort(id, prefix) {
    var t = view.healthTitle(id)
    var low = t.toLowerCase(), p = prefix.toLowerCase()
    if (low.indexOf(p) === 0) t = t.slice(p.length).replace(/^\s*(is\s+|:\s*)?/, "")
    return view.orDash(t)
  }

  function orDash(v) { return v === null || v === undefined || v === "" ? "—" : String(v) }

  function boltLine() {
    var b = view.bolt
    if (!view.s) return ""
    if (b.domain === false) return "No Thunderbolt or USB4 port"
    if (b.daemon === false) return "Thunderbolt support is not answering"
    if (!b.uuid) return "No enclosure seen yet"
    var words = { connected: "plugged in, waiting to be allowed", authorized: "connected", disconnected: "not plugged in",
                  "auth-error": "could not be allowed", authorizing: "being allowed" }
    var parts = [words[b.status] || String(b.status || "unknown")]
    if (b.stored) parts.push("saved")
    if (b.generation) parts.push(String(b.generation))
    return parts.join(" · ")
  }

  function modulesLine() {
    var m = view.driver.modules || {}
    var on = [], off = []
    for (var k in m) (m[k] ? on : off).push(k)
    if (on.length === 0 && off.length === 0) return "—"
    if (off.length === 0) return "loaded"
    if (on.length === 0) return "not loaded"
    return "partly loaded (" + off.join(", ") + " missing)"
  }

  function linkLine() {
    var l = view.pci.link
    if (!l) return "—"
    var now = "PCIe " + String(l.speed || "?").replace(/ PCIe$/, "") + " × " + view.orDash(l.width)
    if (l.max_speed || l.max_width)
      now += " (up to " + String(l.max_speed || "?").replace(/ PCIe$/, "") + " × " + view.orDash(l.max_width) + ")"
    return now
  }

  function memLine() {
    var g = view.gpu
    if (g.mem_used_mb === null || g.mem_used_mb === undefined) return "—"
    return Math.round(g.mem_used_mb) + " MB in use"
  }

  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : view.theme.space(300))

  // Nothing to show yet: the kit's empty state, in words.
  UEmpty {
    theme: view.theme
    width: parent.width
    visible: !view.s
    text: view.statusNote !== "" ? "No eGPU status: " + view.statusNote + "." : "Waiting for the first status…"
  }

  USection {
    theme: view.theme
    visible: view.errorCode !== ""
    title: "Problem"
    first: true
    Fact { label: "Message"; shown: Errors.message(view.errorCode) }
    Fact { label: "Code"; shown: view.errorCode }
  }

  USection {
    theme: view.theme
    visible: !!view.s
    title: "Enclosure"
    first: view.errorCode === ""
    Fact { label: "Name"; shown: view.bolt.name ? view.bolt.name + (view.bolt.vendor ? " (" + view.bolt.vendor + ")" : "") : "—" }
    Fact { label: "Thunderbolt"; shown: view.boltLine() }
  }

  USection {
    theme: view.theme
    visible: view.cardPresent
    title: "Graphics card"
    Fact { label: "Card"; shown: view.orDash(view.cardName) }
    Fact {
      label: "Driver"
      shown: view.driver.bound ? String(view.driver.bound) + (view.gpu.version ? " " + view.gpu.version : "") + " · " + view.modulesLine() : "not loaded"
    }
    Fact { label: "Link"; shown: view.linkLine() }
    Fact { visible: !!view.gpu.ok; label: "Now"; shown: Overview.telemetry(view.gpu) }
    Fact { visible: !!view.gpu.ok; label: "Memory"; shown: view.memLine() }
  }

  USection {
    theme: view.theme
    visible: !!view.gpu.ok
    title: view.procs.length === 0 ? "Apps on the eGPU" : "Apps on the eGPU (" + view.procs.length + ")"
    Fact { visible: view.procs.length === 0; label: "None" }
    Repeater {
      model: view.procs
      delegate: Fact {
        required property var modelData
        label: Overview.base(modelData.name)
        shown: (modelData.mem_mb ? Math.round(modelData.mem_mb) + " MB" : "") +
               (modelData.pid !== null && modelData.pid !== undefined ? (modelData.mem_mb ? " · " : "") + "pid " + modelData.pid : "")
      }
    }
  }

  USection {
    theme: view.theme
    visible: view.cardPresent
    title: "Screens on the eGPU"
    Fact { visible: view.screens.length === 0; label: "None" }
    Repeater {
      model: view.screens
      delegate: Fact {
        required property var modelData
        label: String(modelData.connector || "")
        shown: (modelData.description ? String(modelData.description) + " · " : "") + (modelData.enabled ? "on" : "off")
      }
    }
  }

  USection {
    theme: view.theme
    visible: view.healthRows.length > 0
    title: "Installed"
    // A line the health does not answer is left out, not shown as a dash.
    Fact { visible: view.healthTitle("system.helper") !== ""; label: "System half"; shown: view.healthShort("system.helper", "System half") }
    Fact { visible: view.healthTitle("system.autoconnect") !== ""; label: "Auto-connect"; shown: view.healthShort("system.autoconnect", "Auto-connect") }
    Fact { visible: view.healthTitle("driver.sleep") !== ""; label: "Sleep units"; shown: view.healthShort("driver.sleep", "NVIDIA sleep units") }
    Fact { visible: view.healthTitle("tools.vulkaninfo") !== ""; label: "Vulkan"; shown: view.healthShort("tools.vulkaninfo", "") }
    Fact { visible: view.healthTitle("steam.client") !== ""; label: "Steam"; shown: view.healthShort("steam.client", "") }
  }

  // ------------------------------------------------------------ components

  // One "label  value" line: the kit's row, with the value in its slot so a
  // long one wraps (a row's own `value` is one line) and the row grows to hold it.
  component Fact: URow {
    id: fact
    property string shown: ""
    theme: view.theme
    Text {
      visible: fact.shown !== ""
      width: Math.min(implicitWidth, Math.max(view.theme.space(120), fact.width * 0.62))
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      horizontalAlignment: Text.AlignRight
      text: fact.shown
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
}
