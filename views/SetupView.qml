import QtQuick
import "ui"
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors
import "../common/SetupRows.js" as SetupRows
import "../common/Install.js" as Install

// Setup: what the eGPU needs from this computer, and one way to fix each
// thing (ui-scope.md §2.6, plan-gui.md §5.5, gate G6). Also the first-run
// screen (ux.md rule 4).
//
//   Setup has 2 things to fix               [ Fix all ]
//   ● The system helper is not installed     [ Install ]
//     It lets the plugin connect and eject without a password.   Details
//   ○ The desktop's graphics settings …      [ Fix ]
//   ● Thunderbolt is working
//   Auto-connect when plugged in   (switch)
//   Advanced ›
//
// Every row is a health row (`omarchy-egpu health --json`, through the
// shell's HealthSource) in plain words from common/SetupRows.js; the engine's
// id, title and detail are under the row's "Details". What a Fix does:
//   install  the one system install. The panel opens an Omarchy terminal
//            with a short explanation and the pinned command; sudo asks for
//            the password THERE (common/Install.js says why that is safe).
//            If the terminal cannot be opened, the command and a Copy button
//            are shown instead. Fix all is the same install
//   engine   an engine verb, run here (display apply, device connect --enroll,
//            the Steam ones); the rows are read again after it
//   copy     a command to run by hand, copied with wl-copy; "copied" only
//            once wl-copy says so
//   logout   a sentence: log out and back in
//
// First run (the system helper was never installed): ONE button, "Set up
// eGPU support", above the rows; the rows' own Install buttons are not drawn.
//
// The auto-connect switch is drawn but disabled: the system helper can turn
// it on or off (its `autoconnect` verb), but the engine has no verb for the
// panel to call yet (scope.md DECISION 2026-10-10), so it says why instead of
// offering a password prompt it cannot make. The install sets it (on).
//
// A shared view (plan-gui.md §5.0), as views/StatusView.qml.
Column {
  id: view

  // ----------------------------------------------------- shared interface
  property var status: null
  property var engine: null
  property var theme: Palette.make({})
  property string density: "full"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null
  // Additive: the row to open Setup on ("setup:<id>" from the Overview's
  // Fix). Drawn first, highlighted, its Details open.
  property string focusId: ""

  signal requestRoute(string name)
  signal requestClose()

  // The Advanced disclosure is this view's one sub-level: Escape closes it
  // before it leaves Setup.
  function popView() {
    if (view.advancedOpen) { view.advancedOpen = false; return true }
    return false
  }

  readonly property string title: "Setup"
  readonly property string meta: ""

  // ------------------------------------------------------------ derived
  readonly property real u: view.theme.unit
  readonly property var sp: view.theme.space
  readonly property var rows: view.health ? view.health.rows : null
  readonly property var sum: SetupRows.summarize(view.rows)
  readonly property bool loading: !!view.health && !!view.health.loading
  readonly property string readError: view.health && view.health.error ? String(view.health.error) : ""
  // Problems first, the focused one at the very top.
  // (Not a sort: the JS engine's sort is not stable, and the engine's order
  // within a level is meant.)
  readonly property var problemRows: view.sum.problems.filter(function (r) { return r.id === view.focusId })
    .concat(view.sum.problems.filter(function (r) { return r.id !== view.focusId }))
  readonly property bool fixAll: !view.sum.neverSetUp && view.sum.installRows.length > 0

  function can(verb) { return !!view.engine && typeof view.engine.can === "function" && view.engine.can(verb) }

  property bool advancedOpen: false

  // ------------------------------------------------------------ actions

  // The row whose engine call is in flight, and what each row last said.
  property string busyRow: ""
  property var notes: ({})
  function note(id, text, tone, detail) {
    var n = {}
    for (var k in view.notes) n[k] = view.notes[k]
    n[id] = { text: text, tone: tone || "secondary", detail: detail || "" }
    view.notes = n
  }
  onActiveChanged: if (!active) { view.notes = ({}); view.installState = ""; view.advancedOpen = false }

  function runFix(row) {
    var f = row.fix
    if (f.kind === "install") { view.install("install"); return }
    if (f.kind === "copy") { view.copy(row.id, f.command); return }
    if (f.kind !== "engine" || view.busyRow !== "" || !view.engine) return
    view.busyRow = row.id
    view.note(row.id, "Working…")
    view.engine.run(f.args, function (result) {
      if (!view) return    // the view was closed while the call ran
      view.busyRow = ""
      if (result.ok) view.note(row.id, f.note || "Done.", "secondary")
      else view.note(row.id, Errors.forResult(result), "bad", Errors.code(result))
      if (view.health && typeof view.health.refresh === "function") view.health.refresh()
    })
  }

  function copy(id, text) {
    view.note(id, "Copying…")
    view.engine.copy(text, function (result) {
      if (!view) return    // the view was closed while the call ran
      view.note(id, result.ok ? "Copied. Paste it into a terminal and run it, then come back here."
                              : "It could not be copied: wl-copy did not run. The command is shown under Details.", result.ok ? "secondary" : "bad")
    })
  }

  // The one system install (ui-scope.md §7): the pinned command, checked,
  // into an Omarchy terminal. installState: "" | preparing | opened | failed.
  property string installState: ""
  property string installCommand: ""
  property string installWhy: ""

  function install(mode) {
    if (!view.engine || view.installState === "preparing") return
    view.installState = "preparing"
    view.installWhy = ""
    view.engine.installCommand(mode, function (r) {
      if (!view) return    // the view was closed while the call ran
      if (!r.ok || !Install.commandOk(r.command, mode)) {
        view.installState = "failed"
        view.installCommand = ""
        view.installWhy = "The install command could not be prepared. The README shows it, under \"System half\"."
        return
      }
      view.installCommand = r.command
      view.engine.openTerminal(Install.terminalScript(r.command, mode === "uninstall" ? "Remove eGPU support" : "Set up eGPU support"), function (t) {
        if (!view) return
        if (t.ok) { view.installState = "opened"; return }
        view.installState = "failed"
        view.installWhy = t.code === 127 ? "Omarchy's terminal could not be found, so here is the command to run yourself."
                                         : "The terminal could not be opened, so here is the command to run yourself."
      })
    })
  }

  function copyAdvanced(mode) {
    view.engine.installCommand(mode, function (r) {
      if (!view) return    // the view was closed while the call ran
      if (r.ok && Install.commandOk(r.command, mode)) view.copy("advanced." + mode, r.command)
      else view.note("advanced." + mode, "The command could not be prepared.", "bad")
    })
  }

  function tone(name) {
    var c = view.theme[name]
    return c !== undefined && c !== null ? c : view.theme.foreground
  }

  // Sized by the shell's maxWidth (§5.0).
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : 300 * view.u)
  spacing: view.sp.section

  // --------------------------------------------------------------- header
  Item {
    width: parent.width
    implicitHeight: Math.max(summaryText.implicitHeight, fixAllButton.visible ? fixAllButton.implicitHeight : 0)
    visible: view.sum.loaded && !view.sum.neverSetUp

    Text {
      id: summaryText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - (fixAllButton.visible ? fixAllButton.width + view.sp.section : 0)
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: {
        var n = view.sum.problems.length
        return n === 0 ? "Everything is set up" : (n === 1 ? "One thing to look at" : n + " things to look at")
      }
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.title
      font.bold: true
    }
    Action {
      id: fixAllButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: view.fixAll
      theme: view.theme
      primary: true
      label: "Fix all"
      tone: view.theme.accent
      enabled: view.installState !== "preparing"
      onClicked: view.install("install")
    }
  }

  // First run: one button (ux.md rule 4).
  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.sum.neverSetUp

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "Set up eGPU support"
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.title
      font.bold: true
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Install.EXPLAIN.slice(0, 2).join(" ")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
    Item { width: 1; height: view.sp.row }
    Action {
      width: parent.width
      theme: view.theme
      primary: true
      label: view.installState === "preparing" ? "Opening a terminal…" : "Set up eGPU support"
      tone: view.theme.accent
      enabled: view.installState !== "preparing"
      busy: view.installState === "preparing"
      animate: view.active
      onClicked: view.install("install")
    }
  }

  // What the install did: a terminal is open, or here is the command.
  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.installState === "opened" || view.installState === "failed"

    Sentence {
      width: parent.width
      theme: view.theme
      tone: view.installState === "failed" ? view.theme.warn : view.theme.accent
      text: view.installState === "opened"
        ? "A terminal opened. Type your password there, wait for \"Done\", then come back here."
        : view.installWhy
      linkLabel: view.installState === "opened" ? "Check again" : ""
      onLinkClicked: if (view.health) view.health.refresh()
    }
    Text {
      width: parent.width
      visible: view.installState === "failed" && view.installCommand !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      text: view.installCommand
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.caption
    }
    Row {
      visible: view.installState === "failed" && view.installCommand !== ""
      spacing: view.sp.section
      Action {
        theme: view.theme
        label: "Copy command"
        onClicked: view.copy("install", view.installCommand)
      }
      Link {
        theme: view.theme
        label: "Check again"
        anchors.verticalCenter: parent.verticalCenter
        onClicked: if (view.health) view.health.refresh()
      }
    }
    Sentence {
      width: parent.width
      theme: view.theme
      rule: false
      text: view.notes["install"] ? view.notes["install"].text : ""
      tone: view.theme.secondary
    }
  }

  // ----------------------------------------------------------------- rows
  Row {
    visible: !view.sum.loaded
    spacing: view.sp.row
    Spinner {
      anchors.verticalCenter: parent.verticalCenter
      visible: view.loading
      size: view.theme.font.body
      tone: view.theme.secondary
      running: view.loading && view.active && visible
    }
    Text {
      textFormat: Text.PlainText
      text: view.readError !== "" ? "Setup could not be checked." : "Checking your setup…"
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }

  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.sum.loaded

    Repeater {
      model: view.problemRows
      delegate: SetupRow { required property var modelData; row: modelData }
    }
    Repeater {
      model: view.sum.others
      delegate: SetupRow { required property var modelData; row: modelData }
    }

    // Auto-connect (scope.md DECISION 2026-10-10): shown, not yet a control.
    Item {
      id: autoRow
      width: parent.width
      visible: !!view.sum.autoconnect
      implicitHeight: Math.max(view.sp.rowHeight, autoText.implicitHeight + view.sp.row)
      readonly property bool on: !!view.sum.autoconnect && view.sum.autoconnect.level === "ok"

      Column {
        id: autoText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - autoSwitch.width - view.sp.section
        spacing: view.sp.row / 2
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Auto-connect when plugged in"
          color: view.theme.foreground
          font.family: view.theme.fontFamily
          font.pixelSize: view.theme.font.body
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          // No engine verb changes it yet; say why, and what set it.
          text: view.sum.helper === "ok" ? "Set when the system helper was installed. It can't be changed here yet."
                                         : "Needs the system helper."
          color: view.theme.secondary
          font.family: view.theme.fontFamily
          font.pixelSize: view.theme.font.caption
        }
      }
      Switch {
        id: autoSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        theme: view.theme
        checked: autoRow.on
        enabled: false
      }
    }
  }

  // ------------------------------------------------------------- advanced
  Link {
    visible: view.sum.loaded
    theme: view.theme
    label: view.advancedOpen ? "Advanced ‹" : "Advanced ›"
    tone: view.theme.secondary
    onClicked: view.advancedOpen = !view.advancedOpen
  }

  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.advancedOpen && view.sum.loaded

    Repeater {
      model: view.sum.advanced
      delegate: SetupRow { required property var modelData; row: modelData }
    }
    Row {
      spacing: view.sp.section
      Link { theme: view.theme; label: "Copy the install command"; onClicked: view.copyAdvanced("install") }
      Link { theme: view.theme; label: "Copy the remove command"; onClicked: view.copyAdvanced("uninstall") }
    }
    Sentence {
      width: parent.width
      theme: view.theme
      rule: false
      readonly property var n: view.notes["advanced.install"] || view.notes["advanced.uninstall"] || null
      text: n ? n.text : ""
      tone: view.theme.secondary
    }
    Link {
      theme: view.theme
      label: "Check again"
      tone: view.theme.secondary
      onClicked: if (view.health) view.health.refresh()
    }
  }

  // ------------------------------------------------------------ components

  // One row: a mark for its level, the sentence and why, its one Fix, and
  // the engine's words under Details.
  component SetupRow: Item {
    id: setupRow
    property var row: ({})
    readonly property bool focused: view.focusId !== "" && setupRow.row.id === view.focusId
    readonly property var fix: setupRow.row.fix || { kind: "none", label: "" }
    readonly property bool fixShown: (setupRow.fix.kind === "engine" && view.can(setupRow.fix.verb))
                                     || setupRow.fix.kind === "copy"
                                     || (setupRow.fix.kind === "install" && !view.sum.neverSetUp)
    readonly property bool fixEnabled: view.busyRow === "" && view.installState !== "preparing"
                                       && !(setupRow.fix.needsPlugged && !(view.status && view.status.bolt && view.status.bolt.present))
    readonly property var rowNote: view.notes[setupRow.row.id] || null
    property bool detailsOpen: setupRow.focused

    width: view.width
    implicitHeight: Math.max(view.sp.rowHeight, rowColumn.implicitHeight + view.sp.row)

    // The focused row's rule, in the accent, in a gutter every row keeps so
    // the marks line up whichever row is focused.
    readonly property real gutter: 8 * view.u
    Rectangle {
      visible: setupRow.focused
      x: 0
      width: 3 * view.u
      height: parent.height
      radius: Math.min(view.theme.radius, width / 2)
      color: view.theme.accent
    }

    // The level as a shape as well as a colour: a filled dot (fine), a ring
    // (a suggestion), a filled dot in `bad` (a problem), a dim dot (info).
    Rectangle {
      id: mark
      readonly property string lv: String(setupRow.row.level || "")
      readonly property color tint: lv === "error" ? view.theme.bad : (lv === "warn" ? view.theme.warn
                                   : (lv === "ok" ? view.theme.good : view.theme.secondary))
      x: setupRow.gutter
      y: firstLine.y + (firstLine.implicitHeight - height) / 2 + view.sp.row / 2
      width: Math.max(6, Math.round(8 * view.u))
      height: width
      radius: Math.min(view.theme.radius, width / 2)
      color: lv === "warn" ? "transparent" : tint
      border.width: lv === "warn" ? Math.max(1, Math.round(1.5 * view.u)) : 0
      border.color: tint
      opacity: lv === "skipped" || lv === "info" ? 0.6 : 1
    }

    Column {
      id: rowColumn
      x: mark.x + mark.width + view.sp.section
      // Centred in a row's height when shorter, so one-line rows and
      // two-line rows keep the same rhythm.
      y: Math.max(view.sp.row / 2, (setupRow.height - rowColumn.implicitHeight) / 2)
      width: setupRow.width - x
      spacing: view.sp.row / 2

      Item {
        id: firstLine
        width: parent.width
        implicitHeight: Math.max(sentenceText.implicitHeight, fixButton.visible ? fixButton.implicitHeight : 0)

        Text {
          id: sentenceText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - (fixButton.visible ? fixButton.width + view.sp.section : 0)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: setupRow.row.sentence || ""
          color: setupRow.row.level === "skipped" ? view.theme.secondary : view.theme.foreground
          font.family: view.theme.fontFamily
          font.pixelSize: view.theme.font.body
        }
        Action {
          id: fixButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: setupRow.fixShown
          theme: view.theme
          label: view.busyRow === setupRow.row.id ? "Working…" : setupRow.fix.label
          tone: setupRow.row.level === "error" ? view.theme.accent : view.theme.foreground
          enabled: setupRow.fixEnabled
          busy: view.busyRow === setupRow.row.id
          animate: view.active
          onClicked: view.runFix(setupRow.row)
        }
      }

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: (setupRow.row.why || "") +
              (setupRow.fix.needsPlugged && !(view.status && view.status.bolt && view.status.bolt.present) ? " Plug the enclosure in first." : "")
        color: view.theme.secondary
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.font.caption
      }

      Text {
        width: parent.width
        visible: !!setupRow.rowNote && text !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: setupRow.rowNote ? setupRow.rowNote.text : ""
        color: setupRow.rowNote ? view.tone(setupRow.rowNote.tone) : view.theme.secondary
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.font.caption
      }

      Link {
        theme: view.theme
        label: setupRow.detailsOpen ? "Hide details" : "Details"
        tone: view.theme.secondary
        visible: setupRow.row.details !== "" && setupRow.row.level !== "ok"
        onClicked: setupRow.detailsOpen = !setupRow.detailsOpen
      }
      Text {
        width: parent.width
        visible: setupRow.detailsOpen && text !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WrapAnywhere
        // The engine's own words: id, title, detail; the command for a copy
        // fix; the code of a failed Fix.
        text: [setupRow.row.details,
               setupRow.fix.kind === "copy" ? "Command: " + setupRow.fix.command : "",
               setupRow.rowNote && setupRow.rowNote.detail ? "Code: " + setupRow.rowNote.detail : ""].filter(function (x) { return x !== "" }).join("\n")
        color: view.theme.secondary
        font.family: view.theme.fontFamily
        font.pixelSize: view.theme.font.caption
      }
    }
  }
}
