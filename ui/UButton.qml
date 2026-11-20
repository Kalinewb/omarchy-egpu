import QtQuick
import "keys.js" as KeyMap

// The one button (plan-apple-ui.md 4.2 "Primary", "Destructive").
//
//   primary      at most one per surface, trailing edge: the selected fill and an
//                accent outline (so it never reads by colour alone), semibold
//   quiet        no fill until hover; the secondary action, left of the primary
//   destructive  the quiet shape with a hairline outline, verb + object, last in the
//                row, never the default; red only where the panel owns its colours
//   link         the `flow` variant of full-screen flows (enrol, wizard): accent text,
//                no shape; semibold when it is the one that finishes
//
// Dismiss words are three: Cancel, Done, Not now; anything else is a verb and
// an object ("Remove Ana", "Install Face ID"). dev/check-ui.sh holds the list.
Item {
  id: root
  required property var theme
  property string text: ""
  property string kind: "quiet"
  // The one that finishes a flow; semibold. A page-level UKeys.onPrimary calls clicked() on it.
  property bool finishes: false
  property string tip: ""
  signal clicked()

  // State inputs, overridable for the gallery's state strip.
  property bool hot: mouse.containsMouse
  property bool down: mouse.pressed
  property bool showFocus: activeFocus

  readonly property bool isLink: kind === "link"
  readonly property bool isPrimary: kind === "primary"
  readonly property bool isDestructive: kind === "destructive"

  implicitHeight: isLink ? theme.controlHeight : theme.rowHeight
  implicitWidth: Math.max(theme.minHit, label.implicitWidth + 2 * (isLink ? theme.sp.sm : theme.sp.lg))
  activeFocusOnTab: enabled
  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: root.clicked()

  Item {
    id: face
    anchors.fill: parent
    scale: root.down ? root.theme.pressScale : 1
    Behavior on scale {
      NumberAnimation {
        duration: root.down ? root.theme.pressMs : root.theme.controlMs
        easing.type: root.down ? Easing.OutCubic : Easing.BezierSpline
        easing.bezierCurve: root.theme.controlCurve
      }
    }

    Rectangle {
      anchors.fill: parent
      visible: !root.isLink || root.showFocus
      radius: root.theme.radius(height)
      color: root.isLink ? root.theme.none
        : root.down ? root.theme.pressed
        : root.isPrimary ? (root.hot ? root.theme.pressed : root.theme.selected)
        : root.hot ? root.theme.hover : root.theme.none
      border.width: root.showFocus ? 2 : ((root.isPrimary || root.isDestructive) && root.enabled ? root.theme.hairlineWidth : 0)
      border.color: root.showFocus ? root.theme.ring : (root.isPrimary ? root.theme.accent : root.theme.hairline)
      property bool uiMark: true
      Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
      Behavior on border.color { ColorAnimation { duration: root.theme.focusMs } }
    }

    Text {
      id: label
      anchors.centerIn: parent
      text: root.text
      color: !root.enabled ? root.theme.disabled
        : root.isLink ? (root.hot ? root.theme.label : root.theme.accentText)
        : root.isDestructive ? root.theme.destructive : root.theme.label
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
      font.weight: root.isPrimary || root.finishes ? root.theme.headlineWeight : Font.Normal
      font.underline: root.isLink && root.hot
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
  Keys.onPressed: function(event) {
    if (KeyMap.action("button", event.key) === "activate") { root.clicked(); event.accepted = true }
  }
  UTip { theme: root.theme; text: root.tip }
}
