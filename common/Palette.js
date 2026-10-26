.pragma library

// The two things every view and both shells share about how things LOOK
// (plan-gui.md §5.0, §4, §7.4):
//
//   make(p)        §5.0's `palette` object, handed to every view as its
//                  `theme` property (Item already owns the name `palette`;
//                  views/StatusView.qml says why). A shell fills it
//                  from its own theme — the standalone popup from Omarchy's
//                  Color/Style and the bar, the notch from surfaceHost — and a
//                  view reads colours and sizes from it and from nowhere else.
//                  That is what lets one view file render correctly in both:
//                  a view that read Color.accent itself would arrive in the
//                  notch as "dark blue on black" (notch:INTEGRATION-SCOPE.md
//                  P5).
//
//   look(status)   how summary.state reads as a glyph: colour role, badge,
//                  pulse, the short word. The bar button, and later the notch
//                  glance and notice row, all call this one function, so the
//                  glance can never disagree with the bar.
//
// Nothing here decides a state. summary.state and summary.line are the
// engine's (plan-engine.md §5); this only maps them to a look.

// nf-md-expansion_card. The installed JetBrainsMono Nerd Font carries it at
// this code point (checked against the font's post table, not a cheat sheet).
var glyph = "\u{f08ae}"
// nf-md-monitor, the "+ HDMI monitor" badge.
var monitorGlyph = "\u{f0379}"
// nf-md-arrow_left, as omarchy-face's Back button.
var backGlyph = "\u{f004d}"

// Every key a view may read. A shell passes what it has; anything missing is
// derived from foreground so a partial palette still renders legibly.
function make(p) {
  p = p || {}
  var fg = p.foreground !== undefined ? p.foreground : "#cacccc"
  var unit = Number(p.unit) > 0 ? Number(p.unit) : 1
  var font = p.font || {}
  return {
    foreground: fg,
    secondary: p.secondary !== undefined ? p.secondary : fg,
    accent: p.accent !== undefined ? p.accent : fg,
    good: p.good !== undefined ? p.good : (p.accent !== undefined ? p.accent : fg),
    warn: p.warn !== undefined ? p.warn : fg,
    bad: p.bad !== undefined ? p.bad : fg,
    // null in the notch: hosted panels may not paint their own background
    // (notch:SURFACE-HOSTING.md:229-235).
    background: p.background !== undefined ? p.background : null,
    radius: p.radius !== undefined ? Number(p.radius) : 0,
    fontFamily: p.fontFamily || "",
    // Additive to §5.0's list: sizes, so views need no Style either. `unit` is
    // what Style.space(1) is in the standalone shell; views write
    // `palette.unit * 8` where Omarchy's own panels write Style.space(8).
    unit: unit,
    font: {
      caption: Number(font.caption) || 11 * unit,
      body: Number(font.body) || 13 * unit,
      title: Number(font.title) || 15 * unit,
      display: Number(font.display) || 26 * unit,
      icon: Number(font.icon) || 16 * unit
    },
    space: spacing(unit)
  }
}

// The one set of padding tokens (ui-scope.md §0.2, §5). Every view and both
// shells lay out with these and nothing else, so the popup and the notch keep
// the same distance from their edges:
//   inset     the panel's edge to its content, on every side (the shell's)
//   section   between the blocks of a view (headline, button, sentence, …)
//   row       between the rows inside a block
//   rowHeight a row with a control in it (a button, a switch, a Setup row)
// Scaled by `unit`, which is Style.space(1) in the standalone shell.
var SPACE = { inset: 16, section: 12, row: 6, rowHeight: 36 }

function spacing(unit) {
  var u = Number(unit) > 0 ? Number(unit) : 1
  return { inset: SPACE.inset * u, section: SPACE.section * u, row: SPACE.row * u, rowHeight: SPACE.rowHeight * u }
}

// The palette inside the notch (plan-gui.md §5.0, §7.7): every colour from
// `surfaceHost` and nothing else (notch:SURFACE-HOSTING.md:229-235). The host
// hands over foreground, secondary and accent only, and its accent IS its
// foreground (it takes the hue out of everything), so good is the accent and
// warn and bad are the foreground: in the notch the states differ by word and
// shape (Glance's ring and dot), never by colour. No background, and the
// host's radius, which views cap at half the size they round, exactly
// surfaceHost.radiusFor(). Sizes are the shell's (`sizes`: {unit, font}),
// which are not colours. Without a host (never, inside the notch) the
// host's own defaults stand in.
function fromHost(host, sizes) {
  var s = sizes || {}
  var fg = host ? host.foreground : "#ffffff"
  var accent = host ? host.accent : fg
  return make({
    foreground: fg,
    secondary: host ? host.secondary : "#ebebf5",
    accent: accent,
    good: accent,
    warn: fg,
    bad: fg,
    background: null,
    radius: host ? Number(host.radius) : 8,
    fontFamily: host ? String(host.fontFamily || "") : "",
    unit: s.unit,
    font: s.font
  })
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
