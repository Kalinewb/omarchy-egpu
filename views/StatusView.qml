import QtQuick
import "ui"
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors
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
// A shared view (plan-gui.md §5.0): colours and sizes only from `theme`
// (§5.0's `palette`, renamed because every Qt Quick Item already has a
// `palette` property), no Process (calls go through `engine`), a pure
// function of `status` and `health` plus the calls its buttons make.
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
  // Additive: the shell's HealthSource ({rows, refresh()}), for the
  // first-run button and the sentence that names a Setup problem.
  property var health: null

  // `requestRoute` takes a route name, "setup:<row id>" (Setup, on that row)
  // or "back" (the shell's Back).
  signal requestRoute(string name)
  signal requestClose()

  // No sub-sheets: Back always falls through to the shell.
  function popView() { return false }

  // The shell's header shows tabs over this view, never a title: the
  // headline below is the one place the state is said (ui-scope.md §0.3).
  readonly property string title: ""
  readonly property string meta: ""

  // ------------------------------------------------------------ derived
  readonly property real u: view.theme.unit
  readonly property var sp: view.theme.space

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

  // Sized by the shell's maxWidth (§5.0); a Column's implicit width is its own.
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : 300 * view.u)
  spacing: view.sp.section

  // ------------------------------------------------------------- headline
  Column {
    width: parent.width
    spacing: view.sp.row

    Row {
      width: parent.width
      spacing: view.sp.row * 1.5

      Glance {
        id: glance
        anchors.verticalCenter: headline.verticalCenter
        status: view.status
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
        text: view.d.headline
        color: view.theme.foreground
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.font.title
        font.bold: true
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

    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.d.facts
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }

    // When the status will not update by itself.
    Text {
      width: parent.width
      visible: !!view.status && view.statusNote !== ""
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
    id: primaryButton
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
    text: view.d.sentence ? view.d.sentence.text : ""
    tone: view.d.sentence ? view.tone(view.d.sentence.tone) : view.theme.foreground
    rule: !!view.d.sentence && view.d.sentence.tone !== "secondary"
    linkLabel: view.d.sentence ? view.d.sentence.linkLabel : ""
    linkRoute: view.d.sentence ? view.d.sentence.linkRoute : ""
    onLinkClicked: view.requestRoute(linkRoute)
  }

  // A connecting enclosure's own hint (DEG2: "Check the mode switch…").
  Repeater {
    model: view.d.key === "connecting" ? view.d.hints : []
    delegate: Sentence {
      required property var modelData
      width: view.width
      theme: view.theme
      text: modelData
      tone: view.theme.accent
    }
  }

  // What the last call answered, when it failed.
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

  // ---------------------------------------------------------------- more
  Link {
    visible: view.density !== "compact" && !!view.status
    theme: view.theme
    label: "Details ›"
    route: "details"
    tone: view.theme.secondary
    onClicked: view.requestRoute("details")
  }
}
