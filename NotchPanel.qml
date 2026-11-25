import QtQuick
import "ui"
import "views"

// eGPU inside the notch: the panel the notch creates from
// NotchIntegration.qml's `panel` Component, once per screen (plan-gui.md
// §7.2, §7.6, §7.7; notch:SURFACE-HOSTING.md §4).
//
// Only chrome, like Panel.qml: a route stack with its Back, and the kit's
// theme (ui/, vendored from omarchy-ui) filled from surfaceHost. Every view is
// the shared component from views/, the same file the standalone popup shows,
// and every cost (the status file, the engine's processes) belongs to the
// integration, which exists once.
//
// Routes:  main     CompactView (§7.6)
//          overview, setup (and display, games once built)
//                   the standalone tabs, in the same Header; "full" is
//                   the Overview
//          details  the Details page, pushed over the Overview
//          eject    the eject sheet, pushed over anything
// A route appears in the phase that builds its view; until then asking for it
// is refused with a console line, never a blank page. The notch's own back
// strip IS over every integration now (notch:SURFACE-HOSTING.md §4, §15) and
// is the one visible way back: a press asks goBackInside() below, which pops
// the view's own sub-sheet and then a route; only at the root does it answer
// no, and the notch goes back to where it was opened from or closes. Escape
// is its invisible alias, and goes through the kit's one Esc handler (UKeys):
// a tip, a confirm that is asking, the view's sub-level, a route, then close
// (eject → overview → main → closed). Under a host with no strip (no
// `panelBack` feature: an older notch) the header draws the kit's back
// chevron, as the standalone popup does.
//
// The notch draws an integration's panel from its top edge with no padding
// of its own (notch:Bar.qml integrationHost), so the inset is ours: the kit's
// `sp.lg` on every side, and at the top at least the back strip's zone
// (`surfaceHost.backZoneHeight`) on every page but the compact one, because a
// press anywhere in that zone goes back and nothing of ours may sit in it.
// The compact page (main) keeps its first row in the gutters beside the zone:
// a headline of a word or two on the left, the glyph and the close on the
// right. The pages that open with a header (the tabs, a title, the close)
// start that row below the zone, as the kit says for a header narrower than
// three zones.
//
// Colours come only from surfaceHost, through the kit's theme, as solids.
// Nothing reads Color.
FocusScope {
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
  readonly property color foreground: root.theme.label

  // The kit's theme, once, from the host (a harness may hand in its own).
  property var theme: UTheme { host: root.surfaceHost }
  readonly property real inset: root.theme.sp.lg
  // The host has the notch's back strip: the one visible way back, so no ‹ Back of ours.
  readonly property bool hostHasBack: !!root.surfaceHost && !!root.surfaceHost.features
                                      && root.surfaceHost.features.indexOf("panelBack") !== -1
  // The strip's zone, from the host (0 when it says nothing; its resting height when it has a strip but names no zone).
  readonly property real zoneHeight: !root.surfaceHost ? 0
    : root.surfaceHost.backZoneHeight > 0 ? root.surfaceHost.backZoneHeight
    : (root.hostHasBack && root.surfaceHost.restHeight > 0) ? root.surfaceHost.restHeight : 0
  // The zone's width, from the host (0 when it says nothing). The first row keeps beside it, in the
  // gutters (notch:SURFACE-HOSTING.md §15), when the panel is wide enough to leave each a usable one;
  // otherwise the whole content starts below the zone.
  readonly property real zoneWidth: root.surfaceHost && root.surfaceHost.backZoneWidth > 0 ? root.surfaceHost.backZoneWidth : 0
  readonly property bool besideZone: root.zoneWidth > 0 && (root.implicitWidth - root.zoneWidth) / 2 - root.inset >= root.theme.space(56)
  // Only the compact page has a first row that fits beside the zone; a header starts below it.
  // A tab page's header (the tabs on the left, the close on the right) also sits beside the zone, in the
  // same row as the strip, when the tabs fit in the left gutter; the panel widens a little for it (below).
  readonly property real tabsWidth: header.tabsImplicitWidth
  readonly property bool headerBeside: root.onTab && root.zoneWidth > 0 && root.tabsWidth > 0
                                       && (root.implicitWidth - 2 * root.inset - root.zoneWidth) / 2 - root.theme.sp.sm >= root.tabsWidth
  readonly property real topInset: ((root.current === "main" && root.besideZone) || root.headerBeside) ? root.inset : Math.max(root.inset, root.zoneHeight)

  // True between the notch's open() and close(). Every view keys its live
  // work on this, never on `visible` or the window (§7.7).
  property bool active: false

  // ------------------------------------------------------------- routes

  // Not readonly: dev/g8-offscreen.sh swaps in a stand-in `eject` holding a
  // dialog, to walk the whole Escape chain through a view's own popView().
  property var builtRoutes: ({ main: compactComponent, overview: overviewComponent, setup: setupComponent,
                               details: detailsComponent, eject: ejectComponent, games: gamesComponent })
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

  // The strip's press (notch:SURFACE-HOSTING.md §4): one step back inside the
  // panel, true when it moved. At the root it answers no and the notch decides.
  function goBackInside() {
    var item = pageLoader.item
    if (item && typeof item.popView === "function" && item.popView()) return true
    if (root.routeStack.length > 1) { root.routeStack = root.routeStack.slice(0, -1); return true }
    return false
  }

  function reveal(item) {
    // Only what is inside the scrolled content (not the header's close, not the foot line).
    var inside = false
    for (var a = item; a && !inside; a = a.parent) inside = a === flick.contentItem
    if (!inside) return
    var p = item.mapToItem(flick.contentItem, 0, 0)
    if (p.y < flick.contentY) flick.contentY = Math.max(0, p.y)
    else if (p.y + item.height > flick.contentY + flick.height) flick.contentY = p.y + item.height - flick.height
  }

  // Whether there is a step back inside the panel: a view's own sub-level, or a route to pop. UKeys
  // (the one Esc handler) reads it: with none, Esc closes.
  readonly property bool canStepBack: root.routeStack.length > 1 || (!!pageLoader.item && pageLoader.item.canPop === true)

  // Escape and the header's back.
  function back() {
    var item = pageLoader.item
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

  // ----------------------------------------------------------------- size

  // The compact page is as wide as the others under a back-strip zone: the headline has only the gutter
  // beside it, and 320 leaves each gutter about 70.
  // A tab page under a zone is as wide as its tabs need to sit beside the zone, up to 640.
  readonly property real wantWidth: Math.max(root.theme.space((root.current === "main" && root.zoneWidth <= 0) ? 320 : 400),
      root.onTab && root.zoneWidth > 0 ? Math.min(root.theme.space(640), 2 * (root.tabsWidth + root.theme.sp.sm) + root.zoneWidth) : 0) + 2 * root.inset
  // The foot line is reserved under the content: the kit's tips (placement foot) write to it.
  readonly property real footHeight: foot.implicitHeight
  implicitWidth: Math.min(root.maxWidth > 0 ? root.maxWidth : root.wantWidth, root.wantWidth)
  implicitHeight: Math.min(column.implicitHeight + root.topInset + root.footHeight + root.inset,
                           root.maxHeight > 0 ? root.maxHeight : column.implicitHeight + root.topInset + root.footHeight + root.inset)

  // The one place Esc is handled (the kit's UKeys): a tip first, a confirm that is asking, then one step
  // back inside the panel, and only with nowhere to go back to, close. Enter that nothing under the
  // keyboard took is the page's one primary button.
  UKeys {
    id: keys
    anchors.fill: parent
    focus: true
    level: "back"
    open: root.canStepBack
    onEscaped: root.goBackInside()
    onCloseRequested: root.closeRequested()
    onPrimary: if (pageLoader.item && typeof pageLoader.item.activatePrimary === "function") pageLoader.item.activatePrimary()

    Flickable {
      id: flick
      anchors.fill: parent
      anchors.leftMargin: root.inset
      anchors.rightMargin: root.inset
      anchors.bottomMargin: root.inset + root.footHeight
      anchors.topMargin: root.topInset
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      // The first row sits beside the back strip's zone, and the Flickable spans it: it must not take a press
      // there (notch:SURFACE-HOSTING.md §15; Qt 6.9 gave Flickable acceptedButtons). The wheel still scrolls.
      Component.onCompleted: if (flick.acceptedButtons !== undefined) flick.acceptedButtons = Qt.NoButton

      Column {
        id: column
        width: flick.width
        spacing: root.theme.sp.md

        // Below main only: the tabs (or a sub-page's title), the one close, and the kit's back chevron
        // only when the host has no back strip of its own.
        Header {
          id: header
          width: parent.width
          visible: root.routeStack.length > 1
          theme: root.theme
          tabs: root.tabs
          labels: root.tabLabels
          tab: root.onTab ? root.current : ""
          title: pageLoader.item && pageLoader.item.title !== undefined ? String(pageLoader.item.title) : ""
          dots: ({ setup: !!(root.status && root.status.health_summary && root.status.health_summary.errors > 0) })
          canBack: !root.hostHasBack
          onTabPicked: function (name) { root.pickTab(name) }
          onBack: root.back()
          onCloseRequested: root.closeRequested()
        }

        // One route at a time, so a view that is not on screen holds no timers.
        Loader {
          id: pageLoader
          width: parent.width
          sourceComponent: root.builtRoutes[root.current] || compactComponent
        }
      }
    }

    // A control Tab reached below the fold is scrolled into view.
    Connections {
      target: flick.Window.window
      function onActiveFocusItemChanged() { root.reveal(flick.Window.window ? flick.Window.window.activeFocusItem : null) }
    }

    // The foot line: where a tip (placement foot) says what a control does, one reserved line under the
    // content, no box. It sits in the strip below the content, inside the inset.
    UTip {
      id: foot
      theme: root.theme
      line: true
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: root.inset
      anchors.rightMargin: root.inset
      anchors.bottomMargin: root.inset / 2
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
      zoneWidth: root.besideZone ? root.zoneWidth : 0
      showClose: true
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
    id: gamesComponent
    GamesView {
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
