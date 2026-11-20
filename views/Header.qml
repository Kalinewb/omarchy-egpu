import QtQuick
import "ui"
import "../common/Palette.js" as Palette

// The top row of the full panel, in both shells (ui-scope.md §2): the slim
// tab row (Overview · Games · Screens · Setup, only the built ones) while a
// tab is on screen, or the sub-page's title (Details, Safe eject) when one is
// pushed over it; and "‹ Back" at the right whenever there is somewhere to go
// back to, as on the notch's own pages (‹ Settings, ‹ Setup).
//
// It never repeats the state: the Overview says that once, in its headline
// (ui-scope.md §0.3). Setup carries a dot while something needs fixing,
// drawn in `bad` and as a filled shape, so it does not rest on colour alone.
//
// The shell owns where it sits; its distance from the panel's edge is the
// shell's inset (theme.space.inset), so Back never crowds the corner.
Item {
  id: header

  property var theme: Palette.make({})
  property var tabs: []
  property var labels: ({})
  property string tab: ""          // the tab on screen, or "" on a sub-page
  property string title: ""        // a sub-page's title
  property var dots: ({})          // {setup: true}
  property bool canBack: false
  // The width of the notch's back-strip zone, centred over this row (0 when
  // there is none): nothing of the row may sit in it (notch:SURFACE-HOSTING.md
  // §15), so the tabs split around it and a title keeps to the left gutter.
  property real zoneWidth: 0
  readonly property real gutter: Math.max(0, (header.width - header.zoneWidth) / 2)
  signal tabPicked(string name)
  signal back()

  readonly property real u: header.theme.unit
  readonly property bool showTabs: header.tab !== "" && header.tabs.length > 1
  // With a zone, the first half of the tabs sit at the left and the rest at the right.
  readonly property int split: header.zoneWidth > 0 ? Math.ceil(header.tabs.length / 2) : header.tabs.length

  implicitHeight: Math.max(header.theme.space.rowHeight * 0.75, titleText.implicitHeight, tabRow.implicitHeight, tabRowRight.implicitHeight, backLink.implicitHeight)
  visible: header.showTabs || header.title !== "" || header.canBack

  // One tab, drawn the same in either half.
  Component {
    id: tabDelegate
    Item {
      id: tabItem
      required property var modelData
      readonly property bool current: header.tab === modelData
      implicitWidth: tabText.implicitWidth + (dot.visible ? dot.width + 4 * header.u : 0)
      implicitHeight: tabText.implicitHeight + 6 * header.u

      Text {
        id: tabText
        textFormat: Text.PlainText
        text: header.labels[tabItem.modelData] || tabItem.modelData
        color: tabItem.current ? header.theme.foreground : header.theme.secondary
        font.family: header.theme.fontFamily
        font.pixelSize: header.theme.font.body
        font.bold: tabItem.current
      }
      // The current tab's underline: a rule, not a font underline, so it
      // sits clear of the text.
      Rectangle {
        visible: tabItem.current
        anchors.left: tabText.left
        anchors.right: tabText.right
        anchors.bottom: parent.bottom
        height: Math.max(1, Math.round(2 * header.u))
        radius: Math.min(header.theme.radius, height / 2)
        color: header.theme.foreground
      }
      Rectangle {
        id: dot
        visible: !!header.dots[tabItem.modelData]
        width: Math.max(5, Math.round(6 * header.u))
        height: width
        radius: Math.min(header.theme.radius, width / 2)
        color: header.theme.bad
        anchors.left: tabText.right
        anchors.leftMargin: 4 * header.u
        anchors.top: tabText.top
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -4 * header.u
        cursorShape: Qt.PointingHandCursor
        onClicked: header.tabPicked(tabItem.modelData)
      }
    }
  }

  Row {
    id: tabRow
    visible: header.showTabs
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    spacing: header.theme.space.inset

    Repeater {
      model: header.tabs.slice(0, header.split)
      delegate: tabDelegate
    }
  }

  // The tabs past the zone, at the right edge.
  Row {
    id: tabRowRight
    visible: header.showTabs && header.zoneWidth > 0
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: header.theme.space.inset

    Repeater {
      model: header.tabs.slice(header.split)
      delegate: tabDelegate
    }
  }

  Text {
    id: titleText
    visible: !header.showTabs && header.title !== ""
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: header.zoneWidth > 0 ? header.gutter - 4 * header.u
           : parent.width - backLink.width - header.theme.space.inset
    textFormat: Text.PlainText
    elide: Text.ElideRight
    text: header.title
    color: header.theme.foreground
    font.family: header.theme.fontFamily
    font.pixelSize: header.theme.font.title
    font.bold: true
  }

  Link {
    id: backLink
    theme: header.theme
    visible: header.canBack
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    label: "‹ Back"
    tone: header.theme.secondary
    onClicked: header.back()
  }
}
