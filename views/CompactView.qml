import QtQuick
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors
import "../common/Facts.js" as Facts

// Compact: the notch's first page, route `main` (plan-gui.md §7.6).
//
// A shared view (§5.0): colours and sizes only from `theme`, no Process (engine
// calls go through `engine`), and a pure function of `status` plus the calls
// its buttons make. One column, sized by implicitHeight:
//
//   the Glance and the engine's summary line
//   temperature, utilisation and VRAM on one line, while the card answers
//   one primary button: Connect / Safe eject / Reconnect (as §5.1)
//   the HDMI quick toggle and "Turn off now", when an eGPU monitor is plugged in
//   the attention sentences (§6)
//   Open full panel
//
// Every button is gated on its verb existing in this engine
// (Engine.qml `can`): Connect and Reconnect arrive with E3, Safe eject with
// E5, the display verbs with E4. Until then they are not drawn at all; a
// button that can only answer "usage" is worse than none.
//
// Nothing here keeps state the engine does not have. A call's own answer (an
// error sentence) is the one exception, and it is dropped when the view goes
// inactive, so reopening re-derives everything from `status` (§7.7).
Column {
  id: view

  // ----------------------------------------------------- shared interface
  property var status: null
  property var engine: null
  property var theme: Palette.make({})
  property string density: "compact"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }

  // Additive: the live notice's title (§7.5), shown in the Glance.
  property string noticeTitle: ""

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property real u: view.theme.unit
  readonly property var look: Palette.look(view.s, view.statusNote)
  readonly property string phase: view.s ? String(view.s.phase || "") : ""
  readonly property var gpu: view.s && view.s.gpu ? view.s.gpu : ({})
  readonly property bool relogin: !!(view.s && view.s.display && view.s.display.needs_relogin)
  readonly property bool held: !!(view.s && view.s.modules && view.s.modules.held_after_eject)
  readonly property bool healthErrors: !!(view.s && view.s.health_summary && view.s.health_summary.errors > 0)
  readonly property bool unsupported: !!(view.s && view.s.backend && view.s.backend.name !== null && view.s.backend.supported === false)

  function can(verb) { return !!view.engine && typeof view.engine.can === "function" && view.engine.can(verb) }

  // The one primary action, and whether this engine can run it.
  readonly property string action: Facts.primaryAction(view.s)
  readonly property var actionVerb: ({ connect: "device connect", eject: "device eject", reconnect: "device rescan" })
  readonly property bool actionShown: view.action !== "" && view.can(view.actionVerb[view.action])
  readonly property string actionLabel: view.action === "connect" ? "Connect"
                                      : view.action === "eject" ? "Safe eject"
                                      : view.action === "reconnect" ? "Reconnect" : ""

  readonly property var monitor: Facts.firstMonitor(view.s)
  readonly property string monitorId: view.monitor ? String(view.monitor.description || view.monitor.connector || "") : ""
  readonly property bool hdmiShown: view.monitor !== null && view.monitorId !== ""
                                    && (view.can("display enable") || view.can("display off"))

  // The last call's answer, and which call is in flight.
  property string busy: ""
  property string lastError: ""
  onActiveChanged: if (!active) view.lastError = ""

  function run(name, args) {
    if (view.busy !== "" || !view.engine) return
    view.busy = name
    view.lastError = ""
    view.engine.run(args, function (result) {
      view.busy = ""
      view.lastError = Errors.forResult(result)
    })
  }

  function primary() {
    if (view.action === "eject") view.requestRoute("eject")    // the sheet runs it (§5.2)
    else if (view.action === "connect") view.run("connect", ["device", "connect"])
    else if (view.action === "reconnect") view.run("reconnect", ["device", "rescan"])
  }

  function toggleMonitor() {
    if (!view.monitor) return
    view.run("monitor", ["display", view.monitor.enabled ? "disable" : "enable", view.monitorId])
  }

  // Sized by the shell's maxWidth (§5.0), capped so the notch stays a notch.
  width: view.maxWidth > 0 ? Math.min(view.maxWidth, 320 * view.u) : 320 * view.u
  spacing: 8 * view.u

  // --------------------------------------------------------------- header
  Glance {
    status: view.status
    engine: view.engine
    theme: view.theme
    active: view.active
    statusNote: view.statusNote
    noticeTitle: view.noticeTitle
    maxWidth: view.width
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: view.s && view.s.summary ? String(view.s.summary.line || "")
        : (view.statusNote !== "" ? "No eGPU status: " + view.statusNote + "." : "Waiting for the first status…")
    color: view.theme.foreground
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.font.body
  }

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

  // Plain information, at the size of a caption.
  Text {
    width: parent.width
    visible: !!view.gpu.ok && text !== ""
    textFormat: Text.PlainText
    elide: Text.ElideRight
    text: Facts.now(view.gpu)
    color: view.theme.secondary
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.font.caption
  }

  // ------------------------------------------------------------ attention
  Sentence { shown: view.relogin; tone: view.theme.warn; text: Errors.note("needs_relogin") }
  Sentence { shown: view.held; tone: view.theme.warn; text: Errors.note("held_after_eject") }
  Sentence { shown: view.gpu.error === "smi_hung"; tone: view.theme.bad; text: Errors.message("smi_hung") }
  Sentence { shown: view.unsupported; tone: view.theme.warn; text: Errors.message("backend_stub") }
  Sentence {
    shown: view.healthErrors && !view.relogin && !view.held && !view.unsupported && view.gpu.error !== "smi_hung"
    tone: view.theme.warn
    text: Errors.note("health_errors")
  }
  Sentence { shown: view.lastError !== ""; tone: view.theme.bad; text: view.lastError }

  // -------------------------------------------------------------- actions
  Flow {
    width: parent.width
    spacing: 6 * view.u
    visible: view.actionShown

    Action {
      label: view.busy === view.action ? (view.action === "connect" ? "Connecting…" : "Working…") : view.actionLabel
      // Held modules: a reconnect would load the driver on top of the old one.
      enabled: view.busy === "" && !(view.action === "reconnect" && view.held)
      onClicked: view.primary()
    }
  }

  // HDMI quick toggle (§7.6): the first eGPU monitor, and the escape hatch.
  Item {
    width: parent.width
    visible: view.hdmiShown
    implicitHeight: Math.max(hdmiLabel.implicitHeight, hdmiSwitch.implicitHeight, offButton.implicitHeight)

    Text {
      id: hdmiLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - hdmiSwitch.width - (offButton.visible ? offButton.width : 0) - 16 * view.u
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: "HDMI · " + (view.monitor ? String(view.monitor.connector || view.monitorId) : "")
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
    Action {
      id: offButton
      anchors.right: hdmiSwitch.left
      anchors.rightMargin: 8 * view.u
      anchors.verticalCenter: parent.verticalCenter
      visible: view.can("display off") && !!view.monitor && !!view.monitor.enabled
      label: "Turn off now"
      // No confirmation: it is the glitch escape hatch (§5.3).
      enabled: view.busy === ""
      onClicked: view.run("off", ["display", "off"])
    }
    Switch {
      id: hdmiSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: view.can("display enable") && view.can("display disable")
      checked: !!view.monitor && !!view.monitor.enabled
      enabled: view.busy === ""
      onToggled: view.toggleMonitor()
    }
  }

  Action {
    label: "Open full panel"
    onClicked: view.requestRoute("full")
  }

  // ------------------------------------------------------------ components

  // One sentence that matters: a rule in the tone's colour, text beside it.
  // No fill: the notch forbids own backgrounds.
  component Sentence: Item {
    id: sentence
    property bool shown: false
    property color tone: view.theme.foreground
    property string text: ""
    visible: shown && text !== ""
    width: view.width
    implicitHeight: sentenceText.implicitHeight + 2 * view.u

    Rectangle {
      width: 3 * view.u
      height: parent.height
      radius: Math.min(view.theme.radius, width / 2)
      color: sentence.tone
    }
    Text {
      id: sentenceText
      x: 10 * view.u
      y: 1 * view.u
      width: sentence.width - x
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: sentence.text
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }

  // A minimal button. The kit's Button takes its border from Omarchy's
  // control tokens (Border.controlSpec, which a theme's style overrides can
  // colour), so in the notch it painted a theme colour whatever it was handed
  // (seen in dev/g8-offscreen.sh). This one paints only from `theme`: a
  // foreground outline, an alpha fill on hover, the theme's radius. No
  // tooltip: in the notch a tooltip's own popup is unverified (§7.7).
  component Action: Item {
    id: action
    property string label: ""
    signal clicked()
    implicitWidth: actionText.implicitWidth + 20 * view.u
    implicitHeight: actionText.implicitHeight + 10 * view.u
    width: implicitWidth
    height: implicitHeight
    opacity: enabled ? 1 : 0.5

    Rectangle {
      anchors.fill: parent
      radius: Math.min(view.theme.radius, height / 2)
      color: "transparent"
      border.width: Math.max(1, Math.round(view.u))
      border.color: view.theme.foreground

      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: view.theme.foreground
        opacity: actionArea.pressed ? 0.25 : (actionArea.containsMouse ? 0.12 : 0)
      }
    }
    Text {
      id: actionText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: action.label
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
    MouseArea {
      id: actionArea
      anchors.fill: parent
      enabled: action.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }

  // A minimal switch. The kit's ToggleSwitch rounds its hover ring at
  // Style.cornerRadius and its track as a pill, neither of which is the
  // notch's radius (notch:SURFACE-HOSTING.md:234); this one takes both from
  // `theme`.
  component Switch: Item {
    id: sw
    property bool checked: false
    signal toggled()
    implicitWidth: 34 * view.u
    implicitHeight: 18 * view.u
    width: implicitWidth
    height: implicitHeight
    opacity: enabled ? 1 : 0.5

    Rectangle {
      anchors.fill: parent
      radius: Math.min(view.theme.radius, height / 2)
      color: "transparent"
      border.width: Math.max(1, Math.round(view.u))
      border.color: view.theme.foreground

      // On: the track filled faintly in the foreground (alpha, not hue).
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: view.theme.foreground
        opacity: sw.checked ? 0.3 : 0
      }
      Rectangle {
        width: parent.height - 6 * view.u
        height: width
        radius: Math.min(view.theme.radius, width / 2)
        x: sw.checked ? parent.width - width - 3 * view.u : 3 * view.u
        anchors.verticalCenter: parent.verticalCenter
        color: sw.checked ? view.theme.foreground : view.theme.secondary
      }
    }
    MouseArea {
      anchors.fill: parent
      enabled: sw.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: sw.toggled()
    }
  }
}
