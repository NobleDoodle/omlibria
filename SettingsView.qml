import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Settings, and About behind it, in the same panel as the library and the
// reader. Every row carries the key that works it, so the panel doubles as
// its own cheat sheet.
FocusScope {
  id: root

  property var svc: null
  property bool popup: true

  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Commons.Color.muted
  readonly property color accent: Commons.Color.accent
  // Text to put on an accent fill. The theme's accent can be light or dark, so
  // pick the side of it that stays readable rather than assuming either.
  readonly property color onAccent:
    (0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b) > 0.55 ? "#101010" : "#ffffff"
  readonly property string fontFamily: Style.font.family
  readonly property int fs: Style.font.body

  property bool about: false

  // The manifest the shell handed this plugin, so About can never disagree
  // with what is installed.
  readonly property var mf: svc && svc.manifest ? svc.manifest : null
  readonly property string pluginName: mf && mf.name ? String(mf.name) : "Omlibria"
  readonly property string pluginVersion: mf && mf.version ? String(mf.version) : "unknown"
  readonly property string pluginAuthor: mf && mf.author ? String(mf.author) : "NobleDoodle"
  readonly property string pluginLicense: mf && mf.license ? String(mf.license) : "MIT"

  readonly property string repoUrl: "https://github.com/NobleDoodle/omlibria"
  readonly property string issuesUrl: "https://github.com/NobleDoodle/omlibria/issues/new"
  readonly property string coffeeUrl: "https://buymeacoffee.com/nobledoodle"

  function openLink(url) {
    Quickshell.execDetached(["xdg-open", url])
    svc.close()
  }

  function back() {
    if (about) about = false
    else svc.closeSettings()
  }

  function chooseLibrary() { svc.pickLibrary() }

  onVisibleChanged: if (visible) forceActiveFocus()

  Keys.onPressed: function(e) {
    if (about) {
      switch (e.key) {
      case Qt.Key_I: openLink(issuesUrl); break
      case Qt.Key_G: openLink(repoUrl); break
      case Qt.Key_B: openLink(coffeeUrl); break
      case Qt.Key_Question: case Qt.Key_Escape: case Qt.Key_Comma: about = false; break
      case Qt.Key_Q: svc.close(); break
      default: return
      }
      e.accepted = true
      return
    }
    switch (e.key) {
    case Qt.Key_1: svc.setPanelSize("small"); break
    case Qt.Key_2: svc.setPanelSize("medium"); break
    case Qt.Key_3: svc.setPanelSize("large"); break
    case Qt.Key_V: svc.toggleLibraryView(); break
    case Qt.Key_F: svc.toggleSerif(); break
    case Qt.Key_Plus: case Qt.Key_Equal: svc.adjustFont(1); break
    case Qt.Key_Minus: svc.adjustFont(-1); break
    case Qt.Key_0: svc.resetFont(); break
    case Qt.Key_O: chooseLibrary(); break
    case Qt.Key_R: svc.scan(); break
    case Qt.Key_E: svc.toggleExpanded(); break
    case Qt.Key_Question: about = true; break
    case Qt.Key_Escape: case Qt.Key_Comma: case Qt.Key_B: back(); break
    case Qt.Key_Q: svc.close(); break
    default: return
    }
    e.accepted = true
  }

  // ---- header -------------------------------------------------------------
  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 48
    z: 3

    IconButton {
      id: backButton
      anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
      glyph: "‹"
      tip: root.about ? "Back to settings (?)" : "Back (Esc)"
      onClicked: root.back()
    }

    Text {
      textFormat: Text.PlainText
      anchors { left: backButton.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
      text: root.about ? "About" : "Settings"
      color: root.fg
      font { family: root.fontFamily; pixelSize: root.fs + 2; bold: true }
    }

    IconButton {
      anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
      glyph: "?"
      active: root.about
      tip: root.about ? "Back to settings (?)" : "About Omlibria (?)"
      onClicked: root.about = !root.about
    }
  }

  // ---- settings -----------------------------------------------------------
  Flickable {
    id: body
    anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
    clip: true
    contentWidth: width
    contentHeight: settings.height + 28
    boundsBehavior: Flickable.StopAtBounds
    visible: !root.about

    Column {
      id: settings
      x: 20
      y: 4
      width: parent.width - 40
      spacing: 10

      SectionLabel { text: "Panel" }

      ChoiceRow {
        label: "Size"
        note: root.popup ? "" : "Applies to the menu popup"
        options: [
          { label: "Small", value: "small", key: "1" },
          { label: "Medium", value: "medium", key: "2" },
          { label: "Large", value: "large", key: "3" }
        ]
        current: root.svc ? root.svc.panelSize : "small"
        onPicked: function(value) { root.svc.setPanelSize(value) }
      }

      ChoiceRow {
        label: "Library"
        keyHint: "v"
        options: [
          { label: "List", value: "list", key: "" },
          { label: "Grid", value: "grid", key: "" }
        ]
        current: root.svc ? root.svc.libraryView : "list"
        onPicked: function(value) { root.svc.setLibraryView(value) }
      }

      Separator {}

      SectionLabel { text: "Reading" }

      ChoiceRow {
        label: "Typeface"
        keyHint: "f"
        options: [
          { label: "Serif", value: "serif", key: "" },
          { label: "Sans", value: "sans", key: "" }
        ]
        current: root.svc && root.svc.serif ? "serif" : "sans"
        onPicked: function(value) {
          if ((value === "serif") !== root.svc.serif) root.svc.toggleSerif()
        }
      }

      Item {
        width: parent.width
        height: 32
        Text {
          textFormat: Text.PlainText
          anchors { left: parent.left; verticalCenter: parent.verticalCenter }
          text: "Text size"
          color: root.fg
          font { family: root.fontFamily; pixelSize: root.fs }
        }
        Row {
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          spacing: 6
          Pill { text: "−"; fixedWidth: 32; onPicked: root.svc.adjustFont(-1) }
          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: 34
            horizontalAlignment: Text.AlignHCenter
            text: root.svc ? String(root.svc.fontSize) : ""
            color: root.fg
            font { family: root.fontFamily; pixelSize: root.fs }
          }
          Pill { text: "+"; fixedWidth: 32; onPicked: root.svc.adjustFont(1) }
        }
      }

      Separator {}

      SectionLabel { text: "Calibre library" }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.svc && root.svc.library ? root.svc.library : "No library chosen"
        elide: Text.ElideMiddle
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 2 }
      }

      Row {
        spacing: 8
        Pill { text: "Change folder  (o)"; onPicked: root.chooseLibrary() }
        Pill { text: "Rescan  (r)"; onPicked: root.svc.scan() }
      }

      Item { width: 1; height: 2 }
    }
  }

  // ---- about --------------------------------------------------------------
  Flickable {
    anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
    clip: true
    contentWidth: width
    contentHeight: aboutColumn.height + 28
    boundsBehavior: Flickable.StopAtBounds
    visible: root.about

    Column {
      id: aboutColumn
      x: 20
      y: 4
      width: parent.width - 40
      spacing: 10

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: "Read the EPUBs in your Calibre library from the Omarchy bar."
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 1 }
      }

      Separator {}

      Repeater {
        model: [
          { label: "Plugin", value: root.pluginName + " " + root.pluginVersion },
          { label: "Author", value: root.pluginAuthor },
          { label: "License", value: root.pluginLicense }
        ]
        delegate: Item {
          id: fact
          required property var modelData
          width: aboutColumn.width
          height: 24
          Text {
            id: factLabel
            textFormat: Text.PlainText
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            text: fact.modelData.label
            color: root.dim
            font { family: root.fontFamily; pixelSize: root.fs - 2 }
          }
          Text {
            textFormat: Text.PlainText
            anchors {
              left: factLabel.right; leftMargin: 14
              right: parent.right; verticalCenter: parent.verticalCenter
            }
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            text: fact.modelData.value
            color: root.fg
            font { family: root.fontFamily; pixelSize: root.fs - 1 }
          }
        }
      }

      Separator {}

      Pill { wide: true; text: "Report a problem  (i)"; onPicked: root.openLink(root.issuesUrl) }
      Pill { wide: true; text: "Source on GitHub  (g)"; onPicked: root.openLink(root.repoUrl) }
      Pill { wide: true; text: "Buy me a coffee  (b)"; onPicked: root.openLink(root.coffeeUrl) }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: "A link opens in your browser and closes Omlibria."
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 3 }
      }
    }
  }

  // ---- footer -------------------------------------------------------------
  Item {
    id: footer
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 30
    Text {
      textFormat: Text.PlainText
      anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
      text: root.about ? "i issue   g source   b coffee   ? back"
                       : "1/2/3 size   v view   f font   ± size   ? about   Esc back"
      color: root.dim
      elide: Text.ElideRight
      width: parent.width - 40
      font { family: root.fontFamily; pixelSize: root.fs - 3 }
    }
  }

  // ---- small parts --------------------------------------------------------
  component SectionLabel: Text {
    textFormat: Text.PlainText
    color: root.accent
    font { family: root.fontFamily; pixelSize: root.fs - 3; bold: true }
  }

  component Separator: Rectangle {
    width: parent ? parent.width : 0
    height: 1
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
  }

  component Pill: Rectangle {
    id: pill
    property string text: ""
    property bool wide: false
    property int fixedWidth: 0
    signal picked()
    width: fixedWidth > 0 ? fixedWidth
      : wide ? (parent ? parent.width : 0)
      : pillText.implicitWidth + 22
    height: 30
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, pillArea.containsMouse ? 0.14 : 0.07)
    Text {
      id: pillText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: pill.text
      color: root.fg
      font { family: root.fontFamily; pixelSize: root.fs - 1 }
    }
    MouseArea {
      id: pillArea
      anchors.fill: parent
      hoverEnabled: true
      onClicked: pill.picked()
    }
  }

  // A label on the left and a segmented control on the right: the segment that
  // is on takes the accent, and its key, if it has one, rides beside it.
  component ChoiceRow: Item {
    id: choice
    property string label: ""
    property string keyHint: ""      // a key shown beside the label
    property string note: ""         // a sentence shown under it
    property var options: []
    property string current: ""
    signal picked(string value)

    width: parent ? parent.width : 0
    height: 32

    Column {
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      spacing: 1
      Text {
        textFormat: Text.PlainText
        text: choice.label + (choice.keyHint ? "  (" + choice.keyHint + ")" : "")
        color: root.fg
        font { family: root.fontFamily; pixelSize: root.fs }
      }
      Text {
        textFormat: Text.PlainText
        visible: choice.note !== ""
        text: choice.note
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 4 }
      }
    }

    Row {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 4
      Repeater {
        model: choice.options
        delegate: Rectangle {
          id: seg
          required property var modelData
          readonly property bool on: choice.current === seg.modelData.value
          width: segText.implicitWidth + 20
          height: 28
          radius: Style.cornerRadius
          color: seg.on ? root.accent
            : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, segArea.containsMouse ? 0.14 : 0.07)
          Text {
            id: segText
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: seg.modelData.label + (seg.modelData.key ? "  " + seg.modelData.key : "")
            color: seg.on ? root.onAccent : root.fg
            font { family: root.fontFamily; pixelSize: root.fs - 2 }
          }
          MouseArea {
            id: segArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: choice.picked(seg.modelData.value)
          }
        }
      }
    }
  }

  component IconButton: Rectangle {
    id: btn
    property string glyph: ""
    property string tip: ""
    property bool active: false
    signal clicked()
    width: 30; height: 30
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, ma.containsMouse ? 0.12 : 0)
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: btn.glyph
      color: btn.active ? root.accent : root.fg
      font { family: root.fontFamily; pixelSize: root.fs + 2 }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: btn.clicked() }

    property bool tipShown: false
    Timer {
      interval: 400
      running: ma.containsMouse && btn.tip !== ""
      onTriggered: btn.tipShown = true
    }
    Connections {
      target: ma
      function onContainsMouseChanged() { if (!ma.containsMouse) btn.tipShown = false }
    }
    Rectangle {
      visible: btn.tipShown
      z: 20
      anchors { top: parent.bottom; topMargin: 6; right: parent.right }
      width: tipText.implicitWidth + 16
      height: tipText.implicitHeight + 10
      radius: Style.cornerRadius
      // Opaque, like the shelf's: a translucent tip smears over the rows below.
      color: Qt.rgba(Commons.Color.tooltip.background.r,
                     Commons.Color.tooltip.background.g,
                     Commons.Color.tooltip.background.b, 1)
      border.width: 1
      border.color: Commons.Color.tooltip.border
      Text {
        id: tipText
        anchors.centerIn: parent
        text: btn.tip
        textFormat: Text.PlainText
        color: Commons.Color.tooltip.text
        font { family: root.fontFamily; pixelSize: root.fs - 2 }
      }
    }
  }
}
