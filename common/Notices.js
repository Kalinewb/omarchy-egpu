.pragma library

// Which engine events become a transient notice, and what it says
// (plan-gui.md §7.5). Pure, so dev/g8-offscreen.sh checks it under node too.
//
// Two moments get one: the eGPU was plugged in, and it is safe to unplug.
// A yank (unplugged while in use) is the one warning the event stream can
// already name; it gets a notice as well, marked `warning`, which means the
// plugin's own notification and panel state must show it whatever the notch
// answers (notch:SURFACE-HOSTING.md:321-329, rule 2).
//
// A notice carries state words only: no process names, no account names, no
// enclosure name (notch:SURFACE-HOSTING.md:301-302).

var KEY = "kalinewb.egpu.notice"
var TTL_MS = 8000
var VIEW = "egpu"

// record: {seq, event, at, detail} from StatusSource. status: the document at
// the time. canConnect: whether the engine has `device connect` yet; without
// it "load driver?" would ask a question nothing can answer. glyph: the
// plugin's glyph (Palette.glyph).
//
// Returns null for an event that gets no notice, else
// {key, kind, title, glyph, priority, ttlMs, view, panelRoute, warning, seq}.
function describe(record, status, canConnect, glyph) {
  if (!record) return null
  var ev = String(record.event || "")
  var title = ""
  var warning = false
  if (ev === "plugged") {
    // §7.5 also has "eGPU connected — getting it ready" for when connect.auto
    // will load the driver. The status document does not say that yet (E3
    // adds auto-connect), so the plain sentence stands in for it.
    title = canConnect ? "eGPU connected — load driver?" : "eGPU connected"
  } else if (ev === "eject_ready") {
    title = "Safe to unplug the eGPU"
  } else if (ev === "yanked") {
    title = "eGPU unplugged without ejecting"
    warning = true
  } else {
    return null
  }
  return {
    key: KEY, kind: ev, title: title, glyph: String(glyph || ""),
    priority: "transient", ttlMs: TTL_MS, view: VIEW, panelRoute: "main",
    warning: warning, seq: Number(record.seq) || 0
  }
}

// The claim surfaceHost.claim() is given for a notice: exactly the fields of
// the notch's claim (notch:SURFACE-HOSTING.md:274-285), nothing of ours.
function claimFor(notice) {
  return {
    key: notice.key, title: notice.title, glyph: notice.glyph, priority: notice.priority,
    ttlMs: notice.ttlMs, view: notice.view, panelRoute: notice.panelRoute
  }
}
