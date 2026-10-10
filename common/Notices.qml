import QtQuick
import "Notices.js" as NoticeRules
import "Palette.js" as Palette

// The live transient notice, if any (plan-gui.md §7.5). One of these sits in
// each shell that needs to know: the bar widget, for its `notch` descriptor's
// priority, and the notch integration, which also claims it. Both hold the
// same rules (common/Notices.js), so they cannot disagree about what a
// moment says.
//
// Feed it every StatusSource event with take(record). `notice` is the notice
// for 8 s, then null; a newer one replaces it and restarts the clock.
Item {
  id: root
  visible: false

  property var status: null
  property bool canConnect: false

  property var notice: null
  readonly property bool live: root.notice !== null

  // Raised once per new notice, after `notice` is set.
  signal raised(var notice)

  function take(record) {
    var n = NoticeRules.describe(record, root.status, root.canConnect, Palette.glyph)
    if (!n) return null
    root.notice = n
    clock.restart()
    root.raised(n)
    return n
  }

  function clear() {
    clock.stop()
    root.notice = null
  }

  Timer {
    id: clock
    interval: NoticeRules.TTL_MS
    onTriggered: root.notice = null
  }
}
