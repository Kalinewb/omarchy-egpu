import QtQuick
import QtQuick.Shapes

// Progress (plan-apple-ui.md 4.2 "Progress"): a ring, 16 px beside a label.
// `value` 0..1 is determinate; -1 is indeterminate: a 270 degree arc turning
// once every 900 ms, linear. With reduced motion it stops and shows a steady
// half arc. A bar is only for live values (the OSD).
Item {
  id: root
  required property var theme
  property real value: -1
  property string text: ""
  property int size: 16

  readonly property bool indeterminate: value < 0
  readonly property real stroke: 2

  implicitWidth: row.implicitWidth
  implicitHeight: Math.max(size, label.implicitHeight)
  Accessible.role: Accessible.ProgressBar
  Accessible.name: text !== "" ? text : "Working"

  Row {
    id: row
    spacing: root.theme.sp.sm
    anchors.verticalCenter: parent.verticalCenter

    Item {
      id: ring
      width: root.size
      height: root.size
      anchors.verticalCenter: parent.verticalCenter
      rotation: 0

      // The track carries no information (the arc does), so it is not a mark.
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: root.theme.hover
          strokeWidth: root.stroke
          fillColor: "transparent"
          PathAngleArc {
            centerX: root.size / 2; centerY: root.size / 2
            radiusX: root.size / 2 - root.stroke / 2; radiusY: root.size / 2 - root.stroke / 2
            startAngle: 0; sweepAngle: 360
          }
        }
      }
      Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        property bool uiMark: true
        // Determinate sweeps with the value; indeterminate is 270 in motion, 180 at rest.
        property real sweep: root.indeterminate ? (root.theme.reduced ? 180 : 270) : Math.max(1, 360 * Math.min(1, root.value))
        Behavior on sweep { enabled: !root.indeterminate; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        ShapePath {
          strokeColor: root.theme.accent
          strokeWidth: root.stroke
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          PathAngleArc {
            centerX: root.size / 2; centerY: root.size / 2
            radiusX: root.size / 2 - root.stroke / 2; radiusY: root.size / 2 - root.stroke / 2
            startAngle: -90; sweepAngle: arc.sweep
          }
        }
      }

      RotationAnimation on rotation {
        from: 0
        to: 360
        duration: root.theme.ringMs
        loops: Animation.Infinite
        running: root.indeterminate && root.visible && !root.theme.reduced
      }
    }
    Text {
      id: label
      visible: root.text !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      color: root.theme.secondary
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
    }
  }
}
