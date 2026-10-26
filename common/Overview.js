.pragma library

.import "Errors.js" as Errors
.import "SetupRows.js" as SetupRows
.import "Facts.js" as Facts

// The Overview's state table (ui-scope.md §2.1), once, for both the full
// Overview (views/StatusView.qml) and the notch's compact view
// (views/CompactView.qml), so the two say the same words and offer the same
// one button (ux.md rule 6, ui-scope.md §7).
//
// decide(status, ctx) → {
//   key        which row of the table (for the gates)
//   headline   the state in plain words, shown once
//   headlineRoute  "setup" / "setup:<row id>" when the headline is a Setup
//              problem: tapping it opens Setup there, as Fix does, so a
//              headline that names Setup is never a dead end (§0.1); else ""
//   facts      one line of facts ("RTX 4070 SUPER · 41 °C · idle"), or ""
//   button     the ONE primary button, or null:
//                {label, action, enabled, busy, tone, rowId}
//              action: setup | connect | eject | done | fix | show
//   sentence   one status sentence, or null:
//                {text, tone, linkLabel, linkRoute, secondary}
//              linkRoute "setup" / "setup:<row id>" opens Setup (on that
//              row); "eject" the eject sheet. A sentence that mentions Setup
//              always has a link that opens it (ui-scope.md §0.1).
//   hints      the enclosure profile's hints, for "Show me"
// }
//
// ctx: { rows: health rows or null (not loaded yet), can: function(verb),
//        busy: the view's call in flight ("connect" or ""), statusNote }
//
// Nothing here decides a state: summary.state is the engine's. This chooses
// words and the button for it.

// "NVIDIA GeForce RTX 4070 SUPER" → "RTX 4070 SUPER"; the PCI name's bracket
// when nvidia-smi has not answered ("… AD104 [GeForce RTX 4070 SUPER]").
function shortCard(gpu, pci) {
  var n = gpu && gpu.name ? String(gpu.name) : ""
  if (n === "" && pci && pci.name) {
    var m = String(pci.name).match(/\[([^\]]+)\]/)
    n = m ? m[1] : String(pci.name)
  }
  return n.replace(/^NVIDIA\s+/, "").replace(/^GeForce\s+/, "").replace(/^AMD\s+/, "").replace(/^Radeon\s+/, "Radeon ")
}

// "41 °C · idle" / "41 °C · 37% busy"; "" when the card says nothing.
function telemetry(gpu) {
  var g = gpu || {}
  if (!g.ok) return ""
  var parts = []
  if (g.temp_c !== null && g.temp_c !== undefined) parts.push(Math.round(g.temp_c) + " °C")
  if (g.util_pct !== null && g.util_pct !== undefined) parts.push(Number(g.util_pct) > 0 ? Math.round(g.util_pct) + "% busy" : "idle")
  return parts.join(" · ")
}

function base(p) { var t = String(p || ""); var i = t.lastIndexOf("/"); return i >= 0 ? t.substring(i + 1) : t }

// Who is using the card, for "eGPU in use by …": the first app, "+ n more".
function usedBy(s) {
  var procs = Facts.list(s.gpu ? s.gpu.procs : null)
  var names = []
  for (var i = 0; i < procs.length; i++) {
    var n = base(procs[i] && procs[i].name)
    if (n !== "" && names.indexOf(n) === -1) names.push(n)
  }
  if (names.length === 1) return names[0]
  if (names.length === 2) return names[0] + " and " + names[1]
  if (names.length > 2) return names[0] + " and " + (names.length - 1) + " more"
  var mons = Facts.list(s.display ? s.display.monitors : null)
  for (var j = 0; j < mons.length; j++) if (mons[j] && mons[j].enabled) return "a screen"
  return ""
}

function hintsOf(s) {
  var h = Facts.list(s ? s.hints : null)
  var out = []
  for (var i = 0; i < h.length; i++) if (h[i] && h[i].text) out.push(String(h[i].text))
  return out
}

function modulesMissing(s) {
  var m = s.driver && s.driver.modules ? s.driver.modules : {}
  for (var k in m) if (m[k] === false) return true
  return false
}

function decide(s, ctx) {
  var c = ctx || {}
  var can = typeof c.can === "function" ? c.can : function () { return false }
  var setup = SetupRows.summarize(c.rows)
  var busy = String(c.busy || "")
  var r = { key: "unknown", headline: "", headlineRoute: "", facts: "", button: null, sentence: null, hints: hintsOf(s), setup: setup }

  function btn(label, action, extra) {
    var b = { label: label, action: action, enabled: true, busy: false, tone: "accent", rowId: "" }
    for (var k in (extra || {})) b[k] = extra[k]
    return b
  }
  function connectButton() {
    if (busy === "connect") return btn("Connecting…", "", { enabled: false, busy: true })
    return can("device connect") ? btn("Connect", "connect") : null
  }
  function ejectButton(label) {
    return can("device eject") ? btn(label, "eject") : null
  }
  // The sentence under the button: the first Setup problem with a Fix that
  // opens Setup on its row, else a quiet line about Setup.
  function setupSentence() {
    var hs = s.health_summary || {}
    var err = SetupRows.firstError(setup)
    if (err) return { text: err.sentence + ".", tone: "warn", linkLabel: "Fix", linkRoute: "setup:" + err.id }
    if (Number(hs.errors) > 0) return { text: Errors.note("health_errors"), tone: "warn", linkLabel: "Open Setup", linkRoute: "setup" }
    var w = setup.loaded ? setup.problems.length : Number(hs.warnings) || 0
    if (w > 0) return { text: w === 1 ? "Setup has one suggestion." : "Setup has " + w + " suggestions.",
                        tone: "secondary", linkLabel: "Open Setup", linkRoute: "setup" }
    return { text: "Everything is set up.", tone: "secondary", linkLabel: "", linkRoute: "" }
  }

  if (!s || !s.summary) {
    r.headline = c.statusNote ? "eGPU status unavailable" : "Checking your eGPU…"
    r.facts = c.statusNote ? String(c.statusNote).charAt(0).toUpperCase() + String(c.statusNote).substring(1) + "." : ""
    return r
  }

  var state = String(s.summary.state || "")
  var phase = String(s.phase || "")
  var bolt = s.bolt || {}
  var card = shortCard(s.gpu, s.pci)
  var tele = telemetry(s.gpu)
  var cardFacts = [card, tele].filter(function (x) { return x !== "" }).join(" · ")
  var enclosure = bolt.name ? String(bolt.name) : ""
  var relogin = !!(s.display && s.display.needs_relogin)
  var held = !!(s.modules && s.modules.held_after_eject)
  var unsupported = !!(s.backend && s.backend.name !== null && s.backend.name !== undefined && s.backend.supported === false)
  r.sentence = setupSentence()

  // The phase's own button, for the attention rows that are not about Setup.
  function phaseButton() {
    if (phase === "ready") return modulesMissing(s) ? connectButton() : ejectButton(usedBy(s) !== "" ? "Safe eject…" : "Safe eject")
    if (phase === "ejected") return btn("Done", "done", { tone: "good" })
    if (phase === "plugged" || phase === "authorized" || phase === "bound") return connectButton()
    return null
  }

  if (state === "absent") {
    r.key = setup.neverSetUp ? "absent_setup" : "absent"
    // "Plug in your eGPU" would be wrong where nothing can be plugged in.
    r.headline = bolt.domain === false ? "No Thunderbolt or USB4 port" : "Plug in your eGPU"
    if (bolt.domain === false) r.facts = "A Thunderbolt eGPU cannot connect to this computer."
    else if (enclosure !== "" && bolt.stored) r.facts = "Remembered: " + enclosure
    if (setup.neverSetUp) {
      // The button is the way to Setup; a sentence would say it twice.
      r.button = btn("Set up eGPU support", "setup")
      r.sentence = null
    }
  } else if (state === "connecting") {
    r.facts = enclosure
    if (phase === "authorized" && !(s.pci && s.pci.present)) {
      r.key = "no_gpu"
      r.headline = "Enclosure found, no graphics card"
      r.button = btn(c.hintsShown ? "Hide" : "Show me", "show", { tone: "foreground" })
      if (c.hintsShown) r.sentence = { text: r.hints.length > 0 ? r.hints.join(" ") : Errors.message("no_pci_device"),
                                       tone: "accent", linkLabel: "", linkRoute: "" }
    } else {
      r.key = "connecting"
      r.headline = "Getting your eGPU ready…"
      // The engine moves on by itself only with auto-connect on and nothing
      // asked of the user; otherwise Connect is what moves it (plan-gui.md
      // §5.1). Busy: a spinner, disabled.
      var auto = !!(s.connect && s.connect.auto === true)
      if (busy === "connect" || (auto && !s.summary.needs_action) || !can("device connect"))
        r.button = btn("Connecting…", "", { enabled: false, busy: true })
      else r.button = connectButton()
    }
  } else if (state === "ready") {
    r.key = "ready"
    r.headline = "eGPU ready"
    r.facts = cardFacts
    r.button = modulesMissing(s) ? connectButton() : ejectButton("Safe eject")
  } else if (state === "in_use") {
    r.key = "in_use"
    var who = usedBy(s)
    r.headline = who !== "" ? "eGPU in use by " + who : "eGPU in use"
    r.facts = cardFacts
    r.button = ejectButton("Safe eject…")
  } else if (state === "ejecting") {
    r.key = "ejecting"
    r.headline = "Ejecting…"
    r.facts = enclosure
    r.button = btn("Ejecting…", "", { enabled: false, busy: true })
  } else if (state === "safe_to_unplug") {
    r.key = "safe"
    r.headline = "Safe to unplug"
    r.facts = enclosure
    r.button = btn("Done", "done", { tone: "good" })
  } else if (state === "attention") {
    r.facts = cardFacts !== "" ? cardFacts : enclosure
    if (relogin) {
      r.key = "attention_relogin"
      r.headline = "Log out to use the HDMI monitor"
      r.button = phaseButton()
      r.sentence = { text: Errors.note("needs_relogin"), tone: "warn", linkLabel: "", linkRoute: "" }
    } else if (held) {
      r.key = "attention_held"
      r.headline = phase === "ejected" ? "Safe to unplug" : "Log out before plugging in again"
      r.button = phaseButton()
      r.sentence = { text: Errors.note("held_after_eject"), tone: "warn", linkLabel: "", linkRoute: "" }
    } else if (unsupported) {
      r.key = "attention_unsupported"
      r.headline = "This graphics card is not supported yet"
      r.sentence = { text: Errors.message("backend_stub"), tone: "warn", linkLabel: "Open Setup", linkRoute: "setup" }
    } else {
      // A Setup problem: its sentence is the headline, Fix opens it.
      r.key = "attention"
      var err = SetupRows.firstError(setup)
      r.headline = err ? err.sentence : "Setup has found a problem"
      r.headlineRoute = err ? "setup:" + err.id : "setup"
      r.button = btn("Fix", "fix", { rowId: err ? err.id : "" })
      // The eGPU underneath still needs its own way out (secondary).
      var eject = phase === "ready" && can("device eject")
      r.sentence = { text: phase === "ready" ? "The eGPU itself is ready." : (phase === "ejected" ? "Safe to unplug." : "The eGPU is connecting."),
                     tone: "secondary", linkLabel: eject ? "Safe eject" : "", linkRoute: eject ? "eject" : "", secondary: true }
    }
  } else if (state === "error") {
    r.key = "error"
    var code = s.gpu && s.gpu.error ? String(s.gpu.error) : (bolt.status === "auth-error" ? "auth_error" : "")
    r.headline = code !== "" ? Errors.message(code) : "Something went wrong with the eGPU."
    r.code = code
    r.facts = enclosure
    var e2 = SetupRows.firstError(setup)
    if (code === "smi_hung") r.button = null    // nothing to retry: log out or reboot
    else if (e2 && e2.fix.kind !== "none") r.button = btn("Open Setup", "fix", { rowId: e2.id })
    else if (can("device connect")) r.button = btn("Try again", "connect", busy === "connect" ? { label: "Connecting…", enabled: false, busy: true } : {})
  } else {
    // A state from a newer engine: its own words, no guess at a button.
    r.key = "other"
    r.headline = String(s.summary.line || state)
  }
  // The button already opens Setup on that row: the sentence would only say
  // it twice.
  if (r.button && r.button.action === "fix" && r.sentence && r.button.rowId !== ""
      && r.sentence.linkRoute === "setup:" + r.button.rowId) r.sentence = null
  return r
}
