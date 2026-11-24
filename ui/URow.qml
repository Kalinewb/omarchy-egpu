import QtQuick

// One row (plan-apple-ui.md 4.2 "Row"): label left, a value or a control
// right, an optional trailing slot (buttons, a job), height by density.
//
//   URow { theme: theme; label: "Show the date"; USwitch { ... } }
//   URow { theme: theme; label: "Version"; value: "1.4.0" }
//   URow { theme: theme; variant: "stacked"; label: "Hotkey"; UField { width: parent.width } }
//
// `stacked` (replaces StackedRow): the label on its own line, the control
// below it at full width. Explanation is pulled, not printed: `tip`.
//
// The list-item form is the same row with more filled in: `icon` (a glyph at the
// left), `detail` (a second line, metadata), `badge` (a short word in a hairline
// pill after the label), `current` (this is the chosen one: an accent bar in the
// left margin and a semibold label, so it reads without the keyboard ring) and
// `trailing` for actions (icon UButtons). A list that keeps its own keyboard
// cursor sets `showFocus` on the row under it, as it does for any control.
//
//   URow { theme: theme; clickable: true; icon: "\u25cf"; label: "Work"; detail: "3 apps, last used today"
//          badge: "Default"; current: true; onActivated: switchTo(name)
//          trailing: UButton { theme: theme; glyph: "+"; name: "Add to Work" } }
Item {
  id: root
  required property var theme
  property string label: ""
  // Read-only text on the right. A state that cannot be changed is shown here.
  property string value: ""
  // The value is small print (who set it, where it came from): metadata, not secondary.
  property bool valueQuiet: false
  property string variant: "row"
  property string tip: ""
  // A row that is itself the control (opens a page); it gets hover, focus and a name.
  property bool clickable: false
  // List-item form (ignored by `stacked`).
  // A glyph at the left, in the label colour (a thin glyph in a quieter one measures under 4.5:1), in a column as wide as a control is tall.
  property string icon: ""
  // A second line under the label, in metadata (small print, Light): what it is, when it was used.
  property string detail: ""
  // A short word after the label in a hairline pill: "Default", "Locked". Keep it to a word or two.
  property string badge: ""
  // This is the chosen entry. An accent bar in the left margin and a semibold label: a mark of its own, not the ring.
  property bool current: false
  // The row is a list entry: its content starts after the margin the `current` bar sits in. On by
  // itself with an icon, a detail or a badge; set it for a list whose rows have none of those but
  // one may be `current`, so the labels stay aligned.
  property bool listItem: icon !== "" || detail !== "" || badge !== ""
  signal activated()

  default property alias control: slot.data
  property alias trailing: trailingSlot.data

  // HoverHandler, not the MouseArea: the pointer is still "on the row" over its trailing buttons.
  property bool hot: hover.hovered
  property bool showFocus: activeFocus

  readonly property bool stacked: variant === "stacked"
  readonly property int gap: theme.sp.sm
  // Where the label starts: after the margin of the `current` bar, then the icon column.
  readonly property bool withIcon: !stacked && icon !== ""
  readonly property int lead: (listItem && !stacked ? theme.sp.sm : 0) + (withIcon ? theme.controlHeight : 0)
  readonly property bool twoLines: !stacked && detail !== ""

  width: parent ? parent.width : implicitWidth
  implicitHeight: stacked
    ? Math.ceil(stackedLabel.implicitHeight) + theme.sp.xs + Math.max(slot.childrenRect.height, trailingSlot.childrenRect.height) + theme.sp.sm
    : Math.max(theme.rowHeight, twoLines ? Math.ceil(block.height) + theme.sp.md : 0,
               Math.max(slot.childrenRect.height, trailingSlot.childrenRect.height) + theme.sp.xs)
  implicitWidth: 320
  height: implicitHeight

  activeFocusOnTab: clickable && enabled
  Accessible.role: clickable ? Accessible.Button : Accessible.StaticText
  Accessible.name: label
  Accessible.description: [detail, badge].filter(function(t) { return t !== "" }).join(". ")
  Accessible.selected: current
  Accessible.onPressAction: root.activated()

  Rectangle {
    anchors.fill: parent
    visible: root.clickable
    radius: root.theme.radius(root.theme.rowHeight)
    color: mouse.pressed ? root.theme.pressed : (root.hot ? root.theme.hover : root.theme.none)
    border.width: root.showFocus ? 2 : 0
    border.color: root.theme.ring
    property bool uiMark: true
    Behavior on color { ColorAnimation { duration: root.theme.focusMs } }
  }

  // Under everything else, so a trailing button is above it and gets its own clicks.
  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.clickable
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
  HoverHandler { id: hover; enabled: root.clickable }

  // The `current` mark: an accent bar in the margin.
  Rectangle {
    visible: root.current && !root.stacked
    x: 0
    y: root.theme.sp.xs
    width: 2 * root.theme.hairlineWidth
    height: root.height - 2 * root.theme.sp.xs
    radius: root.theme.radius(width)
    color: root.theme.accent
    property bool uiMark: true
  }

  Text {
    visible: root.withIcon
    x: root.lead - root.theme.controlHeight + (root.theme.controlHeight - width) / 2
    anchors.verticalCenter: parent.verticalCenter
    text: root.icon
    color: root.enabled ? root.theme.label : root.theme.disabled
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.titleSize
  }

  Item {
    id: block
    visible: !root.stacked
    x: root.lead
    width: Math.max(0, group.x - root.gap - root.lead)
    anchors.verticalCenter: parent.verticalCenter
    height: titleLine.height + (detailText.visible ? detailText.height : 0)
    Item {
      id: titleLine
      width: parent.width
      height: rowLabel.implicitHeight
      Text {
        id: rowLabel
        width: Math.min(implicitWidth, parent.width - (badgePill.visible ? badgePill.width + root.gap : 0))
        text: root.label
        elide: Text.ElideRight
        color: root.enabled ? root.theme.label : root.theme.disabled
        font.family: root.theme.fontFamily
        font.pixelSize: root.theme.bodySize
        font.weight: root.current ? root.theme.headlineWeight : Font.Normal
      }
      Rectangle {
        id: badgePill
        visible: root.badge !== "" && !root.stacked
        x: rowLabel.width + root.gap
        anchors.verticalCenter: parent.verticalCenter
        width: badgeText.implicitWidth + 2 * root.theme.sp.sm
        height: badgeText.implicitHeight + 2 * root.theme.hairlineWidth
        radius: root.theme.radius(height)
        color: root.theme.none
        border.width: root.theme.hairlineWidth
        border.color: root.theme.hairline
        property bool uiMark: true
        Text {
          id: badgeText
          anchors.centerIn: parent
          text: root.badge
          color: root.enabled ? root.theme.secondary : root.theme.disabled
          font.family: root.theme.fontFamily
          font.pixelSize: root.theme.footnoteSize
        }
      }
    }
    Text {
      id: detailText
      visible: root.twoLines
      y: titleLine.height
      width: parent.width
      text: root.detail
      elide: Text.ElideRight
      color: root.enabled ? root.theme.metadata : root.theme.disabled
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.footnoteSize
      font.weight: root.theme.metadataWeight
    }
  }
  Text {
    id: stackedLabel
    visible: root.stacked
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.theme.sp.xs
    text: root.label
    elide: Text.ElideRight
    color: root.theme.secondary
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.footnoteSize
  }

  Row {
    id: group
    spacing: root.gap
    x: root.stacked ? 0 : root.width - width
    y: root.stacked ? stackedLabel.y + stackedLabel.height + root.theme.sp.xs : (root.height - height) / 2
    Text {
      visible: root.value !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.value
      color: root.valueQuiet ? root.theme.metadata : root.theme.secondary
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.bodySize
      font.weight: root.valueQuiet ? root.theme.metadataWeight : Font.Normal
    }
    Item {
      id: slot
      width: root.stacked ? root.width - trailingSlot.width : childrenRect.width
      height: childrenRect.height
      anchors.verticalCenter: parent.verticalCenter
    }
    Item {
      id: trailingSlot
      width: childrenRect.width
      height: childrenRect.height
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Keys.onPressed: function(event) {
    if (!root.clickable) return
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { root.activated(); event.accepted = true }
  }
  UTip { theme: root.theme; text: root.tip }
}
