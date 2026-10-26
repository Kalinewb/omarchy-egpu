import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Ui
import "egpu" as Egpu
import "egpu/views" as EgpuViews
import "egpu/common" as EgpuCommon
import "egpu/common/Palette.js" as EgpuPalette

// Gate G1 offscreen (plan-gui.md §10): the REAL Panel.qml, Service.qml and
// views/StatusView.qml in a throwaway Quickshell with no compositor, against
// the running Omarchy's qs.Commons and qs.Ui. Run by dev/g1-offscreen.sh, which
// builds the config root, writes the status files and checks what this prints
// (`HARNESS <key> <value>` lines) before it exits.
//
// Nothing here touches the live shell: a separate Quickshell instance on a
// temp config path, QT_QPA_PLATFORM=offscreen, no WAYLAND_DISPLAY. The one kit
// type that needs a compositor, KeyboardPanel, is replaced in that root by
// dev/qml-harness/KeyboardPanel.qml (a plain Window with the same API).
//
// Cases (EGPU_HARNESS_CASE):
//   indicator   Panel on a bar with no shell facade → the file source
//   service     Service + Panel whose bar hands the Service over → the stream
//   popup       indicator, then the popup opened and grabbed to a PNG
//   routes      the popup's route stack: tabs, pushes, Back, Escape, first run
//   view        one view (EGPU_HARNESS_VIEW: overview, details, setup, eject,
//               compact) from a fixture's status and health, text and buttons
//               dumped, optionally one button clicked (EGPU_HARNESS_CLICK) and
//               dumped again, PNG
//   primaries   the Overview and the compact view for every document in
//               $EGPU_HARNESS_DOCS ({name: {status, health}}): the one
//               primary button each shows, and any text naming Setup with no
//               way to it
//   setups      SetupView for every document there: its rows and buttons
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("EGPU_HARNESS_CASE") || "indicator"
  readonly property int waitMs: Number(Quickshell.env("EGPU_HARNESS_WAIT_MS") || "2500")
  readonly property bool wantsPanel: caseName === "indicator" || caseName === "service" || caseName === "popup" || caseName === "routes"

  function log(key, value) { console.log("HARNESS " + key, value) }

  // ------------------------------------------------------------- the bar

  // A stand-in for the shell facade the built-in bar gives a registered
  // third-party widget (omarchy:shell/services/PluginShellApi.qml): the
  // own-service lookup, scoped to the plugin's own id.
  QtObject {
    id: fakeShell
    property var svc: null
    function serviceFor(id) { return String(id) === "kalinewb.egpu" ? fakeShell.svc : null }
  }

  // The real facade class the bar hands third-party widgets.
  PluginBarApi {
    id: barApi
    pluginId: "kalinewb.egpu"
    moduleName: "kalinewb.egpu"
    shell: rootObj.caseName === "service" ? fakeShell : null
    foreground: "#e0e0e0"
    barForeground: "#d0d0d0"
    background: "#101315"
    urgent: "#a55555"
    fontFamily: "JetBrainsMono Nerd Font"
    barSize: 26
  }

  Loader {
    id: serviceLoader
    active: rootObj.caseName === "service"
    sourceComponent: Component { Egpu.Service {} }
    onLoaded: fakeShell.svc = item
  }

  // The widget sits in a small window of its own so it renders and can be
  // grabbed: what the bar would show, at 4x.
  Window {
    id: barWindow
    visible: rootObj.wantsPanel
    width: 40
    height: 26
    color: "#101315"

    Rectangle { anchors.fill: parent; color: "#101315" }

    Egpu.Panel {
      id: realPanel
      visible: rootObj.wantsPanel
      enabled: rootObj.wantsPanel
      anchors.fill: parent
      bar: rootObj.wantsPanel ? barApi : null
    }
  }

  // Every distinct state the widget showed, in order, and every event the
  // Service raised, so the script can compare whole sequences.
  property var seenStates: []
  property var seenEvents: []

  Connections {
    target: serviceLoader.item
    ignoreUnknownSignals: true
    function onEvent(record) {
      rootObj.seenEvents = rootObj.seenEvents.concat([record.event + "#" + record.seq])
    }
  }

  Timer {
    interval: 100
    repeat: true
    running: rootObj.wantsPanel
    onTriggered: {
      var s = realPanel.look.state
      if (rootObj.seenStates.length === 0 || rootObj.seenStates[rootObj.seenStates.length - 1] !== s)
        rootObj.seenStates = rootObj.seenStates.concat([s])
    }
  }

  function report() {
    var look = realPanel.look
    var ind = realPanel.indicator
    rootObj.log("state", look.state)
    rootObj.log("role", look.role)
    rootObj.log("badge", look.badge === "" ? "none" : look.badge)
    rootObj.log("pulse", look.pulse)
    rootObj.log("monitor", look.monitor)
    rootObj.log("word", look.word === "" ? "none" : look.word)
    rootObj.log("tooltip", look.tooltip)
    rootObj.log("source", realPanel.ownService ? "service" : "file")
    rootObj.log("outcome", realPanel.statusNote === "" ? "live" : realPanel.statusNote)
    rootObj.log("buttonText", ind.text === EgpuPalette.glyph ? "glyph" : ind.text)
    rootObj.log("buttonTooltip", ind.tooltipText)
    rootObj.log("buttonVisible", ind.visible)
    rootObj.log("buttonOpacity", Math.round(ind.opacity * 100) / 100)
    // The glyph is painted in the role's colour (at full strength unless it is
    // pulsing), and the badge dot in the badge's.
    var want = realPanel.roleColor(realPanel.barPalette, look.role)
    rootObj.log("glyphColour", look.pulse ? "pulsing" : (Qt.colorEqual(ind.foreground, want) ? "role" : "wrong:" + ind.foreground))
  }

  // ------------------------------------------------------------- the view

  FileView {
    id: fixtureFile
    path: rootObj.caseName === "view" ? (Quickshell.env("EGPU_HARNESS_STATUS") || "") : ""
    blockLoading: true
    printErrors: false
  }

  readonly property var harnessTheme: EgpuPalette.make({
    foreground: "#e0e0e0", secondary: "#8a8f94", accent: "#7aa2f7", good: "#7aa2f7",
    warn: "#c99a6b", bad: "#a55555", background: "#101315", fontFamily: "JetBrainsMono Nerd Font",
    unit: 1, font: { caption: 10, body: 12, title: 14, display: 24, icon: 14 }
  })

  // The views' engine: the dev stub (OMARCHY_EGPU_DEV_BIN), which answers
  // health and the device verbs from OMARCHY_EGPU_DEV_FIXTURE and records
  // every other call; Setup's terminal and copy go to dev/bin/egpu-launch-stub.
  EgpuCommon.Engine { id: viewEngine; pluginDir: "" }
  EgpuCommon.HealthSource { id: viewHealth; engine: viewEngine; status: rootObj.viewStatus }

  readonly property var viewStatus: {
    if (rootObj.caseName !== "view") return null
    try { return JSON.parse(fixtureFile.text()) } catch (e) { return null }
  }
  readonly property string viewName: Quickshell.env("EGPU_HARNESS_VIEW") || "overview"
  property var routesAsked: []
  property int closesAsked: 0

  Window {
    id: viewWindow
    visible: rootObj.caseName === "view"
    // The popup's content width at its default size, plus the inset.
    width: 328 + 32
    height: Math.max(80, (viewLoader.item ? viewLoader.item.implicitHeight : 0) + 32)
    color: "#101315"

    Rectangle { anchors.fill: parent; color: "#101315" }

    Loader {
      id: viewLoader
      x: 16
      y: 16
      width: 328
      active: rootObj.caseName === "view"
      sourceComponent: rootObj.viewName === "details" ? detailsComp : rootObj.viewName === "setup" ? setupComp
                     : rootObj.viewName === "eject" ? ejectComp : rootObj.viewName === "compact" ? compactViewComp : overviewComp
      onLoaded: {
        item.requestRoute.connect(function (n) { rootObj.routesAsked = rootObj.routesAsked.concat([String(n)]) })
        item.requestClose.connect(function () { rootObj.closesAsked += 1 })
        viewHealth.hold()
      }
    }
  }

  Component { id: overviewComp; EgpuViews.StatusView { status: rootObj.viewStatus; engine: viewEngine; health: viewHealth; theme: rootObj.harnessTheme; maxWidth: 328; active: true; density: Quickshell.env("EGPU_HARNESS_DENSITY") || "full"; statusNote: Quickshell.env("EGPU_HARNESS_NOTE") || "" } }
  Component { id: detailsComp; EgpuViews.DetailsView { status: rootObj.viewStatus; engine: viewEngine; health: viewHealth; theme: rootObj.harnessTheme; maxWidth: 328; active: true; statusNote: Quickshell.env("EGPU_HARNESS_NOTE") || "" } }
  Component { id: setupComp; EgpuViews.SetupView { status: rootObj.viewStatus; engine: viewEngine; health: viewHealth; theme: rootObj.harnessTheme; maxWidth: 328; active: true; focusId: Quickshell.env("EGPU_HARNESS_FOCUS") || "" } }
  Component { id: ejectComp; EgpuViews.EjectFlow { status: rootObj.viewStatus; engine: viewEngine; health: viewHealth; theme: rootObj.harnessTheme; maxWidth: 328; active: true } }
  Component { id: compactViewComp; EgpuViews.CompactView { status: rootObj.viewStatus; engine: viewEngine; health: viewHealth; theme: rootObj.harnessTheme; maxWidth: 320; active: true } }

  // Visible buttons and links (views/ui Action and Link), by label; disabled
  // ones marked, the primary one starred.
  function buttons(item, out) {
    if (!item || !item.visible) return out
    if (item.clicked !== undefined && typeof item.label === "string" && item.label !== "")
      out.push((item.primary === true ? "*" : "") + item.label + (item.enabled ? "" : "(off)"))
    for (var i = 0; i < item.children.length; i++) rootObj.buttons(item.children[i], out)
    return out
  }
  function findButton(item, label) {
    if (!item || !item.visible) return null
    if (item.clicked !== undefined && item.label === label && item.enabled) return item
    for (var i = 0; i < item.children.length; i++) {
      var f = rootObj.findButton(item.children[i], label)
      if (f) return f
    }
    return null
  }
  // The primary button: label|enabled, or "none".
  function primaryOf(item) {
    if (!item || !item.visible) return null
    if (item.primary === true && typeof item.label === "string" && item.clicked !== undefined) return item.label + "|" + (item.enabled ? "on" : "off")
    for (var i = 0; i < item.children.length; i++) {
      var f = rootObj.primaryOf(item.children[i])
      if (f) return f
    }
    return null
  }
  // Every visible text that names Setup without a way to it (ui-scope.md
  // §0.1): a link or a sentence link whose route is Setup, or the primary
  // button when its action opens Setup.
  function setupOrphans(view, item, out) {
    if (!item || !item.visible) return out
    if (item.font !== undefined && typeof item.text === "string" && /\bSetup\b/.test(item.text)) {
      var ok = false
      for (var p = item; p && p !== view.parent; p = p.parent) {
        if (typeof p.route === "string" && p.route.indexOf("setup") === 0) { ok = true; break }
        if (typeof p.linkRoute === "string" && p.linkRoute.indexOf("setup") === 0 && p.linkLabel !== "") { ok = true; break }
        if (p.primary === true && view.d && view.d.button && (view.d.button.action === "setup" || view.d.button.action === "fix")) { ok = true; break }
      }
      if (!ok) out.push(item.text)
    }
    for (var i = 0; i < item.children.length; i++) rootObj.setupOrphans(view, item.children[i], out)
    return out
  }
  function dumpView(prefix) {
    var v = viewLoader.item
    var t = rootObj.texts(v, [])
    rootObj.log(prefix + "texts", t.map(function (x) { return x === EgpuPalette.glyph ? "glyph" : x }).join(" ¦ "))
    rootObj.log(prefix + "buttons", rootObj.buttons(v, []).join(",") || "none")
    rootObj.log(prefix + "primary", rootObj.primaryOf(v) || "none")
    rootObj.log(prefix + "orphans", rootObj.setupOrphans(v, v, []).join(" | ") || "none")
    rootObj.log(prefix + "routes", rootObj.routesAsked.join(",") || "none")
    rootObj.log(prefix + "closes", rootObj.closesAsked)
    rootObj.log(prefix + "title", v.title === undefined ? "none" : (v.title === "" ? "empty" : v.title))
    rootObj.log(prefix + "popView", v.popView())
  }

  // ------------------------------------------------- primaries and setups

  FileView {
    id: docsFile
    path: rootObj.caseName === "primaries" || rootObj.caseName === "setups" ? (Quickshell.env("EGPU_HARNESS_DOCS") || "") : ""
    blockLoading: true
    printErrors: false
  }
  readonly property var docs: {
    if (rootObj.caseName !== "primaries" && rootObj.caseName !== "setups") return ({})
    try { return JSON.parse(docsFile.text()) } catch (e) { return ({}) }
  }
  Window {
    id: docsWindow
    visible: rootObj.caseName === "primaries" || rootObj.caseName === "setups"
    width: 380
    height: 600
    color: "#101315"
    Column { id: docsColumn; x: 16; y: 16; width: 328 }
  }
  Component { id: primOverview; EgpuViews.StatusView { engine: viewEngine; theme: rootObj.harnessTheme; maxWidth: 328; active: true } }
  Component { id: primCompact; EgpuViews.CompactView { engine: viewEngine; theme: rootObj.harnessTheme; maxWidth: 320; active: true } }
  Component { id: primSetup; EgpuViews.SetupView { engine: viewEngine; theme: rootObj.harnessTheme; maxWidth: 328; active: true } }

  function runDocs() {
    var names = Object.keys(rootObj.docs)
    for (var i = 0; i < names.length; i++) {
      var doc = rootObj.docs[names[i]]
      var health = { rows: doc.health, loading: false, error: "", refresh: function () {} }
      if (rootObj.caseName === "primaries") {
        var o = primOverview.createObject(docsColumn)
        var c = primCompact.createObject(docsColumn)
        o.health = health; c.health = health
        o.status = doc.status; c.status = doc.status
        // Without health rows: what shows before the first read returns.
        var o0 = primOverview.createObject(docsColumn)
        o0.status = doc.status
        rootObj.log("p." + names[i] + ".full", rootObj.primaryOf(o) || "none")
        rootObj.log("p." + names[i] + ".compact", rootObj.primaryOf(c) || "none")
        rootObj.log("p." + names[i] + ".norows", rootObj.primaryOf(o0) || "none")
        rootObj.log("p." + names[i] + ".headline", o.d.headline + " / " + c.d.headline)
        rootObj.log("p." + names[i] + ".orphans", (rootObj.setupOrphans(o, o, []).concat(rootObj.setupOrphans(c, c, []))).join(" | ") || "none")
        rootObj.log("p." + names[i] + ".texts", rootObj.texts(o, []).join(" ¦ "))
        rootObj.log("p." + names[i] + ".ctexts", rootObj.texts(c, []).join(" ¦ "))
        o.destroy(); c.destroy(); o0.destroy()
      } else {
        var sv = primSetup.createObject(docsColumn)
        sv.health = health
        sv.status = doc.status
        rootObj.log("s." + names[i] + ".texts", rootObj.texts(sv, []).join(" ¦ "))
        rootObj.log("s." + names[i] + ".buttons", rootObj.buttons(sv, []).join(",") || "none")
        rootObj.log("s." + names[i] + ".rows", sv.sum.problems.length + sv.sum.others.length + sv.sum.advanced.length)
        rootObj.log("s." + names[i] + ".first", sv.problemRows.length > 0 ? sv.problemRows[0].id : "none")
        sv.destroy()
      }
    }
    Qt.exit(0)
  }

  // Every visible Text under an item, top to bottom: what a person would read.
  function texts(item, out) {
    if (!item || !item.visible) return out
    if (item.text !== undefined && typeof item.text === "string" && item.text !== "" && item.font !== undefined)
      out.push(item.text.replace(/\n/g, " "))
    for (var i = 0; i < item.children.length; i++) rootObj.texts(item.children[i], out)
    return out
  }

  // The popup's window: the KeyboardPanel stand-in, found among the Panel's
  // non-visual children by its API.
  function popupWindow() {
    for (var i = 0; i < realPanel.data.length; i++) {
      var d = realPanel.data[i]
      if (d && d.focusTarget !== undefined && d.contentWidth !== undefined) return d
    }
    return null
  }

  function grab(item, path, scale, then) {
    if (path === "") { then(); return }
    var size = scale > 1 ? Qt.size(item.width * scale, item.height * scale) : Qt.size(item.width, item.height)
    item.grabToImage(function (result) {
      rootObj.log("png", result.saveToFile(path))
      then()
    }, size)
  }

  // ------------------------------------------------------------- finish

  Component.onCompleted: {
    if (rootObj.caseName === "popup" || rootObj.caseName === "routes") Qt.callLater(function () { realPanel.open() })
    if (rootObj.caseName === "primaries" || rootObj.caseName === "setups") Qt.callLater(rootObj.runDocs)
  }

  Timer {
    id: afterClick
    property string png: ""
    interval: Number(Quickshell.env("EGPU_HARNESS_CLICK_WAIT_MS") || "1500")
    onTriggered: {
      rootObj.dumpView("after.")
      rootObj.grab(viewWindow.contentItem, png, 1, function () { Qt.exit(0) })
    }
  }

  // The popup's route stack, driven through the same functions the header,
  // the views and Escape call.
  function runRoutes() {
    var p = realPanel
    function st() { return p.routeStack.join(">") }
    var out = []
    out.push("open:" + st() + ":" + (p.opened ? "open" : "closed"))
    p.requestRoute("setup:system.helper"); out.push("fix:" + st() + ":" + p.setupFocus)
    p.back(); out.push("back:" + st())
    p.requestRoute("details"); out.push("details:" + st())
    p.requestRoute("eject"); out.push("eject:" + st())
    p.back(); p.back(); out.push("back2:" + st())
    p.pickTab("setup"); out.push("tab:" + st())
    p.pickTab("overview"); out.push("tab2:" + st())
    p.requestRoute("display"); out.push("unbuilt:" + st())
    p.requestRoute("setup"); p.requestRoute("back"); out.push("viewBack:" + st())
    p.back(); out.push("root:" + (p.opened ? "open" : "closed"))
    rootObj.log("routes", out.join(" "))
    var w = rootObj.popupWindow()
    rootObj.log("padding", w ? w.padding : "no window")
    // The tokens scale with the shell's spacing unit (the theme's [spacing]),
    // so the check needs the unit this run had.
    rootObj.log("unit", realPanel.popupPalette.unit)
    Qt.exit(0)
  }

  Timer {
    interval: rootObj.waitMs
    running: rootObj.caseName !== "primaries" && rootObj.caseName !== "setups"
    onTriggered: {
      var png = Quickshell.env("EGPU_HARNESS_PNG") || ""
      if (rootObj.caseName === "view") {
        rootObj.dumpView("")
        var click = Quickshell.env("EGPU_HARNESS_CLICK") || ""
        if (click === "") { rootObj.grab(viewWindow.contentItem, png, 1, function () { Qt.exit(0) }); return }
        var b = rootObj.findButton(viewLoader.item, click)
        rootObj.log("clicked", b ? "yes" : "no such button")
        if (b) b.clicked()
        afterClick.png = png
        afterClick.start()
        return
      }
      if (rootObj.caseName === "routes") { rootObj.runRoutes(); return }
      if (rootObj.caseName === "popup") {
        var w = rootObj.popupWindow()
        rootObj.log("opened", realPanel.opened)
        rootObj.log("popupVisible", w ? w.visible : "no window")
        if (!w) { Qt.exit(1); return }
        var pt = rootObj.texts(w.contentItem, [])
        for (var j = 0; j < pt.length; j++) rootObj.log("text", pt[j] === EgpuPalette.glyph ? "glyph" : pt[j])
        rootObj.log("backVisible", realPanel.routeStack.length > 1)
        rootObj.grab(w.contentItem, png, 1, function () {
          // Escape at the root route closes the popup (§7.7).
          realPanel.back()
          rootObj.log("afterBack", realPanel.opened ? "open" : "closed")
          Qt.exit(0)
        })
        return
      }
      rootObj.report()
      rootObj.log("states", rootObj.seenStates.join(" "))
      rootObj.log("events", rootObj.seenEvents.length ? rootObj.seenEvents.join(" ") : "none")
      if (serviceLoader.item) {
        rootObj.log("watchState", serviceLoader.item.watchState)
        rootObj.log("serviceStatus", serviceLoader.item.status ? serviceLoader.item.status.summary.state : "null")
      }
      // A route that is not built is refused, never shown as a blank page.
      realPanel.requestRoute("display")
      rootObj.log("unbuiltRoute", realPanel.routeStack.join(">"))
      rootObj.log("tabs", realPanel.tabs.join(","))
      rootObj.grab(barWindow.contentItem, Quickshell.env("EGPU_HARNESS_BAR_PNG") || "", 4, function () {
        // The service case ends by destroying the Service, which must take its
        // watcher with it (the script then checks the lock is free).
        if (serviceLoader.item) serviceLoader.active = false
        Qt.callLater(function () { Qt.exit(0) })
      })
    }
  }
}
