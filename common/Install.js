.pragma library

// The one-time system install, as Setup offers it (ui-scope.md §2.6, §7
// "Setup install"): a button opens an Omarchy terminal that shows a short
// explanation, then runs the pinned command `system/install.sh
// --print-command install` prints. sudo asks for the password in that
// terminal; the panel never sees it, never runs sudo itself, and never
// handles root (plan-engine.md §10.4).
//
// Why a terminal can be opened from here safely, where omarchy-face only
// copies its command:
//   - the panel starts Omarchy's own launcher
//     (omarchy-launch-floating-terminal-with-presentation) with ONE argv
//     element, the script below; nothing is joined from user input
//   - the script is fixed text plus the command, and the command is checked
//     against its known shape first (`commandOk`), so whatever install.sh
//     printed, only that one-line curl+sudo form is ever handed over
//   - the terminal prints the command before it runs and waits for Enter, so
//     the person sees exactly what will ask for their password, and can
//     close the window instead
// The command comes from the plugin folder, which this account can write;
// that is the same trust as a copied command (Face's README says so for its
// own). The checksum it fetches from the release tag is the anchor either
// way. If the launcher is missing or fails, Setup shows the command with a
// Copy button instead.

var LAUNCHER = "omarchy-launch-floating-terminal-with-presentation"

// Shown in the panel above the button, and printed first in the terminal.
var EXPLAIN = [
  "This installs the eGPU plugin's system helper, once.",
  "It lets the panel connect and eject the eGPU without a password, keeps the eGPU driver from loading at startup, and adds the rules that keep the desktop on the laptop's graphics.",
  "Every system file it changes is backed up first. Setup can remove it again.",
  "Your password is typed in the terminal, never in the panel."
]

// The shape install.sh --print-command prints (system/install.sh, "The
// command for README.md and the panel"): one line, the plugin's own folder,
// the checksum from this repository's release tag on GitHub, then sudo.
var PREFIX = "d=\"$HOME/.config/omarchy/plugins/kalinewb.egpu\" && sum=$(curl -fsSL https://raw.githubusercontent.com/Kalinewb/omarchy-egpu/"

function commandOk(cmd, mode) {
  var c = String(cmd || "").replace(/\n+$/, "")
  if (c.indexOf("\n") !== -1 || c.indexOf(PREFIX) !== 0) return false
  if (c.indexOf(" && sudo /usr/bin/bash -c '") === -1) return false
  var m = String(mode || "install")
  if (c.indexOf("--expect-sha256 \"$2\" " + m + (m === "uninstall" ? ";" : " ")) === -1) return false
  return /' omarchy-egpu "\$d" "\$sum" "\$USER"$/.test(c)
}

// Single-quoted for bash: ' becomes '\''.
function quote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

// The script the terminal runs (one argv element of LAUNCHER, which runs it
// with bash -c after Omarchy's logo). Ends with the command's own status so
// the launcher's "Done" shows only after a finished run.
function terminalScript(cmd, title) {
  var lines = ["", String(title || "Set up eGPU support"), ""].concat(EXPLAIN).concat(["", "The command:", "", String(cmd).replace(/\n+$/, ""), ""])
  return "printf '%s\\n' " + lines.map(quote).join(" ") + "\n" +
         "read -r -p 'Press Enter to continue, or close this window to cancel. ' _ || exit 130\n" +
         String(cmd).replace(/\n+$/, "")
}
