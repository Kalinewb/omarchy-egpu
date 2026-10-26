import QtQuick
import "../../common/Palette.js" as Palette

// A button that paints only from `theme` (plan-gui.md §5.0). The kit's Button
// takes its border from Omarchy's control tokens (Border.controlSpec, which a
// theme's style overrides can colour), so in the notch it painted a theme
// colour whatever it was handed (seen in dev/g8-offscreen.sh). This one: an
// outline in its tone, an alpha fill of the same tone, the theme's radius
// capped at half its height (the notch's radiusFor). No tooltip: in the notch
// a tooltip's own popup is unverified (§7.7).
//
// `primary` is the one big button of a screen (ui-scope.md §2.1): full width,
// a row high (theme.space.rowHeight), bold, faintly filled. `busy` draws a
// small spinner beside the label, which runs only while `animate` is true
// (the view's `active`) and it is visible.
Item {
  id: action

  property var theme: Palette.make({})
  property string label: ""
  property color tone: action.theme.foreground
  property bool primary: false
  property bool busy: false
  property bool animate: false
  signal clicked()

  readonly property real u: action.theme.unit
  readonly property real padX: (action.primary ? 16 : 10) * action.u

  implicitWidth: actionText.implicitWidth + 2 * action.padX + (action.busy ? spinner.width + 8 * action.u : 0)
  implicitHeight: action.primary ? action.theme.space.rowHeight : actionText.implicitHeight + 10 * action.u
  opacity: enabled || action.busy ? 1 : 0.5

  Rectangle {
    anchors.fill: parent
    radius: Math.min(action.theme.radius, height / 2)
    color: "transparent"
    border.width: Math.max(1, Math.round((action.primary ? 1.5 : 1) * action.u))
    border.color: action.tone

    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: action.tone
      opacity: actionArea.pressed ? 0.3 : (actionArea.containsMouse ? 0.2 : (action.primary ? 0.1 : 0))
    }
  }

  Row {
    anchors.centerIn: parent
    spacing: 8 * action.u

    Spinner {
      id: spinner
      visible: action.busy
      anchors.verticalCenter: parent.verticalCenter
      size: actionText.font.pixelSize
      tone: action.tone
      running: action.busy && action.animate && action.visible
    }
    Text {
      id: actionText
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: action.label
      color: action.tone
      font.family: action.theme.fontFamily
      font.pixelSize: action.theme.font.body
      font.bold: action.primary
    }
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
