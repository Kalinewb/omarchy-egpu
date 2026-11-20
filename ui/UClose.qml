import QtQuick
import "keys.js" as KeyMap

// Close: the one close, top-right of a header (plan-apple-ui.md 4.2). A window
// closes through this or Esc; on a chip or a row a cross removes that item and
// is not this component.
Item {
  id: root
  required property var theme
  signal activated()

  property bool hot: mouse.containsMouse
  property bool down: mouse.pressed
  property bool showFocus: activeFocus

  implicitWidth: theme.controlHeight
  implicitHeight: theme.controlHeight
  activeFocusOnTab: true
  Accessible.role: Accessible.Button
  Accessible.name: "Close"
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
    text: "✕"
    color: root.theme.label
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.bodySize + 2
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
  UTip { theme: root.theme; text: "Close" }
}
