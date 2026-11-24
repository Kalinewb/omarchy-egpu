import QtQuick

// One line of text (plan-apple-ui.md 4.2). Enter commits, Esc reverts to the
// last committed value (the "edit" layer of UKeys: while there is a change
// not yet committed, Esc is the field's, and the panel does not close).
//
// `secret: true` is the masked field (a password prompt): bullets instead of
// the text, no predictive text or input-method history (echoMode Password,
// ImhSensitiveData), and the accessible name is the label, never the text.
// Esc then does NOT revert: the edit layer is not joined, so the first Esc is the next layer's
// (a confirm, a prompt, the page) and a half-typed secret is never held while
// the person thinks they cancelled; the owner calls clear() when it closes.
// Keep `value` empty for a secret: `committed` is the only way the text leaves,
// and nothing here stores, shows or names it.
//
//   UField { theme: theme; label: "Name"; value: saved; onCommitted: function(t) { saved = t } }
//   UField { theme: theme; label: "Password"; secret: true; onCommitted: function(t) { unlock(t); clear() } }
Item {
  id: root
  required property var theme
  // The accessible name, and what the placeholder says when `placeholder` is empty.
  property string label: ""
  property string placeholder: ""
  // The committed text; the owner updates it from `committed`.
  property string value: ""
  property string tip: ""
  // Masked, no predictive text, Esc cancels at once (see above).
  property bool secret: false
  property alias input: edit
  signal committed(string text)

  // Wipe the typed text (a secret that has been used, a prompt that closed).
  function clear() { edit.text = "" }

  property bool hot: mouse.containsMouse
  property bool showFocus: edit.activeFocus
  readonly property bool dirty: edit.text !== value

  implicitWidth: 200
  implicitHeight: theme.controlHeight

  Rectangle {
    anchors.fill: parent
    radius: root.theme.radius(height)
    color: root.showFocus || root.hot ? root.theme.hover : root.theme.fill
    border.width: root.showFocus ? 2 : root.theme.hairlineWidth
    border.color: root.showFocus ? root.theme.ring : root.theme.hairline
    property bool uiMark: true
    Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
    Behavior on border.color { ColorAnimation { duration: root.theme.focusMs } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    cursorShape: Qt.IBeamCursor
  }

  TextInput {
    id: edit
    anchors.fill: parent
    anchors.leftMargin: root.theme.sp.md
    anchors.rightMargin: root.theme.sp.md
    verticalAlignment: TextInput.AlignVCenter
    clip: true
    text: root.value
    color: root.enabled ? root.theme.label : root.theme.disabled
    selectionColor: root.theme.accent
    selectedTextColor: root.theme.knobOn
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.bodySize
    activeFocusOnTab: root.enabled
    echoMode: root.secret ? TextInput.Password : TextInput.Normal
    passwordCharacter: "\u2022"
    passwordMaskDelay: 0     // never show the last character typed
    inputMethodHints: root.secret
      ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | Qt.ImhHiddenText
      : Qt.ImhNone
    Accessible.role: Accessible.EditableText
    Accessible.name: root.label
    onAccepted: root.committed(text)
    // The owner moved `value`: show it, unless the person is mid-edit.
    Connections { target: root; function onValueChanged() { edit.text = root.value } }

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      visible: edit.text === "" && !edit.activeFocus
      text: root.placeholder !== "" ? root.placeholder : root.label
      color: root.theme.secondary
      font: edit.font
    }
  }

  // A secret never joins the edit layer: Esc is the next layer's at once.
  UKeys { level: "edit"; open: root.dirty && edit.activeFocus && !root.secret; onEscaped: edit.text = root.value }
  UTip { theme: root.theme; text: root.tip; target: edit }
}
