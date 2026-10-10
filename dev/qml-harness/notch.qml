import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Ui
import "egpu" as Egpu
import "egpu/views" as EgpuViews
import "egpu/common" as EgpuCommon
import "egpu/common/Palette.js" as EgpuPalette

// Gate G8 offscreen (plan-gui.md §10): the REAL NotchIntegration.qml,
// NotchPanel.qml, Panel.qml and views/{Glance,CompactView}.qml in a throwaway
// Quickshell, with a stand-in for the notch's `surfaceHost`
// (notch:NotchHost.qml's members) that records what the plugin asks of it.
// Run by dev/g8-offscreen.sh, which builds the config root, writes status
// files and checks what this prints (`HARNESS <key> <value>`).
//
// The real notch is never loaded and the live shell is never contacted:
// QT_QPA_PLATFORM=offscreen, no WAYLAND_DISPLAY, a temp config root and
// $EGPU_RUN. The notch's own rules (contract.js, platform.js, the scanner) are
// applied to what this prints by the script, under node.
//
// Cases (EGPU_HARNESS_CASE):
//   states        Glance and CompactView for every document in
//                 $EGPU_HARNESS_DOCS ({name: status}), on the notch's palette
//   integration   NotchIntegration loaded as the notch loads it (an async
//                 Loader), with or without a host; `available`, claims
//   stack         NotchPanel from the integration's `panel`: routes, Back,
//                 Escape chain, open/close
//   widget        Panel.qml's click rule and `notch` descriptor
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("EGPU_HARNESS_CASE") || "states"
  readonly property int waitMs: Number(Quickshell.env("EGPU_HARNESS_WAIT_MS") || "1500")
  readonly property bool withHost: Quickshell.env("EGPU_HARNESS_NO_HOST") !== "1"

  function log(key, value) { console.log("HARNESS " + key, value) }

  // ------------------------------------------------------- the fake host
  //
  // The members of notch:NotchHost.qml a plugin may use, with the notch's
  // default look (white on black, radius 8). Answers come from the
  // environment so each per-event rule can be driven both ways.
  QtObject {
    id: host
    readonly property int contract: 1
    readonly property var features: ["panel", "activityViews", "heartbeat"]
    readonly property string pluginId: "kalinewb.egpu"
    property bool present: true
    property bool accepted: true
    readonly property string reason: ""
    readonly property string reasonDetail: ""
    property bool hidden: false
    readonly property color color: "#000000"
    readonly property color foreground: "#ffffff"
    readonly property color secondary: "#ebebf5"
    readonly property color accent: "#ffffff"
    readonly property real radius: 8
    readonly property string fontFamily: "JetBrainsMono Nerd Font"
    readonly property real restHeight: 32
    readonly property real maxPanelWidth: 560
    readonly property real maxPanelHeight: 600
    function radiusFor(size) { return Math.min(radius, size / 2) }

    property var opens: []
    property var claims: []
    property var releases: []
    function openPanel(route, screenName) {
      host.opens = host.opens.concat([String(route) + "@" + String(screenName)])
      return Quickshell.env("EGPU_HARNESS_OPEN_ANSWER") || "opened"
    }
    function closePanel() { return "closed" }
    function claim(activity) {
      host.claims = host.claims.concat([activity])
      return Quickshell.env("EGPU_HARNESS_CLAIM_ANSWER") || "shown"
    }
    function release(key) { host.releases = host.releases.concat([String(key)]); return "released" }
  }

  // Every visible Text under an item, top to bottom: what a person would read.
  function texts(item, out) {
    if (!item || !item.visible) return out
    if (item.text !== undefined && typeof item.text === "string" && item.text !== "" && item.font !== undefined)
      out.push(item.text === EgpuPalette.glyph ? "glyph" : item.text.replace(/\n/g, " "))
    for (var i = 0; i < item.children.length; i++) rootObj.texts(item.children[i], out)
    return out
  }

  // Visible buttons (CompactView's Action), by label; disabled ones marked.
  function buttons(item, out) {
    if (!item || !item.visible) return out
    if (item.clicked !== undefined && typeof item.label === "string") out.push(item.label + (item.enabled ? "" : "(off)"))
    for (var i = 0; i < item.children.length; i++) rootObj.buttons(item.children[i], out)
    return out
  }

  // Every colour painted under an item that is not one of the host's
  // (foreground, secondary, accent), transparent, or a derivative the kit
  // makes of the foreground by alpha alone (no hue): what the notch's mono
  // shader check is for, done by value.
  function hueOf(c) { return [Math.round(c.r * 255), Math.round(c.g * 255), Math.round(c.b * 255)].join(",") }
  function foreignColours(item, out) {
    if (!item || !item.visible) return out
    var allowed = [hueOf(host.foreground), hueOf(host.secondary), hueOf(host.accent)]
    function check(c, what) {
      if (c === undefined || c === null || typeof c !== "object" || c.a === undefined) return
      if (c.a === 0) return
      // Alpha blends of white over nothing keep the foreground's hue.
      if (allowed.indexOf(rootObj.hueOf(c)) !== -1) return
      // A neutral grey is a lightness step of a neutral host colour.
      if (Math.abs(c.r - c.g) < 0.02 && Math.abs(c.g - c.b) < 0.02 && hueOf(host.foreground) === "255,255,255") return
      out.push(what + "=" + c)
    }
    var name = String(item).replace(/\(0x.*$/, "").replace(/_QMLTYPE_\d+/, "")
    if (item.font !== undefined && item.color !== undefined) check(item.color, name + ".color")
    else if (item.color !== undefined && item.radius !== undefined) check(item.color, name + ".color")
    if (item.border !== undefined && item.border && item.border.width > 0) check(item.border.color, name + ".border")
    for (var i = 0; i < item.children.length; i++) rootObj.foreignColours(item.children[i], out)
    return out
  }

  // Every drawn rounded item whose radius is not surfaceHost.radiusFor() of
  // its size (notch:SURFACE-HOSTING.md:234; the notch's own radiusAudit).
  function badRadii(item, out) {
    if (!item || !item.visible) return out
    if (item.radius !== undefined && typeof item.radius === "number" && item.radius > 0) {
      var drawn = (item.color !== undefined && item.color.a > 0) || (item.border !== undefined && item.border && item.border.width > 0)
      var want = host.radiusFor(Math.min(item.width, item.height))
      if (drawn && Math.abs(item.radius - want) > 0.01)
        out.push(String(item).replace(/\(0x.*$/, "") + " r=" + item.radius + " want " + want + " (" + item.width + "x" + item.height + ")")
    }
    for (var i = 0; i < item.children.length; i++) rootObj.badRadii(item.children[i], out)
    return out
  }

  // ================================================================ states

  FileView {
    id: docsFile
    path: rootObj.caseName === "states" ? (Quickshell.env("EGPU_HARNESS_DOCS") || "") : ""
    blockLoading: true
    printErrors: false
  }
  readonly property var docs: {
    if (rootObj.caseName !== "states") return ({})
    try { return JSON.parse(docsFile.text()) } catch (e) { return ({}) }
  }
  readonly property var notchTheme: EgpuPalette.fromHost(host, { unit: 1, font: { caption: 10, body: 12, title: 14, display: 24, icon: 14 } })

  EgpuCommon.Engine { id: harnessEngine; pluginDir: "" }

  Window {
    id: statesWindow
    visible: rootObj.caseName === "states"
    width: 360
    height: 400
    color: "#000000"
    Rectangle { anchors.fill: parent; color: "#000000" }
    Column {
      id: statesColumn
      x: 20
      y: 20
      spacing: 12
    }
  }

  Component {
    id: glanceComp
    EgpuViews.Glance { theme: rootObj.notchTheme; engine: harnessEngine }
  }
  Component {
    id: compactComp
    EgpuViews.CompactView { theme: rootObj.notchTheme; engine: harnessEngine; maxWidth: 320 }
  }

  function runStates() {
    var names = Object.keys(rootObj.docs)
    var png = Quickshell.env("EGPU_HARNESS_PNG_DIR") || ""
    var i = 0
    function next() {
      if (i >= names.length) { Qt.exit(0); return }
      var name = names[i++]
      var doc = rootObj.docs[name]
      // Assigned, not passed in createObject's map: as the shells bind it.
      var g = glanceComp.createObject(statesColumn, { active: true })
      var c = compactComp.createObject(statesColumn, { active: true })
      g.status = doc
      c.status = doc
      Qt.callLater(function () {
        var look = g.look
        rootObj.log("g." + name, [look.state, g.word === "" ? "none" : g.word, look.role,
          look.badge === "" ? "none" : look.badge, look.pulse, look.monitor].join("|"))
        rootObj.log("g." + name + ".drawn", g.visible && g.implicitWidth > 0 && g.implicitHeight > 0)
        rootObj.log("c." + name + ".text", rootObj.texts(c, []).join(" ¦ "))
        rootObj.log("c." + name + ".buttons", rootObj.buttons(c, []).join(",") || "none")
        rootObj.log("c." + name + ".size", c.implicitHeight > 0 && c.width > 0 && c.width <= 320)
        var foreign = rootObj.foreignColours(g, rootObj.foreignColours(c, []))
        rootObj.log("c." + name + ".colours", foreign.length ? foreign.join(" ; ") : "host-only")
        var radii = rootObj.badRadii(g, rootObj.badRadii(c, []))
        rootObj.log("c." + name + ".radii", radii.length ? radii.join(" ; ") : "radiusFor")
        // The pulse runs only while the view is active and drawn.
        rootObj.log("g." + name + ".pulsing", g.pulsing)
        g.active = false
        Qt.callLater(function () {
          rootObj.log("g." + name + ".pulseIdle", !g.pulsing && g.pulse === 1)
          statesWindow.height = Math.max(200, c.implicitHeight + g.implicitHeight + 60)
          var after = function () { g.destroy(); c.destroy(); next() }
          if (png === "") { after(); return }
          g.active = true
          statesWindow.contentItem.grabToImage(function (r) { r.saveToFile(png + "/notch-" + name + ".png"); after() })
        })
      })
    }
    next()
  }

  // =========================================================== integration

  Loader {
    id: integrationLoader
    active: rootObj.caseName === "integration" || rootObj.caseName === "stack"
    asynchronous: true
    source: "egpu/NotchIntegration.qml"
    property bool availableAtLoad: false
    onLoaded: {
      // As NotchPlatform does: hand the host over, then read `available`.
      if (rootObj.withHost && "surfaceHost" in item) item.surfaceHost = host
      availableAtLoad = item.available
      rootObj.log("availableAtLoad", item.available)
      if (rootObj.caseName === "stack") Qt.callLater(rootObj.runStack)
    }
  }

  function reportIntegration() {
    var it = integrationLoader.item
    if (!it) { rootObj.log("loaded", false); return }
    rootObj.log("loaded", true)
    rootObj.log("available", it.available)
    rootObj.log("reason", it.unavailableReason === "" ? "none" : it.unavailableReason)
    rootObj.log("hasPanel", !!it.panel)
    rootObj.log("activityViews", Object.keys(it.activityViews).join(","))
    rootObj.log("claims", JSON.stringify(host.claims))
    rootObj.log("claimTitles", host.claims.map(function (c) { return c.title }).join(" | ") || "none")
    rootObj.log("lastAnswer", it.lastAnswer === "" ? "none" : it.lastAnswer)
    rootObj.log("lastClaim", it.lastClaim ? JSON.stringify(it.lastClaim) : "none")
    rootObj.log("noticeTitle", it.noticeTitle === "" ? "none" : it.noticeTitle)
    rootObj.log("state", it.status && it.status.summary ? it.status.summary.state : "none")
    // The notice row the notch would draw from activityViews.
    var row = it.activityViews.egpu.createObject(statesColumn)
    rootObj.log("noticeRow", row ? rootObj.texts(row, []).join(" ") : "none")
    if (row) row.destroy()
  }

  // ================================================================= stack

  Window {
    id: stackWindow
    visible: rootObj.caseName === "stack"
    width: 600
    height: 640
    color: "#000000"
    Item { id: stackSlot; anchors.fill: parent }
  }

  // A stand-in for G3's eject sheet: one sub-sheet (a confirm dialog) that
  // popView() closes first, as §7.7 says Escape must.
  Component {
    id: fakeEject
    Column {
      property bool dialog: true
      readonly property string title: "Safe eject"
      function popView() { if (dialog) { dialog = false; return true } return false }
      Text { text: "eject sheet"; color: "#ffffff" }
    }
  }

  property int closes: 0
  function runStack() {
    var it = integrationLoader.item
    var p = it.panel.createObject(stackSlot, { maxWidth: 560, maxHeight: 600 })
    // As the notch's ExpandedHost does on load.
    p.surfaceHost = host
    p.surfaceScreen = "eDP-1"
    p.closeRequested.connect(function () { rootObj.closes += 1 })
    function st() { return p.routeStack.join(">") }

    p.open("main")
    rootObj.log("open.main", st() + "|" + p.active + "|" + (p.background === undefined ? "?" : p.background))
    rootObj.log("main.texts", rootObj.texts(p, []).join(" ¦ "))
    rootObj.log("main.back", p.routeStack.length > 1)
    p.requestRoute("full")
    rootObj.log("toFull", st())
    rootObj.log("full.texts", rootObj.texts(p, []).join(" ¦ "))
    rootObj.log("full.colours", (function () { var f = rootObj.foreignColours(p, []); return f.length ? f.join(" ; ") : "host-only" })())
    rootObj.log("full.radii", (function () { var f = rootObj.badRadii(p, []); return f.length ? f.join(" ; ") : "radiusFor" })())
    p.requestRoute("games")
    rootObj.log("unbuiltGames", st())
    p.requestRoute("eject")
    rootObj.log("unbuiltEject", st())

    // The Escape chain, with a stand-in sheet that holds a dialog.
    var routes = {}
    for (var k in p.builtRoutes) routes[k] = p.builtRoutes[k]
    routes.eject = fakeEject
    p.builtRoutes = routes
    p.requestRoute("eject")
    rootObj.log("toEject", st())
    var steps = []
    for (var i = 0; i < 5 && rootObj.closes === 0; i++) steps.push(p.back() + ":" + st())
    rootObj.log("escape", steps.join(" "))
    rootObj.log("closes", rootObj.closes)

    // Opened straight at full, Escape still steps through main.
    rootObj.closes = 0
    p.open("full")
    var s2 = [st()]
    while (rootObj.closes === 0 && s2.length < 5) s2.push(p.back() + ":" + st())
    rootObj.log("escapeFromFull", s2.join(" "))

    // An unbuilt route asked for by the notch lands on main, never blank.
    p.open("games")
    rootObj.log("openGames", st())
    // The notch rebinding `route` while open moves the stack too.
    p.route = "full"
    rootObj.log("routeRebind", st())
    p.close()
    rootObj.log("closed.active", p.active)
    p.open("main")
    rootObj.log("reopen", st() + "|" + p.active)
    rootObj.log("focus", p.focus)
    // Measured after the positioners have laid out (a Column's implicit
    // height settles on the next polish, not inside this function).
    stackSizeTimer.panel = p
    stackSizeTimer.start()
  }
  Timer {
    id: stackSizeTimer
    property var panel: null
    interval: 200
    onTriggered: {
      var p = panel
      rootObj.log("sizeMain", Math.round(p.implicitWidth) + "x" + Math.round(p.implicitHeight))
      rootObj.log("size", (p.implicitWidth > 0 && p.implicitWidth <= 560) + "|" + (p.implicitHeight > 0 && p.implicitHeight <= 600))
      p.requestRoute("full")
      stackSizeTimer2.start()
    }
  }
  Timer {
    id: stackSizeTimer2
    interval: 200
    onTriggered: {
      var p = stackSizeTimer.panel
      rootObj.log("sizeFull", Math.round(p.implicitWidth) + "x" + Math.round(p.implicitHeight))
      var png = Quickshell.env("EGPU_HARNESS_PNG_DIR") || ""
      if (png === "") { Qt.exit(0); return }
      stackWindow.contentItem.grabToImage(function (r) { r.saveToFile(png + "/notch-full.png"); Qt.exit(0) })
    }
  }

  // ================================================================ widget

  PluginBarApi {
    id: barApi
    pluginId: "kalinewb.egpu"
    moduleName: "kalinewb.egpu"
    foreground: "#e0e0e0"
    barForeground: "#d0d0d0"
    background: "#101315"
    urgent: "#a55555"
    fontFamily: "JetBrainsMono Nerd Font"
    barSize: 26
  }

  Window {
    id: barWindow
    visible: rootObj.caseName === "widget"
    width: 40
    height: 26
    color: "#101315"
    Loader {
      id: widgetLoader
      anchors.fill: parent
      active: rootObj.caseName === "widget"
      sourceComponent: Component { Egpu.Panel { bar: barApi } }
      onLoaded: {
        // As the notch's injectProps does: only into a widget that declares them.
        if (rootObj.withHost && "surfaceHost" in item) item.surfaceHost = host
        if ("surfaceScreen" in item) item.surfaceScreen = "HDMI-A-1"
      }
    }
  }

  function plainDescriptor(d) {
    function v(x) { return x && typeof x === "object" && typeof x.createObject === "function" ? "component" : x }
    var out = {}
    for (var k in d) out[k] = v(d[k])
    return out
  }

  function reportWidget() {
    var w = widgetLoader.item
    rootObj.log("hasNotch", "notch" in w)
    rootObj.log("descriptor", JSON.stringify(rootObj.plainDescriptor(w.notch)))
    rootObj.log("noticeLive", w.noticeLive)
    var r1 = w.press()
    rootObj.log("press1", r1 + "|" + (w.opened ? "own-open" : "own-closed"))
    rootObj.log("opens", host.opens.join(",") || "none")
    // The descriptor's expandedView, instantiated as a future notch would.
    var view = w.notch.expandedView.createObject(statesColumn)
    rootObj.log("expandedView", view ? rootObj.texts(view, []).slice(0, 2).join(" ¦ ") : "none")
    if (view) view.destroy()
  }

  // ================================================================ finish

  Component.onCompleted: if (rootObj.caseName === "states") Qt.callLater(rootObj.runStates)

  Timer {
    interval: rootObj.waitMs
    running: rootObj.caseName === "integration" || rootObj.caseName === "widget"
    onTriggered: {
      if (rootObj.caseName === "integration") rootObj.reportIntegration()
      else rootObj.reportWidget()
      Qt.callLater(function () { Qt.exit(0) })
    }
  }

  // A stack run that never got its integration loaded must still end.
  Timer {
    interval: 20000
    running: true
    onTriggered: { rootObj.log("timeout", true); Qt.exit(1) }
  }
}
