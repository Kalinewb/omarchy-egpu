import QtQuick
import "../ui"
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
// Auto-connect is a value, not a switch: the system helper can turn it on or
// off (its `autoconnect` verb), but the engine has no verb for the panel to
// call yet (scope.md DECISION 2026-10-10), so the row says what it is and who
// set it instead of offering a control (or a password prompt) it cannot back.
// The install sets it (on).
//
// The row that is asked for (a Fix from the Overview opens Setup on it) is the
// selected one: an accent bar in the margin beside it, apart from the keyboard
// focus ring, which is on a control. It comes first, its Details open, and the
// keyboard rests on its Fix.
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
  readonly property bool canPop: view.advancedOpen

  // Enter, with nothing under the focus to take it: the page's one primary
  // button, Set up eGPU support on a first run, else Fix all.
  function activatePrimary() {
    if (view.installState === "preparing") return false
    if (view.sum.neverSetUp || view.fixAll) { view.install("install"); return true }
    return false
  }

  readonly property string title: "Setup"

  // ------------------------------------------------------------ derived
  readonly property var sp: view.theme.sp
  readonly property var rows: view.health ? view.health.rows : null
  readonly property var sum: SetupRows.summarize(view.rows)
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

  // Sized by the shell's maxWidth (§5.0).
  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : view.theme.space(300))
  spacing: view.sp.md

  // The level's own colour, for the mark: shape tells it apart too (filled, ring).
  function levelTone(lv) {
    return lv === "error" ? view.theme.destructive : (lv === "warn" ? view.theme.warning
         : (lv === "ok" ? view.theme.accent : view.theme.metadata))
  }
  // A note's colour: only a failure is not secondary.
  function noteTone(t) { return t === "bad" ? view.theme.destructive : view.theme.secondary }

  // --------------------------------------------------------------- header
  Item {
    width: parent.width
    implicitHeight: Math.max(summaryText.implicitHeight, fixAllButton.visible ? fixAllButton.implicitHeight : 0)
    visible: view.sum.loaded && !view.sum.neverSetUp

    Text {
      id: summaryText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - (fixAllButton.visible ? fixAllButton.width + view.sp.md : 0)
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: {
        var n = view.sum.problems.length
        return n === 0 ? "Everything is set up" : (n === 1 ? "One thing to look at" : n + " things to look at")
      }
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    UButton {
      id: fixAllButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: view.fixAll
      theme: view.theme
      kind: "primary"
      text: "Fix all"
      enabled: view.installState !== "preparing"
      onClicked: view.install("install")
      UTip { theme: view.theme; placement: "foot"; text: "Installs everything Setup lists, in one terminal." }
    }
  }

  // First run: one button (ux.md rule 4).
  Column {
    width: parent.width
    spacing: view.sp.sm
    visible: view.sum.neverSetUp

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "Set up eGPU support"
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Install.EXPLAIN.slice(0, 2).join(" ")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    UButton {
      width: parent.width
      visible: view.installState !== "preparing"
      theme: view.theme
      kind: "primary"
      text: "Set up eGPU support"
      onClicked: view.install("install")
      UTip { theme: view.theme; placement: "foot"; text: "Opens a terminal that installs it; sudo asks there." }
    }
    URing {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: view.installState === "preparing"
      height: view.theme.rowHeight
      theme: view.theme
      text: "Opening a terminal…"
    }
  }

  // What the install did: a terminal is open, or here is the command.
  Column {
    width: parent.width
    spacing: view.sp.sm
    visible: view.installState === "opened" || view.installState === "failed"

    UNotice {
      theme: view.theme
      width: parent.width
      tone: view.installState === "failed" ? "warning" : "info"
      text: view.installState === "opened"
        ? "A terminal opened. Type your password there, wait for \"Done\", then come back here."
        : view.installWhy
      actionText: view.installState === "opened" ? "Check again" : ""
      onActed: if (view.health) view.health.refresh()
    }
    Text {
      width: parent.width
      visible: view.installState === "failed" && view.installCommand !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      text: view.installCommand
      color: view.theme.metadata
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.footnoteSize
      font.weight: view.theme.metadataWeight
    }
    Row {
      visible: view.installState === "failed" && view.installCommand !== ""
      spacing: view.sp.sm
      UButton {
        theme: view.theme
        text: "Copy command"
        onClicked: view.copy("install", view.installCommand)
      }
      UButton {
        theme: view.theme
        text: "Check again"
        onClicked: if (view.health) view.health.refresh()
      }
    }
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.notes["install"] ? view.notes["install"].text : ""
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }

  // ----------------------------------------------------------------- rows
  URing {
    visible: !view.sum.loaded && view.readError === ""
    theme: view.theme
    text: "Checking your setup…"
  }
  UNotice {
    theme: view.theme
    width: parent.width
    visible: !view.sum.loaded && view.readError !== ""
    tone: "error"
    text: "Setup could not be checked."
    details: view.readError
    actionText: "Try again"
    onActed: if (view.health) view.health.refresh()
  }

  Column {
    width: parent.width
    visible: view.sum.loaded

    Repeater {
      model: view.problemRows
      delegate: SetupRow { required property var modelData; row: modelData }
    }
    Repeater {
      model: view.sum.others
      delegate: SetupRow { required property var modelData; row: modelData }
    }

    // Auto-connect (scope.md DECISION 2026-10-10): shown, not yet a control, so a value (never a
    // disabled switch) that says who set it.
    URow {
      visible: !!view.sum.autoconnect
      theme: view.theme
      label: "Auto-connect"
      value: view.sum.helper !== "ok" ? "Needs the system helper"
           : (!!view.sum.autoconnect && view.sum.autoconnect.level === "ok" ? "On · set by the installer" : "Off")
      valueQuiet: true
    }
  }

  // ------------------------------------------------------------- advanced
  URow {
    visible: view.sum.loaded
    theme: view.theme
    clickable: true
    label: "Advanced"
    value: view.advancedOpen ? "▾" : "▸"
    onActivated: view.advancedOpen = !view.advancedOpen
  }

  Column {
    width: parent.width
    spacing: view.sp.sm
    visible: view.advancedOpen && view.sum.loaded

    Column {
      width: parent.width
      Repeater {
        model: view.sum.advanced
        delegate: SetupRow { required property var modelData; row: modelData }
      }
    }
    Row {
      spacing: view.sp.sm
      UButton { theme: view.theme; text: "Copy the install command"; onClicked: view.copyAdvanced("install") }
      UButton { theme: view.theme; text: "Copy the remove command"; onClicked: view.copyAdvanced("uninstall") }
    }
    Text {
      width: parent.width
      visible: text !== ""
      readonly property var n: view.notes["advanced.install"] || view.notes["advanced.uninstall"] || null
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: n ? n.text : ""
      color: view.noteTone(n ? n.tone : "")
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    UButton {
      theme: view.theme
      text: "Check again"
      onClicked: if (view.health) view.health.refresh()
    }
  }

  // ------------------------------------------------------------ components

  // One row: a mark for its level, the sentence and why, its one Fix, and the engine's words under
  // Details. The kit's row is its frame (height, and the one row class); its content is laid out here
  // because a sentence wraps and a row's label does not.
  component SetupRow: URow {   // ui-allow: its root is a URow; the gate's pattern backtracks over the space after the colon
    id: setupRow
    property var row: ({})
    readonly property bool focused: view.focusId !== "" && setupRow.row.id === view.focusId
    readonly property var fix: setupRow.row.fix || { kind: "none", label: "" }
    readonly property bool fixShown: (setupRow.fix.kind === "engine" && view.can(setupRow.fix.verb))
                                     || setupRow.fix.kind === "copy"
                                     || (setupRow.fix.kind === "install" && !view.sum.neverSetUp)
    readonly property bool fixEnabled: view.busyRow === "" && view.installState !== "preparing"
                                       && !(setupRow.fix.needsPlugged && !(view.status && view.status.bolt && view.status.bolt.present))
    readonly property bool working: view.busyRow === setupRow.row.id
    readonly property var rowNote: view.notes[setupRow.row.id] || null
    property bool detailsOpen: setupRow.focused
    // The first Fix is where the keyboard rests on the row that was asked for.
    readonly property alias fixButton: fixButton

    theme: view.theme
    implicitHeight: body.height + view.sp.sm

    Component.onCompleted: Qt.callLater(function () {
      if (setupRow.focused && setupRow.fixShown && setupRow.fixEnabled) fixButton.forceActiveFocus()
    })

    Item {
      id: body
      // Laid out in the row itself, not in its control slot (which sizes to its children and sits at the
      // right): the row is this content's frame and gives it its height.
      parent: setupRow
      width: setupRow.width
      height: Math.max(view.theme.rowHeight, content.implicitHeight + view.sp.xs)

      // The selected row, an accent bar at its left edge, in a gutter every row keeps so the marks line up
      // whichever row is selected: not under any text, and apart from the keyboard's ring, which is on a
      // control. (The panel scrolls and clips at its content's edge, so the bar cannot sit outside it.)
      Rectangle {
        visible: setupRow.focused
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        width: view.sp.xs
        height: Math.round(parent.height * 0.6)
        radius: view.theme.radius(width)
        color: view.theme.accent
        property bool uiMark: true
      }

      // The level as a shape as well as a colour: a filled dot (fine), a ring (a suggestion), a filled
      // dot in the problem colour (a problem), a quiet dot (info).
      Rectangle {
        id: mark
        readonly property string lv: String(setupRow.row.level || "")
        readonly property color tint: view.levelTone(lv)
        x: view.sp.sm
        y: Math.round((view.theme.rowHeight - height) / 2) + view.sp.xs / 2
        width: view.sp.sm
        height: width
        radius: view.theme.radius(height)
        color: lv === "warn" ? view.theme.none : tint
        border.width: lv === "warn" ? Math.max(view.theme.hairlineWidth, Math.round(width / 4)) : 0
        border.color: tint
        property bool uiMark: true
      }

      Column {
        id: content
        x: mark.x + mark.width + view.sp.md
        y: view.sp.xs / 2
        width: setupRow.width - x
        spacing: view.sp.xs

        Item {
          width: parent.width
          implicitHeight: Math.max(sentenceText.implicitHeight, view.theme.controlHeight)

          Text {
            id: sentenceText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (fixSlot.visible ? fixSlot.width + view.sp.sm : 0)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: setupRow.row.sentence || ""
            color: setupRow.row.level === "skipped" ? view.theme.secondary : view.theme.label
            font.family: view.theme.fontFamily
            font.pixelSize: view.theme.bodySize
          }
          Item {
            id: fixSlot
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(fixButton.visible ? fixButton.width : 0, workRing.visible ? workRing.width : 0)
            height: view.theme.controlHeight
            visible: setupRow.fixShown
            UButton {
              id: fixButton
              visible: !setupRow.working
              height: view.theme.controlHeight
              theme: view.theme
              text: setupRow.fix.label
              enabled: setupRow.fixEnabled
              onClicked: view.runFix(setupRow.row)
            }
            URing {
              id: workRing
              visible: setupRow.working
              anchors.verticalCenter: parent.verticalCenter
              theme: view.theme
            }
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
          font.pixelSize: view.theme.footnoteSize
        }

        Text {
          width: parent.width
          visible: !!setupRow.rowNote && text !== ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: setupRow.rowNote ? setupRow.rowNote.text : ""
          color: setupRow.rowNote ? view.noteTone(setupRow.rowNote.tone) : view.theme.secondary
          font.family: view.theme.fontFamily
          font.pixelSize: view.theme.footnoteSize
        }

        UButton {
          theme: view.theme
          kind: "link"
          // The link's own padding sits left of the column's text: pull it back so the words line up.
          x: -view.sp.sm
          text: setupRow.detailsOpen ? "Hide details" : "Details"
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
          color: view.theme.metadata
          font.family: view.theme.fontFamily
          font.pixelSize: view.theme.footnoteSize
          font.weight: view.theme.metadataWeight
        }
      }
    }
  }
}
