import QtQuick
import "../ui"
import "../common/Facts.js" as Facts
import "../common/Overview.js" as Overview

// Compact: the notch's first page, route `main` (plan-gui.md §7.6;
// ui-scope.md §4, §7). The Overview, smaller, in the same words:
//
//   eGPU ready                     glyph   the headline (common/Overview.js), short
//   the state in a sentence         (when the headline is only a word or two)
//   RTX 4070 SUPER · 29 °C · idle       one facts line
//   [ Safe eject ]                      the same ONE primary button
//   the sentence: a Setup problem opens Setup on its row, never a dead end
//   the HDMI quick toggle and "Turn off now", when an eGPU monitor is in
//   Open full panel                     a row that opens the Overview
//
// Under the notch's back strip the first row is the headline in the left
// gutter and the glyph and the one close in the right gutter; the strip's
// zone at the top centre is clear of text and controls.
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
  required property var theme
  property var status: null
  property var engine: null
  property string density: "compact"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null

  // The width of the notch's back-strip zone, centred at the top of the panel
  // (0 when there is none): the first row keeps out of it.
  property real zoneWidth: 0
  readonly property real gutter: Math.max(0, (view.width - view.zoneWidth) / 2)
  // The shell draws no header over this page, so the one close is drawn here,
  // in the first row's right end.
  property bool showClose: false

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }
  readonly property bool canPop: false

  // Additive: the live notice's title (§7.5), shown in place of the headline
  // for as long as it lives.
  property string noticeTitle: ""

  // ------------------------------------------------------------ derived
  readonly property var s: view.status
  readonly property var sp: view.theme.sp

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

  // Enter, with nothing under the focus to take it: the page's one primary button.
  function activatePrimary() {
    if (!view.d.button || !view.d.button.enabled) return false
    view.act(view.d.button)
    return true
  }

  function tipFor(action) {
    return action === "eject" ? "Checks nothing is using it, then lets you unplug."
         : action === "connect" ? "Loads the driver so apps can use the eGPU."
         : action === "setup" ? "Opens Setup, which installs what the eGPU needs."
         : ""
  }

  function toggleMonitor() {
    if (!view.monitor) return
    view.run("monitor", ["display", view.monitor.enabled ? "disable" : "enable", view.monitorId])
  }

  // Sized by the shell's maxWidth (§5.0), capped so the notch stays a notch.
  readonly property real wantWidth: view.theme.space(view.zoneWidth > 0 ? 400 : 320)
  width: view.maxWidth > 0 ? Math.min(view.maxWidth, view.wantWidth) : view.wantWidth
  spacing: view.sp.md

  // --------------------------------------------------------------- header
  Column {
    width: parent.width
    spacing: view.sp.xs

    // The first row. Under the notch's back strip the zone at its top centre
    // is kept clear of text and controls (notch:SURFACE-HOSTING.md §15), so
    // the headline sits in the gutter at the left, short enough for it, and
    // the glyph (and the close) in the gutter at the right; with no zone they
    // sit side by side.
    Item {
      id: firstRow
      width: parent.width
      height: Math.max(headline.implicitHeight, glance.height, closeButton.visible ? closeButton.height : 0)
      readonly property bool beside: view.zoneWidth > 0
      readonly property real closeRoom: closeButton.visible ? closeButton.width + view.sp.sm : 0

      Glance {
        id: glance
        anchors.verticalCenter: parent.verticalCenter
        x: firstRow.beside ? parent.width - width - firstRow.closeRoom : 0
        theme: view.theme
        status: view.status
        engine: view.engine
        active: view.active
        statusNote: view.statusNote
        showWord: false
      }
      Text {
        id: headline
        anchors.verticalCenter: parent.verticalCenter
        x: firstRow.beside ? 0 : glance.width + view.sp.md
        width: firstRow.beside ? view.gutter - view.sp.xs : parent.width - glance.width - view.sp.md - firstRow.closeRoom
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        text: view.d.headline
        color: view.theme.label
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.bodySize
        font.weight: view.theme.headlineWeight
        // A Setup problem's headline opens Setup on its row, like Fix.
        readonly property string route: view.d.headlineRoute
        MouseArea {
          anchors.fill: parent
          enabled: headline.route !== ""
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: view.requestRoute(headline.route)
        }
      }
      UClose {
        id: closeButton
        theme: view.theme
        // The kit hides it inside a host with its own way back (the notch's strip); this only adds the caller's say.
        visible: view.showClose && !view.theme.hostHasBack
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onActivated: view.requestClose()
      }
    }

    // The state in a full sentence, or a live notice's title (§7.5) while
    // one lives: what does not fit the first row goes here.
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.noticeTitle !== "" ? view.noticeTitle : view.d.detail
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
      // A Setup problem's sentence opens Setup on its row, like its headline.
      readonly property string route: view.noticeTitle === "" ? view.d.headlineRoute : ""
      MouseArea {
        anchors.fill: parent
        enabled: parent.route !== ""
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: view.requestRoute(parent.route)
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
      font.pixelSize: view.theme.footnoteSize
    }
  }

  UNotice {
    theme: view.theme
    width: parent.width
    visible: !!view.s && view.statusNote !== ""
    tone: "warning"
    text: "Not live: " + view.statusNote + "."
  }

  // ------------------------------------------------------- the one button
  UButton {
    id: primaryButton
    width: parent.width
    visible: !!view.d.button && !view.d.button.busy
    theme: view.theme
    kind: "primary"
    text: view.d.button ? view.d.button.label : ""
    enabled: !!view.d.button && view.d.button.enabled
    onClicked: view.act(view.d.button)
    UTip { theme: view.theme; placement: "foot"; text: view.d.button ? view.tipFor(view.d.button.action) : "" }
  }
  URing {
    anchors.horizontalCenter: parent.horizontalCenter
    visible: !!view.d.button && view.d.button.busy
    height: view.theme.rowHeight
    theme: view.theme
    text: view.d.button ? view.d.button.label : ""
  }

  // ------------------------------------------------------------ sentences
  // When all is well the compact view is headline, facts, button and
  // "Open full panel" (ui-scope.md §7): the quiet Setup lines are the full
  // Overview's. A problem, a note, or the eGPU's own way out under a Setup
  // problem (`secondary`) are shown.
  StatusNotes {
    theme: view.theme
    d: view.d
    lastResult: view.lastResult
    quietSetup: false
    onRequestRoute: function (name) { view.requestRoute(name) }
  }

  // HDMI quick toggle (§7.6): the first eGPU monitor, and the escape hatch.
  URow {
    visible: view.hdmiShown
    theme: view.theme
    label: "HDMI · " + (view.monitor ? String(view.monitor.connector || view.monitorId) : "")

    trailing: Row {
      spacing: view.sp.sm
      UButton {
        theme: view.theme
        visible: view.can("display off") && !!view.monitor && !!view.monitor.enabled
        height: view.theme.controlHeight
        text: "Turn off now"
        // No confirmation: it is the glitch escape hatch (§5.3).
        enabled: view.busy === ""
        onClicked: view.run("off", ["display", "off"])
        UTip { theme: view.theme; placement: "foot"; text: "Switches the eGPU's screen off right away." }
      }
      USwitch {
        theme: view.theme
        visible: view.can("display enable") && view.can("display disable")
        label: "Show the screen on the eGPU"
        checked: !!view.monitor && !!view.monitor.enabled
        enabled: view.busy === ""
        onToggled: view.toggleMonitor()
        UTip { theme: view.theme; placement: "foot"; text: "Shows or hides the screen on the eGPU's HDMI port." }
      }
    }
  }

  URow {
    theme: view.theme
    clickable: true
    label: "Open full panel"
    value: "›"
    onActivated: view.requestRoute("full")
  }
}
