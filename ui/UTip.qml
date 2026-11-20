import QtQuick

// The tip (plan-apple-ui.md 4.2 "Tip"): a footnote, 400 ms after hover or
// 250 ms after keyboard focus, at most 60 characters, effect first, no label
// repeat. Declared as a child of the control it explains: it reads that
// control's `hot` and `activeFocus`.
//
//   float   standalone: a small solid box under the control, level 2, a hairline
//   foot    notch pages: no box; the text goes to `theme.foot`, shown by one
//           reserved line at the bottom of the page, `UTip { line: true }`
//
// Esc dismisses it before it does anything else (the "tip" layer of UKeys).
Item {
  id: root
  required property var theme
  property Item target: parent
  property string text: ""
  property string placement: "float"
  // The reserved foot line itself: shows theme.foot, always one line tall.
  property bool line: false
  // For things that are not kit controls (which expose `hot`).
  property var owner: parent
  property bool hovering: !!owner && owner.hot === true

  anchors.fill: line ? undefined : parent

  readonly property bool focused: !!target && target.activeFocus
  property bool armedHover: false
  property bool armedFocus: false
  property bool dismissed: false
  readonly property bool shown: !line && text !== "" && enabled && !dismissed && (armedHover || armedFocus)

  onHoveringChanged: {
    if (hovering) hoverTimer.restart()
    else { hoverTimer.stop(); armedHover = false; if (!focused) dismissed = false }
  }
  onFocusedChanged: {
    if (focused) focusTimer.restart()
    else { focusTimer.stop(); armedFocus = false; if (!hovering) dismissed = false }
  }
  Timer { id: hoverTimer; interval: 400; onTriggered: root.armedHover = true }
  Timer { id: focusTimer; interval: 250; onTriggered: root.armedFocus = true }

  Component.onCompleted: if (!line && text.length > theme.tipMax) console.warn("ui: UTip text over " + theme.tipMax + " characters: " + text)
  onShownChanged: {
    if (line || placement !== "foot") return
    if (shown) theme.foot = text
    else if (theme.foot === text) theme.foot = ""
  }
  Component.onDestruction: if (!line && placement === "foot" && theme.foot === text) theme.foot = ""

  z: shown ? 1000 : 0

  // float
  Rectangle {
    id: box
    visible: opacity > 0
    opacity: root.shown && root.placement === "float" ? 1 : 0
    x: Math.max(0, Math.min(root.width - width, (root.width - width) / 2))
    y: root.height + root.theme.sp.xs
    width: Math.min(280, tipText.implicitWidth + 2 * root.theme.sp.sm)
    height: tipText.implicitHeight + 2 * root.theme.sp.xs
    radius: root.theme.radius(height)
    color: root.theme.raised
    border.width: root.theme.hairlineWidth
    border.color: root.theme.hairline
    property bool uiMark: true
    Behavior on opacity { NumberAnimation { duration: root.shown ? root.theme.fadeInMs : root.theme.fadeOutMs; easing.type: Easing.OutCubic } }
    Text {
      id: tipText
      x: root.theme.sp.sm
      y: root.theme.sp.xs
      width: parent.width - 2 * root.theme.sp.sm
      text: root.text
      wrapMode: Text.WordWrap
      color: root.theme.label
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.footnoteSize
    }
  }

  // the foot line
  Text {
    id: foot
    visible: root.line
    anchors.fill: parent
    verticalAlignment: Text.AlignVCenter
    text: root.theme.foot
    elide: Text.ElideRight
    color: root.theme.metadata
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.footnoteSize
    font.weight: root.theme.metadataWeight
    opacity: foot.text !== "" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: foot.text !== "" ? root.theme.fadeInMs : root.theme.fadeOutMs; easing.type: Easing.OutCubic } }
  }
  implicitHeight: line ? theme.footnoteSize + theme.sp.sm : 0

  UKeys { level: "tip"; open: root.shown; onEscaped: root.dismissed = true }
}
