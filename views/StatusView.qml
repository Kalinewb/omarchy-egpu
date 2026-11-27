import QtQuick
import "../ui"
import "../common/Overview.js" as Overview

// Overview: the state in plain words and the one thing to do next
// (ui-scope.md §2.1, ux.md rules 1-2).
//
//   eGPU ready                          the headline, said once
//   RTX 4070 SUPER · 41 °C · idle       one line of facts
//   [ Safe eject ]                      the ONE primary button
//   Everything is set up.               one sentence (or the problem + Fix)
//   Details ›                           the read-only Details page
//
// The headline, the button and the sentence come from common/Overview.js,
// which the notch's compact view reads too, so the two can never word a state
// differently. Every button runs one engine verb or opens a screen; nothing
// here decides a state.
//
// A shared view (plan-gui.md §5.0): colours, sizes, spacing and radii only from
// `theme` (the kit's UTheme, ui/; §5.0's `palette`, renamed because every Qt
// Quick Item already has a `palette` property), no Process (calls go through
// `engine`), a pure function of `status` and `health` plus the calls its
// buttons make.
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
  // Additive to §5.0: StatusSource.outcomeText, shown when there is no status
  // or when the one shown will not update ("watcher not running").
  property string statusNote: ""
  // Additive: the shell's HealthSource ({rows, refresh()}), for the
  // first-run button and the sentence that names a Setup problem.
  property var health: null

  // `requestRoute` takes a route name, "setup:<row id>" (Setup, on that row)
  // or "back" (the shell's Back).
  signal requestRoute(string name)
  signal requestClose()

  // No sub-sheets: Back always falls through to the shell.
  function popView() { return false }
  readonly property bool canPop: false

  // The shell's header shows tabs over this view, never a title: the
  // headline below is the one place the state is said (ui-scope.md §0.3).
  readonly property string title: ""

  // ------------------------------------------------------------ derived
  readonly property var sp: view.theme.sp

  function can(verb) { return !!view.engine && typeof view.engine.can === "function" && view.engine.can(verb) }

  // The call in flight ("connect" or ""), its answer, and the hint toggle.
  property string busy: ""
  property var lastResult: null
  property bool hintsShown: false
  onActiveChanged: if (!active) { view.lastResult = null; view.hintsShown = false }

  readonly property var d: Overview.decide(view.status, {
    rows: view.health ? view.health.rows : null,
    can: view.can, busy: view.busy, statusNote: view.statusNote, hintsShown: view.hintsShown
  })

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

  // The primary button (Overview.js `button.action`).
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

  // What the primary button does, in a few words (a tip, not a label).
  function tipFor(action) {
    return action === "eject" ? "Checks nothing is using it, then lets you unplug."
         : action === "connect" ? "Loads the driver so apps can use the eGPU."
         : action === "setup" ? "Opens Setup, which installs what the eGPU needs."
         : ""
  }

  // Sized by the shell's maxWidth (§5.0); a Column's implicit width is its own.
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : view.theme.space(300))
  spacing: view.sp.md

  // ------------------------------------------------------------- headline
  Column {
    width: parent.width
    spacing: view.sp.sm

    Row {
      width: parent.width
      spacing: view.sp.md

      Glance {
        id: glance
        anchors.verticalCenter: headline.verticalCenter
        theme: view.theme
        status: view.status
        active: view.active
        statusNote: view.statusNote
        showWord: false
      }
      Text {
        id: headline
        width: parent.width - glance.width - parent.spacing
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: view.d.headline
        color: view.theme.label
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.titleSize
        font.weight: view.theme.titleWeight
        // A Setup problem's headline opens Setup on its row, like Fix.
        readonly property string route: view.d.headlineRoute
        MouseArea {
          anchors.fill: parent
          enabled: headline.route !== ""
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: view.requestRoute(headline.route)
        }
      }
    }

    // The state in a full sentence under the short headline.
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.d.detail
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
      // A Setup problem's sentence opens Setup on its row, like its headline.
      readonly property string route: view.d.headlineRoute
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
      wrapMode: Text.WordWrap
      text: view.d.facts
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }

  // When the status will not update by itself.
  UNotice {
    theme: view.theme
    width: parent.width
    visible: !!view.status && view.statusNote !== ""
    tone: "warning"
    text: "Not live: " + view.statusNote + "."
  }

  // ------------------------------------------------------- the one button
  // A call in flight is a ring and its words, not a dimmed button.
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
  StatusNotes {
    theme: view.theme
    d: view.d
    lastResult: view.lastResult
    showHints: true
    onRequestRoute: function (name) { view.requestRoute(name) }
  }

  // ---------------------------------------------------------------- more
  URow {
    visible: view.density !== "compact" && !!view.status
    theme: view.theme
    clickable: true
    label: "Details"
    value: "›"
    onActivated: view.requestRoute("details")
  }
}
