import QtQuick
import "../common/Palette.js" as Palette

// Glance: the eGPU in one glyph and a word or two (plan-gui.md §7.4).
//
// A shared view (§5.0). The notch's activity row and the compact view's
// header draw it from this file, and the bar button reads the same
// Palette.look(), so none of them can show a different state. It is a pure
// function of summary.state (and, while one is live, the notice's title):
//
//   absent          dim glyph, no word
//   connecting      glyph, slow pulse, "connecting"
//   ready           accent glyph, "ready"
//   in_use          accent glyph + dot, "in use" / "in use 37%", monitor mark if HDMI is on
//   ejecting        pulse, "ejecting"
//   safe_to_unplug  good glyph, "unplug"
//   attention       warn ring, "log out" / "check setup"
//   error           bad dot, "error"
//
// The ring and the dot differ in SHAPE, not only colour: in the notch every
// role but secondary is the notch's one foreground (it takes the hue out of
// everything), so shape and word are what tell the states apart.
//
// The pulse runs only while `active` and visible: a looping animation at zero
// opacity still repaints the host every frame (notch:SURFACE-HOSTING.md:490-492).
Item {
  id: view

  // ----------------------------------------------------- shared interface
  property var status: null
  property var engine: null
  property var theme: Palette.make({})
  property string density: "compact"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }

  // Additive to §5.0: the live notice's title (common/Notices.qml), shown in
  // place of the state word for as long as the notice lives (§7.5).
  property string noticeTitle: ""
  // False draws the glyph alone, as the bar does.
  property bool showWord: true

  readonly property var look: Palette.look(view.status, view.statusNote)
  readonly property string word: view.noticeTitle !== "" ? view.noticeTitle : view.look.word
  readonly property real u: view.theme.unit
  readonly property real glyphSize: view.theme.font.icon

  function roleColor(role) {
    var c = view.theme[role]
    return c !== undefined && c !== null ? c : view.theme.foreground
  }

  property real pulse: 1
  readonly property alias pulsing: pulseAnimation.running
  SequentialAnimation on pulse {
    id: pulseAnimation
    running: view.look.pulse && view.active && view.visible
    loops: Animation.Infinite
    alwaysRunToEnd: false
    NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) view.pulse = 1
  }

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Row {
    id: row
    spacing: 6 * view.u

    Item {
      id: mark
      width: glyph.implicitWidth + (badge.visible ? badge.width / 2 : 0)
      height: Math.max(glyph.implicitHeight, view.glyphSize)

      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Palette.glyph
        readonly property color tint: view.roleColor(view.look.role)
        color: Qt.rgba(tint.r, tint.g, tint.b, tint.a * view.pulse)
        font.family: view.theme.fontFamily
        font.pixelSize: view.glyphSize
      }

      // Corner dot: filled for in use (accent) and error (bad), a ring for
      // attention (warn), as on the bar.
      Rectangle {
        id: badge
        readonly property color tint: view.roleColor(view.look.badge)
        visible: view.look.badge !== ""
        width: Math.max(5, Math.round(6 * view.u))
        height: width
        radius: Math.min(view.theme.radius, width / 2)
        color: view.look.badge === "warn" ? "transparent" : tint
        border.width: view.look.badge === "warn" ? Math.max(1, Math.round(width / 4)) : 0
        border.color: tint
        anchors.right: parent.right
        anchors.top: parent.top
      }

      // "+ HDMI monitor": a small monitor under the dot's corner.
      Text {
        id: monitorMark
        visible: view.look.monitor
        textFormat: Text.PlainText
        text: Palette.monitorGlyph
        color: view.theme.accent
        font.family: view.theme.fontFamily
        font.pixelSize: Math.max(7, Math.round(view.theme.font.caption * 0.7))
        anchors.right: parent.right
        anchors.bottom: parent.bottom
      }
    }

    Text {
      id: wordText
      anchors.verticalCenter: parent.verticalCenter
      visible: view.showWord && view.word !== ""
      textFormat: Text.PlainText
      text: view.word
      color: view.noticeTitle !== "" ? view.theme.foreground : view.roleColor(view.look.role === "secondary" ? "secondary" : "foreground")
      elide: Text.ElideRight
      width: view.maxWidth > 0 ? Math.min(implicitWidth, Math.max(0, view.maxWidth - mark.width - row.spacing)) : implicitWidth
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }
}
