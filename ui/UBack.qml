import QtQuick
import "keys.js" as KeyMap

// Back: the chevron left of the title (plan-apple-ui.md 4.2). "Back" is its
// tooltip and its accessible name. In the notch the back step is the existing
// top-middle strip (BackStrip.qml, hidden until hover) and this is not drawn.
// Esc is not handled here: UKeys goes back one step.
Item {
  id: root
  required property var theme
  signal activated()

  // State inputs, overridable for the gallery's state strip.
  property bool hot: mouse.containsMouse
  property bool down: mouse.pressed
  property bool showFocus: activeFocus

  implicitWidth: theme.controlHeight
  implicitHeight: theme.controlHeight
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: "Back"
  Accessible.onPressAction: root.activated()

  Rectangle {
    anchors.fill: parent
    radius: root.theme.radius(height)
    color: root.down ? root.theme.pressed : (root.hot ? root.theme.hover : root.theme.none)
    border.width: root.showFocus ? 2 : 0
    border.color: root.theme.ring
    property bool uiMark: true
    Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
    Behavior on border.color { ColorAnimation { duration: root.theme.focusMs } }
  }
  Text {
    anchors.centerIn: parent
    text: "‹"
    color: root.theme.label
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.titleSize + 6
    font.weight: Font.Medium
  }
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
  Keys.onPressed: function(event) {
    if (KeyMap.action("button", event.key) === "activate") { root.activated(); event.accepted = true }
  }
  UTip { theme: root.theme; text: "Back" }
}
