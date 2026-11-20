import QtQuick

// A section header (plan-apple-ui.md 4.2): a footnote in secondary, 24 px of
// air above it, no rule. The rows go inside.
//
//   USection { theme: theme; title: "Appearance"; URow { ... } URow { ... } }
Column {
  id: root
  required property var theme
  property string title: ""
  // The first section on a page has no gap above it.
  property bool first: false
  default property alias content: body.data

  width: parent ? parent.width : implicitWidth
  topPadding: first ? 0 : theme.sp.xl
  spacing: theme.sp.xs

  Text {
    text: root.title
    color: root.theme.secondary
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.footnoteSize
    font.weight: root.theme.headlineWeight
    Accessible.role: Accessible.Heading
    Accessible.name: root.title
  }
  Column {
    id: body
    width: parent.width
  }
}
