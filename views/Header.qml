import QtQuick
import "../ui"

// The top row of the full panel, in both shells (ui-scope.md §2): the tabs
// (Overview · Screens · Games · Setup, only the built ones) while a tab is on
// screen, as the kit's segmented control, or the sub-page's title (Details,
// Safe eject) when one is pushed over it; the one close, at the right; and,
// only where nothing else goes back, the one back, a chevron at the left.
//
// Under the notch the strip at the top centre is the one visible way back
// (and Esc its invisible alias), so there is no chevron: the shell leaves
// `canBack` false and starts this row below the strip's zone, so nothing of
// it sits where a press goes back. The standalone popup has no strip: the
// chevron is always drawn when there is somewhere to go back to.
//
// It never repeats the state: the Overview says that once, in its headline
// (ui-scope.md §0.3). Setup carries a mark while something needs fixing, as a
// dot in its tab's name, so it does not rest on colour alone.
Item {
  id: header

  required property var theme
  property var tabs: []
  property var labels: ({})
  property string tab: ""          // the tab on screen, or "" on a sub-page
  property string title: ""        // a sub-page's title
  property var dots: ({})          // {setup: true}
  property bool canBack: false
  signal tabPicked(string name)
  signal back()
  signal closeRequested()

  readonly property bool showTabs: header.tab !== "" && header.tabs.length > 1
  // How wide the tabs want to be, so a notch panel can put them beside its back strip when they fit.
  readonly property real tabsImplicitWidth: tabsControl.implicitWidth

  implicitHeight: header.theme.rowHeight

  UBack {
    id: backButton
    theme: header.theme
    visible: header.canBack
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    onActivated: header.back()
  }

  USegmented {
    id: tabsControl
    theme: header.theme
    visible: header.showTabs
    anchors.left: backButton.visible ? backButton.right : parent.left
    anchors.leftMargin: backButton.visible ? header.theme.sp.xs : 0
    anchors.verticalCenter: parent.verticalCenter
    label: "Panel"
    value: header.tab
    options: header.tabs.map(function (t) {
      return { value: t, label: (header.labels[t] || t) + (header.dots[t] ? " •" : "") }
    })
    onPicked: function (name) { header.tabPicked(name) }
  }

  Text {
    visible: !header.showTabs && header.title !== ""
    anchors.left: backButton.visible ? backButton.right : parent.left
    anchors.leftMargin: backButton.visible ? header.theme.sp.xs : 0
    anchors.right: closeButton.left
    anchors.rightMargin: header.theme.sp.sm
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    elide: Text.ElideRight
    text: header.title
    color: header.theme.label
    font.family: header.theme.fontFamily
    font.pixelSize: header.theme.titleSize
    font.weight: header.theme.titleWeight
    Accessible.role: Accessible.Heading
    Accessible.name: text
  }

  UClose {
    id: closeButton
    theme: header.theme
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    onActivated: header.closeRequested()
  }
}
