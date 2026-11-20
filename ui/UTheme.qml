import QtQuick
import Quickshell
import qs.Commons as Commons
import "tokens.js" as Tokens
import "spring.js" as Spring

// What every U component reads, and nothing else.
//
//   UTheme { id: theme; host: surfaceHost }     // once, at the plugin's root
//   UButton { theme: theme; ... }                // passed down, never looked up
//
// Not a singleton: a singleton cannot see a plugin's `surfaceHost`. Three modes
// (plan-apple-ui.md 5.2), chosen by `host`:
//
//   standalone     host null: Omarchy's palette, alpha fills
//   hosted-opaque  host set, host.styled not true (contract 1): colours from the
//                  host only, every one opaque
//   styled         host.styled === true (contract 2): the kit's own roles over the
//                  host's surface; when the notch's guard trips `styled` goes false
//                  and the same bindings fall to hosted-opaque by themselves
//
// All colour decisions are tokens.js `roles`, which node tests in every mode.
QtObject {
  id: root

  property var host: null

  // For tests and the gallery; leave undefined and the host or the environment decides.
  property var reducedOverride: undefined

  readonly property bool hosted: host !== null && host !== undefined
  readonly property bool styled: hosted && host.styled === true
  readonly property string mode: !hosted ? "standalone" : (styled ? "styled" : "hosted-opaque")
  readonly property string density: hosted ? "notch" : "standalone"

  // ---- reduced motion: the host's, else OMARCHY_REDUCED_MOTION (alias NOTCH_REDUCED_MOTION)
  readonly property bool envReduced: Tokens.reducedFrom(function(name) { return Quickshell.env(name) || "" })
  readonly property bool reduced: reducedOverride !== undefined ? reducedOverride === true
    : (hosted && host.reducedMotion !== undefined ? host.reducedMotion === true : envReduced)

  // ---- colour
  readonly property var roles: Tokens.roles({
    mode: !hosted ? "standalone" : (styled ? "styled" : "hosted"),
    surface: hosted ? host.color : Commons.Color.background,
    foreground: hosted ? host.foreground : Commons.Color.foreground,
    secondary: hosted ? host.secondary : undefined,
    accent: hosted && !styled ? host.accent : Commons.Color.accent,
    urgent: hosted && !styled ? undefined : Commons.Color.urgent,
    warning: hosted ? host.warning : undefined,   // a host may hand one over; else amber (standalone, styled) or the label (hosted-opaque)
    focusAlpha: Commons.Style.focusBorderAlpha
  })
  function paint(c) { return Qt.rgba(c.r, c.g, c.b, c.a) }

  readonly property color surface: paint(roles.surface)
  readonly property color label: paint(roles.label)
  readonly property color secondary: paint(roles.secondary)
  readonly property color metadata: paint(roles.metadata)
  readonly property color accent: paint(roles.accent)
  readonly property color accentText: paint(roles.accentText)
  readonly property color destructive: paint(roles.destructive)
  readonly property color warning: paint(roles.warning)
  readonly property color fill: paint(roles.fill)
  readonly property color hover: paint(roles.hover)
  readonly property color selected: paint(roles.selected)
  readonly property color pressed: paint(roles.pressed)
  readonly property color raised: paint(roles.raised)
  readonly property color hairline: paint(roles.hairline)
  readonly property color ring: paint(roles.ring)
  readonly property color trackOn: paint(roles.trackOn)
  readonly property color knobOn: paint(roles.knobOn)
  readonly property color trackOff: paint(roles.trackOff)
  readonly property color knobOff: paint(roles.knobOff)
  readonly property color disabled: paint(roles.disabled)
  readonly property color none: "transparent"

  // [{name, role: "text" | "ui", fg, bg: [colour, ...]}], for a plugin's `palette: theme.pairs`
  // (plan-surface-v2.md section 2: palette is {pairs}) and for the gallery's table.
  readonly property var pairs: Tokens.pairs(roles).map(function(p) {
    return { name: p.name, role: p.role, fg: paint(p.fg), bg: p.bg.map(paint) }
  })
  readonly property var palette: ({ pairs: pairs })

  // ---- type: one family; title, headline (body size, DemiBold), body, footnote
  // Three text levels in it: primary (`label`), secondary (`secondary`: values, captions, section
  // titles) and metadata (`metadata` and `metadataWeight`: tips, codes, small print), by colour and
  // weight as well as size. Every level holds 4.5:1; a face without a Light weight shows Regular.
  readonly property string fontFamily: hosted && host.fontFamily ? host.fontFamily : Commons.Style.font.family
  readonly property int bodySize: Math.max(Tokens.MIN_TEXT, density === "notch" ? Commons.Style.font.body : Commons.Style.font.subtitle)
  readonly property int titleSize: Math.max(bodySize, Commons.Style.font.title)
  readonly property int footnoteSize: Math.max(Tokens.MIN_TEXT, Commons.Style.font.bodySmall)
  readonly property int headlineWeight: Font.DemiBold
  readonly property int titleWeight: Font.DemiBold
  readonly property int metadataWeight: Font.Light

  // ---- size
  readonly property int minHit: Tokens.MIN_HIT
  readonly property int rowHeight: Math.max(Tokens.DENSITY[density].row, bodySize + 2 * sp.sm)
  readonly property int controlHeight: rowHeight - 4
  readonly property int switchWidth: Tokens.SWITCH.width
  readonly property int switchHeight: Tokens.SWITCH.height
  readonly property int hairlineWidth: Tokens.HAIRLINE
  readonly property int tipMax: Tokens.TIP_MAX
  function space(n) { return Commons.Style.space(n) }
  // The named scale (tokens.js SPACING), each through space(): theme.sp.md is 12 at the default scale.
  readonly property QtObject sp: QtObject {
    readonly property int xs: root.space(Tokens.SPACING.xs)
    readonly property int sm: root.space(Tokens.SPACING.sm)
    readonly property int md: root.space(Tokens.SPACING.md)
    readonly property int lg: root.space(Tokens.SPACING.lg)
    readonly property int xl: root.space(Tokens.SPACING.xl)
    readonly property int xxl: root.space(Tokens.SPACING.xxl)
  }
  function radius(h) {
    if (hosted) return typeof host.radiusFor === "function" ? host.radiusFor(h) : Tokens.radius(host.radius, h)
    return Tokens.radius(Commons.Style.cornerRadius, h)
  }

  // ---- motion: springs only for what arrives; OutCubic for what fades or leaves
  readonly property var arriveCurve: Spring.curve(Tokens.MOTION.arrive.damping, Tokens.MOTION.arrive.peakAt, 8)
  readonly property var controlCurve: Spring.curve(Tokens.MOTION.control.damping, Tokens.MOTION.control.peakAt, 8)
  readonly property var celebrateCurve: Spring.curve(Tokens.MOTION.celebrate.damping, Tokens.MOTION.celebrate.peakAt, 8)
  readonly property int arriveMs: reduced ? 0 : Tokens.MOTION.arrive.ms
  readonly property int controlMs: reduced ? 0 : Tokens.MOTION.control.ms
  readonly property int celebrateMs: reduced ? 0 : Tokens.MOTION.celebrate.ms
  readonly property int exitMs: reduced ? 0 : Tokens.MOTION.exit.ms
  // Fades are kept under reduced motion: they carry no movement.
  readonly property int fadeOutMs: Tokens.MOTION.fade.out
  readonly property int fadeInMs: Tokens.MOTION.fade.in
  readonly property int focusMs: Tokens.MOTION.focus.ms
  readonly property real pressScale: reduced ? 1 : Tokens.MOTION.press.scale
  readonly property int pressMs: reduced ? 0 : Tokens.MOTION.press.ms
  readonly property int ringMs: Tokens.MOTION.ring.ms
  function staggerDelay(i) { return reduced ? 0 : Tokens.staggerDelay(i) }

  // The one line a `foot` UTip writes to and a `line` UTip shows.
  property string foot: ""
}
