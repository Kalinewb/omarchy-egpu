import QtQuick
import "../ui"
import "../common/Errors.js" as Errors

// What a view says under its one button, in the kit's words (ui/UNotice.qml):
//
//   the state's own sentence  a Setup problem with its Fix, or a quiet line
//                             about Setup (common/Overview.js `sentence`)
//   the enclosure's hint      while "Show me" is open (DEG2: "Check the mode
//                             switch...")
//   what the last call said   when it failed: the sentence from Errors.js, a
//                             way to Setup when that is the way out, and the
//                             engine's code only under Details
//
// Shared by the Overview and the compact view, so the two word and draw them
// the same. A sentence that is only a quiet line (no link) is plain secondary
// text, not a notice: "Everything is set up." is not a warning.
Column {
  id: notes

  required property var theme
  // Overview.decide()'s answer.
  property var d: null
  // The last engine call's answer, when it failed.
  property var lastResult: null
  // The compact view leaves out the quiet Setup lines: only a problem, or the
  // eGPU's own way out under one, is shown there.
  property bool quietSetup: true
  // The enclosure's own hints (the Overview, while it is connecting).
  property bool showHints: false

  signal requestRoute(string name)

  width: parent ? parent.width : implicitWidth
  spacing: notes.theme.sp.sm

  readonly property var sentence: notes.d && notes.d.sentence
                                  && (notes.quietSetup || notes.d.sentence.tone !== "secondary" || notes.d.sentence.secondary)
                                  ? notes.d.sentence : null
  readonly property bool quiet: !!notes.sentence && notes.sentence.tone === "secondary" && notes.sentence.linkLabel === ""
  readonly property string errorRoute: Errors.routeFor(notes.lastResult)

  // The state's sentence: a notice, or one quiet line.
  UNotice {
    theme: notes.theme
    width: notes.width
    visible: !!notes.sentence && !notes.quiet && notes.sentence.text !== ""
    tone: notes.sentence && notes.sentence.tone === "warn" ? "warning" : "info"
    text: notes.sentence ? notes.sentence.text : ""
    actionText: notes.sentence ? notes.sentence.linkLabel : ""
    property string linkRoute: notes.sentence ? notes.sentence.linkRoute : ""
    onActed: notes.requestRoute(linkRoute)
  }
  Text {
    width: notes.width
    visible: notes.quiet
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: notes.quiet ? notes.sentence.text : ""
    color: notes.theme.secondary
    font.family: notes.theme.fontFamily
    font.pixelSize: notes.theme.bodySize
  }

  // A connecting enclosure's own hint (DEG2: "Check the mode switch...").
  Repeater {
    model: notes.showHints && notes.d && notes.d.key === "connecting" ? notes.d.hints : []
    delegate: UNotice {
      required property var modelData
      theme: notes.theme
      width: notes.width
      tone: "info"
      text: modelData
    }
  }

  // What the last call answered, when it failed.
  UNotice {
    theme: notes.theme
    width: notes.width
    visible: !!notes.lastResult
    tone: "error"
    text: notes.lastResult ? Errors.forResult(notes.lastResult) : ""
    details: Errors.code(notes.lastResult)
    actionText: notes.errorRoute === "setup" ? "Open Setup" : ""
    property string linkRoute: notes.errorRoute
    onActed: notes.requestRoute(linkRoute)
  }
}
