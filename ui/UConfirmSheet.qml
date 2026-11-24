import QtQuick

// The confirm (plan-apple-ui.md 4.2 "Confirm"): an inline row, never an
// overlay or a window. It replaces the action row it belongs to, in place:
// one sentence naming the consequence ("Remove Ana? Her face data is erased."),
// then [Cancel] [verb]. A sentence that fits one line beside the buttons sits
// there (one row high); a longer one wraps over the full width with the buttons
// right-aligned under it (`stacked`). Over 400 characters it logs a warning: a
// consequence that long wants a shorter sentence and a UNotice. The slot is as
// tall as the larger of the two states, so nothing around it moves; the swap is
// a 90 ms fade. Esc is Cancel (the "modal" layer of UKeys). A destructive verb is
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
  // True when the sentence does not fit one line beside the buttons: it wraps
  // across the full width and the buttons sit right-aligned under it.
  readonly property bool stacked: probe.implicitWidth > width - buttons.width - theme.sp.sm
  // A longer sentence is a smell (a consequence that long wants a UNotice), not an error.
  readonly property int sentenceMax: 400
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
  Component.onCompleted: if (sentence.length > sentenceMax) console.warn("ui: UConfirmSheet sentence over " + sentenceMax + " characters: " + sentence)

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
    implicitHeight: root.stacked ? sentenceText.height + root.theme.sp.sm + buttons.height : Math.max(root.theme.rowHeight, buttons.height)
    opacity: root.asking ? 1 : 0
    visible: opacity > 0 || root.asking
    enabled: root.asking
    Behavior on opacity { NumberAnimation { duration: root.theme.fadeOutMs; easing.type: Easing.OutCubic } }

    // Measures the sentence on one line, to choose the layout; never shown.
    Text {
      id: probe
      visible: false
      text: root.sentence
      font: sentenceText.font
    }
    Text {
      id: sentenceText
      x: 0
      y: root.stacked ? 0 : (asker.height - height) / 2
      width: root.stacked ? asker.width : asker.width - buttons.width - root.theme.sp.sm
      text: root.sentence
      wrapMode: Text.Wrap
      color: root.theme.label
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
    }
    Row {
      id: buttons
      x: asker.width - width
      y: root.stacked ? sentenceText.height + root.theme.sp.sm : (asker.height - height) / 2
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
