import QtQuick
import "../../common/Palette.js" as Palette

// One sentence that matters, with at most one link after it ("… [Fix]",
// "… [Open Setup]") and, when there is an engine code behind it, a "Details"
// that shows the code (ux.md rule 3: the code never on the surface). A rule
// in the tone's colour at the left, no fill: the notch forbids own
// backgrounds.
//
// `linkRoute` is where the link goes; the view handles linkClicked. The
// gates walk up from any text naming Setup to the Sentence around it and
// check that `linkRoute` opens Setup (ui-scope.md §0.1).
Item {
  id: sentence

  property var theme: Palette.make({})
  property string text: ""
  property color tone: sentence.theme.foreground
  property bool rule: true
  property string linkLabel: ""
  property string linkRoute: ""
  property string detail: ""
  signal linkClicked()

  readonly property real u: sentence.theme.unit
  property bool detailOpen: false

  visible: sentence.text !== ""
  implicitWidth: parent ? parent.width : 0
  implicitHeight: column.implicitHeight + 2 * sentence.u

  Rectangle {
    visible: sentence.rule
    width: 3 * sentence.u
    height: parent.height
    radius: Math.min(sentence.theme.radius, width / 2)
    color: sentence.tone
  }

  Column {
    id: column
    x: sentence.rule ? 10 * sentence.u : 0
    y: 1 * sentence.u
    width: sentence.width - x
    spacing: sentence.theme.space.row

    Text {
      id: body
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: sentence.text
      color: sentence.theme.foreground
      font.family: sentence.theme.fontFamily
      font.pixelSize: sentence.theme.font.body
    }

    Row {
      visible: sentence.linkLabel !== "" || sentence.detail !== ""
      spacing: 14 * sentence.u
      Link {
        theme: sentence.theme
        visible: sentence.linkLabel !== ""
        label: sentence.linkLabel
        route: sentence.linkRoute
        onClicked: sentence.linkClicked()
      }
      Link {
        theme: sentence.theme
        visible: sentence.detail !== ""
        label: sentence.detailOpen ? "Hide details" : "Details"
        tone: sentence.theme.secondary
        onClicked: sentence.detailOpen = !sentence.detailOpen
      }
    }

    Text {
      width: parent.width
      visible: sentence.detailOpen && sentence.detail !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      text: sentence.detail
      color: sentence.theme.secondary
      font.family: sentence.theme.fontFamily
      font.pixelSize: sentence.theme.font.caption
    }
  }
}
