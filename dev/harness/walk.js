.pragma library

// The tree walk behind dev/harness/ui-gallery.qml and ui-walk.qml: plain JS
// over `children`, no Qt types, so both harnesses count the same things.

function name(item) { return String(item).replace(/\(0x[0-9a-f]+\)$/, "") }

function isText(item) {
  return typeof item.text === "string" && item.font !== undefined && item.contentWidth !== undefined
}

// Every item under `root` that can be seen: visible, with some opacity left
// after its parents'. Each record: {item, path, opacity}.
function collect(root) {
  var out = []
  function visit(item, path, opacity) {
    var op = opacity * (item.opacity === undefined ? 1 : item.opacity)
    if (item.visible === false || op <= 0) return
    var here = path + "/" + name(item)
    out.push({ item: item, path: here, opacity: op })
    for (var i = 0; i < item.children.length; i++) visit(item.children[i], here, op)
  }
  visit(root, "", 1)
  return out
}

function alphaBetween(c) { return c !== undefined && c !== null && typeof c === "object" && c.a > 0 && c.a < 1 }

// Contract 1 forbids translucency: any colour, border, gradient, layer effect
// or opacity that leaves a visible item part-transparent. A colour of alpha 0
// paints nothing and is not translucent.
function translucent(root) {
  var found = []
  collect(root).forEach(function(r) {
    var it = r.item
    var why = []
    if (it.opacity !== undefined && it.opacity > 0 && it.opacity < 1) why.push("opacity " + it.opacity)
    if (it.color !== undefined && alphaBetween(it.color)) why.push("colour alpha " + it.color.a.toFixed(2))
    if (it.border !== undefined && it.border.width > 0 && alphaBetween(it.border.color)) why.push("border alpha " + it.border.color.a.toFixed(2))
    if (it.gradient !== undefined && it.gradient !== null) why.push("gradient")
    if (it.layer !== undefined && it.layer.enabled) why.push("layer effect")
    if (why.length) found.push(r.path + ": " + why.join(", "))
  })
  return found
}

// A Text's painted rectangle in `scene` coordinates (the content, not the item).
function textRect(item, scene) {
  var w = Math.min(item.contentWidth, item.width), h = Math.min(item.contentHeight, item.height)
  var dx = 0, dy = 0
  var ha = item.horizontalAlignment
  if (ha === 2 || ha === 4) dx = (item.width - w) / (ha === 2 ? 1 : 2)   // AlignRight 2, AlignHCenter 4
  var va = item.verticalAlignment
  if (va === 64) dy = (item.height - h) / 2                               // AlignVCenter 128? set below
  if (va === 128) dy = (item.height - h) / 2
  if (va === 32) dy = item.height - h
  var p = item.mapToItem(scene, dx, dy)
  return { x: p.x, y: p.y, w: w, h: h }
}

function pixelSize(font) {
  if (font.pixelSize > 0) return font.pixelSize
  return font.pointSize * 96 / 72
}

// Animations (and anything else with `running` and `loops`) under `root`,
// searched through `data`, which holds the non-visual children too.
function loops(root) {
  var found = []
  function visit(obj, path) {
    var here = path + "/" + name(obj)
    if (obj.running === true && obj.loops !== undefined && obj.loops !== 1) found.push(here + " (loops " + obj.loops + ")")
    var kids = obj.data
    if (kids) for (var i = 0; i < kids.length; i++) visit(kids[i], here)
  }
  visit(root, "")
  return found
}
