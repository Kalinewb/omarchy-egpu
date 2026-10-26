import QtQuick
import "ui"
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors
import "../common/Facts.js" as Facts
import "../common/Overview.js" as Overview

// Compact: the notch's first page, route `main` (plan-gui.md §7.6;
// ui-scope.md §4, §7). The Overview, smaller, in the same words:
//
//   glyph  eGPU ready                   the headline (common/Overview.js)
//   RTX 4070 SUPER · 29 °C · idle       one facts line
//   [ Safe eject ]                      the same ONE primary button
//   the sentence: a Setup problem opens Setup on its row, never a dead end
//   the HDMI quick toggle and "Turn off now", when an eGPU monitor is in
//   Open full panel
//
// Every button is gated on its verb existing in this engine (Engine.qml
// `can`); a button that can only answer "usage" is worse than none.
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
  property var health: null

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }

  // Additive: the live notice's title (§7.5), shown in place of the headline
  // for as long as it lives.
  property string noticeTitle: ""

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property real u: view.theme.unit
  readonly property var sp: view.theme.space

  function can(verb) { return !!view.engine && typeof view.engine.can === "function" && view.engine.can(verb) }

  property string busy: ""
  property var lastResult: null
  property bool hintsShown: false
  onActiveChanged: if (!active) { view.lastResult = null; view.hintsShown = false }

  readonly property var d: Overview.decide(view.s, {
    rows: view.health ? view.health.rows : null,
    can: view.can, busy: view.busy, statusNote: view.statusNote, hintsShown: view.hintsShown
  })

  readonly property var monitor: Facts.firstMonitor(view.s)
  readonly property string monitorId: view.monitor ? String(view.monitor.description || view.monitor.connector || "") : ""
  readonly property bool hdmiShown: view.monitor !== null && view.monitorId !== ""
                                    && (view.can("display enable") || view.can("display off"))

  function tone(name) {
    var c = view.theme[name]
    return c !== undefined && c !== null ? c : view.theme.foreground
  }

  function run(name, args) {
    if (view.busy !== "" || !view.engine) return
    view.busy = name
    view.lastResult = null
    view.engine.run(args, function (result) {
      if (!view) return    // the view was closed while the call ran
      view.busy = ""
      view.lastResult = result.ok ? null : result
      if (view.health && typeof view.health.refresh === "function") view.health.refresh()
    })
  }

  // The same actions as the Overview's (views/StatusView.qml act()).
  function act(b) {
    if (!b || !b.enabled) return
    if (b.action === "setup") view.requestRoute("setup")
    else if (b.action === "fix") view.requestRoute(b.rowId !== "" ? "setup:" + b.rowId : "setup")
    else if (b.action === "connect") view.run("connect", ["device", "connect"])
    else if (b.action === "eject") view.requestRoute("eject")
    else if (b.action === "done") view.requestClose()
    else if (b.action === "show") view.hintsShown = !view.hintsShown
  }

  function toggleMonitor() {
    if (!view.monitor) return
    view.run("monitor", ["display", view.monitor.enabled ? "disable" : "enable", view.monitorId])
  }

  // Sized by the shell's maxWidth (§5.0), capped so the notch stays a notch.
  width: view.maxWidth > 0 ? Math.min(view.maxWidth, 320 * view.u) : 320 * view.u
  spacing: view.sp.section

  // --------------------------------------------------------------- header
  Column {
    width: parent.width
    spacing: view.sp.row / 2

    Row {
      width: parent.width
      spacing: view.sp.row * 1.5

      Glance {
        id: glance
        anchors.verticalCenter: headline.verticalCenter
        status: view.status
        engine: view.engine
        theme: view.theme
        active: view.active
        statusNote: view.statusNote
        showWord: false
      }
      Text {
        id: headline
        width: parent.width - glance.width - parent.spacing
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: view.noticeTitle !== "" ? view.noticeTitle : view.d.headline
        color: view.theme.foreground
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.font.body
        font.bold: true
        // A Setup problem's headline opens Setup on its row, like Fix.
        readonly property string route: view.noticeTitle === "" ? view.d.headlineRoute : ""
        MouseArea {
          anchors.fill: parent
          enabled: headline.route !== ""
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: view.requestRoute(headline.route)
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: view.d.facts
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.caption
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
  }

  // ------------------------------------------------------- the one button
  Action {
    width: parent.width
    visible: !!view.d.button
    theme: view.theme
    primary: true
    label: view.d.button ? view.d.button.label : ""
    tone: view.d.button ? view.tone(view.d.button.tone) : view.theme.foreground
    enabled: !!view.d.button && view.d.button.enabled
    busy: !!view.d.button && view.d.button.busy
    animate: view.active
    onClicked: view.act(view.d.button)
  }

  // ------------------------------------------------------------ sentences
  Sentence {
    width: parent.width
    theme: view.theme
    // When all is well the compact view is headline, facts, button and
    // "Open full panel" (ui-scope.md §7): the quiet Setup lines are the full
    // Overview's. A problem, a note, or the eGPU's own way out under a Setup
    // problem (`secondary`) are shown.
    text: view.d.sentence && (view.d.sentence.tone !== "secondary" || view.d.sentence.secondary)
          ? view.d.sentence.text : ""
    tone: view.d.sentence ? view.tone(view.d.sentence.tone) : view.theme.foreground
    rule: !!view.d.sentence && view.d.sentence.tone !== "secondary"
    linkLabel: view.d.sentence ? view.d.sentence.linkLabel : ""
    linkRoute: view.d.sentence ? view.d.sentence.linkRoute : ""
    onLinkClicked: view.requestRoute(linkRoute)
  }

  Sentence {
    width: parent.width
    theme: view.theme
    text: view.lastResult ? Errors.forResult(view.lastResult) : ""
    tone: view.theme.bad
    linkLabel: Errors.routeFor(view.lastResult) === "setup" ? "Open Setup" : ""
    linkRoute: Errors.routeFor(view.lastResult)
    detail: Errors.code(view.lastResult)
    onLinkClicked: view.requestRoute(linkRoute)
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
      width: parent.width - hdmiSwitch.width - (offButton.visible ? offButton.width : 0) - 2 * view.sp.section
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
      anchors.rightMargin: view.sp.section
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
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
      theme: view.theme
      visible: view.can("display enable") && view.can("display disable")
      checked: !!view.monitor && !!view.monitor.enabled
      enabled: view.busy === ""
      onToggled: view.toggleMonitor()
    }
  }

  Link {
    theme: view.theme
    label: "Open full panel"
    route: "full"
    tone: view.theme.secondary
    onClicked: view.requestRoute("full")
  }
}
