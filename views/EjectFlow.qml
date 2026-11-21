import QtQuick
import "../ui"
import "../common/Errors.js" as Errors

// The eject sheet, pushed over the Overview by Safe eject (ui-scope.md §2.5,
// plan-gui.md §5.2, gate G3). It runs `omarchy-egpu device eject` as soon as
// it is on screen, and shows each answer:
//
//   checking   "Turning off the screen on the eGPU… Checking what's using it…"
//   holders    "vkcube is using the eGPU."  Cancel  [ Close vkcube ]
//              Closing asks each app to quit, so it is the kit's confirm row
//              (a destructive verb with an object, never the default): "Ask
//              vkcube to quit? Save your work first." Cancel  [ Close vkcube ]
//              background helpers that only hold the device, under "Also open
//              (harmless)": they keep the driver loaded, not the card
//   closing    `device eject --close`: SIGTERM to this user's apps, never
//              SIGKILL; what survives is listed again
//   done       "Safe to unplug", and the note when the driver stayed loaded
//   failed     the sentence from Errors.js and what to do: Cancel, Try again,
//              Open Setup (helper missing); remove_timeout and a hung driver
//              are an error notice and say do not unplug, with no way to make
//              it look finished
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
  required property var theme
  property string density: "full"
  property real maxWidth: 0
  property real maxHeight: 0
  property bool active: false
  property string statusNote: ""
  property var health: null

  signal requestRoute(string name)
  signal requestClose()

  // A confirm that is asking is the view's one sub-level, and Esc (the kit's
  // "modal" level) cancels it first: UConfirmSheet handles that itself, so
  // there is nothing for the shell's back step to pop.
  function popView() { return false }
  readonly property bool canPop: false
  // Enter, with nothing under the focus to take it: Done, or Try again.
  function activatePrimary() {
    if (view.step === "done") { view.requestClose(); return true }
    if (view.step === "failed" && view.canRetry) { view.start(false); return true }
    if (view.step === "holders" && !view.canClose) { view.start(false); return true }
    return false
  }

  readonly property string title: "Safe eject"
  readonly property string meta: ""

  // ------------------------------------------------------------ state
  readonly property var sp: view.theme.sp

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

  // remove_timeout and a hung driver: nothing here can make it safe, so
  // there is no button that would look like it did.
  readonly property bool canRetry: view.code !== "remove_timeout" && view.code !== "smi_hung"
  // The verb names what it closes: "Close vkcube", "Close 3 apps".
  readonly property var holderNames: view.names(view.holders)
  readonly property string closeVerb: view.holderNames.length === 1 ? "Close " + view.holderNames[0]
                                      : view.holderNames.length === 0 ? "Close them" : "Close " + view.holderNames.length + " apps"
  // One short sentence: the verb names what it closes, and the row holds Cancel and the verb beside it.
  readonly property string closeAsk: "Save your work first."

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

  width: view.maxWidth > 0 ? view.maxWidth : (parent ? parent.width : view.theme.space(300))
  spacing: view.sp.md

  // ------------------------------------------------------------ checking
  Row {
    visible: view.step === "checking" || view.step === "closing" || view.step === ""
    spacing: view.sp.sm
    URing {
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
      visible: view.active && parent.visible
    }
    Text {
      width: view.width - view.theme.titleSize - parent.spacing
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.step === "closing" ? "Closing " + view.joined(view.names(view.holders.filter(function (h) { return h.closeable }))) + "…"
                                    : "Turning off the screens on the eGPU… Checking what's using it…"
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
  Text {
    width: parent.width
    visible: view.step === "checking" || view.step === "closing"
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    text: "You can close this; the eject carries on."
    color: view.theme.metadata
    font.family: view.theme.fontFamily
    font.pixelSize: view.theme.footnoteSize
    font.weight: view.theme.metadataWeight
  }

  // ------------------------------------------------------------- holders
  Column {
    width: parent.width
    spacing: view.sp.sm
    visible: view.step === "holders"

    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      readonly property var n: view.holderNames
      text: n.length === 0 ? "Something is still using the eGPU."
          : view.joined(n) + (n.length === 1 ? " is" : " are") + " using the eGPU."
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.answer && view.answer.timed_out ? "It did not quit in time. Close it yourself, then try again."
          : (!view.canClose ? "Close it yourself, then try again." : "")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }

  // Closing apps asks them to quit: the kit's confirm row replaces the buttons in place, and Esc
  // cancels it. A destructive verb is never the default: Cancel has the focus.
  UConfirmSheet {
    id: confirm
    width: parent.width
    visible: view.step === "holders" && view.canClose
    theme: view.theme
    sentence: view.closeAsk
    verb: view.closeVerb
    destructive: true
    onConfirmed: view.start(true)

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: view.sp.sm
      UButton {
        theme: view.theme
        text: "Cancel"
        onClicked: view.requestRoute("back")
      }
      UButton {
        theme: view.theme
        text: view.closeVerb
        kind: "destructive"
        onClicked: confirm.ask()
        UTip { theme: view.theme; placement: "foot"; text: "Asks each app to quit, as closing its window would." }
      }
    }
  }

  Item {
    width: parent.width
    height: view.theme.rowHeight
    visible: view.step === "holders" && !view.canClose
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: view.sp.sm
      UButton { theme: view.theme; text: "Cancel"; onClicked: view.requestRoute("back") }
      UButton { theme: view.theme; text: "Try again"; kind: "primary"; onClicked: view.start(false) }
    }
  }

  // ---------------------------------------------------------------- done
  Column {
    width: parent.width
    spacing: view.sp.xs
    visible: view.step === "done"

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "Safe to unplug"
      color: view.theme.accentText
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    Text {
      width: parent.width
      visible: view.held
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "The driver stays loaded until you log out. " + Errors.note("held_after_eject")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
  UButton {
    width: parent.width
    visible: view.step === "done"
    theme: view.theme
    kind: "primary"
    text: "Done"
    onClicked: view.requestClose()
  }

  // -------------------------------------------------------------- failed
  UNotice {
    theme: view.theme
    width: parent.width
    visible: view.step === "failed"
    tone: !view.canRetry ? "error" : "warning"
    text: view.step !== "failed" ? ""
        : (view.code === "126" || (view.result && view.result.code === 126) ? "Not ejected: permission was declined."
        : Errors.forResult(view.result))
    details: view.code
    actionText: Errors.routeFor(view.result) === "setup" ? "Open Setup" : ""
    property string linkRoute: Errors.routeFor(view.result)
    onActed: view.requestRoute(linkRoute)
  }
  Item {
    width: parent.width
    height: view.theme.rowHeight
    visible: view.step === "failed" && view.canRetry
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: view.sp.sm
      UButton { theme: view.theme; text: "Cancel"; onClicked: view.requestRoute("back") }
      UButton { theme: view.theme; text: "Try again"; kind: "primary"; onClicked: view.start(false) }
    }
  }

  // ------------------------------------------------------------ harmless
  // Background helpers that only hold the device file: they keep the driver
  // loaded, not the card, and never block (lib/device.sh "incidental").
  USection {
    theme: view.theme
    visible: (view.step === "holders" || view.step === "done") && view.incidental.length > 0
    title: "Also open (harmless)"
    first: true
    Text {
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.joined(view.names(view.incidental))
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
}
