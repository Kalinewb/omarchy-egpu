import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons

// Harness stand-in for qs.Ui's KeyboardPanel, the one kit type an offscreen
// Quickshell cannot load: it is a layer-shell PanelWindow ("No PanelWindow
// backend loaded"). dev/g1-offscreen.sh links every other qs.Ui file from the
// installed shell unchanged and puts this file in KeyboardPanel's place.
//
// Same API as the real one, as far as Panel.qml uses it (anchorItem, owner,
// bar, open, focusTarget, contentWidth/Height, fitted*), but a plain QtQuick
// Window: it maps on the offscreen platform, so the popup's real content —
// hero, tabs, the view Loader — instantiates and can be grabbed to a PNG.
// Placement, focus priming and outside-click dismissal are the real panel's
// and are not what this harness checks.
Window {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property bool open: false
  property Item focusTarget: null

  // The real panel names its default property contentItem; here that name
  // would shadow Window.contentItem, and the name of a default property is
  // never written by its users anyway.
  default property alias content: holder.children

  function fittedContentWidth(width, cap) {
    var w = Math.max(1, Number(width) || 1)
    return Math.round(cap !== undefined && Number(cap) > 0 ? Math.min(w, Number(cap)) : w)
  }

  function fittedContentHeight(implicitHeight, cap) {
    var h = (Number(implicitHeight) || 0) + root.padding * 2
    return Math.round(cap !== undefined && Number(cap) > 0 ? Math.min(h, Number(cap)) : h)
  }

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  width: contentWidth
  height: contentHeight
  visible: open
  color: Commons.Color.popups.background

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.popups.background
  }

  Item {
    id: holder
    anchors.fill: parent
    anchors.margins: root.padding
  }
}
