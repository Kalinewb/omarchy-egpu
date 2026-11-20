import QtQuick
import "keys.js" as KeyMap

// The one switch, ported from NotchSettings.qml:1105 (plan-apple-ui.md 4.2).
// Lives in a URow, which supplies the visible label; `label` here is its
// accessible name. Two-option choices are switches. A state that cannot be
// changed is a value on the right of the row ("Set by the installer"), never
// a disabled switch.
//
// `toggled()` says the user asked for the other state; the owner flips
// `checked` (the same convention as Omarchy's ToggleSwitch).
Item {
  id: root
  required property var theme
  property string label: ""
  property bool checked: false
  property string tip: ""
  signal toggled()

  property bool hot: mouse.containsMouse
  property bool down: mouse.pressed
  property bool showFocus: activeFocus

  // 22 x 42 track (rubric 9) in a 24 px hit target.
  implicitWidth: theme.switchWidth
  implicitHeight: Math.max(theme.minHit, theme.switchHeight)
  activeFocusOnTab: enabled
  Accessible.role: Accessible.CheckBox
  Accessible.name: label
  Accessible.checkable: true
  Accessible.checked: checked
  Accessible.onToggleAction: root.toggled()
  Accessible.onPressAction: root.toggled()

  Rectangle {
    id: track
    width: root.theme.switchWidth
    height: root.theme.switchHeight
    anchors.centerIn: parent
    radius: root.theme.radius(height)
    color: root.checked ? root.theme.trackOn : root.theme.trackOff
    border.width: root.checked ? 0 : root.theme.hairlineWidth
    border.color: root.theme.hairline
    property bool uiMark: true
    Behavior on color { ColorAnimation { duration: root.theme.focusMs } }

    Rectangle {
      id: knob
      readonly property int size: Math.round(track.height * 0.72)
      readonly property real inset: (track.height - size) / 2
      width: size
      height: size
      radius: root.theme.radius(height)
      anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? track.width - width - inset : inset
      scale: root.down ? root.theme.pressScale : 1
      color: !root.enabled ? root.theme.disabled : (root.checked ? root.theme.knobOn : root.theme.knobOff)
      property bool uiMark: true
      Behavior on x {
        NumberAnimation {
          duration: root.theme.controlMs
          easing.type: Easing.BezierSpline
          easing.bezierCurve: root.theme.controlCurve
        }
      }
      Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
      Behavior on scale { NumberAnimation { duration: root.theme.pressMs; easing.type: Easing.OutCubic } }
    }
  }

  // The focus ring: 2 px, hugging the track from outside.
  Rectangle {
    anchors.centerIn: track
    width: track.width + 4
    height: track.height + 4
    radius: root.theme.radius(height)
    color: root.theme.none
    border.width: root.showFocus ? 2 : 0
    border.color: root.theme.ring
    property bool uiMark: true
    Behavior on border.color { ColorAnimation { duration: root.theme.focusMs } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggled()
  }
  Keys.onPressed: function(event) {
    if (KeyMap.action("switch", event.key) === "toggle") { root.toggled(); event.accepted = true }
  }
  UTip { theme: root.theme; text: root.tip }
}
