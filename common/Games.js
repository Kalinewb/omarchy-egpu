.pragma library

// Words and lists for the Games view (views/GamesView.qml). Nothing here
// decides anything: states come from the engine (`steam list`, `apps list`).

var SHORT_LIST = 14

// Steam's states (lib/steam/steam.sh): off, on, stale (on while the eGPU is not
// there), pending_on / pending_off (queued until Steam closes), manual (the game
// has GPU options of its own) and modified (the managed options were edited).
function isOn(state) { return state === "on" || state === "stale" || state === "pending_on" }

function togglable(state) { return state !== "manual" && state !== "modified" }

function stateWord(state) {
  switch (state) {
  case "stale": return "waiting for the eGPU"
  case "pending_on": case "pending_off": return "when Steam closes"
  case "manual": return "set by hand"
  case "modified": return "edited by hand"
  default: return ""
  }
}

function appWord(state) { return state === "manual" ? "set by hand" : "" }

function pending(games) {
  var n = 0
  for (var i = 0; i < games.length; i++)
    if (games[i].state === "pending_on" || games[i].state === "pending_off") n++
  return n
}

function matches(name, query) { return query === "" || String(name).toLowerCase().indexOf(query) !== -1 }

function filterSteam(games, query) {
  var out = []
  for (var i = 0; i < games.length; i++) if (matches(games[i].name, query)) out.push(games[i])
  return out
}

// {rows, hidden}: with a search, every match. Without one, the apps that are
// on and the games first, up to a short list, and the rest behind "Show all".
function pickApps(apps, query, all) {
  if (query !== "") {
    var found = []
    for (var i = 0; i < apps.length; i++) if (matches(apps[i].name, query)) found.push(apps[i])
    return { rows: found, hidden: 0 }
  }
  if (all || apps.length <= SHORT_LIST) return { rows: apps, hidden: all ? apps.length - SHORT_LIST : 0 }
  var first = [], rest = []
  for (var j = 0; j < apps.length; j++) (apps[j].state === "on" || apps[j].game ? first : rest).push(apps[j])
  var rows = first.concat(rest).slice(0, Math.max(SHORT_LIST, first.length))
  rows.sort(function (a, b) { return String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1 })
  return { rows: rows, hidden: apps.length - rows.length }
}
