import QtQuick
import "../../common/Palette.js" as Palette

// A text button (ui-scope.md §5: "links as text buttons"): the label in its
// tone, underlined on hover, a hit area a little larger than the text. Used
// for everything that is not a screen's one primary button: "Details ›",
// "Open Setup", "Fix" beside a sentence.
//
// `route` is what it opens, when it opens a screen ("setup", "setup:<row>",
// "details", "eject"); the view decides what a click does, but the gates read
// `route` to check that a sentence naming Setup has a way to it.
Item {
  id: link

  property var theme: Palette.make({})
  property string label: ""
  property string route: ""
  property color tone: link.theme.accent
  property bool bold: false
  signal clicked()

  readonly property real u: link.theme.unit

  implicitWidth: linkText.implicitWidth
  implicitHeight: linkText.implicitHeight
  opacity: enabled ? 1 : 0.5

  Text {
    id: linkText
    textFormat: Text.PlainText
    text: link.label
    color: link.tone
    font.family: link.theme.fontFamily
    font.pixelSize: link.theme.font.body
    font.bold: link.bold
    font.underline: linkArea.containsMouse
  }

  MouseArea {
    id: linkArea
    anchors.fill: parent
    anchors.margins: -4 * link.u
    enabled: link.enabled
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: link.clicked()
  }
}
