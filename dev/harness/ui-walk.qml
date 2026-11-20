import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "repo/ui"
import "repo/ui/tokens.js" as Tokens
import "walk.js" as Walk

// The consistency walk (plan-apple-ui.md 6.2, rule 5): loads a root item with
// a fake surfaceHost and walks `children` recursively. Run by dev/check-ui.sh
// (and dev/walk.sh) under Quickshell, offscreen, like ui-gallery.qml. One
// per plugin root: a plugin's adapter is the file named by UI_WALK_ROOT, any
// QML file with a `theme` property.
//
// Checks, each printed as `WALK <name> pass|FAIL ...`:
//   names      every item with activeFocusOnTab, or a button or checkbox role,
//              has a non-empty Accessible.name
//   hit        every such item is at least 24 px both ways; a primary UButton is
//              at least the density row height tall
//   text       no Text or TextInput under 11 px
//   contrast   every text against its background, measured from the RENDERED
//              PIXELS at least 4.5:1 (see `measure` below)
//   loops      with reduced motion on, no Animation with running and loops != 1: no declared
//              animation like that, and (because a `Foo on prop` animation is not in `data`)
//              two renders 300 ms apart, a second and a half in, are identical
//   opaque     (hosted mode only) not one translucent item: no colour, border,
//              opacity, gradient or layer effect that leaves a visible item part-transparent
//
// The pixel clause. Two grabs of the root: A as drawn; B with every Text and
// TextInput at opacity 0 (opacity, not `visible`, so nothing re-lays out). For a
// text, over the rectangle its glyphs occupy: the ink is the pixel of A that
// differs most in luminance from B at the same place (the glyph core); the
// backdrop is every pixel of B under the box of all pixels that differ, one
// pixel around it, and the ratio is the ink against the WORST of them. A text whose ink does not differ from B at all is
// invisible and measures 1:1. Contrast is tokens.js `contrast`, the one body.
// Anti-aliasing: a stroke thinner than a pixel never reaches full coverage, so
// the ink is a blend and the ratio reads low; the clause allows AA_TOLERANCE
// (below) under 4.5 for it. Disabled text is exempt (WCAG 1.4.3).
//
// Environment: UI_WALK_ROOT (default dev/gallery.qml, relative to the repo),
// UI_WALK_MODE (standalone | hosted | styled), UI_WALK_HOST (black | white),
// UI_WALK_REDUCED=1, UI_WALK_THEME.
ShellRoot {
  id: shell

  readonly property string rootFile: Quickshell.env("UI_WALK_ROOT") || "dev/gallery.qml"
  readonly property string mode: Quickshell.env("UI_WALK_MODE") || "standalone"
  readonly property string hostKind: Quickshell.env("UI_WALK_HOST") || "black"
  readonly property string themeName: Quickshell.env("UI_WALK_THEME") || "current"
  readonly property real aaTolerance: 0.5

  property int failures: 0
  function say(key, value) { console.log("WALK " + key + " " + value) }
  function report(name, bad, detail) {
    if (bad.length === 0) say(name, "pass " + detail)
    else { failures++; say(name, "FAIL " + bad.length + " of " + detail); bad.slice(0, 8).forEach(function(b) { say(name + "-item", b) }) }
  }

  FileView {
    id: colors
    blockLoading: true
    path: shell.themeName === "current"
      ? Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
      : "/usr/share/omarchy/themes/" + shell.themeName + "/colors.toml"
  }
  Component.onCompleted: Commons.Color.loadColors(colors.text())

  QtObject {
    id: fakeHost
    readonly property bool black: shell.hostKind !== "white"
    readonly property color color: black ? "#000000" : "#ffffff"
    readonly property color foreground: black ? "#ffffff" : "#000000"
    readonly property color secondary: black ? "#99EBEBF5" : "#993C3C43"
    readonly property color accent: foreground
    readonly property real radius: 10
    readonly property string fontFamily: Commons.Style.font.family
    readonly property bool styled: shell.mode === "styled"
    function radiusFor(size) { return Math.max(0, Math.min(radius, size / 2)) }
  }
  UTheme {
    id: theme
    host: shell.mode === "standalone" ? null : fakeHost
    reducedOverride: Quickshell.env("UI_WALK_REDUCED") === "1" ? true : undefined
  }

  Window {
    id: win
    visible: true
    width: loader.item ? Math.max(1, Math.ceil(loader.item.implicitWidth)) : 800
    height: loader.item ? Math.max(1, Math.ceil(loader.item.implicitHeight)) : 600
    color: theme.surface

    Rectangle {
      id: scene
      width: win.width
      height: win.height
      color: theme.surface
      Loader {
        id: loader
        Component.onCompleted: setSource("repo/" + shell.rootFile, { theme: theme })
      }
    }

    // The readback: an Image of each grab, drawn into a Canvas, read with getImageData.
    Image { id: img; cache: false; visible: false }
    Canvas {
      id: canvas
      x: win.width + 1
      width: scene.width
      height: scene.height
      renderTarget: Canvas.Image
      renderStrategy: Canvas.Immediate
      property bool wanted: false
      onPaint: {
        if (!wanted || img.status !== Image.Ready) return
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.drawImage(img, 0, 0)
        shell.pixels = ctx.getImageData(0, 0, width, height)
        wanted = false
        shell.pixelsReady()
      }
    }
  }

  property var pixels: null
  property var declaredLoops: []
  signal pixelsReady()
  function read(done) {   // read(function(imageData) {...}): grab the scene, hand back its pixels
    scene.grabToImage(function(result) {
      shell.pixelsReady.connect(function once() { shell.pixelsReady.disconnect(once); done(shell.pixels) })
      img.source = result.url
      canvasKick.restart()
    })
  }
  Timer { id: canvasKick; interval: 60; onTriggered: { canvas.wanted = true; canvas.requestPaint() } }

  readonly property var scene: win.contentItem.children[0]

  function lumAt(d, i) { return Tokens.luminance({ r: d.data[i] / 255, g: d.data[i + 1] / 255, b: d.data[i + 2] / 255 }) }
  function rgbAt(d, i) { return { r: d.data[i] / 255, g: d.data[i + 1] / 255, b: d.data[i + 2] / 255 } }

  function structural(root, records) {
    var Role = { Button: Accessible.Button, CheckBox: Accessible.CheckBox }
    var focusable = records.filter(function(r) {
      var it = r.item
      return it.activeFocusOnTab === true || it.Accessible.role === Role.Button || it.Accessible.role === Role.CheckBox
    })
    report("names", focusable.filter(function(r) { return !r.item.Accessible.name }).map(function(r) { return r.path }),
           focusable.length + " focusable or button items")
    report("hit", focusable.filter(function(r) {
      var it = r.item
      var small = it.width < theme.minHit || it.height < theme.minHit
      var shortPrimary = it.kind === "primary" && it.height < theme.rowHeight
      return small || shortPrimary
    }).map(function(r) { return r.path + " " + Math.round(r.item.width) + "x" + Math.round(r.item.height) }),
           focusable.length + " items, minimum " + theme.minHit + " px, primary " + theme.rowHeight + " px")
    var texts = records.filter(function(r) { return Walk.isText(r.item) && r.item.text !== "" })
    report("text", texts.filter(function(r) { return Walk.pixelSize(r.item.font) < Tokens.MIN_TEXT }).map(function(r) { return r.path + " " + Walk.pixelSize(r.item.font) + " px" }),
           texts.length + " texts, minimum " + Tokens.MIN_TEXT + " px")
    declaredLoops = theme.reduced ? Walk.loops(root) : []
    if (theme.mode === "hosted-opaque") report("opaque", Walk.translucent(root), "hosted: no translucent item")
    else say("opaque", "skip (" + theme.mode + " may use alpha)")
  }

  function contrastOf(texts, a, b) {
    var bad = [], worstAll = Infinity, n = 0
    texts.forEach(function(r) {
      var rc = Walk.textRect(r.item, scene)
      var x0 = Math.max(0, Math.floor(rc.x)), y0 = Math.max(0, Math.floor(rc.y))
      var x1 = Math.min(a.width, Math.ceil(rc.x + rc.w)), y1 = Math.min(a.height, Math.ceil(rc.y + rc.h))
      if (x1 <= x0 || y1 <= y0) return
      // The ink: the pixel of A that differs most from B. Its box: every pixel that differs at all.
      var inkI = -1, inkDiff = -1, bx0 = x1, by0 = y1, bx1 = x0, by1 = y0
      for (var y = y0; y < y1; y++) for (var x = x0; x < x1; x++) {
        var i = (y * a.width + x) * 4
        var diff = Math.abs(lumAt(a, i) - lumAt(b, i))
        if (diff > inkDiff) { inkDiff = diff; inkI = i }
        if (diff > 0.01) { bx0 = Math.min(bx0, x); by0 = Math.min(by0, y); bx1 = Math.max(bx1, x + 1); by1 = Math.max(by1, y + 1) }
      }
      // The backdrop is B under that box and one pixel around it, not the whole line box of the text.
      var ink = rgbAt(a, inkI), ratio = Infinity
      bx0 = Math.max(x0, bx0 - 1); by0 = Math.max(y0, by0 - 1); bx1 = Math.min(x1, bx1 + 1); by1 = Math.min(y1, by1 + 1)
      for (y = by0; y < by1; y++) for (x = bx0; x < bx1; x++) {
        var j = (y * a.width + x) * 4
        ratio = Math.min(ratio, Tokens.contrast(ink, rgbAt(b, j)))
      }
      if (inkDiff < 0.01) ratio = 1
      n++
      worstAll = Math.min(worstAll, ratio)
      r.ratio = ratio
      if (ratio < Tokens.TEXT - aaTolerance) bad.push(r.path + " \"" + r.item.text.slice(0, 24) + "\" " + ratio.toFixed(2) + ":1")
    })
    var low = texts.filter(function(r) { return r.ratio !== undefined }).sort(function(p, q) { return p.ratio - q.ratio }).slice(0, 3)
    low.forEach(function(r) { say("contrast-lowest", r.ratio.toFixed(2) + ":1 \"" + r.item.text.slice(0, 24) + "\" " + r.path.split("/").slice(-3).join("/")) })
    report("contrast", bad, n + " texts, worst " + (isFinite(worstAll) ? worstAll.toFixed(2) : "n/a") + ":1 (floor 4.5, AA allowance " + aaTolerance + ")")
    return n
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: {
      var root = loader.item
      if (!root) { shell.say("load", "FAIL " + shell.rootFile); Qt.exit(2); return }
      shell.say("root", shell.rootFile)
      shell.say("mode", theme.mode + " " + (shell.mode === "standalone" ? "" : shell.hostKind) + (theme.reduced ? " reduced" : ""))
      var records = Walk.collect(root)
      shell.say("items", records.length)
      structural(root, records)

      // Text exempt from contrast: disabled, or empty.
      var texts = records.filter(function(r) { return Walk.isText(r.item) && r.item.text !== "" && r.item.enabled !== false && r.opacity >= 0.99 })
      shell.read(function(a) {
        // Looping, behaviourally: with reduced motion on, nothing may still be changing a second and a half in.
        // (A `Foo on prop` animation is not in `data`, so the declared-animation search above cannot see it; the pixels can.)
        shell.after(300, function() { shell.read(function(a2) {
          if (theme.reduced) {
            var differing = 0
            for (var i = 0; i < a.data.length; i += 4)
              if (a.data[i] !== a2.data[i] || a.data[i + 1] !== a2.data[i + 1] || a.data[i + 2] !== a2.data[i + 2]) differing++
            var bad = declaredLoops.slice()
            if (differing > 0) bad.push("the frame changed in " + differing + " pixels over 300 ms")
            report("loops", bad, "reduced motion: no declared animation loops, and two frames 300 ms apart are identical")
          } else say("loops", "skip (reduced motion is off)")
          var saved = texts.map(function(r) { return r.item.opacity })
          texts.forEach(function(r) { r.item.opacity = 0 })
          shell.after(200, function() { shell.read(function(b) {
            contrastOf(texts, a, b)
            shell.say("done", "failures=" + shell.failures)
            Qt.exit(shell.failures ? 1 : 0)
          }) })
        }) })
      })
    }
  }
  // after(ms, fn): run fn once, ms from now
  property var pending: null
  function after(ms, fn) { pending = fn; stepTimer.interval = ms; stepTimer.restart() }
  Timer { id: stepTimer; onTriggered: { var f = shell.pending; shell.pending = null; f() } }
  Timer { interval: 20000; running: true; onTriggered: { shell.say("timeout", "FAIL"); Qt.exit(3) } }
}
