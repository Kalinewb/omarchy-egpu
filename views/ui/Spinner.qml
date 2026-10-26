import QtQuick

// Three quarters of a ring, turning: "something is under way". Drawn on a
// Canvas so it has no radius of its own for the notch's radius rule to
// object to, and painted only in its tone. Turns only while `running`; the
// caller ties that to its view being active and visible, because a looping
// animation repaints the host every frame even when nobody can see it
// (notch:SURFACE-HOSTING.md:490-492).
Item {
  id: spin

  property real size: 12
  property color tone: "white"
  property bool running: false

  implicitWidth: spin.size
  implicitHeight: spin.size
  width: implicitWidth
  height: implicitHeight

  Canvas {
    id: canvas
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = Math.max(1, spin.size / 7)
      ctx.lineWidth = w
      ctx.strokeStyle = spin.tone
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.arc(width / 2, height / 2, Math.max(1, width / 2 - w), 0, Math.PI * 1.5)
      ctx.stroke()
    }
    Connections {
      target: spin
      function onToneChanged() { canvas.requestPaint() }
      function onSizeChanged() { canvas.requestPaint() }
    }
  }

  RotationAnimation on rotation {
    running: spin.running
    from: 0
    to: 360
    duration: 900
    loops: Animation.Infinite
    onRunningChanged: if (!running) spin.rotation = 0
  }
}
