.pragma library

// Small readers of the E§5 document that more than one file uses
// (plan-gui.md §5.1, §7.6). Pure functions; nothing here decides a state.

// A list from the document, or []. Not Array.isArray: a document that has
// passed through a QVariantMap (createObject's property map, a Loader's
// initial properties) holds its arrays as QML sequences, for which
// Array.isArray is false although they index and have a length.
function list(v) {
  return v && typeof v === "object" && typeof v.length === "number" ? v : []
}

// The first eGPU monitor that is plugged in (connector status "connected"),
// or null. The compact view's HDMI quick toggle is for this one (§7.6).
function firstMonitor(status) {
  var mons = list(status && status.display ? status.display.monitors : null)
  for (var i = 0; i < mons.length; i++) if (mons[i] && mons[i].status === "connected") return mons[i]
  return null
}
