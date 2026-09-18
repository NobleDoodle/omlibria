import QtQuick
import qs.Commons

// Full-panel cheat sheet. `rows` is a list of [keys, description] pairs; an
// entry with an empty description renders as a section label.
Rectangle {
  id: root

  property string heading: ""
  property var rows: []
  property string footnote: ""
  signal dismissed()

  color: Color.popups.background
  z: 10

  MouseArea { anchors.fill: parent; onClicked: root.dismissed() }

  Column {
    anchors { fill: parent; margins: 24 }
    spacing: 6

    Text {
      text: root.heading
      color: Color.popups.text
      font { family: Style.font.family; pixelSize: Style.font.body + 5; bold: true }
      bottomPadding: 8
    }

    Repeater {
      model: root.rows
      Row {
        required property var modelData
        spacing: 14
        Text {
          width: 150
          text: modelData[0]
          color: Color.accent
          elide: Text.ElideRight
          font { family: Style.font.family; pixelSize: Style.font.body - 1; bold: true }
        }
        Text {
          width: root.width - 48 - 150 - 14
          text: modelData[1]
          color: Color.popups.text
          elide: Text.ElideRight
          font { family: Style.font.family; pixelSize: Style.font.body - 1 }
        }
      }
    }

    Text {
      topPadding: 10
      text: root.footnote
      width: parent.width
      wrapMode: Text.Wrap
      color: Color.muted
      font { family: Style.font.family; pixelSize: Style.font.body - 2 }
    }
  }
}
