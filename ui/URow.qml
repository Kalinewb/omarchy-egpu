import QtQuick

// One row (plan-apple-ui.md 4.2 "Row"): label left, a value or a control
// right, an optional trailing slot (buttons, a job), height by density.
//
//   URow { theme: theme; label: "Show the date"; USwitch { ... } }
//   URow { theme: theme; label: "Version"; value: "1.4.0" }
//   URow { theme: theme; variant: "stacked"; label: "Hotkey"; UField { width: parent.width } }
//
// `stacked` (replaces StackedRow): the label on its own line, the control
// below it at full width. Explanation is pulled, not printed: `tip`.
Item {
  id: root
  required property var theme
  property string label: ""
  // Read-only text on the right. A state that cannot be changed is shown here.
  property string value: ""
  // The value is small print (who set it, where it came from): metadata, not secondary.
  property bool valueQuiet: false
  property string variant: "row"
  property string tip: ""
  // A row that is itself the control (opens a page); it gets hover, focus and a name.
  property bool clickable: false
  signal activated()

  default property alias control: slot.data
  property alias trailing: trailingSlot.data

  property bool hot: mouse.containsMouse
  property bool showFocus: activeFocus

  readonly property bool stacked: variant === "stacked"
  readonly property int gap: theme.sp.sm

  width: parent ? parent.width : implicitWidth
  implicitHeight: stacked
    ? Math.ceil(stackedLabel.implicitHeight) + theme.sp.xs + Math.max(slot.childrenRect.height, trailingSlot.childrenRect.height) + theme.sp.sm
    : Math.max(theme.rowHeight, Math.max(slot.childrenRect.height, trailingSlot.childrenRect.height) + theme.sp.xs)
  implicitWidth: 320
  height: implicitHeight

  activeFocusOnTab: clickable && enabled
  Accessible.role: clickable ? Accessible.Button : Accessible.StaticText
  Accessible.name: label
  Accessible.onPressAction: root.activated()

  Rectangle {
    anchors.fill: parent
    visible: root.clickable
    radius: root.theme.radius(root.theme.rowHeight)
    color: mouse.pressed ? root.theme.pressed : (root.hot ? root.theme.hover : root.theme.none)
    border.width: root.showFocus ? 2 : 0
    border.color: root.theme.ring
    property bool uiMark: true
    Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
  }

  Text {
    id: rowLabel
    visible: !root.stacked
    anchors.left: parent.left
    anchors.right: group.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    elide: Text.ElideRight
    color: root.enabled ? root.theme.label : root.theme.disabled
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.bodySize
  }
  Text {
    id: stackedLabel
    visible: root.stacked
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.theme.sp.xs
    text: root.label
    elide: Text.ElideRight
    color: root.theme.secondary
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.footnoteSize
  }

  Row {
    id: group
    spacing: root.gap
    x: root.stacked ? 0 : root.width - width
    y: root.stacked ? stackedLabel.y + stackedLabel.height + root.theme.sp.xs : (root.height - height) / 2
    Text {
      visible: root.value !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.value
      color: root.valueQuiet ? root.theme.metadata : root.theme.secondary
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
      font.weight: root.valueQuiet ? root.theme.metadataWeight : Font.Normal
    }
    Item {
      id: slot
      width: root.stacked ? root.width - trailingSlot.width : childrenRect.width
      height: childrenRect.height
      anchors.verticalCenter: parent.verticalCenter
    }
    Item {
      id: trailingSlot
      width: childrenRect.width
      height: childrenRect.height
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.clickable
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
  Keys.onPressed: function(event) {
    if (!root.clickable) return
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.activated(); event.accepted = true }
  }
  UTip { theme: root.theme; text: root.tip }
}
