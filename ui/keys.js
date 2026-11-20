.pragma library

// The key map (plan-apple-ui.md 4.2 "Keys"), as pure functions, so node can
// test what the components do with a key (dev/tests/keys.mjs).
//
// Two halves:
//
//   action(role, key)   what a key means to one kind of control: "activate",
//                       "toggle", "inc", "dec", "prev", "next", "first", "last",
//                       "open", "commit", "search", or "none"
//   a registry          who answers Esc. Esc closes, in order: an edit in
//                       progress, a tip, an open pick, a modal (a confirm), then
//                       goes back one step, then closes. UKeys.qml joins this
//                       registry and the page-level UKeys routes the press.
//
// Qt key codes are used as numbers so this file needs no Qt (Qt.Key_*).

var KEY = {
  Escape: 0x01000000, Tab: 0x01000001, Backtab: 0x01000002, Backspace: 0x01000003,
  Return: 0x01000004, Enter: 0x01000005, Home: 0x01000010, End: 0x01000011,
  Left: 0x01000012, Up: 0x01000013, Right: 0x01000014, Down: 0x01000015,
  Space: 0x20, Slash: 0x2f
}

// Highest priority first. "edit" is a field with an unsaved change.
var LAYERS = ["edit", "tip", "pick", "modal", "back"]

// `open` maps a layer name to whether it is open; the answer is the layer Esc
// goes to, or "close" when nothing is open and the panel itself should leave.
function escapeTarget(open) {
  for (var i = 0; i < LAYERS.length; i++) if (open && open[LAYERS[i]]) return LAYERS[i]
  return "close"
}

function createRegistry() {
  var entries = {}
  var next = 1
  return {
    // join(layer, open, fire) -> id. `fire` is called when Esc lands on the layer.
    join: function(layer, open, fire) {
      if (LAYERS.indexOf(layer) === -1) throw new Error("not a key layer: " + layer)
      var id = next++
      entries[id] = { layer: layer, open: !!open, fire: fire }
      return id
    },
    set: function(id, open) { if (entries[id]) entries[id].open = !!open },
    leave: function(id) { delete entries[id] },
    // Esc: fire the top open layer (the newest one of a layer, if several);
    // "close" when there is none, for the caller to emit its own closeRequested.
    escape: function() {
      var best = null
      for (var id in entries) {
        var e = entries[id]
        if (!e.open) continue
        var rank = LAYERS.indexOf(e.layer)
        if (best === null || rank < best.rank || (rank === best.rank && Number(id) > best.id)) best = { rank: rank, id: Number(id), e: e }
      }
      if (!best) return "close"
      best.e.fire()
      return best.e.layer
    },
    openLayers: function() {
      var out = {}
      for (var id in entries) if (entries[id].open) out[entries[id].layer] = true
      return out
    }
  }
}

// One registry per importing plugin: a pragma-library module is one instance per URL.
var shared = createRegistry()

function pressed(key, which) {
  return which.indexOf(key) !== -1
}

// What `key` means to a control of kind `role`:
//   button | switch | stepper | segmented | pick | pickOpen | field | list
// Enter and Space activate; Space toggles a switch; Up/Down move through a
// list; Left/Right step a stepper or a segmented control or open a pick; "/"
// searches a list past a screenful. Tab is the toolkit's.
function action(role, key) {
  var go = pressed(key, [KEY.Return, KEY.Enter])
  var space = key === KEY.Space
  switch (role) {
  case "button": return go || space ? "activate" : "none"
  case "switch": return go || space ? "toggle" : "none"
  case "stepper":
    if (key === KEY.Left) return "dec"
    if (key === KEY.Right) return "inc"
    return "none"
  case "segmented":
    if (key === KEY.Left) return "prev"
    if (key === KEY.Right) return "next"
    return go || space ? "activate" : "none"
  case "pick":
    return go || space || key === KEY.Right || key === KEY.Down ? "open" : "none"
  case "pickOpen":
    if (key === KEY.Up) return "prev"
    if (key === KEY.Down) return "next"
    if (key === KEY.Home) return "first"
    if (key === KEY.End) return "last"
    return go || space ? "activate" : "none"
  case "field": return go ? "commit" : "none"
  case "list":
    if (key === KEY.Up) return "prev"
    if (key === KEY.Down) return "next"
    if (key === KEY.Home) return "first"
    if (key === KEY.End) return "last"
    if (key === KEY.Slash) return "search"
    return go ? "activate" : "none"
  }
  return "none"
}

// A step of `delta` from `value`, held in [from, to]; the control does not wrap.
function step(value, delta, from, to) { return Math.max(from, Math.min(to, value + delta)) }
