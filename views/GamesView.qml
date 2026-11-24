import QtQuick
import "../ui"
import "../common/Errors.js" as Errors
import "../common/Games.js" as Games

// Games: which games and apps run on the eGPU (ui-scope.md §2.3, extended
// to desktop apps). One switch per row, all off until the person turns one on.
//
//   Steam games   the engine's `steam list` (a launch option in Steam's own
//                 settings; the file is only written while Steam is closed,
//                 so with Steam open a change waits and "Close Steam and
//                 apply" does it, never silently)
//   Apps          the engine's `apps list` (a copy of the app's launcher that
//                 starts it through egpu-run: applies the next time it starts)
//
// No launch-option words on the surface. Rows the person set by hand
// (state manual / modified) say so and are left alone. Tools, runtimes and
// Steam's own entries are never listed (the engine hides them).
//
// A shared view (plan-gui.md §5.0), as views/StatusView.qml.
Column {
  id: view

  // ----------------------------------------------------- shared interface
  property var status: null
  property var engine: null
  required property var theme
  property string density: "full"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }
  readonly property bool canPop: false
  function activatePrimary() { return false }

  readonly property string title: "Games"
  readonly property string meta: ""

  // ------------------------------------------------------------ derived
  readonly property var sp: view.theme.sp
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : view.theme.space(300))
  spacing: view.sp.md

  // What the engine last said. null = not read yet.
  property var steam: null          // the `steam list` document, or an error
  property var apps: null           // the `apps list` document, or an error
  property string steamError: ""
  property string appsError: ""
  property string note: ""          // the one line a failed or queued change leaves
  property string noteTone: "secondary"
  property bool busy: false
  property bool showAllApps: false
  readonly property string query: search.input.text.trim().toLowerCase()

  readonly property var steamGames: view.steam && view.steam.games ? view.steam.games : []
  readonly property var appRows: view.apps && view.apps.apps ? view.apps.apps : []
  readonly property bool steamRunning: !!(view.steam && view.steam.steam_running)
  readonly property int pendingCount: Games.pending(view.steamGames)

  // The rows that match the search, and for the apps a short list until the
  // person asks for the rest (a launcher has hundreds of entries).
  readonly property var shownGames: Games.filterSteam(view.steamGames, view.query)
  readonly property var appPick: Games.pickApps(view.appRows, view.query, view.showAllApps)
  readonly property var shownApps: view.appPick.rows

  function can(verb) { return !!view.engine && typeof view.engine.can === "function" && view.engine.can(verb) }

  // ------------------------------------------------------------ reading
  function refresh() {
    if (!view.engine) return
    if (view.can("steam list")) view.engine.run(["steam", "list"], function (r) {
      if (!view) return    // the view was closed while the call ran
      if (r.ok && r.json) { view.steam = r.json; view.steamError = "" }
      else { view.steam = null; view.steamError = r.error === "steam_not_found" ? "" : Errors.forResult(r) }
    })
    if (view.can("apps list")) view.engine.run(["apps", "list"], function (r) {
      if (!view) return
      if (r.ok && r.json) { view.apps = r.json; view.appsError = "" }
      else { view.apps = null; view.appsError = Errors.forResult(r) }
    })
  }
  onActiveChanged: if (active) view.refresh(); else { view.note = ""; search.clear() }
  Component.onCompleted: if (active) view.refresh()

  // ------------------------------------------------------------ changing
  function say(text, tone) { view.note = text; view.noteTone = tone || "secondary" }

  // One Steam game. With Steam open the change is queued (--queue), so the
  // switch always does what it says, either now or when Steam closes.
  function setGame(g, on) {
    if (view.busy || !view.engine) return
    view.busy = true
    view.engine.run(["steam", "set", String(g.appid), on ? "on" : "off", "--queue"], function (r) {
      if (!view) return
      view.busy = false
      if (r.ok) view.say(r.json && r.json.queued ? "Saved. It takes effect when Steam closes." : "", "secondary")
      else view.say(Errors.forResult(r), "bad")
      view.refresh()
    })
  }

  function setApp(a, on) {
    if (view.busy || !view.engine) return
    view.busy = true
    view.engine.run(["apps", "set", a.id, on ? "on" : "off"], function (r) {
      if (!view) return
      view.busy = false
      if (r.ok) view.say(on ? "Starts on the eGPU next time you open it." : "", "secondary")
      else view.say(Errors.forResult(r), "bad")
      view.refresh()
    })
  }

  function applyNow() {
    if (view.busy || !view.engine) return
    view.busy = true
    view.say("Closing Steam…", "secondary")
    view.engine.run(["steam", "apply", "--close", "--relaunch"], function (r) {
      if (!view) return
      view.busy = false
      if (r.ok) view.say("Done. Steam is open again.", "secondary")
      else view.say(Errors.forResult(r), "bad")
      view.refresh()
    })
  }

  // ------------------------------------------------------------ the page
  UField {
    id: search
    theme: view.theme
    width: parent.width
    label: "Search"
    placeholder: "Search games and apps"
    tip: "Type to narrow the lists."
  }

  UNotice {
    theme: view.theme
    width: parent.width
    visible: view.pendingCount > 0 && view.steamRunning
    tone: "info"
    text: (view.pendingCount === 1 ? "One game change waits" : view.pendingCount + " game changes wait")
          + " for Steam to close."
    actionText: view.can("steam apply") ? "Close Steam and apply" : ""
    onActed: view.applyNow()
  }

  Text {
    width: parent.width
    visible: view.note !== ""
    text: view.note
    wrapMode: Text.WordWrap
    color: view.noteTone === "bad" ? view.theme.destructive : view.theme.secondary
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.footnoteSize
    Accessible.role: Accessible.StaticText
    Accessible.name: view.note
  }

  UEmpty {
    theme: view.theme
    width: parent.width
    visible: view.steam === null && view.apps === null && view.steamError === "" && view.appsError === ""
    text: "Reading your games and apps…"
  }

  UNotice {
    theme: view.theme
    width: parent.width
    visible: view.appsError !== ""
    tone: "error"
    text: view.appsError
  }

  // ---- Steam games
  USection {
    id: steamSection
    theme: view.theme
    first: true
    visible: view.steamGames.length > 0
    title: "Steam games"

    Repeater {
      model: view.shownGames
      delegate: URow {
        required property var modelData
        theme: view.theme
        label: modelData.name
        value: Games.stateWord(modelData.state)
        valueQuiet: true
        USwitch {
          theme: view.theme
          label: modelData.name
          checked: Games.isOn(modelData.state)
          enabled: !view.busy && Games.togglable(modelData.state)
          visible: Games.togglable(modelData.state)
          anchors.verticalCenter: parent.verticalCenter
          onToggled: view.setGame(modelData, !checked)
        }
      }
    }
    Text {
      visible: view.query !== "" && view.shownGames.length === 0
      text: "No Steam game matches."
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }

  UEmpty {
    theme: view.theme
    width: parent.width
    visible: view.steam === null && view.apps !== null && view.steamError === ""
    text: "Steam is not installed, so only apps are listed."
  }

  // ---- Apps
  USection {
    theme: view.theme
    first: view.steamGames.length === 0
    visible: view.appRows.length > 0
    title: "Apps"

    Repeater {
      model: view.shownApps
      delegate: URow {
        required property var modelData
        theme: view.theme
        label: modelData.name
        value: Games.appWord(modelData.state)
        valueQuiet: true
        USwitch {
          theme: view.theme
          label: modelData.name
          checked: modelData.state === "on"
          enabled: !view.busy && modelData.state !== "manual"
          visible: modelData.state !== "manual"
          anchors.verticalCenter: parent.verticalCenter
          onToggled: view.setApp(modelData, !checked)
        }
      }
    }
    URow {
      theme: view.theme
      visible: view.appPick.hidden > 0
      clickable: true
      label: view.showAllApps ? "Show fewer" : "Show all " + view.appRows.length + " apps"
      value: view.showAllApps ? "▴" : "▸"
      onActivated: view.showAllApps = !view.showAllApps
    }
    Text {
      visible: view.query !== "" && view.shownApps.length === 0
      text: "No app matches."
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }

  Text {
    width: parent.width
    visible: view.apps !== null || view.steam !== null
    text: "A game or app set to the eGPU uses it when it is connected, and the laptop's graphics when it is not. Everything starts off."
    wrapMode: Text.WordWrap
    color: view.theme.metadata
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.footnoteSize
  }
}
