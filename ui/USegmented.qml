pragma ComponentBehavior: Bound
import QtQuick
import "keys.js" as KeyMap

// Two to four options on one line (plan-apple-ui.md 4.2). Chips, tabs and
// per-row choice buttons retire. One tab stop; Left and Right move the choice.
// Selection shows as a fill, an accent outline and semibold, so it never
// reads by colour alone.
//
//   USegmented { theme: theme; label: "Scope"; options: [{value: "a", label: "A"}, ...]
//                value: current; onPicked: function(v) { current = v } }
Item {
  id: root
  required property var theme
  property var options: []
  property string value: ""
  // The accessible name of the group.
  property string label: "Options"
  property string tip: ""
  signal picked(string value)

  property bool showFocus: activeFocus
  readonly property int index: {
    for (var i = 0; i < options.length; i++) if (options[i].value === value) return i
    return -1
  }

  implicitHeight: theme.controlHeight
  implicitWidth: row.implicitWidth + 4
  activeFocusOnTab: enabled
  Component.onCompleted: if (options.length < 2 || options.length > 4) console.warn("ui: USegmented takes 2 to 4 options (UPick for more), got " + options.length)
  Accessible.role: Accessible.Grouping
  Accessible.name: label

  Rectangle {
    anchors.fill: parent
    radius: root.theme.radius(height)
    color: root.theme.fill
    border.width: root.showFocus ? 2 : root.theme.hairlineWidth
    border.color: root.showFocus ? root.theme.ring : root.theme.hairline
    property bool uiMark: true
    Behavior on border.color { ColorAnimation { duration: root.theme.focusMs } }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0
    Repeater {
      model: root.options
      Item {
        id: segment
        required property var modelData
        required property int index
        readonly property bool chosen: modelData.value === root.value
        property bool hot: segMouse.containsMouse
        width: Math.max(root.theme.minHit, text.implicitWidth + 2 * root.theme.sp.md)
        height: root.height - 4
        Accessible.role: Accessible.RadioButton
        Accessible.name: modelData.label
        Accessible.checkable: true
        Accessible.checked: chosen
        Accessible.onPressAction: root.picked(modelData.value)

        Rectangle {
          anchors.fill: parent
          radius: root.theme.radius(height)
          color: segment.chosen ? root.theme.selected : (segment.hot ? root.theme.hover : root.theme.none)
          border.width: segment.chosen ? root.theme.hairlineWidth : 0
          border.color: root.theme.accent
          property bool uiMark: true
          Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
        }
        Text {
          id: text
          anchors.centerIn: parent
          text: segment.modelData.label
          color: !root.enabled ? root.theme.disabled : (segment.chosen ? root.theme.label : root.theme.secondary)
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.bodySize
          font.weight: segment.chosen ? root.theme.headlineWeight : Font.Normal
        }
        MouseArea {
          id: segMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(segment.modelData.value)
        }
      }
    }
  }

  Keys.onPressed: function(event) {
    var a = KeyMap.action("segmented", event.key)
    if (a !== "prev" && a !== "next") return
    var i = KeyMap.step(index < 0 ? 0 : index, a === "next" ? 1 : -1, 0, options.length - 1)
    if (options.length > 0 && i !== index) root.picked(options[i].value)
    event.accepted = true
  }
  UTip { theme: root.theme; text: root.tip }
}
