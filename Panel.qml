import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "common"
import "views"
import "common/Palette.js" as Palette

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

  // ------------------------------------------------------------- palette
  //
  // The only place Omarchy's Color and Style reach the views (§5.0). Two
  // palettes because the glyph sits on the bar and the views on the popup, and
  // each has its own foreground. The theme has no green or amber: `good` is
  // the accent (the ejected state also changes the word and the tooltip, so
  // colour is never the only signal), `bad` is the theme's urgent, and `warn`
  // is urgent softened toward the foreground so the two dots differ.
  //
  // Color is always `Commons.Color`: since Omarchy 4.0.5 a bare `Color` in a
  // plugin no longer resolves to the theme (its own Ui files qualify it too).
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function themed(fg, background) {
    return Palette.make({
      foreground: fg,
      secondary: Qt.darker(fg, 1.55),
      accent: Commons.Color.accent,
      good: Commons.Color.accent,
      warn: Qt.tint(Commons.Color.urgent, Qt.rgba(fg.r, fg.g, fg.b, 0.35)),
      bad: Commons.Color.urgent,
      background: background,
      radius: Style.cornerRadius,
      fontFamily: root.fontFamily,
      unit: Style.spaceReal(1),
      font: { caption: Style.font.caption, body: Style.font.body, title: Style.font.title,
              display: Style.font.display, icon: Style.font.icon }
    })
  }

  readonly property var popupPalette: themed(root.foreground, Commons.Color.popups.background)
  readonly property var barPalette: themed(root.barForeground, null)

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
    id: engine
    pluginDir: root.pluginDir
  }

  StatusSource {
    id: source
    service: root.ownService
    engine: engine
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
    canConnect: engine.can("device connect")
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

  // Colours for a view the notch would draw from the descriptor: the host's,
  // as in NotchPanel.qml.
  readonly property var surfacePalette: Palette.fromHost(root.surfaceHost, {
    unit: Style.spaceReal(1),
    font: { caption: Style.font.caption, body: Style.font.body, title: Style.font.title,
            display: Style.font.display, icon: Style.font.icon }
  })

  Component {
    id: glanceComponent
    Glance {
      status: root.status
      engine: engine
      theme: root.surfacePalette
      active: true
      statusNote: root.statusNote
      noticeTitle: root.noticeLive ? notices.notice.title : ""
    }
  }

  Component {
    id: compactComponent
    CompactView {
      status: root.status
      engine: engine
      theme: root.surfacePalette
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
  // The popup's tabs are the top-level routes (§5: Overview · Display · Games ·
  // Setup); anything else a view asks for is pushed over the current one (the
  // eject sheet, G3). A route appears here in the phase that builds its view —
  // until then requesting it is a no-op with a console line, never a blank page.
  readonly property var builtRoutes: ({ overview: overviewComponent })
  readonly property var tabOrder: ["overview", "display", "games", "setup"]
  readonly property var tabLabels: ({ overview: "Overview", display: "Display", games: "Games", setup: "Setup" })
  readonly property var tabs: tabOrder.filter(function (t) { return !!root.builtRoutes[t] })

  property var routeStack: ["overview"]
  readonly property string route: routeStack[routeStack.length - 1]

  function resetRoute(name) { root.routeStack = [name] }

  function requestRoute(name) {
    var n = String(name || "")
    if (n === "full" || n === root.route) return    // the popup IS the full panel
    if (!root.builtRoutes[n]) {
      console.warn("kalinewb.egpu", "route not built yet:", n)
      return
    }
    if (root.tabOrder.indexOf(n) !== -1) root.resetRoute(n)
    else root.routeStack = root.routeStack.concat([n])
  }

  // Escape and the Back button (§7.7): the view's own sub-sheet first, then
  // one route, and only at the root does it close.
  function back() {
    var item = viewLoader.item
    if (item && typeof item.popView === "function" && item.popView()) return
    if (root.routeStack.length > 1) root.routeStack = root.routeStack.slice(0, -1)
    else root.close()
  }

  // Left click opens on the Overview (§4).
  onOpenedChanged: if (opened) root.resetRoute("overview")

  // ---------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A slow fade while connecting or ejecting (§4 "pulsing"). Runs only while
  // the glyph is on screen: a looping animation repaints every frame even when
  // nobody can see it (notch:SURFACE-HOSTING.md:490-492).
  property real pulse: 1
  SequentialAnimation on pulse {
    running: root.look.pulse && button.visible
    loops: Animation.Infinite
    alwaysRunToEnd: false
    NumberAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) root.pulse = 1
  }

  function roleColor(palette, role) {
    var c = palette[role] !== undefined ? palette[role] : palette.foreground
    return c
  }

  BarIndicator {
    id: button
    anchors.fill: parent
    bar: root.bar
    moduleName: root.moduleName
    // Always shown. BarIndicator conceals an inactive glyph unless the bar's
    // indicator block reveals it; this one is a widget of its own, and its
    // "absent" look is a dim glyph, not no glyph (§4). Hiding while absent is
    // the user's `gui.hide_when_absent`, which arrives with `config` (E3+).
    activeOverride: true
    activeText: Palette.glyph
    activeTooltipText: root.look.tooltip
    readonly property color roleTint: root.roleColor(root.barPalette, root.look.role)
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
      readonly property color tint: root.roleColor(root.barPalette, root.look.badge)
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
      color: root.barPalette.accent
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.7))
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: Style.space(1)
      anchors.bottomMargin: Style.space(3)
    }
  }

  // --------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.back()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height,
                                                              flick.contentY + dy * Style.space(40)))
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // The right gutter is always reserved, as omarchy-face learned: the
        // hero's Back button sits at its right edge, which is where the
        // scrollbar's track appears on a tall view.
        Column {
          id: column
          width: flick.width - Style.space(10)
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: viewLoader.item && viewLoader.item.title !== undefined ? viewLoader.item.title : "eGPU"
            meta: viewLoader.item && viewLoader.item.meta !== undefined ? viewLoader.item.meta : ""
            foreground: root.popupPalette.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Palette.glyph
                color: root.roleColor(root.popupPalette, root.look.role)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                visible: root.routeStack.length > 1
                iconText: Palette.backGlyph
                tooltipText: "Back"
                foreground: root.popupPalette.foreground
                fontFamily: root.fontFamily
                onClicked: root.back()
              }
            }
          }

          // Hidden while Overview is the only view built; the row exists so
          // each later phase only adds its route to builtRoutes.
          ButtonGroup {
            visible: root.tabs.length > 1
            options: root.tabs.map(function (t) { return { value: t, label: root.tabLabels[t] } })
            value: root.routeStack[0]
            foreground: root.popupPalette.foreground
            accent: root.popupPalette.accent
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function (v) { root.requestRoute(v) }
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
    }
  }

  // Every view gets the same §5.0 interface; the shell only fills it in.
  Component {
    id: overviewComponent
    StatusView {
      status: root.status
      engine: engine
      theme: root.popupPalette
      density: "full"
      maxWidth: column.width
      active: root.opened
      statusNote: root.statusNote
      onRequestRoute: function (name) { root.requestRoute(name) }
      onRequestClose: root.close()
    }
  }
}
