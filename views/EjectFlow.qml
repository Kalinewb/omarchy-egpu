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
//   done       "Safe to unplug"; with the driver still loaded (a stale status:
//              the engine no longer answers ok then) "Do not suspend" instead
//   failed     the sentence from Errors.js and what to do: Cancel, Try again,
//              Open Setup (helper missing); remove_timeout and a hung driver
//              are an error notice and say do not unplug, with no way to make
//              it look finished. Per answer (lib/device.sh):
//                driver_in_use    who still uses it (`names`), whether the session
//                                 itself does, Close <apps> when `can_close`, and no
//                                 retry when the driver is shared with this
//                                 computer's own NVIDIA GPU (`shared_driver`)
//                modules_held     `detail`, "Do not suspend. Log out first.", no retry
//                remove_failed    with `driver_unloaded`: Connect is the primary action
//                any answer       "Turn the screens back on" (`display enable`) for the
//                                 monitors the eject turned off and did not restore
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
    if (view.step === "failed" && view.unloaded && view.canConnect) { view.connect(); return true }
    if (view.step === "failed" && view.canRetry && !view.canClose) { view.start(false); return true }
    if (view.step === "holders" && !view.canClose) { view.start(false); return true }
    return false
  }

  readonly property string title: "Safe eject"

  // ------------------------------------------------------------ state
  readonly property var sp: view.theme.sp

  // "" (not started) | checking | holders | closing | done | failed
  property string step: ""
  property var answer: null        // the last call's JSON
  property var result: null        // the last call's Engine result

  readonly property var holders: view.list(view.answer ? view.answer.holders : null)
  readonly property var incidental: view.list(view.answer ? view.answer.incidental : null)
    .filter(function (h) { return h && h.role !== "compositor" })
  readonly property bool held: !!(view.answer && view.answer.modules && view.answer.modules.held_after_eject)
  readonly property string code: view.result ? Errors.code(view.result) : ""

  // What the failed answers carry (lib/device.sh _dev_driver_in_use, _dev_modules_held_fail, _dev_note_unloaded).
  readonly property bool inUse: view.code === "driver_in_use"
  // The helper's refusal: this computer's own NVIDIA GPU runs on the same driver. Nothing to close, nothing to retry.
  readonly property bool shared: view.inUse && !!(view.answer && view.answer.shared_driver)
  readonly property bool sessionHolds: view.inUse && !!(view.answer && view.answer.session_holds)
  readonly property var stillUsing: view.inUse ? view.list(view.answer ? view.answer.names : null) : []
  // The card is gone and the driver is loaded: a suspend now would crash the kernel.
  readonly property bool doNotSuspend: !!(view.answer && view.answer.do_not_suspend === true)
  // Unloaded for the eject, then the helper could not remove the card or load it back: still attached, dark.
  readonly property bool unloaded: view.code !== "" && !!(view.answer && view.answer.driver_unloaded === true)
  readonly property bool canClose: !!(view.answer && view.answer.can_close) && !view.shared
  readonly property bool canConnect: !!view.engine && view.engine.can("device connect")
  // Not gated on engine.can(): the panel's verb list leaves out the monitor verbs on purpose (listing them draws the
  // compact view's HDMI switch, common/Engine.qml), and the engine itself runs this very verb to restore the screens.
  readonly property bool canEnable: !!view.engine

  // The monitors this eject turned off and the engine did not put back (display.restored lists those it did).
  // Each is named as the display verb takes it.
  readonly property var screensOff: {
    var d = view.answer ? view.answer.display : null
    var off = d ? view.list(d.off) : []
    var back = d ? view.list(d.restored) : []
    var out = []
    for (var i = 0; i < off.length; i++) {
      var m = off[i] || {}
      var id = String(m.description || m.name || "")
      if (id !== "" && back.indexOf(id) === -1) out.push(id)
    }
    return out
  }
  property string screensState: ""   // "" | busy | done | later | failed
  property string connectState: ""   // "" | busy | failed
  property var connectResult: null

  // remove_timeout and a hung driver: nothing here can make it safe, so
  // there is no button that would look like it did. Nor after modules_held
  // (the answer is the same until the user logs out), nor with a shared
  // driver, and with the driver unloaded Connect is the way back, not another eject.
  readonly property bool canRetry: view.code !== "remove_timeout" && view.code !== "smi_hung"
                                   && !view.shared && !view.doNotSuspend && !view.unloaded
  // The verb names what it closes: "Close vkcube", "Close 3 apps". Only apps it may signal.
  readonly property var holderNames: view.names(view.holders)
  readonly property var closeNames: view.names(view.holders.filter(function (h) { return h && h.closeable }))
  readonly property string closeVerb: view.closeNames.length === 1 ? "Close " + view.closeNames[0]
                                      : view.closeNames.length === 0 ? "Close them" : "Close " + view.closeNames.length + " apps"
  // Who still uses the driver, said as the holders step says it, at most six.
  readonly property string usingLine: {
    var n = view.stillUsing
    if (n.length === 0) return ""
    return "Still using it: " + (n.length > 6 ? n.slice(0, 6).join(", ") + " and " + (n.length - 6) + " more" : view.joined(n)) + "."
  }
  // The notice's sentence. A hung or unloaded driver and the others keep the table's; modules_held says
  // what the engine saw (who holds the modules).
  readonly property string failText: view.step !== "failed" ? ""
      : (view.code === "126" || (view.result && view.result.code === 126) ? "Not ejected: permission was declined."
      : view.doNotSuspend && view.answer.detail ? String(view.answer.detail)
      : view.unloaded ? Errors.note("driver_unloaded")
      : Errors.forResult(view.result))
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
    view.screensState = ""
    view.connectState = ""
    view.engine.run(close ? ["device", "eject", "--close"] : ["device", "eject"], function (r) {
      if (!view) return    // the view was closed while the call ran
      view.result = r
      view.answer = r.json
      if (r.ok) view.step = "done"
      else if (r.error === "holders_present") view.step = "holders"
      else view.step = "failed"
    })
  }

  // `display enable` for each monitor the eject left off, one after the other (the display verbs take a lock).
  function screensBack() {
    if (!view.engine || view.screensState === "busy") return
    var todo = view.screensOff.slice()
    var failed = false
    var later = false
    view.screensState = "busy"
    function next() {
      if (!view) return
      if (todo.length === 0) { view.screensState = failed ? "failed" : later ? "later" : "done"; return }
      view.engine.run(["display", "enable", todo.shift()], function (r) {
        if (!r.ok) failed = true
        // Remembered, not lit: the monitor is not on the screen (the card is gone).
        else if (r.json && r.json.live === false) later = true
        next()
      })
    }
    next()
  }

  // The driver is unloaded and the card is still attached: Connect loads it again. When it did, the Overview
  // (the status the engine keeps) says the eGPU is ready, so the sheet leaves.
  function connect() {
    if (!view.engine || view.connectState === "busy") return
    view.connectState = "busy"
    view.engine.run(["device", "connect"], function (r) {
      if (!view) return
      view.connectResult = r
      if (r.ok) { view.connectState = ""; view.requestRoute("back") }
      else view.connectState = "failed"
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
    visible: (view.step === "holders" || (view.step === "failed" && view.inUse)) && view.canClose
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

    // Never "Safe to unplug" with the driver still loaded and no card (a stale status; the engine answers
    // modules_held for it now): a suspend then crashes the kernel.
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: view.held ? "Do not suspend" : "Safe to unplug"
      color: view.held ? view.theme.label : view.theme.accentText
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    Text {
      width: parent.width
      visible: view.held
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Errors.note("held_after_eject")
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
    tone: !view.canRetry && !view.unloaded ? "error" : "warning"
    text: view.failText
    details: view.code
    actionText: Errors.routeFor(view.result) === "setup" ? "Open Setup" : ""
    property string linkRoute: Errors.routeFor(view.result)
    onActed: view.requestRoute(linkRoute)
  }
  Column {
    width: parent.width
    spacing: view.sp.xs
    visible: view.step === "failed"

    // The one thing to do, when there is only one thing: it leads.
    Text {
      width: parent.width
      visible: view.doNotSuspend
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Errors.note("do_not_suspend")
      color: view.theme.label
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.titleSize
      font.weight: view.theme.titleWeight
    }
    Text {
      width: parent.width
      visible: view.usingLine !== "" && !view.shared
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.usingLine
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    Text {
      width: parent.width
      visible: view.sessionHolds && !view.shared
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Errors.note("session_holds")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    // What the engine says of the unloaded driver: it names the step that failed.
    Text {
      width: parent.width
      visible: view.unloaded && !!view.answer && !!view.answer.detail
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.unloaded && view.answer && view.answer.detail ? String(view.answer.detail) : ""
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    // A hung driver cannot be asked to light them: the way back is the lid.
    Text {
      width: parent.width
      visible: view.screensOff.length > 0 && (!view.canEnable || view.code === "smi_hung")
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: Errors.note("screens_off")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
    Text {
      width: parent.width
      visible: view.screensState === "done" || view.screensState === "later" || view.screensState === "failed"
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: view.screensState === "done" ? "The screens are back on."
          : view.screensState === "later" ? "The screens come back on when the eGPU is connected again."
          : Errors.note("screens_off")
      color: view.theme.secondary
      font.family: view.theme.fontFamily
      font.pixelSize: view.theme.bodySize
    }
  }
  // Connect, pressed, did not bring the driver back: its own sentence, from the table.
  UNotice {
    theme: view.theme
    width: parent.width
    visible: view.step === "failed" && view.connectState === "failed"
    tone: "error"
    text: view.connectResult ? Errors.forResult(view.connectResult) : ""
    details: view.connectResult ? Errors.code(view.connectResult) : ""
  }
  // The monitors the eject turned off and the engine did not turn back on.
  Item {
    width: parent.width
    height: view.theme.rowHeight
    visible: view.step === "failed" && view.screensOff.length > 0 && view.canEnable && view.code !== "smi_hung"
             && view.screensState !== "done" && view.screensState !== "later"
    UButton {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      theme: view.theme
      text: view.screensState === "busy" ? "Turning them on…" : "Turn the screens back on"
      enabled: view.screensState !== "busy"
      onClicked: view.screensBack()
    }
  }
  // Try again for what a retry can change; Connect when the driver is unloaded (the primary, then).
  Item {
    width: parent.width
    height: view.theme.rowHeight
    visible: view.step === "failed" && !view.canClose && (view.canRetry || (view.unloaded && view.canConnect))
    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: view.sp.sm
      UButton { theme: view.theme; text: "Cancel"; onClicked: view.requestRoute("back") }
      UButton {
        theme: view.theme
        visible: view.canRetry
        text: "Try again"
        kind: "primary"
        onClicked: view.start(false)
      }
      UButton {
        theme: view.theme
        visible: view.unloaded
        text: view.connectState === "busy" ? "Connecting…" : "Connect"
        kind: "primary"
        enabled: view.connectState !== "busy"
        onClicked: view.connect()
      }
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
