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
//   KEYS_SETS   comma list of what to run: esc (Escape and the strip), keys (Tab, Enter, Space, arrows),
//               switch (Space on the HDMI switch; needs the ready-hdmi fixture and the display verbs),
//               confirm (the eject sheet's confirm, with the in-use-procs fixture),
//               failed (the eject sheet's failed step, one answer per fixture: eject-unloaded,
//               eject-in-use-screens, eject-in-use-shared, eject-modules-held, eject-in-use-closeable),
//               setup (a Fix from the Overview: the keyboard rests on the row asked for; this-machine),
//               scroll (Up, Down, j and k scroll the popup; this-machine on the Setup page)
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

  // What the dev engine was asked (it records every verb it does not answer from a fixture).
  FileView {
    id: callsFile
    path: (Quickshell.env("EGPU_RUN") || "/nonexistent") + "/calls.jsonl"
    blockLoading: true
    printErrors: false
  }
  // FileView reloads asynchronously, so the answer is read a moment after asking.
  function callLog() { callsFile.reload(); hostedTest.wait(200); return callsFile.text().trim().replace(/\n/g, " ") }

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
          shell.hostedKeys()
          shell.hostedSwitch()
          shell.hostedConfirm()
          shell.hostedFailed()
          shell.hostedSetup()
          shell.finish()
        }
      }
    }
  }

  // What the keyboard is on: a button's or row's words, "✕" for the close, "" for nothing.
  function focusName(w) {
    var f = w.activeFocusItem
    if (!f) return ""
    if (f.kind !== undefined && typeof f.text === "string") return f.text
    if (f.clickable === true && typeof f.label === "string") return f.label
    if (f.checked !== undefined && typeof f.label === "string") return f.label
    for (var i = 0; i < f.children.length; i++) { var c = f.children[i]; if (c.font !== undefined && c.text === "✕") return "✕" }
    return f.activeFocusOnTab === true ? "(a control)" : ""
  }

  // The keys the kit controls answer, on the real pages (sets keys, switch, confirm, setup).
  function hostedKeys() {
    var t = hostedTest
    var p = t.make()
    p.open("main"); t.wait(300)
    if (shell.sets.indexOf("keys") !== -1) {
      // Tab walks the controls in reading order: the one primary, the row that opens the Overview. No close:
      // this notch draws its own way back (panelBack), so the kit hides the ✕.
      var seen = []
      for (var i = 0; i < 2; i++) { t.keyClick(Qt.Key_Tab); seen.push(shell.focusName(hostedWindow)) }
      shell.check("Tab walks the compact page: the primary, the row that opens the Overview (no ✕ in the notch)", "Safe eject|Open full panel", seen.join("|"))
      t.keyClick(Qt.Key_Tab)
      shell.check("...and Tab goes on round (the ring is closed, nothing is trapped)", true, shell.focusName(hostedWindow) !== "")
      t.keyClick(Qt.Key_Backtab); t.keyClick(Qt.Key_Backtab)
      shell.check("Shift+Tab walks back", "Safe eject", shell.focusName(hostedWindow))
      t.keyClick(Qt.Key_Space); t.wait(100)
      shell.check("Space on the focused primary runs it (Safe eject pushes the sheet)", "main>eject", t.st())
      t.keyClick(Qt.Key_Escape)
      shell.check("...and Escape steps back from it", "main", t.st())

      // Enter with nothing under the keyboard is the page's one primary button.
      p = t.make(); p.open("main"); t.wait(300)
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Enter, with the keyboard on the panel itself, runs the page's primary", "main>eject", t.st())
      // ...and Enter on the focused button does the same once, not twice.
      p = t.make(); p.open("main"); t.wait(300)
      var primary = shell.findText(p, "Safe eject")
      primary.forceActiveFocus()
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Enter on the focused primary runs it once (no second push)", "main>eject", t.st())

      // The tabs are one control: Left and Right pick.
      p = t.make(); p.open("full"); t.wait(300)
      var seg = shell.findProp(p, "options")
      shell.check("the Overview has its tabs, a segmented control", true, !!seg)
      if (seg) {
        seg.forceActiveFocus()
        t.keyClick(Qt.Key_Right); t.wait(50)
        shell.check("Right on the tabs picks Games (the tab replaces the tab)", "main>games", t.st())
        t.keyClick(Qt.Key_Right); t.wait(50)
        shell.check("Right again picks Setup (the tab replaces the tab)", "main>setup", t.st())
        t.keyClick(Qt.Key_Left); t.wait(50)
        t.keyClick(Qt.Key_Left); t.wait(50)
        shell.check("Left twice picks Overview again", "main>overview", t.st())
      }
      // No close in the notch: its strip goes back and Escape closes, so Tab never lands on a ✕.
      p = t.make(); p.open("full"); t.wait(300)
      var close = false
      for (var j = 0; j < 8 && !close; j++) { t.keyClick(Qt.Key_Tab); if (shell.focusName(hostedWindow) === "✕") close = true }
      shell.check("the full panel in the notch has no ✕ for Tab to reach (the notch's own way back is the one)", false, close)
      shell.check("...and nothing closed on the way round", 0, t.closes)
    }
  }

  // Space on the HDMI quick switch asks the engine to turn the eGPU's screen off (the script checks the
  // engine's call log afterwards: display disable <the monitor>).
  function hostedSwitch() {
    if (shell.sets.indexOf("switch") === -1) return
    var t = hostedTest
    var p = t.make()
    p.open("main"); t.wait(400)
    var sw = shell.findProp(p, "checked")
    shell.check("the compact page has the HDMI switch (a kit USwitch, with a name)", true, !!sw && sw.label !== "")
    if (!sw) return
    shell.check("...it shows the screen is on", true, sw.checked)
    sw.forceActiveFocus()
    t.keyClick(Qt.Key_Space); t.wait(600)
    var log = shell.callLog()
    shell.check("Space on the focused switch asks the engine, once, to turn the screen off", "1 call, display disable", (log === "" ? 0 : log.split("] [").length) + " call, " + (log.indexOf('["display","disable",') === 0 ? "display disable" : log))
  }

  // The confirm: Closing apps asks them to quit, so it asks first. Cancel has the keyboard, Enter on it does
  // not close anything, Esc cancels the question before it leaves the sheet.
  function hostedConfirm() {
    if (shell.sets.indexOf("confirm") === -1) return
    var t = hostedTest
    var p = t.make()
    p.open("full"); p.requestRoute("eject"); t.wait(1500)
    var sheet = shell.findProp(p, "asking")
    shell.check("the eject sheet shows the confirm for the apps holding the eGPU", true, !!sheet)
    if (!sheet) return
    var verb = shell.findText(p, "Close 2 apps")
    shell.check("the destructive verb names what it closes", true, !!verb)
    verb.forceActiveFocus()
    t.keyClick(Qt.Key_Return); t.wait(300)
    shell.check("Enter on it only asks", true, sheet.asking)
    shell.check("...the keyboard is on Cancel, not on the verb (a destructive verb is never the default)", "Cancel", shell.focusName(hostedWindow))
    t.keyClick(Qt.Key_Return); t.wait(300)
    shell.check("Enter on Cancel puts the buttons back and closes nothing", false, sheet.asking)
    shell.check("...and the sheet is still up, and only the first check ran", "main>overview>eject", t.st())
    shell.check("...no app was asked to quit", '["device","eject"]', shell.callLog())
    shell.findText(p, "Close 2 apps").forceActiveFocus()
    t.keyClick(Qt.Key_Return); t.wait(300)
    t.keyClick(Qt.Key_Escape); t.wait(300)
    shell.check("Escape cancels the question first, and stays on the sheet", "false main>overview>eject", sheet.asking + " " + t.st())
    t.keyClick(Qt.Key_Escape)
    shell.check("...the next Escape leaves the sheet", "main>overview", t.st())
    // The verb itself, reached on purpose (Tab, or a click): it closes them.
    p = t.make(); p.open("full"); p.requestRoute("eject"); t.wait(1500)
    shell.findText(p, "Close 2 apps").forceActiveFocus()
    t.keyClick(Qt.Key_Return); t.wait(300)
    var verbs = []
    function collect(item) {
      if (!item || !item.visible) return
      if (item.kind !== undefined && item.text === "Close 2 apps" && item.enabled) verbs.push(item)
      for (var i = 0; i < item.children.length; i++) collect(item.children[i])
    }
    collect(p)
    shell.check("once asked, the confirm's own verb is the one that can be pressed", 1, verbs.length)
    if (verbs.length) { verbs[0].forceActiveFocus(); t.keyClick(Qt.Key_Return); t.wait(1200) }
    shell.check("...and Enter on it asks the engine to close them (--close), after the first check (a second sheet ran its own)", '["device","eject"] ["device","eject"] ["device","eject","--close"]', shell.callLog())
  }

  // The eject sheet's failed step, with the fixture's answer (lib/device.sh's templates): which action takes
  // Enter, which is not there, and that a destructive verb is never the default. One run per fixture, because
  // the call log is the run's.
  function hostedFailed() {
    if (shell.sets.indexOf("failed") === -1) return
    var t = hostedTest
    var fx = Quickshell.env("OMARCHY_EGPU_DEV_FIXTURE")
    var p = t.make()
    p.open("full"); p.requestRoute("eject"); t.wait(1500)
    var tryAgain = shell.findText(p, "Try again")
    if (fx === "eject-unloaded") {
      shell.check("driver_unloaded: Connect is there and Try again is not", "true|false", (!!shell.findText(p, "Connect")) + "|" + (!!tryAgain))
      t.keyClick(Qt.Key_Return); t.wait(800)
      shell.check("Enter, with nothing under the keyboard, runs Connect (the primary), not another eject", '["device","eject"] ["device","connect"]', shell.callLog())
      shell.check("...and when it works the sheet goes back to the Overview", "main>overview", t.st())
    } else if (fx === "eject-in-use-screens") {
      var screens = shell.findText(p, "Turn the screens back on")
      shell.check("monitors left off: Turn the screens back on is offered, with Try again beside it", "true|true", (!!screens) + "|" + (!!tryAgain))
      if (!screens) return
      screens.forceActiveFocus()
      t.keyClick(Qt.Key_Space); t.wait(800)
      shell.check("Space on it runs display enable for the monitor, once", '["device","eject"] ["display","enable","Samsung TV"]', shell.callLog())
      shell.check("...and the button is gone once they are on", false, !!shell.findText(p, "Turn the screens back on"))
    } else if (fx === "eject-in-use-shared") {
      t.keyClick(Qt.Key_Return); t.wait(500)
      shell.check("shared driver: no Try again, and Enter does not eject again", "false|" + '["device","eject"]', (!!tryAgain) + "|" + shell.callLog())
    } else if (fx === "eject-modules-held") {
      t.keyClick(Qt.Key_Return); t.wait(500)
      shell.check("modules_held: no Try again, and Enter does not eject again", "false|" + '["device","eject"]', (!!tryAgain) + "|" + shell.callLog())
    } else if (fx === "eject-in-use-closeable") {
      var verb = shell.findText(p, "Close chromium")
      shell.check("driver_in_use with can_close: Close <app> is there, Try again is not", "true|false", (!!verb) + "|" + (!!tryAgain))
      if (!verb) return
      verb.forceActiveFocus()
      t.keyClick(Qt.Key_Return); t.wait(300)
      shell.check("Enter on it only asks: the keyboard is on Cancel, nothing was closed", "Cancel|" + '["device","eject"]', shell.focusName(hostedWindow) + "|" + shell.callLog())
    }
  }

  // A Fix from the Overview opens Setup on its row: the row is marked (selected), and the keyboard rests on
  // its Fix, so Enter fixes it.
  function hostedSetup() {
    if (shell.sets.indexOf("setup") === -1) return
    var t = hostedTest
    var p = t.make()
    p.open("main"); p.requestRoute("full"); p.requestRoute("setup:hypr.session_env"); t.wait(1200)
    var f = hostedWindow.activeFocusItem
    var row = null
    for (var q = f; q && !row; q = q.parent) if (q.row !== undefined && q.focused !== undefined) row = q
    shell.check("the keyboard rests on the Fix of the row that was asked for", "hypr.session_env|Fix", (row ? row.row.id : "none") + "|" + shell.focusName(hostedWindow))
    shell.check("...and that row is the selected one (the accent bar), apart from the focus ring", true, !!row && row.focused)
    t.keyClick(Qt.Key_Return); t.wait(800)
    shell.check("Enter on it runs the Fix (the engine's display apply)", '["display","apply"]', shell.callLog())
    // Tab to a control below the fold scrolls it into view.
    p = t.make(); p.open("setup"); t.wait(800)
    var fl = shell.findProp(p, "contentY")
    shell.check("Setup is taller than the panel", true, !!fl && fl.contentHeight > fl.height)
    if (fl) {
      for (var n = 0; n < 60 && fl.contentY === 0; n++) t.keyClick(Qt.Key_Tab)
      shell.check("Tab to a control below the fold scrolls it into view", true, fl.contentY > 0)
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
    if (shell.sets.indexOf("keys") !== -1) {
      // The popup used Omarchy's PanelKeyCatcher, which took Tab, Enter and Space before a control could;
      // the kit's controls need them, so Esc and Enter go through UKeys and Tab walks the controls.
      realPanel.open(); t.wait(150); focus()
      var names = []
      for (var i = 0; i < 6; i++) { t.keyClick(Qt.Key_Tab); names.push(shell.focusName(w)) }
      shell.check("Tab walks the popup's controls: the tabs, the close, the primary, the notice's link, the row that opens Details", "(a control)|✕|Safe eject|Open Setup|Details|(a control)", names.join("|"))
      var primary = shell.findText(w.contentItem, "Safe eject")
      primary.forceActiveFocus()
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Enter on the focused primary runs it (Safe eject pushes the sheet)", "overview>eject/open", st())
      t.keyClick(Qt.Key_Escape)
      shell.check("...and Escape is back one step", "overview/open", st())
      // Enter with the keyboard on the popup itself is the page's one primary.
      focus()
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Enter, with nothing focused, runs the page's primary", "overview>eject/open", st())
      t.keyClick(Qt.Key_Escape)
      var seg = shell.findProp(w.contentItem, "options")
      seg.forceActiveFocus()
      t.keyClick(Qt.Key_Right); t.wait(50)
      shell.check("Right on the tabs picks Games", "games/open", st())
      t.keyClick(Qt.Key_Right); t.wait(50)
      shell.check("Right again picks Setup", "setup/open", st())
      t.keyClick(Qt.Key_Left); t.wait(50)
      t.keyClick(Qt.Key_Left); t.wait(50)
      shell.check("Left twice picks Overview again", "overview/open", st())
      // The one close.
      focus()
      for (var j = 0; j < 4 && shell.focusName(w) !== "✕"; j++) t.keyClick(Qt.Key_Tab)
      t.keyClick(Qt.Key_Return); t.wait(100)
      shell.check("Tab to the close and Enter closes the popup", "overview/closed", st())
    }
    if (shell.sets.indexOf("scroll") !== -1) {
      realPanel.open(); t.wait(150); focus()
      realPanel.requestRoute("setup"); t.wait(500); focus()
      var fl = shell.findProp(w.contentItem, "contentY")
      shell.check("Setup is taller than the popup, so there is something to scroll", true, !!fl && fl.contentHeight > fl.height)
      if (fl) {
        t.keyClick(Qt.Key_Down); t.wait(50)
        var down = fl.contentY
        shell.check("Down scrolls", true, down > 0)
        t.keyClick(Qt.Key_Up); t.wait(50)
        shell.check("Up scrolls back", true, fl.contentY < down)
        t.keyClick("j"); t.wait(50)
        var j = fl.contentY
        shell.check("j scrolls down", true, j > 0)
        t.keyClick("k"); t.wait(50)
        shell.check("k scrolls up", true, fl.contentY < j)
        // A Tab to a control below the fold scrolls it into view.
        fl.contentY = 0
        for (var n = 0; n < 40 && fl.contentY === 0; n++) t.keyClick(Qt.Key_Tab)
        shell.check("Tab to a control below the fold scrolls it into view", true, fl.contentY > 0)
      }
    }
    shell.finish()
  }

  Timer { interval: 40000; running: true; onTriggered: { console.log("KEYS FAIL timeout"); Qt.exit(3) } }
}
