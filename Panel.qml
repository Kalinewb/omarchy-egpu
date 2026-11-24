import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"
import "views"
import "ui"
import "common/Palette.js" as Palette
import "common/SetupRows.js" as SetupRows

// eGPU: the bar indicator and the standalone popup (plan-gui.md §2, §4, §5).
//
// This file is only the standalone shell. Every decision lives in
// bin/omarchy-egpu (the "summary" it computes is even the indicator's state and
// tooltip), and every view is a shared component in views/ that the notch will
// instantiate as well (REVISION 4). What this file owns is the chrome: the
// button, the popup, the route stack with its Back, and the palette it fills
// from Omarchy's theme for the views.
//
// Nothing here writes under ~/.config/omarchy/plugins: any write there reloads
// every plugin (omarchy:shell/services/PluginRegistry.qml:663-679). All state is
// the engine's, in $XDG_RUNTIME_DIR/omarchy-egpu and ~/.local/state.
Panel {
  id: root
  moduleName: "kalinewb.egpu"
  ipcTarget: "kalinewb.egpu"

  // The manifest id, not moduleName: the own-service lookup is scoped to it
  // (omarchy:shell/shell.qml pluginOwnsTarget).
  readonly property string pluginId: "kalinewb.egpu"

  // Where the plugin is checked out, from where this file was loaded rather
  // than from $HOME (plan-gui.md §3; same decoding as omarchy-face).
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url).replace(/\/+$/, "")
  }

  // -------------------------------------------------------------- colours
  //
  // The popup's views read the kit's theme (ui/UTheme.qml, vendored from
  // omarchy-ui): standalone, so Omarchy's own palette and spacing, with no
  // host. A second one, over `surfaceHost`, is for the views the notch would
  // draw from the descriptor below (the notch's colours and radius, as solids).
  //
  // The bar button is not a panel: it sits on the bar and takes the bar's own
  // foreground, with the theme's accent and urgent. The theme has no green or
  // amber: `good` is the accent (the ejected state also changes the word and
  // the tooltip, so colour is never the only signal), `bad` is the theme's
  // urgent, and `warn` is urgent softened toward the foreground so the two
  // dots differ.
  //
  // Color is always `Commons.Color`: since Omarchy 4.0.5 a bare `Color` in a
  // plugin no longer resolves to the theme (its own Ui files qualify it too).
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  UTheme { id: popupTheme }
  UTheme { id: surfaceTheme; host: root.surfaceHost }
  // For dev/qml-harness, which checks the popup's padding against the theme's token.
  readonly property alias uiTheme: popupTheme

  // A look's colour role (common/Palette.js look()) on the bar.
  function barTone(role) {
    var fg = root.barForeground
    if (role === "secondary") return Qt.darker(fg, 1.55)
    if (role === "accent" || role === "good") return Commons.Color.accent
    if (role === "warn") return Qt.tint(Commons.Color.urgent, Qt.rgba(fg.r, fg.g, fg.b, 0.35))
    if (role === "bad") return Commons.Color.urgent
    return fg
  }

  // -------------------------------------------------------------- status

  // The plugin's own Service when the bar can hand it over; otherwise the file
  // source, exactly as the notch reads it (§3).
  property var ownService: null

  function findService() {
    var sh = root.bar && root.bar.shell ? root.bar.shell : null
    var svc = sh && typeof sh.serviceFor === "function" ? sh.serviceFor(root.pluginId) : null
    if (svc !== root.ownService) root.ownService = svc
  }

  // The service can mount after this widget, and is rebuilt on every plugin
  // reload. A lookup costs one function call, so it is simply asked again
  // until there is an answer.
  Timer {
    interval: 3000
    repeat: true
    running: root.ownService === null
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  Engine {
    id: engineRunner
    pluginDir: root.pluginDir
  }

  StatusSource {
    id: source
    service: root.ownService
    engine: engineRunner
  }

  readonly property var status: source.status
  readonly property string statusNote: source.outcomeText
  readonly property var look: Palette.look(source.status, source.outcomeText)
  // For dev/qml-harness, which checks the rendered button, not just the look.
  readonly property alias indicator: button

  // ---------------------------------------------------------------- notch
  //
  // Everything below is inert under omarchy.bar or any other bar: nothing
  // sets surfaceHost or surfaceScreen and nothing reads `notch`, so there is
  // no code path to guard (notch:SURFACE-HOSTING.md:190-192). Under the notch
  // (plan-gui.md §7.2-§7.3) it is declared, never detected.

  // The notch's host for this plugin, and the screen this copy of the widget
  // is on, so a click opens the notch panel on the clicked screen.
  property var surfaceHost: null
  property string surfaceScreen: ""

  // The live transient notice (§7.5), for the descriptor's priority. The
  // integration claims it; this copy only needs to know it is live.
  Notices {
    id: notices
    status: root.status
    canConnect: engineRunner.can("device connect")
  }
  Connections {
    target: source
    function onEvent(record) { notices.take(record) }
  }
  readonly property bool noticeLive: notices.live

  // The per-widget descriptor of notch:contract.js:24-28, read by the notch's
  // registry only if `"notch" in item`. Every value is within contract.js's
  // checks, and an invalid one falls back to its default rather than failing.
  //
  // closedView stays "widget" (this BarIndicator) while the notch does not
  // draw a widget's declared Components: re-checked for G8 against the
  // notch's head, its registry collects them but nothing instantiates them
  // (docs/notch-requests.md). The day it does, closedView becomes
  // glanceComponent, one line. expandedView is declared already; it is the
  // compact view, which the integration's panel shows today.
  readonly property var notch: ({
    closedView: "widget",
    expandedView: compactComponent,
    priority: root.noticeLive ? "transient"
            : (["in_use", "ejecting", "attention"].indexOf(root.look.state) !== -1 ? "persistent" : "persistent-low"),
    groupable: !root.noticeLive,
    hideable: true
  })

  Component {
    id: glanceComponent
    Glance {
      status: root.status
      engine: engineRunner
      theme: surfaceTheme
      active: true
      statusNote: root.statusNote
      noticeTitle: root.noticeLive ? notices.notice.title : ""
    }
  }

  Component {
    id: compactComponent
    CompactView {
      status: root.status
      engine: engineRunner
      theme: surfaceTheme
      density: "compact"
      active: true
      statusNote: root.statusNote
      noticeTitle: root.noticeLive ? notices.notice.title : ""
    }
  }

  // A left click (§7.2, notch:SURFACE-HOSTING.md:200-206, 316-319). The
  // notch's panel when it takes this click, else our own popup. Per event:
  // only "opened" means the notch is showing it, and "closed" means the click
  // shut the notch panel that was already open, which is the toggle the user
  // asked for, not a cue to open a second UI. Every other answer
  // (declined:hidden, declined:not-accepted, no notch at all) opens our own.
  // Returns what happened, for dev/g8-offscreen.sh.
  function press() {
    if (root.opened) { root.close(); return "own-closed" }
    var answer = root.surfaceHost && typeof root.surfaceHost.openPanel === "function"
               ? String(root.surfaceHost.openPanel("main", root.surfaceScreen)) : "no-host"
    if (answer === "opened" || answer === "closed") return answer
    root.open()
    return "own:" + answer
  }

  // --------------------------------------------------------------- routes
  //
  // The popup's tabs are the top-level routes (ui-scope.md §2: Overview ·
  // Games · Screens · Setup; only the built ones show). A tab picked in the
  // header replaces the stack; a route a view asks for is pushed over the
  // current one (Details, the eject sheet, Setup from a Fix), so Back and
  // Escape always return one level (ui-scope.md §2). A route appears here in
  // the phase that builds its view — until then requesting it is a no-op
  // with a console line, never a blank page.
  readonly property var builtRoutes: ({ overview: overviewComponent, setup: setupComponent,
                                        details: detailsComponent, eject: ejectComponent,
                                        games: gamesComponent })
  readonly property var tabOrder: ["overview", "display", "games", "setup"]
  readonly property var tabLabels: ({ overview: "Overview", display: "Screens", games: "Games", setup: "Setup" })
  readonly property var tabs: tabOrder.filter(function (t) { return !!root.builtRoutes[t] })

  property var routeStack: ["overview"]
  readonly property string route: routeStack[routeStack.length - 1]
  readonly property bool onTab: root.tabOrder.indexOf(root.route) !== -1
  // The Setup row a Fix asked for ("setup:<id>").
  property string setupFocus: ""
  // Whether the person has moved since the popup opened (first-run landing
  // only happens while they have not).
  property bool navigated: false

  function resetRoute(name) { root.routeStack = [name] }

  function pickTab(name) {
    if (!root.builtRoutes[name]) return
    root.navigated = true
    root.setupFocus = ""
    root.resetRoute(name)
  }

  function requestRoute(name) {
    var n = String(name || "")
    if (n === "back") { root.back(); return }
    if (n === "full") return    // the popup IS the full panel
    var focus = ""
    if (n.indexOf("setup:") === 0) { focus = n.substring(6); n = "setup" }
    if (!root.builtRoutes[n]) {
      console.warn("kalinewb.egpu", "route not built yet:", n)
      return
    }
    root.navigated = true
    if (n === "setup") root.setupFocus = focus
    if (n !== root.route) root.routeStack = root.routeStack.concat([n])
  }

  // Whether there is a step back inside the popup: a view's own sub-level, or a route to pop. UKeys
  // reads it: with none, Esc closes.
  readonly property bool canStepBack: root.routeStack.length > 1 || (!!viewLoader.item && viewLoader.item.canPop === true)

  // Escape and the Back button (§7.7): the view's own sub-sheet first, then
  // one route, and only at the root does it close.
  function back() {
    var item = viewLoader.item
    if (item && typeof item.popView === "function" && item.popView()) return
    if (root.routeStack.length > 1) root.routeStack = root.routeStack.slice(0, -1)
    else root.close()
  }

  // First run (ux.md rule 4): the system helper was never installed and
  // there is no eGPU to show, so the popup opens on Setup. Decided from the
  // last rows read, and once more when this opening's read arrives, but only
  // while the person has not moved.
  readonly property var setupSummary: SetupRows.summarize(healthSource.rows)
  readonly property bool firstRun: root.setupSummary.neverSetUp && (!root.status || !root.status.summary
                                   || root.status.summary.state === "absent")
  readonly property bool absentAndSetUp: !root.firstRun && !!root.status && !!root.status.summary
                                         && root.status.summary.state === "absent"
  onFirstRunChanged: if (root.opened && root.firstRun && !root.navigated) root.resetRoute("setup")

  // Left click opens on the Overview (§4), or on Setup on a first run.
  onOpenedChanged: {
    if (opened) {
      root.navigated = false
      root.setupFocus = ""
      root.resetRoute(root.firstRun ? "setup" : "overview")
      healthSource.hold()
    } else {
      healthSource.release()
    }
  }

  // Setup's rows, read while the popup is open (common/HealthSource.qml).
  HealthSource {
    id: healthSource
    engine: engineRunner
    status: root.status
  }

  // ---------------------------------------------------------- bar button

  // Not in the bar while no eGPU is attached and the system helper is already
  // set up: nothing here to look at. A first run keeps it, since the glyph is
  // how you reach Setup before there is anything to plug in. Settings stay one
  // press away on the notch's Plugins page ("Open settings").
  visible: !root.absentAndSetUp
  implicitWidth: root.visible ? button.implicitWidth : 0
  implicitHeight: root.visible ? button.implicitHeight : 0

  // A slow fade while connecting or ejecting (§4 "pulsing"). Runs only while
  // the glyph is on screen: a looping animation repaints every frame even when
  // nobody can see it (notch:SURFACE-HOSTING.md:490-492). Reduced motion stops
  // it and shows the final frame: the glyph at full strength (the state's word
  // and tooltip say what is under way). The period is the kit's loop token.
  property real pulse: 1
  SequentialAnimation on pulse {
    running: root.look.pulse && button.visible && !popupTheme.reduced
    loops: Animation.Infinite
    alwaysRunToEnd: false
    NumberAnimation { to: 0.35; duration: popupTheme.ringMs; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: popupTheme.ringMs; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) root.pulse = 1
  }

  BarIndicator {
    id: button
    anchors.fill: parent
    bar: root.bar
    moduleName: root.moduleName
    // Always active as an indicator; whether the widget is there at all is
    // decided on the root (absentAndSetUp). Its "absent" look is a dim glyph.
    activeOverride: true
    activeText: Palette.glyph
    activeTooltipText: root.look.tooltip
    readonly property color roleTint: root.barTone(root.look.role)
    foreground: Qt.rgba(roleTint.r, roleTint.g, roleTint.b, roleTint.a * root.pulse)

    // Left opens the notch's panel or the popup (press()). Right will run `display off` while an eGPU monitor
    // is on (§4, the second fast path to "monitor off"); the display verbs
    // land with E4/G4, so until then right does nothing at all rather than
    // something else.
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.press()
    }

    // Corner dot: accent while in use, warn for attention, bad for error. The
    // theme has one alarm colour, so warn is also a different SHAPE (a ring)
    // from bad (a filled dot): the two must not depend on telling two reds
    // apart.
    Rectangle {
      readonly property color tint: root.barTone(root.look.badge)
      visible: root.look.badge !== ""
      width: Math.max(5, Style.space(6))
      height: width
      radius: width / 2
      color: root.look.badge === "warn" ? "transparent" : tint
      border.width: root.look.badge === "warn" ? Math.max(1, Math.round(width / 4)) : 0
      border.color: tint
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(4)
    }

    // "+ HDMI monitor" (§4): a small monitor under the dot's corner.
    Text {
      visible: root.look.monitor
      textFormat: Text.PlainText
      text: Palette.monitorGlyph
      color: root.barTone("accent")
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(Style.font.bodySmall * 0.7))
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: Style.space(1)
      anchors.bottomMargin: Style.space(3)
    }
  }

  // --------------------------------------------------------------- popup
  //
  // The panel's inset is the kit's `sp.lg` (ui-scope.md §0.2): KeyboardPanel
  // pads its card by it, and the scrollbar sits in that gutter rather than
  // over the content, so nothing crowds the edge and the close keeps clear of
  // the corner. There is no back strip here: the header draws the kit's back
  // chevron whenever there is somewhere to go back to, and the one close.
  //
  // Esc and Enter go through the kit's UKeys (the one Esc handler), not Omarchy's
  // PanelKeyCatcher, which takes every key before a control could: the kit's
  // buttons, switch and tabs need Tab, Enter and Space. Up, Down, j and k still scroll.

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    padding: Math.round(popupTheme.sp.lg)
    contentWidth: panel.fittedContentWidth(popupTheme.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + foot.implicitHeight, popupTheme.space(600))

    UKeys {
      id: keys
      anchors.fill: parent
      focus: true
      level: "back"
      open: root.canStepBack
      onEscaped: root.back()
      onCloseRequested: root.close()
      onPrimary: if (viewLoader.item && typeof viewLoader.item.activatePrimary === "function") viewLoader.item.activatePrimary()
      Keys.onUpPressed: root.scrollBy(-1)
      Keys.onDownPressed: root.scrollBy(1)
      Keys.onPressed: function (event) {
        // j and k scroll too, as they do in Omarchy's other panels.
        if (event.text === "j") { root.scrollBy(1); event.accepted = true }
        else if (event.text === "k") { root.scrollBy(-1); event.accepted = true }
      }

      Flickable {
        id: flick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: foot.top
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: scrollBar

        Column {
          id: column
          width: flick.width
          spacing: popupTheme.sp.md

          Header {
            id: header
            width: parent.width
            theme: popupTheme
            tabs: root.tabs
            labels: root.tabLabels
            tab: root.onTab ? root.route : ""
            title: viewLoader.item && viewLoader.item.title !== undefined ? String(viewLoader.item.title) : ""
            dots: ({ setup: !!(root.status && root.status.health_summary && root.status.health_summary.errors > 0) })
            canBack: root.routeStack.length > 1
            onTabPicked: function (name) { root.pickTab(name) }
            onBack: root.back()
            onCloseRequested: root.close()
          }

          // One view at a time, so a view that is not on screen holds no
          // timers and no animations.
          Loader {
            id: viewLoader
            width: parent.width
            sourceComponent: root.builtRoutes[root.route] || overviewComponent
          }
        }
      }

      // In the panel's right gutter, outside the content.
      ScrollBar {
        id: scrollBar
        x: flick.width + (panel.padding - width) / 2
        y: 0
        height: flick.height
        policy: ScrollBar.AsNeeded
      }

      // The foot line: where a tip (placement foot) says what a control does, one reserved line under
      // the content.
      UTip {
        id: foot
        theme: popupTheme
        line: true
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
      }
    }
  }

  // Up and Down scroll the popup by a step (what the arrows did before).
  function scrollBy(dy) {
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * popupTheme.space(40)))
  }

  // A control Tab reached below the fold is scrolled into view (the popup is its own window).
  Connections {
    target: flick.Window.window
    function onActiveFocusItemChanged() { root.reveal(flick.Window.window ? flick.Window.window.activeFocusItem : null) }
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

  // Every view gets the same §5.0 interface; the shell only fills it in.
  Component {
    id: overviewComponent
    StatusView {
      status: root.status
      engine: engineRunner
      health: healthSource
      theme: popupTheme
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }

  Component {
    id: setupComponent
    SetupView {
      status: root.status
      engine: engineRunner
      health: healthSource
      theme: popupTheme
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      focusId: root.setupFocus
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }

  Component {
    id: gamesComponent
    GamesView {
      status: root.status
      engine: engineRunner
      health: healthSource
      theme: popupTheme
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }

  Component {
    id: detailsComponent
    DetailsView {
      status: root.status
      engine: engineRunner
      health: healthSource
      theme: popupTheme
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }

  Component {
    id: ejectComponent
    EjectFlow {
      status: root.status
      engine: engineRunner
      health: healthSource
      theme: popupTheme
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }
}
