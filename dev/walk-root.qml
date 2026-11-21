import QtQuick
import Quickshell
import Quickshell.Io

// The root `dev/check-ui.sh --walk` uses for the panel: the real NotchPanel.qml, once for every page and
// state the fixtures cover, stacked in one tall item, so the walk sees every button, row, notice, switch,
// ring and sentence the panel can draw and measures names, hit targets, text size and contrast on all of
// them, in the seven configurations (standalone, hosted black and white, styled black and white, hosted and
// standalone with reduced motion):
//
//   ./dev/check-ui.sh --walk dev/walk-root.qml
//
// The walk hands in `theme` (the kit's, over its fake host or none); each panel is given that theme and
// the host it stands for, so a hosted run draws the panel as the notch does. The status and Setup's rows
// are the fixtures' own (dev/fixtures/<name>), and the engine is a stand-in that answers the eject with
// what each state needs (apps holding the eGPU, a monitor still on, done). Nothing here starts a process,
// reads the machine or touches the shell.
Item {
  id: root
  property var theme: null
  readonly property real panelWidth: 440

  implicitWidth: panelWidth
  implicitHeight: stack.implicitHeight

  // ---------------------------------------------------------------- fixtures
  function slurp(path) {
    var f = fileHolder.createObject(root, { path: Quickshell.shellPath("repo/dev/fixtures/" + path) })
    var text = f.text()
    f.destroy()
    try { return JSON.parse(text) } catch (e) { return null }
  }
  Component { id: fileHolder; FileView { blockLoading: true; printErrors: false } }

  // The engine, as far as the panel asks: every verb is there, the eject answers as `mode` says.
  Component {
    id: engineComp
    QtObject {
      property string mode: "holders"
      function can(verb) { return true }
      function run(args, cb) {
        var eject = args.length > 1 && args[0] === "device" && args[1] === "eject"
        if (!eject) { cb({ ok: true, json: null, code: 0, error: "" }); return }
        if (mode === "holders") cb({ ok: false, code: 1, error: "holders_present", json: {
          holders: [{ comm: "vkcube", closeable: true }, { comm: "worker", closeable: true }],
          incidental: [{ comm: "chromium", role: "browser" }], can_close: true } })
        else if (mode === "failed") cb({ ok: false, code: 1, error: "hdmi_still_active", json: { error: "hdmi_still_active" } })
        else cb({ ok: true, code: 0, error: "", json: { modules: { held_after_eject: true }, incidental: [] } })
      }
      function copy(text, cb) { cb({ ok: true }) }
      function installCommand(mode, cb) { cb({ ok: false, command: "" }) }
      function openTerminal(script, cb) { cb({ ok: true, code: 0 }) }
    }
  }
  Component {
    id: healthComp
    QtObject {
      property var rows: null
      property bool loading: false
      property string error: ""
      function refresh() {}
      function hold() {}
      function release() {}
    }
  }

  // name | fixture | route | engine mode | extra (adv: Setup's Advanced open; ask: the confirm asking)
  readonly property var pages: [
    { fx: "ready-hdmi", route: "main" },
    { fx: "ejecting", route: "main" },
    { fx: "stranger-no-tb", route: "main" },
    { fx: "this-machine", route: "full" },
    { fx: "smi-hung", route: "full" },
    { fx: "auth-error", route: "full" },
    { fx: "this-machine", route: "setup:hypr.session_env", extra: "adv" },
    { fx: "stranger-no-tb", route: "setup" },
    { fx: "in-use-procs", route: "details" },
    { fx: "in-use-procs", route: "eject", mode: "holders" },
    { fx: "in-use-procs", route: "eject", mode: "holders", extra: "ask" },
    { fx: "ready-hdmi", route: "eject", mode: "failed" },
    { fx: "ready", route: "eject", mode: "done" }
  ]

  Column {
    id: stack
    spacing: root.theme ? root.theme.sp.xl : 24

    Repeater {
      model: root.theme ? root.pages : []
      delegate: Item {
        id: slot
        required property var modelData
        width: root.panelWidth
        height: loader.item ? loader.item.implicitHeight : 0

        Loader {
          id: loader
          // A Loader by file URL, not the NotchPanel type: the walk runs under Quickshell's `qs:` scheme, where a
          // folder is importable only if the harness root imports it (it imports repo/ui only), and the panel
          // imports views/ and common/ too. A file: URL is resolved by Qt itself, folder imports and all.
          Component.onCompleted: {
            var engine = engineComp.createObject(slot, { mode: slot.modelData.mode || "holders" })
            var health = healthComp.createObject(slot, { rows: root.slurp(slot.modelData.fx + "/health.json") })
            setSource("file://" + Quickshell.shellPath("repo/NotchPanel.qml"), {
              theme: root.theme,
              surfaceHost: root.theme ? root.theme.host : null,
              status: root.slurp(slot.modelData.fx + "/status.json"),
              engine: engine,
              health: health,
              maxWidth: root.panelWidth,
              maxHeight: 6000
            })
          }
          onLoaded: {
            item.open(slot.modelData.route)
            if (slot.modelData.extra === "adv") root.openAdvanced(item)
            if (slot.modelData.extra === "ask") Qt.callLater(function () { root.askConfirm(item) })
          }
        }
      }
    }
  }

  function openAdvanced(item) {
    if (!item) return false
    if (item.advancedOpen !== undefined) { item.advancedOpen = true; return true }
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) if (root.openAdvanced(kids[i])) return true
    return false
  }
  // The eject sheet's confirm, asking: its answer arrives from the stand-in engine at once.
  function askConfirm(item) {
    if (!item) return false
    if (item.asking !== undefined && item.ask !== undefined) { item.ask(); return true }
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) if (root.askConfirm(kids[i])) return true
    return false
  }
}
