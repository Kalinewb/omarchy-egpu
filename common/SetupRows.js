.pragma library

// Setup's words for every health row (ui-scope.md §2.6, plan-gui.md §5.5).
//
// The engine's rows (`omarchy-egpu health --json`, lib/health.sh and the
// modules it sources) carry a technical title and detail: file names, module
// names, policy words. Those stay under each row's "Details". What a person
// reads first is the sentence here, one per row id and level, and the one
// thing to do about it:
//
//   fix.kind  install   the one system install, run in a terminal (Setup's
//                       Install / Fix all; the panel never sees the password)
//             engine    an engine verb the plugin runs itself (`args`)
//             copy      a command to copy and run by hand (`command`)
//             logout    "log out and back in" (a sentence; nothing to press)
//             none      nothing to do here
//
// Nothing here decides a level: that is the engine's. Where one id has
// several engine titles (bolt.daemon: no port / bolt missing / not answering)
// the branch is on the engine's fix label or title, which tests/run.sh pins
// through the fixtures, and an unknown variant falls back to the engine's
// own title rather than a guess. dev/g1-offscreen.sh checks that every id
// lib/ can emit has an entry here, and that no sentence carries jargon.

// The ids lib/ emits. g1 compares this list with a grep of lib/.
var IDS = [
  "bolt.daemon", "bolt.device", "kernel.thunderbolt_early", "boot.modules_load_mask",
  "boot.mkinitcpio_conf", "boot.initramfs_nvidia", "kernel.modprobe_options",
  "kernel.nouveau_blacklist", "driver.modeset", "driver.fbdev", "driver.flavour",
  "driver.persistenced", "driver.sleep", "backend.supported", "hypr.links", "hypr.order",
  "hypr.gpu_list", "hypr.session_env", "tools.vulkaninfo", "system.helper",
  "system.autoconnect", "steam.pending", "steam.options", "steam.stale",
  "steam.flatpak_gl", "diag.kernel_params"
]

function known(id) { return IDS.indexOf(String(id)) !== -1 }

function problem(level) { return level === "error" || level === "warn" }

// The first command-looking run in a detail ("… : flatpak install flathub X").
function commandIn(text, head) {
  var t = String(text || "")
  var i = t.indexOf(head)
  if (i < 0) return ""
  return t.substring(i).replace(/[.\s]+$/, "").split(/\s*[;\n]/)[0]
}

function rowById(rows, id) {
  var list = rows && typeof rows.length === "number" ? rows : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) return list[i]
  return null
}

var INSTALL = { kind: "install", label: "Install" }
var NONE = { kind: "none", label: "" }

// The words for one row: {id, level, sentence, why, fix: {kind, label, args?,
// command?, note?}, details}. `rows` (all of them) lets one row look at
// another (hypr.order's fix needs the links first).
function describe(row, rows) {
  var r = row || {}
  var id = String(r.id || "")
  var level = String(r.level || "info")
  var title = String(r.title || "")
  var fixLabel = r.fix ? String(r.fix.label || "") : ""
  var fixKind = r.fix ? String(r.fix.kind || "none") : "none"
  var out = { id: id, level: level, sentence: "", why: "", fix: NONE, details: "" }
  // What the engine said, for "Details": the id, its title, its detail.
  out.details = [id, title, String(r.detail || "")].filter(function (x) { return x !== "" }).join("\n")

  function say(s, why, fix) { out.sentence = s; out.why = why || ""; out.fix = fix || NONE }
  var p = problem(level)

  switch (id) {
  case "bolt.daemon":
    if (level === "ok") say("Thunderbolt is working")
    else if (/^No Thunderbolt/.test(title)) say("This computer has no Thunderbolt or USB4 port", "A Thunderbolt eGPU cannot connect here.")
    else if (fixLabel === "Install bolt") say("Thunderbolt support is not installed", "It is needed to allow an eGPU enclosure.",
                                              { kind: "copy", label: "Copy command", command: "omarchy-pkg-add bolt" })
    else say("Thunderbolt support is not answering", "Restarting the computer usually fixes this.")
    break
  case "bolt.device":
    if (level === "ok") say("Your eGPU enclosure is remembered")
    else if (level === "skipped") say("Enclosure not checked", "Thunderbolt support has to work first.")
    else if (/authorization failed/.test(title)) say("Your enclosure could not be allowed", "Allowing it again usually fixes this.",
                                                     { kind: "engine", label: "Try again", args: ["device", "connect", "--enroll"], verb: "device connect" })
    else if (fixKind === "user") say("Your enclosure has to be allowed on every plug-in", "Remembering it lets it connect by itself.",
                                     { kind: "engine", label: "Remember it", args: ["device", "connect", "--enroll"], verb: "device connect", needsPlugged: true })
    else say("No eGPU enclosure seen yet", "Plug it in once; you will be asked to allow it.")
    break
  case "kernel.thunderbolt_early":
    if (level === "ok") say("Thunderbolt starts early at boot")
    else say("Thunderbolt starts late at boot", "An eGPU plugged in at boot may come up after the desktop.", INSTALL)
    break
  case "boot.modules_load_mask":
    if (level === "ok") say("The eGPU driver stays off at startup")
    else if (level === "skipped") say("Startup driver check not needed")
    else say("The eGPU driver loads at startup (can freeze)", "Loading it with no card plugged in froze this computer before.", INSTALL)
    break
  case "boot.mkinitcpio_conf":
    if (level === "ok") say("The boot setup does not add the eGPU driver")
    else if (level === "skipped") say("Boot setup check not needed")
    else say("The boot setup adds the eGPU driver", "The driver should load only when you connect the eGPU.", INSTALL)
    break
  case "boot.initramfs_nvidia":
    if (level === "ok") say("The boot image does not carry the eGPU driver")
    else if (level === "skipped") say("Boot image not checked", "Only the system helper can read it. Never rebuild it with the eGPU plugged in.")
    else say("The boot image carries the eGPU driver", "Unplug the eGPU, then rebuild the boot image.")
    break
  case "kernel.modprobe_options":
    if (level === "ok") say("Driver options are set")
    else say("Driver options need setting", level === "error" ? "The eGPU's own screen ports cannot work without them." : "Nothing pins them yet.", INSTALL)
    break
  case "kernel.nouveau_blacklist":
    if (level === "ok") say("The built-in NVIDIA driver is kept off")
    else say("The built-in NVIDIA driver could take the card", "It would block the real driver when you plug in.", INSTALL)
    break
  case "driver.modeset":
    if (level === "ok") say("Screen support in the driver is on")
    else if (level === "error") say("Screen support in the driver is off", "Screens on the eGPU's own ports need it.", INSTALL)
    else say("Screen support is checked once the eGPU is connected")
    break
  case "driver.fbdev":
    if (r.value === "Y") say("Driver console is on")
    else if (r.value === "N") say("Driver console is off")
    else say("Driver console is checked once the eGPU is connected")
    break
  case "driver.flavour":
    if (/not installed/.test(title)) say("The NVIDIA driver is not installed", "Only needed for an NVIDIA eGPU.")
    else if (/not loaded/.test(title)) say("The NVIDIA driver is installed")
    else if (/open kernel/i.test(title)) say("The NVIDIA driver is installed (open edition)")
    else say("The NVIDIA driver is installed")
    break
  case "driver.persistenced":
    if (level === "ok") say("No NVIDIA background service holds the card")
    else say("An NVIDIA background service keeps the card busy", "Safe eject cannot free the card while it runs.",
             { kind: "copy", label: "Copy command", command: "sudo systemctl disable --now nvidia-persistenced" })
    break
  case "driver.sleep":
    if (/not enabled/.test(title)) say("Eject the eGPU before the computer sleeps", "Its memory may be lost in sleep otherwise.")
    else say("Sleep with the eGPU attached is handled")
    break
  case "backend.supported":
    say("This graphics card is not supported yet", "It is detected, but connect and eject do not work for it yet.")
    break
  case "hypr.links":
    if (level === "ok") say("The desktop's graphics order is pinned")
    else if (level === "error") say("The desktop's graphics pin points at the wrong card", "", INSTALL)
    else say("The desktop's graphics order is not pinned",
             level === "info" ? "Optional: the laptop's graphics stay in charge by themselves." : "The system install pins it.", INSTALL)
    break
  case "hypr.order":
    if (level === "ok" || level === "info") say("The desktop runs on the laptop's graphics")
    else if (level === "skipped") say("Desktop graphics order not checked")
    else if (fixLabel === "Log out and in")
      say(/started with the eGPU/.test(title) ? "The desktop started with the eGPU" : "The graphics order applies after you log out",
          "Log out and back in to finish.", { kind: "logout", label: "" })
    else {
      var links = rowById(rows, "hypr.links")
      var linked = !links || links.level === "ok"
      say(level === "error" ? "The desktop is not running on the laptop's graphics" : "Nothing keeps the desktop on the laptop's graphics",
          linked ? "Fix writes the order; then log out and back in." : "The system install pins it; then log out and back in.",
          linked ? { kind: "engine", label: "Fix", args: ["display", "apply"], verb: "display apply", note: "Log out and back in to finish." } : INSTALL)
    }
    break
  case "hypr.gpu_list":
    if (level === "skipped") say("Desktop graphics not checked")
    else {
      var n = Number((title.match(/(\d+)/) || [0, 0])[1])
      say(n === 1 ? "The desktop uses one graphics card" : "The desktop uses " + n + " graphics cards")
    }
    break
  case "hypr.session_env":
    if (level === "ok") say("Apps start on the laptop's graphics")
    else if (level === "skipped") say("Desktop graphics settings not checked")
    else if (fixLabel === "Log out and in") say("Log out and back in to finish the graphics settings",
                                                "Apps started now may pick the eGPU's drivers by mistake.", { kind: "logout", label: "" })
    else say(/out of date/.test(title) ? "The desktop's graphics settings are out of date" : "The desktop's graphics settings are not written yet",
             "They keep the desktop and its apps on the laptop's graphics.",
             { kind: "engine", label: "Fix", args: ["display", "apply"], verb: "display apply" })
    break
  case "tools.vulkaninfo":
    if (level === "ok") say("The graphics check tool is installed")
    else say("The graphics check tool is missing", "Connect skips one check without it.",
             { kind: "copy", label: "Copy command", command: /^omarchy-pkg-add [a-z0-9-]+$/.test(fixLabel) ? fixLabel : "omarchy-pkg-add vulkan-tools" })
    break
  case "system.helper":
    if (level === "ok") say("The system helper is installed")
    else if (/out of date/.test(title)) say("The system helper needs updating", "The plugin was updated; its system part was not.", { kind: "install", label: "Update" })
    else if (/not installed/.test(title)) say("The system helper is not installed", "It lets the plugin connect and eject without a password.", INSTALL)
    else say("The system helper is incomplete", "Installing it again repairs it.", INSTALL)
    break
  case "system.autoconnect":
    // Drawn as Setup's switch row; the sentence is its label.
    say("Auto-connect when plugged in", level === "skipped" ? "Needs the system helper." : "")
    break
  case "steam.pending":
    if (level === "ok") say("No game changes are waiting")
    else {
      var k = Number((title.match(/^(\d+)/) || [0, 0])[1])
      say((k === 1 ? "One game change waits" : k + " game changes wait") + " for Steam to close", "",
          { kind: "engine", label: "Close Steam and apply", args: ["steam", "apply", "--close", "--relaunch"], verb: "steam apply" })
    }
    break
  case "steam.options":
    if (level === "ok") say("Steam's game settings look fine")
    else if (level === "skipped") say("Steam is not installed")
    else if (/does not parse/.test(title)) say("Steam's settings could not be read", "Steam rewrites them when it closes; nothing was changed.")
    else if (/Edited by hand/.test(title)) say("Some games' eGPU settings were edited by hand", "They are left alone.")
    else say("Some games have their own graphics settings", "They are left alone.")
    break
  case "steam.stale":
    if (level === "ok") say("No game waits for the eGPU")
    else if (level === "skipped") say("Steam is not installed")
    else {
      var g = Number((title.match(/^(\d+)/) || [0, 0])[1])
      say((g === 1 ? "One game is" : g + " games are") + " set to the eGPU while it is unplugged",
          "Most still start on the laptop's graphics.",
          { kind: "engine", label: "Turn them off", args: ["steam", "set-all", "off", "--only-stale"], verb: "steam set-all" })
    }
    break
  case "steam.flatpak_gl":
    if (level === "ok") say("Flatpak Steam can use the eGPU")
    else if (level === "skipped") say("Flatpak is not installed")
    else if (level === "info") say("Flatpak Steam's graphics add-on is installed")
    else {
      var cmd = commandIn(r.detail, "flatpak install flathub ")
      say("Flatpak Steam is missing a graphics add-on", "Games in Flatpak Steam cannot use the eGPU without it.",
          /^flatpak install flathub [A-Za-z0-9._-]+$/.test(cmd) ? { kind: "copy", label: "Copy command", command: cmd } : NONE)
    }
    break
  case "diag.kernel_params":
    say("Optional startup settings exist for this enclosure", "Not needed in most cases.")
    break
  default:
    // A row from a newer engine: its own title, and the fix its kind says.
    say(title !== "" ? title : id, "", fixKind === "system" ? INSTALL : NONE)
  }
  // A row that is fine has nothing to fix, whatever its kind.
  if (!p && out.fix.kind !== "logout" && id !== "steam.pending" && id !== "steam.stale") out.fix = NONE
  if (level === "skipped") out.fix = NONE
  return out
}

var ORDER = { error: 0, warn: 1, info: 2, ok: 3, skipped: 4 }

// Everything Setup and the Overview need from the rows at once:
//   loaded       rows have arrived
//   helper       the system.helper row ("" until loaded: ok | missing | outdated | broken)
//   neverSetUp   the helper was never installed (first run, ux.md rule 4).
//                system.autoconnect is `skipped` exactly when the helper is
//                not there at all (lib/health.sh), which tells "never" from
//                "out of date" without reading a title (an engine without
//                that row: the title's "not installed")
//   problems     described error and warn rows, errors first, engine order
//                within a level
//   installRows  the problems the one system install fixes
//   others       ok rows, and info rows with something to do
//   advanced     the rest of the info rows and the skipped ones: Setup puts
//                them under "Advanced" (plain facts, nothing to fix)
//   skipped      the skipped ones alone
//   autoconnect  the system.autoconnect row described, or null
function summarize(rows) {
  var list = rows && typeof rows.length === "number" ? rows : null
  var out = { loaded: list !== null, helper: "", neverSetUp: false, problems: [], installRows: [], others: [], skipped: [],
              advanced: [], autoconnect: null }
  if (!list) return out
  var helper = rowById(list, "system.helper")
  var auto = rowById(list, "system.autoconnect")
  if (helper) {
    if (helper.level === "ok") out.helper = "ok"
    else if (/out of date/.test(String(helper.title))) out.helper = "outdated"
    // An engine older than the auto-connect row says so only in the title.
    else if ((auto && auto.level === "skipped") || (!auto && /not installed/.test(String(helper.title)))) out.helper = "missing"
    else out.helper = "broken"
  }
  out.neverSetUp = out.helper === "missing"
  var described = []
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || !list[i].id) continue
    var d = describe(list[i], list)
    d.order = i
    if (d.id === "system.autoconnect") { out.autoconnect = d; continue }
    described.push(d)
  }
  // Ties broken on the engine's order: the JS engine's sort is not stable.
  described.sort(function (a, b) {
    var la = ORDER[a.level] !== undefined ? ORDER[a.level] : 2, lb = ORDER[b.level] !== undefined ? ORDER[b.level] : 2
    return la !== lb ? la - lb : a.order - b.order
  })
  for (var j = 0; j < described.length; j++) {
    var e = described[j]
    if (problem(e.level)) {
      out.problems.push(e)
      if (e.fix.kind === "install") out.installRows.push(e)
    } else if (e.level === "skipped") { out.skipped.push(e); out.advanced.push(e) }
    else if (e.level === "info" && e.fix.kind === "none") out.advanced.push(e)
    else out.others.push(e)
  }
  return out
}

// The first problem at error level, or null: what the Overview names.
function firstError(summary) {
  var p = summary && summary.problems ? summary.problems : []
  return p.length > 0 && p[0].level === "error" ? p[0] : null
}
