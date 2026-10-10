.pragma library

// Engine error code → the sentence a person reads (plan-gui.md §6).
//
// One table for both shells, so the standalone popup and the notch cannot word
// the same failure two ways. The codes are the full set of plan-engine.md §1.1;
// a code this table has never heard of still renders ("Something went wrong:
// <code>") rather than nothing, because an empty error line reads as success.

var sentences = {
  // device
  not_connected: "The eGPU is not connected.",
  no_pci_device: "The enclosure is connected but no graphics card appeared. Check its power and its mode switch.",
  modules_failed: "The driver could not be loaded.",
  smi_hung: "The driver is not answering. Do not unplug: save your work, then log out or reboot.",
  holders_present: "Some apps are still using the eGPU.",
  remove_timeout: "Do not unplug. The driver has not let go of the card. Save your work and log out; unplug after.",
  helper_missing: "The system half is not installed. Setup shows how to install it.",
  // display
  hdmi_still_active: "The monitor on the eGPU is still on.",
  unsafe_name: "That monitor name cannot be used safely.",
  // any backend call
  backend_stub: "This kind of GPU is detected but not supported yet.",
  // steam
  steam_not_found: "Steam is not installed.",
  account_not_found: "That Steam account was not found.",
  steam_running: "Steam is open. It overwrites launch options when it quits.",
  game_running: "A game is running. Close it first.",
  steam_close_timeout: "Steam did not close in time. Nothing was changed.",
  vdf_parse_failed: "Nothing was changed: Steam's settings file could not be read.",
  vdf_check_failed: "Nothing was changed: the edited settings did not pass the safety check.",
  vdf_changed_underneath: "Nothing was changed: Steam's settings changed while they were being edited. Try again.",
  token_modified: "The eGPU option on this game was edited by hand, so it was left alone.",
  manual_offload: "This game already has its own GPU options, so it was left alone.",
  backup_failed: "Nothing was changed: the backup could not be written.",
  // the engine's own answers that are not module codes
  busy: "Busy — another eGPU action is running",
  usage: "This needs a newer version of the plugin's engine.",
  // Engine.qml's own, before anything runs: bin/omarchy-egpu is not there.
  engine_missing: "The plugin's engine (bin/omarchy-egpu) is missing. Reinstall the plugin."
}

// Exit codes that mean the same thing whatever the verb (plan-engine.md §1.1).
var exits = {
  3: "Busy — another eGPU action is running",
  126: "Permission declined",
  127: "The system half is not installed"
}

function message(code) {
  var c = String(code === undefined || code === null ? "" : code)
  if (c === "") return ""
  if (sentences.hasOwnProperty(c)) return sentences[c]
  return "Something went wrong: " + c
}

// Conditions in the status document that are not errors but need a sentence
// (plan-gui.md §5.1 banners, §7.6 "attention sentences"). Here so the Overview
// and the notch's compact view say them in the same words.
var notes = {
  needs_relogin: "The HDMI monitor needs a new session to appear. Offloading apps works now.",
  held_after_eject: "Log out before plugging the eGPU in again.",
  health_errors: "Setup has found a problem."
}

function note(id) {
  return notes.hasOwnProperty(id) ? notes[id] : ""
}

// result is Engine.qml's {ok, json, code, error}. Exit codes 3/126/127 win over
// whatever JSON came with them: pkexec's 126 has no JSON of the engine's at all.
function forResult(result) {
  if (!result || result.ok) return ""
  if (exits.hasOwnProperty(result.code)) return exits[result.code]
  return message(result.error || ("exit " + result.code))
}

// 127 is the one exit with somewhere to go: Setup says how to install the
// system half (plan-gui.md §6).
function routeFor(result) {
  return result && !result.ok && (result.code === 127 || result.error === "helper_missing") ? "setup" : ""
}
