import QtQuick
import "../../common/Palette.js" as Palette

// A minimal switch. The kit's ToggleSwitch rounds its hover ring at
// Style.cornerRadius and its track as a pill, neither of which is the notch's
// radius (notch:SURFACE-HOSTING.md:234); this one takes both from `theme`.
Item {
  id: sw

  property var theme: Palette.make({})
  property bool checked: false
  signal toggled()

  readonly property real u: sw.theme.unit

  implicitWidth: 34 * sw.u
  implicitHeight: 18 * sw.u
  width: implicitWidth
  height: implicitHeight
  opacity: enabled ? 1 : 0.45

  Rectangle {
    anchors.fill: parent
    radius: Math.min(sw.theme.radius, height / 2)
    color: "transparent"
    border.width: Math.max(1, Math.round(sw.u))
    border.color: sw.theme.foreground

    // On: the track filled faintly in the foreground (alpha, not hue).
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: sw.theme.foreground
      opacity: sw.checked ? 0.3 : 0
    }
    Rectangle {
      width: parent.height - 6 * sw.u
      height: width
      radius: Math.min(sw.theme.radius, width / 2)
      x: sw.checked ? parent.width - width - 3 * sw.u : 3 * sw.u
      anchors.verticalCenter: parent.verticalCenter
      color: sw.checked ? sw.theme.foreground : sw.theme.secondary
    }
  }
  MouseArea {
    anchors.fill: parent
    enabled: sw.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: sw.toggled()
  }
}
