import QtQuick
import qs.Ui
import "ui"
import "../common/Palette.js" as Palette
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
  property var theme: Palette.make({})
  property string density: "full"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }

  readonly property string title: "Details"
  readonly property string meta: ""

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property real u: view.theme.unit
  readonly property var sp: view.theme.space
  readonly property color dim: view.theme.secondary

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
    if (b.stored) parts.push("remembered")
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

  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : 300 * view.u)
  spacing: view.sp.section

  Text {
    width: parent.width
    visible: !view.s
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: view.statusNote !== "" ? "No eGPU status: " + view.statusNote + "." : "Waiting for the first status…"
    color: view.dim
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.font.body
  }

  Section {
    visible: view.errorCode !== ""
    label: "Problem"
    Fact { label: "Message"; value: Errors.message(view.errorCode) }
    Fact { label: "Code"; value: view.errorCode }
  }

  Section {
    visible: !!view.s
    label: "Enclosure"
    Fact { label: "Name"; value: view.bolt.name ? view.bolt.name + (view.bolt.vendor ? " (" + view.bolt.vendor + ")" : "") : "—" }
    Fact { label: "Thunderbolt"; value: view.boltLine() }
  }

  Section {
    visible: view.cardPresent
    label: "Graphics card"
    Fact { label: "Card"; value: view.orDash(view.cardName) }
    Fact {
      label: "Driver"
      value: view.driver.bound ? String(view.driver.bound) + (view.gpu.version ? " " + view.gpu.version : "") + " · " + view.modulesLine() : "not loaded"
    }
    Fact { label: "Link"; value: view.linkLine() }
    Fact { visible: !!view.gpu.ok; label: "Now"; value: Overview.telemetry(view.gpu) }
    Fact { visible: !!view.gpu.ok; label: "Memory"; value: view.memLine() }
  }

  Section {
    visible: !!view.gpu.ok
    label: view.procs.length === 0 ? "Apps on the eGPU" : "Apps on the eGPU (" + view.procs.length + ")"
    Fact { visible: view.procs.length === 0; label: ""; value: "None" }
    Repeater {
      model: view.procs
      delegate: Fact {
        required property var modelData
        label: Overview.base(modelData.name)
        value: (modelData.mem_mb ? Math.round(modelData.mem_mb) + " MB" : "") +
               (modelData.pid !== null && modelData.pid !== undefined ? (modelData.mem_mb ? " · " : "") + "pid " + modelData.pid : "")
      }
    }
  }

  Section {
    visible: view.cardPresent
    label: "Screens on the eGPU"
    Fact { visible: view.screens.length === 0; label: ""; value: "None" }
    Repeater {
      model: view.screens
      delegate: Fact {
        required property var modelData
        label: String(modelData.connector || "")
        value: (modelData.description ? String(modelData.description) + " · " : "") + (modelData.enabled ? "on" : "off")
      }
    }
  }

  // ------------------------------------------------------------ components

  // A titled group of facts. Children go into the inner column.
  component Section: Column {
    id: section
    property string label: ""
    default property alias rows: body.data
    width: view.width
    spacing: view.sp.row

    PanelSectionHeader {
      text: section.label
      foreground: view.theme.foreground
      fontFamily: view.theme.fontFamily
      fontSize: view.theme.font.caption
    }
    Column {
      id: body
      width: parent.width
      spacing: view.sp.row / 2
    }
  }

  // One "label  value" line. The value wraps; the label column is fixed so the
  // values line up down the view.
  component Fact: Item {
    id: fact
    property string label: ""
    property string value: ""
    width: view.width
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

    Text {
      id: labelText
      width: 92 * view.u
      textFormat: Text.PlainText
      text: fact.label
      color: view.dim
      elide: Text.ElideRight
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
    Text {
      id: valueText
      x: labelText.width + view.sp.row
      width: fact.width - x
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: fact.value
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }
}
