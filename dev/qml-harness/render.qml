import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui
import "egpu" as Egpu

// Renders one page of the panel to a PNG, offscreen: the real NotchIntegration.qml and NotchPanel.qml on a
// stand-in surfaceHost (black or white, radius 8; contract 1), or the real Panel.qml's standalone popup on
// Omarchy's own palette. Run by dev/render.sh under Quickshell with the OpenGL RHI; no real window opens and
// the running shell is never contacted. The status is $EGPU_RUN/status.json and the engine is the dev stub
// (dev/bin), both set up by the script from a fixture.
//
//   UI_RENDER_MODE    hosted | standalone
//   UI_RENDER_HOST    black | white       (the stand-in host's colour)
//   UI_RENDER_ROUTE   main | overview | setup | setup:<row id> | details | eject
//   UI_RENDER_ADV     1 opens Setup's Advanced
//   UI_RENDER_ZONE    1 draws the notch's back zone (180 x 32, top centre) as a box over the panel
//   UI_RENDER_WAIT    ms to wait for the engine's answers before the grab (default 1600)
//   UI_RENDER_OUT     PNG path
ShellRoot {
  id: shell

  readonly property bool hostedMode: (Quickshell.env("UI_RENDER_MODE") || "hosted") !== "standalone"
  readonly property bool black: (Quickshell.env("UI_RENDER_HOST") || "black") !== "white"
  readonly property string route: Quickshell.env("UI_RENDER_ROUTE") || "overview"
  readonly property bool adv: Quickshell.env("UI_RENDER_ADV") === "1"
  readonly property bool zone: Quickshell.env("UI_RENDER_ZONE") === "1"
  readonly property int waitMs: Number(Quickshell.env("UI_RENDER_WAIT") || "1600")
  readonly property string out: Quickshell.env("UI_RENDER_OUT") || "/tmp/egpu-panel.png"

  function say(key, value) { console.log("RENDER " + key + " " + value) }

  FileView {
    id: colors
    blockLoading: true
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  }
  Component.onCompleted: Commons.Color.loadColors(colors.text())

  // A contract-1 surfaceHost, as the notch hands it to a panel (members of notch:NotchHost.qml).
  QtObject {
    id: host
    readonly property int contract: 1
    readonly property var features: ["panel", "activityViews", "heartbeat", "panelBack", "backZone"]
    readonly property real backZoneWidth: 180
    readonly property real backZoneHeight: 32
    readonly property string pluginId: "kalinewb.egpu"
    readonly property color color: shell.black ? "#000000" : "#ffffff"
    readonly property color foreground: shell.black ? "#ffffff" : "#000000"
    readonly property color secondary: shell.black ? "#99EBEBF5" : "#993C3C43"
    readonly property color accent: foreground
    readonly property real radius: 8
    readonly property string fontFamily: Commons.Style.font.family
    readonly property real restHeight: 32
    // 560 unless UI_RENDER_MAXW says otherwise (the live notch gives a panel most of the screen's width).
    readonly property real maxPanelWidth: Number(Quickshell.env("UI_RENDER_MAXW") || 560)
    readonly property real maxPanelHeight: 600
    function radiusFor(size) { return Math.max(0, Math.min(radius, size / 2)) }
    function openPanel(r, s) { return "opened" }
    function closePanel() { return "closed" }
    function claim(a) { return "shown" }
    function release(k) { return "released" }
  }

  // ---------------------------------------------------------------- hosted
  Loader {
    id: integrationLoader
    active: shell.hostedMode
    asynchronous: true
    source: "egpu/NotchIntegration.qml"
    onLoaded: {
      item.surfaceHost = host
      Qt.callLater(shell.openHosted)
    }
  }

  property var hostedPanel: null
  function openHosted() {
    var p = integrationLoader.item.panel.createObject(slot, { maxWidth: host.maxPanelWidth, maxHeight: host.maxPanelHeight })
    p.surfaceHost = host
    p.surfaceScreen = "eDP-1"
    p.open("main")
    var r = shell.route
    if (r === "overview") r = "full"
    if (r !== "main") p.requestRoute(r)
    shell.hostedPanel = p
    if (shell.adv) Qt.callLater(function () { shell.openAdvanced(p) })
    grabTimer.start()
  }

  // Setup's Advanced is the view's own sub-level: found by its property, wherever the shell put the view.
  function openAdvanced(item) {
    if (!item) return false
    if (item.advancedOpen !== undefined) { item.advancedOpen = true; return true }
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) if (shell.openAdvanced(kids[i])) return true
    return false
  }

  Window {
    id: hostedWindow
    visible: shell.hostedMode
    width: shell.hostedPanel ? Math.max(1, Math.ceil(shell.hostedPanel.implicitWidth)) : 440
    height: shell.hostedPanel ? Math.max(1, Math.ceil(shell.hostedPanel.implicitHeight)) : 200
    color: host.color
    Rectangle {
      id: scene
      anchors.fill: parent
      color: host.color
      Item { id: slot; anchors.fill: parent }
      Rectangle {
        visible: shell.zone
        x: (scene.width - host.backZoneWidth) / 2
        y: 0
        width: host.backZoneWidth
        height: host.backZoneHeight
        color: "transparent"
        border.width: 1
        border.color: "#ff3b30"
      }
    }
  }

  // ------------------------------------------------------------ standalone
  PluginBarApi {
    id: barApi
    pluginId: "kalinewb.egpu"
    moduleName: "kalinewb.egpu"
    foreground: Commons.Color.foreground
    barForeground: Commons.Color.foreground
    background: Commons.Color.background
    urgent: Commons.Color.urgent
    fontFamily: Commons.Style.font.family
    barSize: 26
  }
  Window {
    id: barWindow
    visible: !shell.hostedMode
    width: 40
    height: 26
    color: Commons.Color.background
    Egpu.Panel {
      id: realPanel
      visible: !shell.hostedMode
      enabled: !shell.hostedMode
      anchors.fill: parent
      bar: shell.hostedMode ? null : barApi
    }
  }
  // The popup's window: the KeyboardPanel stand-in (dev/qml-harness/KeyboardPanel.qml), found by its API.
  function popupWindow() {
    for (var i = 0; i < realPanel.data.length; i++) {
      var d = realPanel.data[i]
      if (d && d.focusTarget !== undefined && d.contentWidth !== undefined) return d
    }
    return null
  }
  Timer {
    interval: 300
    running: !shell.hostedMode
    onTriggered: {
      realPanel.open()
      var r = shell.route
      if (r === "main") r = "overview"
      if (r !== "overview") realPanel.requestRoute(r)
      if (shell.adv) Qt.callLater(function () { shell.openAdvanced(shell.popupWindow().contentItem) })
      grabTimer.start()
    }
  }

  Timer {
    id: grabTimer
    interval: shell.waitMs
    onTriggered: {
      var target = null
      if (shell.hostedMode) {
        var ok = shell.hostedPanel !== null
        if (!ok) { shell.say("load", "FAIL"); Qt.exit(2); return }
        target = scene
      } else {
        var w = shell.popupWindow()
        if (!w) { shell.say("load", "FAIL no popup"); Qt.exit(2); return }
        target = w.contentItem
      }
      Qt.callLater(function () {
        target.grabToImage(function (result) {
          var saved = result.saveToFile(shell.out)
          shell.say("saved", shell.out + " " + target.width + "x" + target.height + (saved ? "" : " FAILED"))
          Qt.exit(saved ? 0 : 1)
        })
      })
    }
  }
  Timer { interval: 25000; running: true; onTriggered: { shell.say("timeout", "FAIL"); Qt.exit(3) } }
}
