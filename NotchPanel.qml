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
//          full     the standalone tabs (Overview · Display · Games · Setup)
//          display, games, setup   full, at that tab
//          eject    the eject sheet (G3), pushed over anything
// A route appears in the phase that builds its view; until then asking for it
// is refused with a console line, never a blank page. The notch's own back
// strip is never over an integration (notch:INTEGRATION-SCOPE.md:79-81), so
// Back is ours: Escape asks the view to pop its own sub-sheet, then pops a
// route, and only at the root closes (eject → full → main → closed).
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

  // True between the notch's open() and close(). Every view keys its live
  // work on this, never on `visible` or the window (§7.7).
  property bool active: false

  // ------------------------------------------------------------- routes

  // Not readonly: dev/g8-offscreen.sh adds a stand-in `eject` to walk the
  // whole Escape chain before G3 builds the real sheet.
  property var builtRoutes: ({ main: compactComponent, full: fullComponent })
  readonly property var tabOrder: ["overview", "display", "games", "setup"]
  readonly property var tabLabels: ({ overview: "Overview", display: "Display", games: "Games", setup: "Setup" })
  readonly property var builtTabs: ({ overview: overviewComponent })
  readonly property var tabs: root.tabOrder.filter(function (t) { return !!root.builtTabs[t] })

  property var routeStack: ["main"]
  readonly property string current: root.routeStack[root.routeStack.length - 1]
  property string tab: "overview"

  // Where an opening lands. Anything but main sits over main, so Escape from
  // a panel opened straight at `full` still steps back through the compact
  // view (§7.7: full → main → closed).
  function resetTo(name) {
    var n = String(name || "main")
    if (n === "main") { root.routeStack = ["main"]; return }
    if (root.tabOrder.indexOf(n) !== -1) {
      if (!root.builtTabs[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); root.routeStack = ["main"]; return }
      root.tab = n
      root.routeStack = ["main", "full"]
      return
    }
    if (n === "full") { root.tab = root.tabs[0]; root.routeStack = ["main", "full"]; return }
    if (!root.builtRoutes[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); root.routeStack = ["main"]; return }
    root.routeStack = ["main", n]
  }

  // A view asking for another (§5.0 requestRoute).
  function requestRoute(name) {
    var n = String(name || "")
    if (n === "main") { root.routeStack = ["main"]; return }
    if (n === "full" || root.tabOrder.indexOf(n) !== -1) {
      if (n !== "full") {
        if (!root.builtTabs[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); return }
        root.tab = n
      }
      if (root.current !== "full") root.routeStack = root.routeStack.concat(["full"])
      return
    }
    if (!root.builtRoutes[n]) { console.warn("kalinewb.egpu", "notch route not built yet:", n); return }
    if (root.current !== n) root.routeStack = root.routeStack.concat([n])
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
  function open(next) {
    root.active = true
    root.resetTo(next !== undefined ? next : root.route)
    root.forceActiveFocus()
  }

  // A real close (§7.7): the views go inactive and drop what they held; an
  // engine call in flight is left to finish in the integration's pool.
  function close() {
    root.active = false
  }

  // `route` is bound: a later openPanel at another route changes it here.
  onRouteChanged: if (root.active) root.resetTo(root.route)

  focus: true
  Keys.onEscapePressed: function (event) { root.back(); event.accepted = true }

  // ----------------------------------------------------------------- size

  readonly property real wantWidth: (root.current === "main" ? 320 : 400) * root.u
  implicitWidth: Math.min(root.maxWidth > 0 ? root.maxWidth : root.wantWidth, root.wantWidth)
  implicitHeight: Math.min(column.implicitHeight, root.maxHeight > 0 ? root.maxHeight : column.implicitHeight)

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    Column {
      id: column
      width: flick.width
      spacing: 10 * root.u

      // The header, below main only: the view's title, and ‹ Back at the top
      // right as on the notch's own pages (‹ Settings, ‹ Setup).
      Item {
        id: header
        width: parent.width
        visible: root.routeStack.length > 1
        implicitHeight: Math.max(titleText.implicitHeight, backText.implicitHeight)

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - backText.width - 12 * root.u
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: content.item && content.item.title !== undefined ? String(content.item.title) : "eGPU"
          color: root.theme.foreground
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.font.title
          font.bold: true
        }
        Text {
          id: backText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "‹ Back"
          color: backArea.containsMouse ? root.theme.foreground : root.theme.secondary
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.font.body
          MouseArea {
            id: backArea
            anchors.fill: parent
            anchors.margins: -4 * root.u
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.back()
          }
        }
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

  Component {
    id: compactComponent
    CompactView {
      status: root.status
      engine: root.engine
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

  // The standalone popup's tabs at full density, from the same view files
  // (§7.6 "nothing is forked"). The tab row shows once a second tab exists.
  Component {
    id: fullComponent
    Column {
      id: full
      spacing: 10 * root.u
      readonly property string title: tabLoader.item && tabLoader.item.title !== undefined ? tabLoader.item.title : "eGPU"
      function popView() {
        var item = tabLoader.item
        return !!(item && typeof item.popView === "function" && item.popView())
      }

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: tabLoader.item && tabLoader.item.meta !== undefined ? String(tabLoader.item.meta) : ""
        color: root.theme.secondary
        font.family: root.theme.fontFamily
        font.pixelSize: root.theme.font.body
      }

      Row {
        visible: root.tabs.length > 1
        spacing: 14 * root.u
        Repeater {
          model: root.tabs
          delegate: Text {
            required property var modelData
            textFormat: Text.PlainText
            text: root.tabLabels[modelData]
            color: root.tab === modelData ? root.theme.foreground : root.theme.secondary
            font.family: root.theme.fontFamily
            font.pixelSize: root.theme.font.body
            font.underline: root.tab === modelData
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = parent.modelData }
          }
        }
      }

      Loader {
        id: tabLoader
        width: column.width
        sourceComponent: root.builtTabs[root.tab] || overviewComponent
      }
    }
  }

  Component {
    id: overviewComponent
    StatusView {
      status: root.status
      engine: root.engine
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
