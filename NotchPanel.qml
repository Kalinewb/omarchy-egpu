import QtQuick
import qs.Commons
import "views"
import "common/Palette.js" as Palette

// eGPU inside the notch: the panel the notch creates from
// NotchIntegration.qml's `panel` Component, once per screen (plan-gui.md
// §7.2, §7.6, §7.7; notch:SURFACE-HOSTING.md §4).
//
// Only chrome, like Panel.qml: a route stack with its Back, and the palette
// filled from surfaceHost. Every view is the shared component from views/,
// the same file the standalone popup shows, and every cost (the status file,
// the engine's processes) belongs to the integration, which exists once.
//
// Routes:  main     CompactView (§7.6)
//          overview, setup (and display, games once built)
//                   the standalone tabs, in the same Header; "full" is
//                   the Overview
//          details  the Details page, pushed over the Overview
//          eject    the eject sheet, pushed over anything
// A route appears in the phase that builds its view; until then asking for it
// is refused with a console line, never a blank page. The notch's own back
// strip is never over an integration (notch:INTEGRATION-SCOPE.md:79-81), so
// Back is ours: Escape asks the view to pop its own sub-sheet, then pops a
// route, and only at the root closes (eject → overview → main → closed).
//
// The notch draws an integration's panel from its top edge with no padding
// of its own (notch:Bar.qml integrationHost), so the inset is ours: the one
// padding token (common/Palette.js `space.inset`) on every side.
//
// Colours come only from surfaceHost (common/Palette.js fromHost). Sizes
// come from Style, which are not colours. Nothing reads Color.
Item {
  id: root

  // ----------------------------------------------- set by the notch (§4)
  property var surfaceHost: null
  property string surfaceScreen: ""
  property string route: "main"
  property real maxWidth: 400
  property real maxHeight: 400
  signal closeRequested()

  // ------------------------------------------- set by NotchIntegration.qml
  property var status: null
  property var engine: null
  property var health: null
  property string statusNote: ""
  property string noticeTitle: ""

  // What the notch's colour report reads off an integration panel
  // (notch:Bar.qml coloursReport). Never painted: the notch is the background.
  readonly property color background: root.surfaceHost ? root.surfaceHost.color : "transparent"
  readonly property color foreground: root.theme.foreground

  readonly property var theme: Palette.fromHost(root.surfaceHost, {
    unit: Style.spaceReal(1),
    font: { caption: Style.font.caption, body: Style.font.body, title: Style.font.title,
            display: Style.font.display, icon: Style.font.icon }
  })
  readonly property real u: root.theme.unit
  readonly property real inset: root.theme.space.inset

  // True between the notch's open() and close(). Every view keys its live
  // work on this, never on `visible` or the window (§7.7).
  property bool active: false

  // ------------------------------------------------------------- routes

  // Not readonly: dev/g8-offscreen.sh swaps in a stand-in `eject` holding a
  // dialog, to walk the whole Escape chain through a view's own popView().
  property var builtRoutes: ({ main: compactComponent, overview: overviewComponent, setup: setupComponent,
                               details: detailsComponent, eject: ejectComponent })
  readonly property var tabOrder: ["overview", "display", "games", "setup"]
  readonly property var tabLabels: ({ overview: "Overview", display: "Screens", games: "Games", setup: "Setup" })
  readonly property var tabs: root.tabOrder.filter(function (t) { return !!root.builtRoutes[t] })

  property var routeStack: ["main"]
  readonly property string current: root.routeStack[root.routeStack.length - 1]
  readonly property bool onTab: root.tabOrder.indexOf(root.current) !== -1
  property string setupFocus: ""

  // "full" is the Overview; "setup:<id>" is Setup on that row.
  function resolve(name) {
    var n = String(name || "main")
    if (n === "full") n = "overview"
    if (n.indexOf("setup:") === 0) { root.setupFocus = n.substring(6); n = "setup" }
    else if (n === "setup") root.setupFocus = ""
    return n
  }

  // Where an opening lands. Anything but main sits over main, so Escape from
  // a panel opened straight at a tab still steps back through the compact
  // view (§7.7: overview → main → closed).
  function resetTo(name) {
    var n = root.resolve(name)
    if (n === "main") { root.routeStack = ["main"]; return }
    if (!root.builtRoutes[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); root.routeStack = ["main"]; return }
    root.routeStack = ["main", n]
  }

  // A view asking for another (§5.0 requestRoute): pushed, so Back returns.
  function requestRoute(name) {
    if (String(name) === "back") { root.back(); return }
    var n = root.resolve(name)
    if (n === "main") { root.routeStack = ["main"]; return }
    if (!root.builtRoutes[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); return }
    if (root.current !== n) root.routeStack = root.routeStack.concat([n])
  }

  // A tab picked in the header replaces the tab on screen.
  function pickTab(name) {
    if (!root.builtRoutes[name]) return
    root.setupFocus = ""
    root.routeStack = root.onTab ? root.routeStack.slice(0, -1).concat([name]) : root.routeStack.concat([name])
  }

  // Escape and ‹ Back.
  function back() {
    var item = content.item
    if (item && typeof item.popView === "function" && item.popView()) return "view"
    if (root.routeStack.length > 1) { root.routeStack = root.routeStack.slice(0, -1); return "route" }
    root.closeRequested()
    return "close"
  }

  // ------------------------------------------------- the notch's lifecycle

  // Called on every open, at the route asked for (the bar widget asks for
  // "main", a notice's panelRoute too). Everything is re-derived from
  // `status`, so a panel reopened mid-eject shows `ejecting`.
  property bool holding: false
  function open(next) {
    root.active = true
    if (!root.holding && root.health) { root.health.hold(); root.holding = true }
    root.resetTo(next !== undefined ? next : root.route)
    root.forceActiveFocus()
  }

  // A real close (§7.7): the views go inactive and drop what they held; an
  // engine call in flight is left to finish in the integration's pool.
  function close() {
    root.active = false
    if (root.holding && root.health) { root.health.release(); root.holding = false }
  }
  Component.onDestruction: if (root.holding && root.health) root.health.release()

  // `route` is bound: a later openPanel at another route changes it here.
  onRouteChanged: if (root.active) root.resetTo(root.route)

  focus: true
  Keys.onEscapePressed: function (event) { root.back(); event.accepted = true }

  // ----------------------------------------------------------------- size

  readonly property real wantWidth: (root.current === "main" ? 320 : 400) * root.u + 2 * root.inset
  implicitWidth: Math.min(root.maxWidth > 0 ? root.maxWidth : root.wantWidth, root.wantWidth)
  implicitHeight: Math.min(column.implicitHeight + 2 * root.inset, root.maxHeight > 0 ? root.maxHeight : column.implicitHeight + 2 * root.inset)

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.margins: root.inset
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    Column {
      id: column
      width: flick.width
      spacing: root.theme.space.section

      // Below main only: the tabs (or a sub-page's title), and ‹ Back at the
      // top right as on the notch's own pages (‹ Settings, ‹ Setup).
      Header {
        id: header
        width: parent.width
        visible: root.routeStack.length > 1
        theme: root.theme
        tabs: root.tabs
        labels: root.tabLabels
        tab: root.onTab ? root.current : ""
        title: content.item && content.item.title !== undefined ? String(content.item.title) : ""
        dots: ({ setup: !!(root.status && root.status.health_summary && root.status.health_summary.errors > 0) })
        canBack: true
        onTabPicked: function (name) { root.pickTab(name) }
        onBack: root.back()
      }

      // One route at a time, so a view that is not on screen holds no timers.
      Loader {
        id: content
        width: parent.width
        sourceComponent: root.builtRoutes[root.current] || compactComponent
      }
    }
  }

  // ------------------------------------------------------------ the routes
  //
  // The standalone popup's views at full density, from the same files
  // (§7.6 "nothing is forked").

  Component {
    id: compactComponent
    CompactView {
      status: root.status
      engine: root.engine
      health: root.health
      theme: root.theme
      density: "compact"
      maxWidth: column.width
      maxHeight: root.maxHeight
      active: root.active
      statusNote: root.statusNote
      noticeTitle: root.noticeTitle
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.closeRequested()
    }
  }

  Component {
    id: overviewComponent
    StatusView {
      status: root.status
      engine: root.engine
      health: root.health
      theme: root.theme
      density: "full"
      maxWidth: column.width
      active: root.active
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.closeRequested()
    }
  }

  Component {
    id: setupComponent
    SetupView {
      status: root.status
      engine: root.engine
      health: root.health
      theme: root.theme
      density: "full"
      maxWidth: column.width
      active: root.active
      statusNote: root.statusNote
      focusId: root.setupFocus
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.closeRequested()
    }
  }

  Component {
    id: detailsComponent
    DetailsView {
      status: root.status
      engine: root.engine
      health: root.health
      theme: root.theme
      density: "full"
      maxWidth: column.width
      active: root.active
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.closeRequested()
    }
  }

  Component {
    id: ejectComponent
    EjectFlow {
      status: root.status
      engine: root.engine
      health: root.health
      theme: root.theme
      density: "full"
      maxWidth: column.width
      active: root.active
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.closeRequested()
    }
  }
}
