import QtQuick

// Setup's rows, `omarchy-egpu health --json` (plan-gui.md §5.5), read for
// whoever is looking and for no one else.
//
// The status document carries only health_summary (counts). Setup needs the
// rows, and so does the Overview: its "never set up" button and the sentence
// that names the first problem (ui-scope.md §2.1). One of these per shell,
// like StatusSource, so the Overview and Setup tabs share one read.
//
// Nothing runs while nobody holds it: a shell calls hold() when its panel
// opens and release() when it closes (plan-gui.md §3, "while the popup is
// closed nothing else runs"). While held it reads once, again whenever the
// status's health_summary changes, and again on refresh() (after a Fix).
// The last rows are kept across a close, so the next open draws at once and
// first-run (ux.md rule 4) can be decided before the read returns.
Item {
  id: root

  property var engine: null
  property var status: null

  // null until the first answer, then the array of rows.
  property var rows: null
  // The last read's error code ("" when it worked); the rows stay as they were.
  property string error: ""
  property bool loading: false
  property int holders: 0
  readonly property bool active: root.holders > 0

  // A read asked for while one runs: done once it ends.
  property bool again: false

  function hold() { root.holders += 1; if (root.holders === 1) root.refresh() }
  function release() { root.holders = Math.max(0, root.holders - 1) }

  function refresh() {
    if (!root.engine) return
    if (root.loading) { root.again = true; return }
    root.loading = true
    root.engine.run(["health", "--json"], function (result) {
      if (!root) return    // the shell went away while the read ran
      root.loading = false
      if (result.ok && result.json && typeof result.json.length === "number") {
        root.rows = result.json
        root.error = ""
      } else {
        root.error = result.error || ("exit " + result.code)
      }
      if (root.again) { root.again = false; root.refresh() }
    })
  }

  readonly property string summaryKey: root.status && root.status.health_summary ? JSON.stringify(root.status.health_summary) : ""
  onSummaryKeyChanged: if (root.active) root.refresh()
}
