import QtQuick
import "ui"
import "../common/Palette.js" as Palette
import "../common/Errors.js" as Errors

// The eject sheet, pushed over the Overview by Safe eject (ui-scope.md §2.5,
// plan-gui.md §5.2, gate G3). It runs `omarchy-egpu device eject` as soon as
// it is on screen, and shows each answer:
//
//   checking   "Turning off the screen on the eGPU… Checking what's using it…"
//   holders    "vkcube is using the eGPU."  [ Close it ]  Cancel
//              background helpers that only hold the device, under "Also open
//              (harmless)": they keep the driver loaded, not the card
//   closing    `device eject --close`: SIGTERM to this user's apps, never
//              SIGKILL; what survives is listed again
//   done       "Safe to unplug", and the note when the driver stayed loaded
//   failed     the sentence from Errors.js and what to do: Try again, Cancel,
//              Open Setup (helper missing); remove_timeout is red and says
//              do not unplug, with no way to make it look finished
//
// The engine does the work and keeps going if this sheet is closed (Back,
// Escape, the notch closing): the Overview then shows Ejecting… from the
// status, so the user never has to hold the panel open (plan-gui.md §7.7,
// focus grab). Nothing here decides anything; every word about who holds the
// card is the engine's classification (lib/device.sh _dev_classify).
//
// plan-gui.md §5.2's once-per-session yank warning is not drawn: under the
// default igpu policy a yank only warns (ui-scope.md §3), and G7's
// notification says it at the moment it matters.
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

  signal requestRoute(string name)
  signal requestClose()

  function popView() { return false }

  readonly property string title: "Safe eject"
  readonly property string meta: ""

  // ------------------------------------------------------------ state
  readonly property real u: view.theme.unit
  readonly property var sp: view.theme.space

  // "" (not started) | checking | holders | closing | done | failed
  property string step: ""
  property var answer: null        // the last call's JSON
  property var result: null        // the last call's Engine result

  readonly property var holders: view.list(view.answer ? view.answer.holders : null)
  readonly property var incidental: view.list(view.answer ? view.answer.incidental : null)
    .filter(function (h) { return h && h.role !== "compositor" })
  readonly property bool canClose: !!(view.answer && view.answer.can_close)
  readonly property bool held: !!(view.answer && view.answer.modules && view.answer.modules.held_after_eject)
  readonly property string code: view.result ? Errors.code(view.result) : ""

  function list(v) { return v && typeof v === "object" && typeof v.length === "number" ? v : [] }

  function names(rows) {
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var n = String(rows[i].comm || "")
      if (n !== "" && out.indexOf(n) === -1) out.push(n)
    }
    return out
  }

  function joined(n) {
    if (n.length <= 1) return n.join("")
    return n.slice(0, -1).join(", ") + " and " + n[n.length - 1]
  }

  function start(close) {
    if (!view.engine || view.step === "checking" || view.step === "closing") return
    view.step = close ? "closing" : "checking"
    view.engine.run(close ? ["device", "eject", "--close"] : ["device", "eject"], function (r) {
      if (!view) return    // the view was closed while the call ran
      view.result = r
      view.answer = r.json
      if (r.ok) view.step = "done"
      else if (r.error === "holders_present") view.step = "holders"
      else view.step = "failed"
    })
  }

  // It runs once it is on screen, and again whenever it is opened anew.
  onActiveChanged: if (active && view.step === "") view.start(false)
  Component.onCompleted: if (view.active) view.start(false)

  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : 300 * view.u)
  spacing: view.sp.section

  // ------------------------------------------------------------ checking
  Row {
    visible: view.step === "checking" || view.step === "closing" || view.step === ""
    spacing: view.sp.row * 1.5
    Spinner {
      anchors.verticalCenter: parent.verticalCenter
      size: view.theme.font.title
      tone: view.theme.foreground
      running: view.active && parent.visible
    }
    Text {
      width: view.width - view.theme.font.title - parent.spacing
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.step === "closing" ? "Closing " + view.joined(view.names(view.holders.filter(function (h) { return h.closeable }))) + "…"
                                    : "Turning off the screens on the eGPU… Checking what's using it…"
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }
  Text {
    width: parent.width
    visible: view.step === "checking" || view.step === "closing"
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: "You can close this; the eject carries on."
    color: view.theme.secondary
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.font.caption
  }

  // ------------------------------------------------------------- holders
  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.step === "holders"

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      readonly property var n: view.names(view.holders)
      text: n.length === 0 ? "Something is still using the eGPU."
          : view.joined(n) + (n.length === 1 ? " is" : " are") + " using the eGPU."
      color: view.theme.foreground
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.title
      font.bold: true
    }
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.answer && view.answer.timed_out ? "It did not quit in time. Close it yourself, then try again."
          : (!view.canClose ? "Close it yourself, then try again."
          : "Closing asks each app to quit, as closing its window would. Save your work first.")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }

  Row {
    visible: view.step === "holders"
    spacing: view.sp.section
    Action {
      theme: view.theme
      primary: true
      visible: view.canClose
      label: view.names(view.holders).length > 1 ? "Close them" : "Close it"
      tone: view.theme.accent
      onClicked: view.start(true)
    }
    Action {
      theme: view.theme
      primary: !view.canClose
      visible: !view.canClose
      label: "Try again"
      onClicked: view.start(false)
    }
    Link {
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
      label: "Cancel"
      tone: view.theme.secondary
      onClicked: view.requestRoute("back")
    }
  }

  // ---------------------------------------------------------------- done
  Column {
    width: parent.width
    spacing: view.sp.row
    visible: view.step === "done"

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "Safe to unplug"
      color: view.theme.good
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.display
      font.bold: true
    }
    Text {
      width: parent.width
      visible: view.held
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "The driver stays loaded until you log out. " + Errors.note("held_after_eject")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }
  Action {
    width: parent.width
    visible: view.step === "done"
    theme: view.theme
    primary: true
    label: "Done"
    tone: view.theme.good
    onClicked: view.requestClose()
  }

  // -------------------------------------------------------------- failed
  Sentence {
    width: parent.width
    visible: view.step === "failed"
    theme: view.theme
    text: view.step !== "failed" ? ""
        : (view.code === "126" || (view.result && view.result.code === 126) ? "Not ejected: permission was declined."
        : Errors.forResult(view.result))
    tone: view.code === "remove_timeout" || view.code === "smi_hung" ? view.theme.bad : view.theme.warn
    linkLabel: Errors.routeFor(view.result) === "setup" ? "Open Setup" : ""
    linkRoute: Errors.routeFor(view.result)
    detail: view.code
    onLinkClicked: view.requestRoute(linkRoute)
  }
  Row {
    // remove_timeout and a hung driver: nothing here can make it safe, so
    // there is no button that would look like it did.
    visible: view.step === "failed" && view.code !== "remove_timeout" && view.code !== "smi_hung"
    spacing: view.sp.section
    Action {
      theme: view.theme
      primary: true
      label: "Try again"
      tone: view.theme.accent
      onClicked: view.start(false)
    }
    Link {
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
      label: "Cancel"
      tone: view.theme.secondary
      onClicked: view.requestRoute("back")
    }
  }

  // ------------------------------------------------------------ harmless
  // Background helpers that only hold the device file: they keep the driver
  // loaded, not the card, and never block (lib/device.sh "incidental").
  Column {
    width: parent.width
    spacing: view.sp.row / 2
    visible: (view.step === "holders" || view.step === "done") && view.incidental.length > 0

    Text {
      textFormat: Text.PlainText
      text: "Also open (harmless)"
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.caption
    }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.joined(view.names(view.incidental))
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.font.body
    }
  }

}
