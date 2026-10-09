import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Ui
import "egpu" as Egpu
import "egpu/views" as EgpuViews
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
//   view        StatusView alone at a given density, text dumped, PNG
ShellRoot {
  id: rootObj

  readonly property string caseName: Quickshell.env("EGPU_HARNESS_CASE") || "indicator"
  readonly property int waitMs: Number(Quickshell.env("EGPU_HARNESS_WAIT_MS") || "2500")
  readonly property bool wantsPanel: caseName === "indicator" || caseName === "service" || caseName === "popup"

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

  Window {
    id: viewWindow
    visible: rootObj.caseName === "view"
    width: 380
    height: Math.max(80, viewColumn.implicitHeight + 32)
    color: "#101315"

    Rectangle { anchors.fill: parent; color: "#101315" }

    Column {
      id: viewColumn
      x: 16
      y: 16
      width: 348
      spacing: 12

      Text {
        text: statusView.title + "  ·  " + statusView.meta
        color: "#e0e0e0"
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 14
        font.bold: true
        width: parent.width
        wrapMode: Text.WordWrap
      }

      EgpuViews.StatusView {
        id: statusView
        status: {
          if (rootObj.caseName !== "view") return null
          try { return JSON.parse(fixtureFile.text()) } catch (e) { return null }
        }
        theme: EgpuPalette.make({
          foreground: "#e0e0e0", secondary: "#8a8f94", accent: "#7aa2f7", good: "#7aa2f7",
          warn: "#c99a6b", bad: "#a55555", background: "#101315", fontFamily: "JetBrainsMono Nerd Font",
          unit: 1, font: { caption: 10, body: 12, title: 14, display: 24, icon: 14 }
        })
        density: Quickshell.env("EGPU_HARNESS_DENSITY") || "full"
        maxWidth: 348
        active: true
        statusNote: Quickshell.env("EGPU_HARNESS_NOTE") || ""
      }
    }
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

  Component.onCompleted: if (rootObj.caseName === "popup") Qt.callLater(function () { realPanel.open() })

  Timer {
    interval: rootObj.waitMs
    running: true
    onTriggered: {
      var png = Quickshell.env("EGPU_HARNESS_PNG") || ""
      if (rootObj.caseName === "view") {
        rootObj.log("title", statusView.title)
        rootObj.log("meta", statusView.meta)
        rootObj.log("popView", statusView.popView())
        var t = rootObj.texts(statusView, [])
        for (var i = 0; i < t.length; i++) rootObj.log("text", t[i])
        rootObj.grab(viewWindow.contentItem, png, 1, function () { Qt.exit(0) })
        return
      }
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
