.pragma library

// Short fact lines that more than one view prints (plan-gui.md §5.1, §7.6), so
// the Overview and the notch's compact view word them the same way. Pure
// functions of the E§5 document; nothing here decides a state.

// "41 °C · 3% busy · 500 MB VRAM", from status.gpu; "" when the card says
// nothing (not bound, or nvidia-smi did not answer).
function now(gpu) {
  var g = gpu || {}
  var parts = []
  if (g.temp_c !== null && g.temp_c !== undefined) parts.push(Math.round(g.temp_c) + " °C")
  if (g.util_pct !== null && g.util_pct !== undefined) parts.push(Math.round(g.util_pct) + "% busy")
  if (g.mem_used_mb !== null && g.mem_used_mb !== undefined) parts.push(Math.round(g.mem_used_mb) + " MB VRAM")
  return parts.join(" · ")
}

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

// Which one primary action the phase offers (§5.1, §7.6), before any
// capability gate: "connect", "eject", "reconnect" or "". Connect also covers
// `ready` with a KMS module missing, which the Overview offers too. `bound`
// offers both in §5.1; with room for one, finishing the connect wins (Safe
// eject stays one tap away in the full panel).
function primaryAction(status) {
  if (!status) return ""
  // A backend the engine detects but does not implement (the amdgpu/intel
  // stubs) answers every device verb with backend_stub: no button.
  if (status.backend && status.backend.name !== null && status.backend.name !== undefined
      && status.backend.supported === false) return ""
  var phase = String(status.phase || "")
  if (phase === "plugged" || phase === "authorized" || phase === "bound") return "connect"
  if (phase === "ready") {
    var m = status.driver && status.driver.modules ? status.driver.modules : {}
    for (var k in m) if (m[k] === false) return "connect"
    return "eject"
  }
  if (phase === "ejected") return "reconnect"
  return ""
}
