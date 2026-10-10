import QtQuick
import qs.Ui
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors
import "../common/Facts.js" as Facts

// Overview: what the eGPU is doing, as the engine says it (plan-gui.md §5.1).
//
// A shared view (§5.0): the standalone popup shows it as its Overview tab and
// the notch will show it inside its own panel, from this same file. So it
// reads colours and sizes only from `theme` (§5.0's `palette`, renamed because
// every Qt Quick Item already has a `palette` property, and shadowing it would
// also change what child controls inherit), runs nothing itself, and is a pure
// function of `status` — the E§5 document — plus the engine calls its buttons
// will make.
//
// What is here is the read-only half: the facts, the hints and the banners.
// The buttons (Connect, Safe eject, Reconnect, Run on eGPU) land with the
// engine verbs they run (G2/E3, G3/E5). Until then they are not drawn at all:
// the status contract has no field that says a verb exists, and a button that
// can only fail is worse than none.
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
  // Additive to §5.0: StatusSource.outcomeText, shown when there is no status
  // or when the one shown will not update ("watcher not running").
  property string statusNote: ""

  signal requestRoute(string name)
  signal requestClose()

  // No sub-sheets yet (the eject sheet arrives with G3), so Back always falls
  // through to the shell.
  function popView() { return false }

  // What a shell shows above this view: its own header is the shell's, its
  // words are the view's.
  readonly property string title: {
    if (!view.s) return "eGPU"
    if (view.s.bolt && view.s.bolt.name) return String(view.s.bolt.name)
    return view.cardName !== "" ? view.cardName : "eGPU"
  }
  readonly property string meta: view.s && view.s.summary ? String(view.s.summary.line || "") : view.statusNote

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property bool full: view.density !== "compact"
  readonly property real u: view.theme.unit
  readonly property color dim: view.theme.secondary

  readonly property var bolt: view.s && view.s.bolt ? view.s.bolt : ({})
  readonly property var pci: view.s && view.s.pci ? view.s.pci : ({})
  readonly property var gpu: view.s && view.s.gpu ? view.s.gpu : ({})
  readonly property var driver: view.s && view.s.driver ? view.s.driver : ({})
  readonly property string phase: view.s ? String(view.s.phase || "") : ""
  readonly property bool cardPresent: !!view.pci.present
  readonly property string cardName: view.gpu.name ? String(view.gpu.name) : (view.pci.name ? String(view.pci.name) : "")
  readonly property var procs: Array.isArray(view.gpu.procs) ? view.gpu.procs : []
  readonly property bool relogin: !!(view.s && view.s.display && view.s.display.needs_relogin)
  readonly property bool held: !!(view.s && view.s.modules && view.s.modules.held_after_eject)

  // The banners below say these conditions already, so the enclosure
  // profile's hint for the same one would only repeat it.
  readonly property var hints: {
    var h = view.s && Array.isArray(view.s.hints) ? view.s.hints : []
    var out = []
    for (var i = 0; i < h.length; i++) {
      if (!h[i] || !h[i].text) continue
      if (h[i].id === "needs_relogin" && view.relogin) continue
      if (h[i].id === "held_after_eject" && view.held) continue
      if (h[i].id === "smi_hung" && view.gpu.error === "smi_hung") continue
      out.push(String(h[i].text))
    }
    return out
  }

  function basename(p) { var t = String(p || ""); var i = t.lastIndexOf("/"); return i >= 0 ? t.substring(i + 1) : t }
  function orDash(v) { return v === null || v === undefined || v === "" ? "—" : String(v) }

  function boltLine() {
    var b = view.bolt
    if (!view.s) return ""
    if (b.daemon === false) return "Thunderbolt service (boltd) is not running"
    if (!b.uuid) return "No Thunderbolt enclosure"
    var parts = [b.status ? String(b.status) : "unknown"]
    if (b.policy) parts.push("policy " + b.policy)
    if (b.stored) parts.push("remembered")
    if (b.generation) parts.push(String(b.generation))
    return parts.join(" · ")
  }

  function modulesLine() {
    var m = view.driver.modules || {}
    var on = [], off = []
    for (var k in m) (m[k] ? on : off).push(k)
    if (on.length === 0 && off.length === 0) return "—"
    if (off.length === 0) return "all loaded (" + on.join(", ") + ")"
    if (on.length === 0) return "not loaded"
    return on.join(", ") + " loaded; " + off.join(", ") + " not"
  }

  function kmsLine() {
    var d = view.driver
    if (d.modeset === null && d.fbdev === null) return "unknown"
    function w(v) { return v === true ? "on" : (v === false ? "off" : "unknown") }
    return "modeset " + w(d.modeset) + " · fbdev " + w(d.fbdev)
  }

  // Plain information, never a warning: 2.5 GT/s x4 right after connect is
  // normal (binding fact 3; plan-gui.md §5.1).
  function linkLine() {
    var l = view.pci.link
    if (!l) return "—"
    var now = String(l.speed || "?").replace(/ PCIe$/, "") + " × " + view.orDash(l.width)
    if (l.max_speed || l.max_width)
      now += " · max " + String(l.max_speed || "?").replace(/ PCIe$/, "") + " × " + view.orDash(l.max_width)
    return now
  }

  function nowLine() { return Facts.now(view.gpu) }

  // Sized by the shell's maxWidth (§5.0); a Column's implicit width is its own.
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : 300 * view.u)
  spacing: 10 * view.u

  // ------------------------------------------------------------ no status
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

  // Shown above everything when the status will not update by itself.
  Text {
    width: parent.width
    visible: !!view.s && view.statusNote !== ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: "Not live: " + view.statusNote + "."
    color: view.theme.warn
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.font.caption
  }

  // -------------------------------------------------------------- banners
  Banner {
    shown: view.relogin
    tone: view.theme.warn
    text: Errors.note("needs_relogin")
  }
  Banner {
    shown: view.held
    tone: view.theme.warn
    text: Errors.note("held_after_eject")
  }
  Banner {
    shown: !!view.s && view.s.backend && view.s.backend.name !== null && view.s.backend.supported === false
    tone: view.theme.warn
    text: Errors.message("backend_stub")
  }
  Banner {
    shown: view.gpu.error === "smi_hung"
    tone: view.theme.bad
    text: Errors.message("smi_hung")
  }
  Repeater {
    model: view.hints
    delegate: Banner {
      required property var modelData
      shown: true
      tone: view.theme.accent
      text: modelData
    }
  }

  // ---------------------------------------------------------------- facts
  Section {
    visible: !!view.s
    label: "Enclosure"
    Fact { label: "Device"; value: view.bolt.name ? view.bolt.name + (view.bolt.vendor ? " (" + view.bolt.vendor + ")" : "") : "—" }
    Fact { label: "Thunderbolt"; value: view.boltLine() }
    Fact { visible: view.full && !!view.bolt.profile; label: "Profile"; value: view.orDash(view.bolt.profile) }
  }

  Section {
    visible: view.cardPresent
    label: "Card"
    Fact { label: "GPU"; value: view.orDash(view.cardName) }
    Fact {
      label: "Driver"
      value: view.driver.bound ? String(view.driver.bound) + (view.gpu.version ? " " + view.gpu.version : "") : "none bound"
    }
    Fact { visible: view.full; label: "Modules"; value: view.modulesLine() }
    Fact { visible: view.full && view.driver.bound === "nvidia"; label: "KMS"; value: view.kmsLine() }
    Fact { visible: !!view.gpu.ok; label: "Now"; value: view.nowLine() }
    Fact { visible: view.full; label: "Link"; value: view.linkLine() }
  }

  Section {
    visible: view.full && !!view.gpu.ok
    label: view.procs.length === 0 ? "Apps on the eGPU" : "Apps on the eGPU (" + view.procs.length + ")"
    Fact { visible: view.procs.length === 0; label: ""; value: "None" }
    Repeater {
      model: view.procs
      delegate: Fact {
        required property var modelData
        label: modelData.pid !== null && modelData.pid !== undefined ? String(modelData.pid) : ""
        value: view.basename(modelData.name) + (modelData.mem_mb ? " · " + Math.round(modelData.mem_mb) + " MB" : "")
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
    spacing: 4 * view.u

    PanelSectionHeader {
      text: section.label
      foreground: view.theme.foreground
      fontFamily: view.theme.fontFamily
      fontSize: view.theme.font.caption
    }
    Column {
      id: body
      width: parent.width
      spacing: 2 * view.u
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
      width: 84 * view.u
      textFormat: Text.PlainText
      text: fact.label
      color: view.dim
      elide: Text.ElideRight
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
    Text {
      id: valueText
      x: labelText.width + 8 * view.u
      width: fact.width - x
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: fact.value
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }

  // A sentence that matters more than a fact: a rule in the tone's colour and
  // the text beside it. No filled background, so it reads the same on the
  // popup's surface and on the notch's (which forbids own backgrounds).
  component Banner: Item {
    id: banner
    property bool shown: false
    property color tone: view.theme.foreground
    property string text: ""
    visible: shown
    width: view.width
    implicitHeight: bannerText.implicitHeight + 4 * view.u

    Rectangle {
      width: 3 * view.u
      height: parent.height
      radius: width / 2
      color: banner.tone
    }
    Text {
      id: bannerText
      x: 10 * view.u
      y: 2 * view.u
      width: banner.width - x
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: banner.text
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }
}
