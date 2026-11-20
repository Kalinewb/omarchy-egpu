import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import qs.Ui
import "egpu" as Egpu

// The panel's keys, pressed for real (QtTest's keyClick into the focused item), offscreen: the real
// NotchIntegration.qml and NotchPanel.qml on a stand-in notch host (with the back strip), and the real
// Panel.qml's standalone popup. Run by dev/keys.sh under Quickshell; no real window opens and nothing
// touches the running shell. Prints `KEYS pass|FAIL <name> [detail]` per check.
//
//   KEYS_CASE   hosted | standalone
//   KEYS_SETS   comma list of what to run: esc (Escape and the strip), keys (Tab, Enter, Space, arrows)
//
// Escape: one step back at a time, the view's own sub-level first (Setup's Advanced), then the route,
// and only at the root does it close; the strip's press (goBackInside) walks the same steps and never
// closes. Standalone, Escape is back one step too and the root closes.
ShellRoot {
  id: shell

  readonly property bool hostedCase: (Quickshell.env("KEYS_CASE") || "hosted") === "hosted"
  readonly property var sets: (Quickshell.env("KEYS_SETS") || "esc,keys").split(",")
  property int failures: 0
  property int checks: 0

  function check(name, expected, actual) {
    shell.checks++
    var ok = String(expected) === String(actual)
    if (!ok) shell.failures++
    console.log("KEYS " + (ok ? "pass" : "FAIL") + " " + name + (ok ? "" : "   expected '" + expected + "', got '" + actual + "'"))
  }
  function finish() {
    console.log("KEYS done " + shell.checks + " " + shell.failures)
    Qt.exit(shell.failures === 0 ? 0 : 1)
  }

  FileView {
    id: colors
    blockLoading: true
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  }
  Component.onCompleted: Commons.Color.loadColors(colors.text())

  QtObject {
    id: host
    readonly property int contract: 1
    readonly property var features: ["panel", "activityViews", "heartbeat", "panelBack", "backZone"]
    readonly property real backZoneWidth: 180
    readonly property real backZoneHeight: 32
    readonly property string pluginId: "kalinewb.egpu"
    readonly property color color: "#000000"
    readonly property color foreground: "#ffffff"
    readonly property color secondary: "#99EBEBF5"
    readonly property color accent: "#ffffff"
    readonly property real radius: 8
    readonly property string fontFamily: Commons.Style.font.family
    readonly property real restHeight: 32
    readonly property real maxPanelWidth: 560
    readonly property real maxPanelHeight: 600
    function radiusFor(size) { return Math.max(0, Math.min(radius, size / 2)) }
    function openPanel(r, s) { return "opened" }
    function closePanel() { return "closed" }
    function claim(a) { return "shown" }
    function release(k) { return "released" }
  }

  function findProp(item, prop) {
    if (!item) return null
    if (item[prop] !== undefined) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var f = shell.findProp(kids[i], prop); if (f) return f }
    return null
  }
  // A visible item by its label or text: a button, a row, a tab.
  function findText(item, text) {
    if (!item || !item.visible) return null
    if ((item.label === text || item.text === text) && item.clicked !== undefined) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var f = shell.findText(kids[i], text); if (f) return f }
    return null
  }

  // -------------------------------------------------------------- hosted
  Loader {
    id: integrationLoader
    active: shell.hostedCase
    asynchronous: true
    source: "egpu/NotchIntegration.qml"
    onLoaded: { item.surfaceHost = host; hostedTimer.start() }
  }
  property bool hostedReady: false
  Timer { id: hostedTimer; interval: 300; onTriggered: shell.hostedReady = true }

  Window {
    id: hostedWindow
    visible: shell.hostedCase
    width: 560
    height: 600
    color: "#000000"
    Item {
      id: slot
      anchors.fill: parent
      TestCase {
        id: hostedTest
        name: "hosted"
        when: hostedWindow.visible && shell.hostedReady
        windowShown: true
        property int closes: 0
        property var panel: null

        function make() {
          if (panel) panel.destroy()
          closes = 0
          var p = integrationLoader.item.panel.createObject(slot, { maxWidth: host.maxPanelWidth, maxHeight: host.maxPanelHeight })
          p.surfaceHost = host
          p.surfaceScreen = "eDP-1"
          p.closeRequested.connect(function () { hostedTest.closes += 1 })
          panel = p
          return p
        }
        function st() { return panel.routeStack.join(">") }
        function esc() { keyClick(Qt.Key_Escape); return st() + "/" + closes }

        // QtTest runs `test_*` functions once `when` holds, so the whole sequence is one of them.
        function test_keys() {
          if (!shell.hostedCase) return
          var p = make()
          p.open("main")
          wait(100)
          shell.check("the panel takes the keyboard when the notch opens it", true, p.activeFocus)
          if (shell.sets.indexOf("esc") !== -1) {
            // Esc at the root asks the notch to close.
            shell.check("Escape at main closes", "main/1", esc())

            p = make(); p.open("full"); wait(50)
            shell.check("opened at the Overview: Escape goes back to main", "main/0", esc())
            shell.check("...and the next one closes", "main/1", esc())

            p = make(); p.open("main"); wait(50)
            p.requestRoute("full"); p.requestRoute("details"); wait(50)
            shell.check("Details over the Overview over main: Escape steps back, one route at a time", "main>overview/0 main/0 main/1",
              [esc(), esc(), esc()].join(" "))

            p = make(); p.open("main"); wait(50)
            p.requestRoute("full"); p.requestRoute("eject"); wait(50)
            shell.check("the eject sheet: Escape steps back like any route", "main>overview/0 main/0 main/1",
              [esc(), esc(), esc()].join(" "))

            // Setup's Advanced is the view's own sub-level: Escape closes it before it leaves Setup.
            p = make(); p.open("setup"); wait(300)
            var sv = shell.findProp(p, "advancedOpen")
            shell.check("Setup is on screen with its Advanced", true, !!sv)
            if (sv) {
              sv.advancedOpen = true; wait(50)
              shell.check("Escape closes Advanced first, and stays on Setup", "main>setup/0 false", esc() + " " + sv.advancedOpen)
              shell.check("...then leaves Setup, then closes", "main/0 main/1", [esc(), esc()].join(" "))
            }

            // The back strip's press (goBackInside) walks the same steps and never closes.
            p = make(); p.open("main"); wait(50)
            p.requestRoute("full"); p.requestRoute("details"); wait(50)
            var steps = []
            for (var i = 0; i < 4; i++) steps.push(String(p.goBackInside()) + ":" + st())
            shell.check("the strip steps back through the routes and then answers no, never closing", "true:main>overview true:main false:main false:main/0",
              steps.join(" ") + "/" + closes)
          }
          if (shell.sets.indexOf("keys") !== -1) shell.hostedKeys()
          shell.finish()
        }
      }
    }
  }

  // The keys the kit controls answer, on the real pages (set "keys").
  function hostedKeys() {
    var t = hostedTest
    var p = t.make()
    p.open("main"); t.wait(300)
    // Tab reaches the primary button, and Enter on it does what a click does: Safe eject opens the sheet.
    var ready = shell.findText(p, "Safe eject")
    shell.check("compact page: the primary button is there", true, !!ready)
    if (ready) {
      shell.check("...and takes keyboard focus by Tab", true, ready.activeFocusOnTab)
      ready.forceActiveFocus()
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Enter on the focused primary runs it (Safe eject pushes the sheet)", "main>eject", t.st())
      t.keyClick(Qt.Key_Escape)
      shell.check("...and Escape steps back from it", "main", t.st())
    }
  }

  // ---------------------------------------------------------- standalone
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
    visible: !shell.hostedCase
    width: 40
    height: 26
    color: Commons.Color.background
    Egpu.Panel {
      id: realPanel
      visible: !shell.hostedCase
      enabled: !shell.hostedCase
      anchors.fill: parent
      bar: shell.hostedCase ? null : barApi
    }
  }
  function popupWindow() {
    for (var i = 0; i < realPanel.data.length; i++) {
      var d = realPanel.data[i]
      if (d && d.focusTarget !== undefined && d.contentWidth !== undefined) return d
    }
    return null
  }
  Timer {
    interval: 500
    running: !shell.hostedCase
    onTriggered: shell.runStandalone()
  }

  property var popupTest: null
  function runStandalone() {
    realPanel.open()
    var w = shell.popupWindow()
    if (!w) { shell.check("the popup opened", true, false); shell.finish(); return }
    // A TestCase in the popup's own window, so its key events go there.
    var t = Qt.createQmlObject('import QtQuick; import QtTest; TestCase { name: "popup"; when: true; windowShown: true }', w.contentItem, "keys-popup")
    shell.popupTest = t
    Qt.callLater(function () { shell.standaloneRun(t, w) })
  }
  function standaloneRun(t, w) {
    function focus() { if (w.focusTarget) w.focusTarget.forceActiveFocus() }
    function st() { return realPanel.routeStack.join(">") + "/" + (realPanel.opened ? "open" : "closed") }
    function esc() { t.keyClick(Qt.Key_Escape); return st() }
    t.wait(200)
    focus()
    shell.check("the popup opens on the Overview", "overview/open", st())
    if (shell.sets.indexOf("esc") !== -1) {
      shell.check("Escape at the root closes the popup", "overview/closed", esc())

      realPanel.open(); t.wait(100); focus()
      realPanel.requestRoute("details"); t.wait(50)
      shell.check("Details over the Overview: Escape is back one step, not close", "overview/open overview/closed", [esc(), esc()].join(" "))

      realPanel.open(); t.wait(100); focus()
      realPanel.requestRoute("setup"); t.wait(300)
      var sv = shell.findProp(w.contentItem, "advancedOpen")
      shell.check("Setup is on screen with its Advanced", true, !!sv)
      if (sv) {
        sv.advancedOpen = true; t.wait(50)
        shell.check("Escape closes Advanced first and stays on Setup", "overview>setup/open false", esc() + " " + sv.advancedOpen)
        shell.check("...then back to the Overview, then closes", "overview/open overview/closed", [esc(), esc()].join(" "))
      }
    }
    shell.finish()
  }

  Timer { interval: 40000; running: true; onTriggered: { console.log("KEYS FAIL timeout"); Qt.exit(3) } }
}
