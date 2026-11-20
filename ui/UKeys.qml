import QtQuick
import "keys.js" as KeyMap

// The one place Esc is handled (plan-apple-ui.md 4.2 "Keys").
//
// Esc closes, in order: an edit in progress, a tip, an open pick, a modal (a
// confirm), then goes back one step, then closes. Every layer joins one
// registry (keys.js); the page-level UKeys, the one that has focus, routes the
// press to the top open layer.
//
//   UKeys {                       // once, around the page: it routes
//     anchors.fill: parent
//     focus: true
//     level: "back"; open: depth > 0
//     onEscaped: goBack()          // fired when "back" is the top open layer
//     onCloseRequested: root.closeRequested()
//     onPrimary: save.clicked()   // Enter that nothing under the focus took
//     ...the page...
//   }
//
// The kit's own parts (UTip, UPick, UField, UConfirmSheet) join with their own
// level and need no wiring. Outside ui/ there is no Key_Escape and no
// onEscapePressed: a lint failure (dev/check-ui.sh).
FocusScope {
  id: root

  // "edit", "tip", "pick", "modal" or "back" (keys.js LAYERS). Named `level`: `layer` is
  // an Item's own property.
  property string level: "back"
  // Whether this level is open right now: a tip showing, a pick expanded,
  // a confirm asking, a page deeper than the root.
  property bool open: false

  // Fired when Esc lands on this level.
  signal escaped()
  // Esc with no layer open anywhere: the panel itself should leave.
  signal closeRequested()
  // Enter or Return that nothing under the focus took: the surface's primary.
  signal primary()

  default property alias content: holder.data

  property int _id: 0
  Component.onCompleted: _id = KeyMap.shared.join(level, open, function() { root.escaped() })
  Component.onDestruction: KeyMap.shared.leave(_id)
  onOpenChanged: KeyMap.shared.set(_id, open)

  Item { id: holder; anchors.fill: parent }

  Keys.onEscapePressed: function(event) {
    event.accepted = true
    if (KeyMap.shared.escape() === "close") root.closeRequested()
  }
  Keys.onReturnPressed: function(event) { root.primary(); event.accepted = true }
  Keys.onEnterPressed: function(event) { root.primary(); event.accepted = true }
}
