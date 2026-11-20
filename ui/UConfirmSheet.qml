import QtQuick

// The confirm (plan-apple-ui.md 4.2 "Confirm"): an inline row, never an
// overlay or a window. It replaces the action row it belongs to, in place:
// one sentence naming the consequence (60 characters at most, "Remove Ana? Her
// face data is erased."), then [Cancel] [verb]. The slot is as tall as the
// larger of the two states, so nothing around it moves; the swap is a 90 ms
// fade. Esc is Cancel (the "modal" layer of UKeys). A destructive verb is
// never the default and never takes the initial focus (Cancel does, Enter
// does not fire the verb); any other verb takes it, so Enter confirms.
//
//   UConfirmSheet {
//     id: confirm; theme: theme
//     sentence: "Remove Ana? Her face data is erased."; verb: "Remove"; destructive: true
//     onConfirmed: remove()
//     UButton { text: "Remove Ana"; kind: "destructive"; onClicked: confirm.ask() }   // the row it replaces
//   }
Item {
  id: root
  required property var theme
  property string sentence: ""
  property string verb: ""
  property bool destructive: false
  property bool asking: false
  signal confirmed()
  signal cancelled()

  // What is shown until `ask()`: the buttons this row replaces.
  default property alias actions: actionsHolder.data

  function ask() {
    asking = true
    if (destructive) cancelButton.forceActiveFocus()
    else verbButton.forceActiveFocus()
  }
  function cancel() { asking = false; cancelled() }
  function confirm() { asking = false; confirmed() }

  implicitWidth: 360
  implicitHeight: Math.max(actionsHolder.childrenRect.height, asker.implicitHeight, theme.rowHeight)
  Component.onCompleted: if (sentence.length > theme.tipMax) console.warn("ui: UConfirmSheet sentence over " + theme.tipMax + " characters: " + sentence)

  Item {
    id: actionsHolder
    anchors.fill: parent
    opacity: root.asking ? 0 : 1
    visible: opacity > 0 || !root.asking
    enabled: !root.asking
    Behavior on opacity { NumberAnimation { duration: root.theme.fadeOutMs; easing.type: Easing.OutCubic } }
  }

  Item {
    id: asker
    anchors.fill: parent
    implicitHeight: root.theme.rowHeight
    opacity: root.asking ? 1 : 0
    visible: opacity > 0 || root.asking
    enabled: root.asking
    Behavior on opacity { NumberAnimation { duration: root.theme.fadeOutMs; easing.type: Easing.OutCubic } }

    Text {
      anchors.left: parent.left
      anchors.right: buttons.left
      anchors.rightMargin: root.theme.sp.sm
      anchors.verticalCenter: parent.verticalCenter
      text: root.sentence
      elide: Text.ElideRight
      color: root.theme.label
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
    }
    Row {
      id: buttons
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.sp.sm
      UButton { id: cancelButton; theme: root.theme; text: "Cancel"; onClicked: root.cancel() }
      UButton {
        id: verbButton
        theme: root.theme
        text: root.verb
        kind: root.destructive ? "destructive" : "primary"
        onClicked: root.confirm()
      }
    }
  }

  UKeys { level: "modal"; open: root.asking; onEscaped: root.cancel() }
}
