import QtQuick

// The empty state: one sentence and at most one action (plan-apple-ui.md
// 4.2 "Empty"), centred. "No profiles yet." and [Set up profiles].
Item {
  id: root
  required property var theme
  property string text: ""
  property string actionText: ""
  signal acted()

  implicitWidth: 320
  implicitHeight: column.implicitHeight + 2 * theme.sp.lg
  Accessible.role: Accessible.StaticText
  Accessible.name: text

  Column {
    id: column
    anchors.centerIn: parent
    spacing: root.theme.sp.sm
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.text
      color: root.theme.secondary
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
    }
    UButton {
      anchors.horizontalCenter: parent.horizontalCenter
      theme: root.theme
      visible: root.actionText !== ""
      text: root.actionText
      onClicked: root.acted()
    }
  }
}
