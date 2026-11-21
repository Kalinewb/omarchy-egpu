.pragma library

// How a state LOOKS, shared by the bar button, the Glance and the panels (plan-gui.md §4, §7.4):
//
//   look(status)   how summary.state reads as a glyph: colour role, badge,
//                  pulse, the short word. The bar button, the notch glance and
//                  notice row all call this one function, so the glance can
//                  never disagree with the bar.
//   tone(theme, role)  a role as a colour of the kit's theme (ui/UTheme.qml).
//
// Colours, sizes, spacing and radii are the kit's (ui/, vendored from
// omarchy-ui): every view is handed one `theme` and reads nothing else, in the
// popup and in the notch alike. The private palette this file used to build
// (`make`, `fromHost`, the spacing tokens) is gone.
//
// Nothing here decides a state. summary.state and summary.line are the
// engine's (plan-engine.md §5); this only maps them to a look.

// nf-md-expansion_card. The installed JetBrainsMono Nerd Font carries it at
// this code point (checked against the font's post table, not a cheat sheet).
var glyph = "\u{f08ae}"
// nf-md-monitor, the "+ HDMI monitor" badge.
var monitorGlyph = "\u{f0379}"

// A palette role (what look() names) as a colour of the kit's theme (ui/UTheme.qml). The notch hands a
// panel its foreground, secondary and accent only, so there every role but secondary is the foreground
// (the kit's warning and destructive roles fall back to the label there): the states differ by word and
// shape (Glance's ring and dot), never by colour alone.
//   secondary  dim            accent, good  the accent as text (accentText: held to 4.5:1)
//   warn       the warning    bad           the destructive role
//   anything else             the label
function tone(theme, role) {
  switch (role) {
  case "secondary": return theme.secondary
  case "accent":
  case "good": return theme.accentText
  case "warn": return theme.warning
  case "bad": return theme.destructive
  default: return theme.label
  }
}

function enabledMonitors(status) {
  // Not Array.isArray: see Facts.js list().
  var raw = status && status.display ? status.display.monitors : null
  var mons = raw && typeof raw === "object" && typeof raw.length === "number" ? raw : []
  var n = 0
  for (var i = 0; i < mons.length; i++) if (mons[i] && mons[i].enabled) n++
  return n
}

// status: the E§5 document or null. unavailable: why there is none (shown as
// the tooltip), from StatusSource.outcomeText.
//
// Returns { state, role, pulse, badge, monitor, word, tooltip }:
//   role    palette key for the glyph: secondary (dim) | foreground | accent | good
//   badge   palette key for the corner dot, or "" for none
//   pulse   a slow fade while something is under way; the caller runs it only
//           while it is on screen (plan-gui.md §7.4)
//   monitor an eGPU monitor is enabled ("+ HDMI monitor", §4)
//   word    the glance's one or two words (§7.4); the bar shows the glyph only
function look(status, unavailable) {
  if (!status || !status.summary) {
    return { state: "unknown", role: "secondary", pulse: false, badge: "", monitor: false, word: "",
             tooltip: "eGPU · " + (unavailable || "no status yet") }
  }
  var s = String(status.summary.state || "")
  var line = String(status.summary.line || "")
  var phase = String(status.phase || "")
  var monitor = enabledMonitors(status) > 0
  var r = { state: s, role: "foreground", pulse: false, badge: "", monitor: false, word: "", tooltip: line }

  if (s === "absent") {
    r.role = "secondary"
  } else if (s === "connecting") {
    r.pulse = true
    r.word = "connecting"
  } else if (s === "ready") {
    r.role = "accent"
    r.word = "ready"
  } else if (s === "in_use") {
    r.role = "accent"
    r.badge = "accent"
    r.monitor = monitor
    var util = status.gpu && Number(status.gpu.util_pct) > 0 ? Math.round(Number(status.gpu.util_pct)) : 0
    r.word = util > 0 ? "in use " + util + "%" : "in use"
  } else if (s === "ejecting") {
    r.pulse = true
    r.word = "ejecting"
  } else if (s === "safe_to_unplug") {
    r.role = "good"
    r.word = "unplug"
  } else if (s === "attention") {
    // The glyph keeps the colour of the phase underneath; the warn dot is what
    // says "look at me" (§4: needs_relogin / held_after_eject / health errors).
    r.role = phase === "ready" ? "accent" : (phase === "ejected" ? "good" : (phase === "absent" ? "secondary" : "foreground"))
    r.badge = "warn"
    r.monitor = monitor
    var relog = (status.display && status.display.needs_relogin) || (status.modules && status.modules.held_after_eject)
    r.word = relog ? "log out" : "check setup"
  } else if (s === "error") {
    r.badge = "bad"
    r.word = "error"
  } else {
    // A state this plugin has never heard of: a newer engine. Shown, never
    // guessed at.
    r.role = "secondary"
    r.badge = "warn"
    r.word = s
  }
  return r
}
