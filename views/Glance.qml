import QtQuick
import "../ui"
import "../common/Palette.js" as Palette

// Glance: the eGPU in one glyph and a word or two (plan-gui.md §7.4).
//
// A shared view (§5.0). The notch's activity row and the compact view's
// header draw it from this file, and the bar button reads the same
// Palette.look(), so none of them can show a different state. It is a pure
// function of summary.state (and, while one is live, the notice's title):
//
//   absent          dim glyph, no word
//   connecting      glyph, a ring turning beside it, "connecting"
//   ready           accent glyph, "ready"
//   in_use          accent glyph + dot, "in use" / "in use 37%", monitor mark if HDMI is on
//   ejecting        the ring, "ejecting"
//   safe_to_unplug  good glyph, "unplug"
//   attention       warn ring, "log out" / "check setup"
//   error           bad dot, "error"
//
// The ring and the dot differ in SHAPE, not only colour: in the notch every
// role but secondary is the notch's one foreground (it takes the hue out of
// everything), so shape and word are what tell the states apart.
//
// "Under way" is the kit's ring (URing), not a fading glyph: it holds still
// under reduced motion (a steady half arc) and, like every loop, runs only
// while `active` and drawn: a looping animation at zero opacity still repaints
// the host every frame (notch:SURFACE-HOSTING.md:490-492).
Item {
  id: view

  // ----------------------------------------------------- shared interface
  required property var theme
  property var status: null
  property var engine: null
  property string density: "compact"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }
  readonly property bool canPop: false

  // Additive to §5.0: the live notice's title (common/Notices.qml), shown in
  // place of the state word for as long as the notice lives (§7.5).
  property string noticeTitle: ""
  // False draws the glyph alone, as the bar does.
  property bool showWord: true

  readonly property var look: Palette.look(view.status, view.statusNote)
  readonly property string word: view.noticeTitle !== "" ? view.noticeTitle : view.look.word
  readonly property real glyphSize: view.theme.titleSize + view.theme.sp.xs

  function roleColor(role) { return Palette.tone(view.theme, role) }

  // Something is under way (connecting, ejecting) and the glance is on screen.
  readonly property bool working: view.look.pulse && view.active && view.visible
  // The ring is turning (it holds still under reduced motion).
  readonly property bool pulsing: view.working && !view.theme.reduced

  implicitWidth: row.implicitWidth
  implicitHeight: Math.max(row.implicitHeight, view.glyphSize)

  Row {
    id: row
    spacing: view.theme.sp.sm

    Item {
      id: mark
      width: glyph.implicitWidth + (badge.visible ? badge.width / 2 : 0)
      height: Math.max(glyph.implicitHeight, view.glyphSize)

      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Palette.glyph
        color: view.roleColor(view.look.role)
        font.family: view.theme.fontFamily
        font.pixelSize: view.glyphSize
      }

      // Corner dot: filled for in use (accent) and error (bad), a ring for
      // attention (warn), as on the bar.
      Rectangle {
        id: badge
        readonly property color tint: view.roleColor(view.look.badge)
        visible: view.look.badge !== ""
        width: Math.round(view.theme.sp.sm * 0.75)
        height: width
        radius: view.theme.radius(height)
        color: view.look.badge === "warn" ? view.theme.none : tint
        border.width: view.look.badge === "warn" ? Math.max(view.theme.hairlineWidth, Math.round(width / 4)) : 0
        border.color: tint
        property bool uiMark: true
        anchors.right: parent.right
        anchors.top: parent.top
      }

      // "+ HDMI monitor": a small monitor under the dot's corner.
      Text {
        id: monitorMark
        visible: view.look.monitor
        textFormat: Text.PlainText
        text: Palette.monitorGlyph
        color: view.theme.accentText
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.footnoteSize
        anchors.right: parent.right
        anchors.bottom: parent.bottom
      }
    }

    URing {
      id: ring
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
      visible: view.working
    }

    Text {
      id: wordText
      anchors.verticalCenter: parent.verticalCenter
      visible: view.showWord && view.word !== ""
      textFormat: Text.PlainText
      text: view.word
      color: view.noticeTitle !== "" ? view.theme.label : view.roleColor(view.look.role === "secondary" ? "secondary" : "foreground")
      elide: Text.ElideRight
      width: view.maxWidth > 0 ? Math.min(implicitWidth, Math.max(0, view.maxWidth - mark.width - (ring.visible ? ring.width + row.spacing : 0) - row.spacing)) : implicitWidth
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
}
