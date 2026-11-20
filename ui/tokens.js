.pragma library

// The kit's tokens, and the one place a colour is worked out.
//
// Everything a component reads from `UTheme` is decided here, as pure
// functions, so node can test the exact code the shell runs
// (dev/tests/contrast.mjs): every role pair, in every mode, on any surface.
//
// A colour in this file is {r, g, b, a}, each 0..1. `parse` takes that, a
// "#rrggbb" string or a "#aarrggbb" string (Qt's order: alpha first); `hex`
// gives it back.
//
// Modes (plan-apple-ui.md 5.2):
//   standalone  surface, foreground and accent from Omarchy's palette, alpha fills
//   hosted      contract 1: only what the notch hands over, and every colour
//               OPAQUE (states and elevation are tints worked out here, never a
//               translucent item)
//   styled      contract 2: the kit's own roles and alpha fills over the notch's
//               surface; the guard may drop the panel back to `hosted`
//
// Contrast has one body: WCAG 2.x relative luminance, identical to
// omarchy-notch Bar.qml (`luminance`/`contrast`, "colours on the notch"), which
// plan-surface-v2.md moves into panelstyle.js. dev/tests/contrast.mjs checks
// this copy against that source when a notch checkout is beside this one.

// Bumped on a breaking change to the kit's API; sync-ui.sh writes it into ui/KIT.
var MAJOR = 1

// ---------------------------------------------------------------- colour

function parse(c) {
  if (c && typeof c === "object") {
    return { r: Number(c.r), g: Number(c.g), b: Number(c.b), a: c.a === undefined ? 1 : Number(c.a) }
  }
  var s = String(c).replace(/^\s+|\s+$/g, "")
  var short = /^#([0-9a-fA-F])([0-9a-fA-F])([0-9a-fA-F])$/.exec(s)
  if (short) s = "#" + short[1] + short[1] + short[2] + short[2] + short[3] + short[3]
  var m = /^#([0-9a-fA-F]{6})$/.exec(s)
  if (m) return { r: parseInt(m[1].substr(0, 2), 16) / 255, g: parseInt(m[1].substr(2, 2), 16) / 255, b: parseInt(m[1].substr(4, 2), 16) / 255, a: 1 }
  m = /^#([0-9a-fA-F]{8})$/.exec(s)
  if (m) return { a: parseInt(m[1].substr(0, 2), 16) / 255, r: parseInt(m[1].substr(2, 2), 16) / 255, g: parseInt(m[1].substr(4, 2), 16) / 255, b: parseInt(m[1].substr(6, 2), 16) / 255 }
  throw new Error("not a colour: " + c)
}

function byte(v) { return Math.max(0, Math.min(255, Math.round(v * 255))) }
function two(n) { return (n < 16 ? "0" : "") + n.toString(16) }

function hex(c) {
  c = parse(c)
  var rgb = two(byte(c.r)) + two(byte(c.g)) + two(byte(c.b))
  return c.a >= 1 ? "#" + rgb : "#" + two(byte(c.a)) + rgb
}

function rgba(r, g, b, a) { return { r: r, g: g, b: b, a: a === undefined ? 1 : a } }

// `top` composited over `bottom`. Opaque when `bottom` is.
function over(top, bottom) {
  top = parse(top); bottom = parse(bottom)
  var a = top.a + bottom.a * (1 - top.a)
  if (a <= 0) return rgba(0, 0, 0, 0)
  function ch(t, b) { return (t * top.a + b * bottom.a * (1 - top.a)) / a }
  return rgba(ch(top.r, bottom.r), ch(top.g, bottom.g), ch(top.b, bottom.b), a)
}

// `fg` at alpha `a` over `bg`: the solid colour a tint comes to.
function mix(bg, fg, a) {
  fg = parse(fg)
  return over(rgba(fg.r, fg.g, fg.b, a), bg)
}

// WCAG 2.x, the body of omarchy-notch Bar.qml:1558-1566.
function luminance(value) {
  var c = parse(value)
  function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

function contrast(a, b) {
  var la = luminance(a), lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

var WHITE = rgba(1, 1, 1, 1)
var BLACK = rgba(0, 0, 0, 1)

function extreme(against) { return contrast(WHITE, against) >= contrast(BLACK, against) ? WHITE : BLACK }

var TEXT = 4.5   // text, no large-text relaxation
var MARK = 3     // a control's fill or border, an icon, a ring, a progress fill

// The colour moved toward whichever of white and black contrasts more with
// `against` (white if tied), one 8-bit step at a time, each channel rounded
// away from where it started, stopping at the first step that reaches
// `floor`; a colour that already passes comes back unchanged. The better
// extreme always reaches 4.58:1 on any backdrop, so this ends. This is the
// `lift` of plan-surface-v2.md section 2, for a panel with no host to ask.
function lift(color, against, floor) {
  var bg = parse(against)
  var c = over(color, bg)   // a translucent colour is judged as it lands on the backdrop
  if (contrast(c, bg) >= floor) return rgba(c.r, c.g, c.b, 1)
  var t = extreme(bg)
  var from = [byte(c.r), byte(c.g), byte(c.b)], to = [byte(t.r), byte(t.g), byte(t.b)]
  for (var k = 1; k <= 255; k++) {
    var out = []
    for (var i = 0; i < 3; i++) {
      var v = from[i] + (to[i] - from[i]) * k / 255
      out.push((to[i] >= from[i] ? Math.ceil(v - 1e-9) : Math.floor(v + 1e-9)) / 255)
    }
    var next = rgba(out[0], out[1], out[2], 1)
    if (contrast(next, bg) >= floor) return next
  }
  return t
}

// Smallest alpha (0.01 steps) at which `fg` tinted over `bg` is `ratio` clear
// of `bg`; 1 when even the full colour is not.
function markAlpha(bg, fg, ratio, least) {
  for (var a = Math.round((least || 0) * 100); a <= 100; a++)
    if (contrast(mix(bg, fg, a / 100), bg) >= ratio) return a / 100
  return 1
}

// Largest alpha (0.01 steps) up to `limit` at which `ink` still reads on `bg`
// tinted with `tint`: a fill may not eat the text that sits on it.
function capAlpha(bg, ink, tint, ratio, limit) {
  for (var a = Math.round(limit * 100); a > 0; a--)
    if (contrast(ink, mix(bg, tint, a / 100)) >= ratio) return a / 100
  return 0
}

// ---------------------------------------------------------------- tokens

// The named spacing scale: every gap, margin and inset a component draws is one
// of these (UTheme.sp.<name>, each through Style.space, so it follows the user's
// spacing scale). One scale for both densities; density changes row height only.
var SPACING = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 }
var SPACE = [SPACING.xs, SPACING.sm, SPACING.md, SPACING.lg, SPACING.xl, SPACING.xxl]   // the grid, smallest first; hairline is 1
var HAIRLINE = 1
var MIN_HIT = 24                 // px, any hit target
var SWITCH = { height: 22, width: 42 }
var MIN_TEXT = 11                // px, nothing smaller is ever drawn
var TIP_MAX = 60                 // characters in a tip or a confirm sentence

var DENSITY = {
  notch: { row: 30, body: "body" },            // Style.font.body, 12 at the default size
  standalone: { row: 32, body: "subtitle" }    // Style.font.subtitle, 13
}

// The warning colour when the palette has none to hand over: a plain amber,
// a fallback default only (the colour is worked out from whatever is handed in,
// and repaired to 4.5:1 like every other text colour).
var WARNING_DEFAULT = "#e0a030"

// How much of secondary stays when metadata is eased back toward the surface.
var METADATA_EASE = 0.6

// The fills a control is drawn with: the label colour tinted over the surface.
var ALPHA = { fill: 0.04, hover: 0.08, selected: 0.18, pressed: 0.22, raised: 0.08, hairline: 0.4 }

// Motion (swiftui-animation-lessons.md). `damping` and `peakAt` go to
// Spring.curve; the overshoot each gives is Spring.overshoot(damping).
var MOTION = {
  arrive:    { damping: 0.72, peakAt: 0.6,  ms: 350 },   // anything that grows or arrives
  control:   { damping: 0.85, peakAt: 0.55, ms: 200 },   // a control settling on release
  celebrate: { damping: 0.60, peakAt: 0.6,  ms: 450 },   // one use: "All set"
  exit:      { ms: 180 },                                // OutCubic, never overshoots
  fade:      { out: 90, in: 150 },
  press:     { scale: 0.97, ms: 60 },
  stagger:   { ms: 40, cap: 240 },
  focus:     { ms: 90 },
  ring:      { ms: 900 }                                 // linear, the indeterminate ring
}

// How long a stagger of `n` siblings runs, and the delay of sibling `i`.
function staggerDelay(i) { return Math.min(i * MOTION.stagger.ms, MOTION.stagger.cap) }

// Reduced motion: OMARCHY_REDUCED_MOTION=1, with NOTCH_REDUCED_MOTION=1 as an
// alias the notch also reads. `env` is a lookup from name to string.
function reducedFrom(env) {
  function on(v) { return v === "1" || String(v).toLowerCase() === "true" }
  return on(env("OMARCHY_REDUCED_MOTION")) || on(env("NOTCH_REDUCED_MOTION"))
}

// ---------------------------------------------------------------- roles

// Every colour the components use, for one mode.
//
//   p.mode        "standalone" | "hosted" | "styled"
//   p.surface     what the panel sits on (host.color; Omarchy's background)
//   p.foreground  the label colour
//   p.secondary   optional; else the label at 60 %
//   (metadata, the third text level, is worked out from secondary: see below)
//   p.accent      optional; else the label colour
//   p.urgent      optional; red
//   p.warning     optional; amber. Standalone and styled fall back to WARNING_DEFAULT;
//                 a hosted-opaque panel with none handed over uses the label (as for
//                 destructive: colour only where the panel owns its colours)
//   p.focusAlpha  optional; Style.focusBorderAlpha
//
// Whatever is handed in is repaired to the floors, not trusted: label and
// secondary to 4.5:1, accent marks to 3:1, accent text to 4.5:1. Fills are
// capped so the text on them keeps 4.5:1. A colour that already passes is
// returned unchanged.
function roles(p) {
  var mode = p.mode || "standalone"
  var opaque = mode === "hosted"
  var S = parse(p.surface); S = rgba(S.r, S.g, S.b, 1)

  var label = lift(p.foreground !== undefined ? p.foreground : extreme(S), S, TEXT)   // lift flattens a translucent colour over S

  // Fills: the label tinted over the surface, capped so the label keeps 4.5:1 on each.
  var capLabel = capAlpha(S, label, label, TEXT, 1)
  var a = {
    fill: Math.min(ALPHA.fill, capLabel), hover: Math.min(ALPHA.hover, capLabel),
    selected: Math.min(ALPHA.selected, capLabel), pressed: Math.min(ALPHA.pressed, capLabel),
    raised: Math.min(ALPHA.raised, capLabel)
  }
  function tint(alpha) { return opaque ? mix(S, label, alpha) : rgba(label.r, label.g, label.b, alpha) }
  // The backdrops quiet text sits on: the surface, and the surface under each fill it can meet.
  var backs = [S, mix(S, label, a.fill), mix(S, label, a.hover), mix(S, label, a.raised)]
  // `c` made to read on all of them; on a mid-tone nothing but the label itself can, and then it is the label.
  function legible(c, floor) {
    c = over(c, S)
    for (var i = 0; i < backs.length; i++) c = lift(c, backs[i], floor)
    for (i = 0; i < backs.length; i++) if (contrast(c, backs[i]) < floor) return label
    return c
  }

  var secondary = legible(p.secondary !== undefined ? p.secondary : mix(S, label, 0.6), TEXT)
  // The third text level (tips, codes, "set by the installer"): secondary eased
  // back toward the surface, then lifted to the same 4.5:1 floor, so it is the
  // quietest text that still reads. Never louder than secondary; where the
  // floor leaves no room (a mid-tone surface) it is secondary, or the label.
  var metadata = legible(mix(S, secondary, METADATA_EASE), TEXT)
  if (contrast(metadata, S) > contrast(secondary, S)) metadata = secondary
  var accent = p.accent !== undefined ? over(p.accent, S) : label
  var accentMark = lift(accent, S, MARK)
  var accentText = legible(accent, TEXT)
  // Red is for destructive and errors, and only where the panel owns its colours.
  var destructive = opaque || p.urgent === undefined ? label : legible(p.urgent, TEXT)

  // Warning, the middle of info (label) and error (destructive): a mark and a word are what
  // tell it apart where there is no colour to use.
  var warningBase = p.warning !== undefined ? p.warning : (opaque ? undefined : WARNING_DEFAULT)
  var warning = warningBase === undefined ? label : legible(warningBase, TEXT)

  var hairlineA = Math.max(ALPHA.hairline, markAlpha(S, label, MARK))
  var ringA = Math.max(p.focusAlpha !== undefined ? Number(p.focusAlpha) : 0.25, markAlpha(S, label, MARK))
  var knobOn = extreme(accentMark)

  return {
    mode: mode, opaque: opaque,
    surface: S,
    label: label, secondary: secondary, metadata: metadata,
    accent: accentMark, accentText: accentText, destructive: destructive, warning: warning,
    fill: tint(a.fill), hover: tint(a.hover), selected: tint(a.selected), pressed: tint(a.pressed),
    // Level 2 floats over content (a tip, a toast, an open pick): a solid colour in every mode, or the text behind would show through.
    raised: mix(S, label, a.raised),
    hairline: tint(hairlineA), ring: tint(ringA),
    trackOn: accentMark, knobOn: knobOn,
    trackOff: tint(a.fill), knobOff: secondary,
    // Text that cannot be used right now: exempt from contrast (WCAG 1.4.3), opaque in every mode.
    disabled: mix(S, label, 0.38),
    alphas: a, hairlineAlpha: hairlineA, ringAlpha: ringA
  }
}

// Alpha of a role colour, for the "no translucent item" count.
function translucent(c) { c = parse(c); return c.a > 0 && c.a < 1 }

// Every role pair the components draw: {name, role: "text" | "ui", fg, bg: [..]}.
// `bg` colours may be translucent; they are laid over `surface` when measured.
function pairs(r) {
  return [
    { name: "label on surface",           role: "text", fg: r.label,       bg: [r.surface] },
    { name: "secondary on surface",       role: "text", fg: r.secondary,   bg: [r.surface] },
    { name: "label on fill",              role: "text", fg: r.label,       bg: [r.fill, r.hover, r.selected, r.pressed, r.raised] },
    { name: "secondary on fill",          role: "text", fg: r.secondary,   bg: [r.fill, r.hover, r.raised] },
    { name: "metadata on surface",        role: "text", fg: r.metadata,     bg: [r.surface] },
    { name: "metadata on fill",           role: "text", fg: r.metadata,     bg: [r.fill, r.hover, r.raised] },
    { name: "accent text on surface",     role: "text", fg: r.accentText,  bg: [r.surface, r.hover] },
    { name: "destructive on surface",     role: "text", fg: r.destructive, bg: [r.surface, r.hover, r.fill] },
    { name: "warning on surface",         role: "text", fg: r.warning,     bg: [r.surface, r.hover, r.fill] },
    { name: "accent mark on surface",     role: "ui",   fg: r.accent,      bg: [r.surface] },
    { name: "hairline on surface",        role: "ui",   fg: r.hairline,    bg: [r.surface] },
    { name: "focus ring on surface",      role: "ui",   fg: r.ring,        bg: [r.surface] },
    { name: "switch on: track on surface", role: "ui",  fg: r.trackOn,     bg: [r.surface] },
    { name: "switch on: knob on track",   role: "ui",   fg: r.knobOn,      bg: [r.trackOn] },
    { name: "switch off: knob on track",  role: "ui",   fg: r.knobOff,     bg: [r.trackOff] }
  ]
}

// Measure every pair: the worst ratio over its backgrounds, against its floor.
function check(r) {
  return pairs(r).map(function(p) {
    var worst = Infinity
    p.bg.forEach(function(bg) {
      var flat = over(bg, r.surface)
      var fg = over(p.fg, flat)
      worst = Math.min(worst, contrast(fg, flat))
    })
    var floor = p.role === "text" ? TEXT : MARK
    return { name: p.name, role: p.role, ratio: worst, floor: floor, pass: worst >= floor - 1e-9 }
  })
}

// Corner radius for a control `h` px tall: the host's, never more than half.
function radius(hostRadius, h) { return Math.max(0, Math.min(Number(hostRadius) || 0, h / 2)) }
