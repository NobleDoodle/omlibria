import QtQuick
import qs.Commons

// Cover list of the selected Calibre library.
FocusScope {
  id: root

  property var svc: null
  property bool popup: true
  readonly property bool compact: popup

  readonly property color fg: Color.popups.text
  readonly property color dim: Color.muted
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property int fs: Style.font.body

  property string query: ""
  property bool searching: false
  property bool picking: false
  property bool showHelp: false
  readonly property var sortModes: ["recent", "title", "author", "added"]

  readonly property var filtered: {
    var list = svc ? svc.books : []
    var words = query.toLowerCase().split(/\s+/).filter(function(w) { return w.length })
    var out = []
    for (var i = 0; i < list.length; i++) {
      var b = list[i]
      var hay = (b.title + " " + b.authors + " " + b.series).toLowerCase()
      var ok = true
      for (var w = 0; w < words.length; w++) if (hay.indexOf(words[w]) === -1) { ok = false; break }
      if (ok) out.push(b)
    }
    var mode = svc ? svc.sort : "recent"
    var prog = function(b) { var p = svc.progressFor(b.key); return p ? p.ts : 0 }
    out.sort(function(a, b) {
      if (mode === "recent") {
        var d = prog(b) - prog(a)
        if (d !== 0) return d
        return a.sort < b.sort ? -1 : a.sort > b.sort ? 1 : 0
      }
      if (mode === "author") {
        var x = a.authors.toLowerCase(), y = b.authors.toLowerCase()
        if (x !== y) return x < y ? -1 : 1
        return a.seriesIndex - b.seriesIndex || (a.sort < b.sort ? -1 : 1)
      }
      if (mode === "added") return a.added < b.added ? 1 : a.added > b.added ? -1 : 0
      return a.sort < b.sort ? -1 : a.sort > b.sort ? 1 : 0
    })
    return out
  }

  function openCurrent() {
    if (list.currentIndex >= 0 && list.currentIndex < filtered.length)
      svc.openBook(filtered[list.currentIndex].key)
  }

  function move(delta) {
    if (!filtered.length) return
    list.currentIndex = Math.max(0, Math.min(filtered.length - 1, list.currentIndex + delta))
  }

  function cycleSort() {
    var i = sortModes.indexOf(svc.sort)
    svc.setSort(sortModes[(i + 1) % sortModes.length])
  }

  // Same FocusScope rule as the reader's table of contents: clear the child's
  // own focus before handing it back, or it keeps receiving keys while hidden.
  function returnFocus() {
    searchField.focus = false
    pathField.focus = false
    found.focus = false
    root.forceActiveFocus()
  }

  function startPicking() {
    picking = true
    svc.refreshLibraries()
    pathField.text = svc.library
    pathField.forceActiveFocus()
  }

  onVisibleChanged: if (visible) {
    forceActiveFocus()
    if (svc && stateSettled && !svc.library) startPicking()
  }
  readonly property bool stateSettled: svc ? svc.stateReady : false
  onStateSettledChanged: if (stateSettled && visible && !svc.library) startPicking()

  Connections {
    target: root.svc
    function onLibraryChanged() { root.picking = false; root.returnFocus() }
  }

  onFilteredChanged: {
    if (list.currentIndex >= filtered.length) list.currentIndex = Math.max(0, filtered.length - 1)
  }

  Keys.onPressed: function(e) {
    var ctrl = e.modifiers & Qt.ControlModifier
    var shift = e.modifiers & Qt.ShiftModifier
    if (picking) return
    if (showHelp) { showHelp = false; e.accepted = true; return }
    switch (e.key) {
    case Qt.Key_Down: case Qt.Key_J: move(1); break
    case Qt.Key_Up: case Qt.Key_K: move(-1); break
    case Qt.Key_PageDown: move(6); break
    case Qt.Key_PageUp: move(-6); break
    case Qt.Key_D: if (ctrl) move(6); else return; break
    case Qt.Key_U: if (ctrl) move(-6); else return; break
    case Qt.Key_Home: case Qt.Key_G:
      if (e.key === Qt.Key_G && shift) list.currentIndex = Math.max(0, filtered.length - 1)
      else list.currentIndex = 0
      break
    case Qt.Key_End: list.currentIndex = Math.max(0, filtered.length - 1); break
    case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Right: case Qt.Key_L: case Qt.Key_Space:
      openCurrent(); break
    case Qt.Key_Slash: case Qt.Key_F:
      if (e.key === Qt.Key_F && !ctrl) return
      searching = true; searchField.forceActiveFocus(); break
    case Qt.Key_C:
      if (svc.st.lastKey) svc.openBook(svc.st.lastKey); break
    case Qt.Key_S: cycleSort(); break
    case Qt.Key_R: svc.scan(); break
    case Qt.Key_O: startPicking(); break
    case Qt.Key_E: svc.toggleExpanded(); break
    case Qt.Key_Question: showHelp = true; break
    case Qt.Key_Escape: case Qt.Key_Q:
      if (query !== "") query = ""
      else svc.close()
      break
    default: return
    }
    e.accepted = true
  }

  // ---- header -------------------------------------------------------------
  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 92
    z: 3          // above the list, so button tooltips can overhang it

    Text {
      id: title
      x: 20; y: 14
      text: "Omlibria"
      textFormat: Text.PlainText
      color: root.fg
      font { family: root.fontFamily; pixelSize: root.compact ? root.fs + 2 : root.fs + 5; bold: true }
    }
    Text {
      visible: !root.compact
      anchors { left: title.right; leftMargin: 10; baseline: title.baseline }
      text: root.svc ? (root.filtered.length + (root.query ? " of " + root.svc.books.length : "") + " books") : ""
      color: root.dim
      font { family: root.fontFamily; pixelSize: root.fs - 2 }
    }

    Row {
      anchors { right: parent.right; rightMargin: 14; top: parent.top; topMargin: 10 }
      spacing: 4
      IconButton { glyph: "↻"; tip: "Rescan library folder (r)"; onClicked: root.svc.scan() }
      IconButton { glyph: "☰"; tip: "Choose library (o)"; onClicked: root.startPicking() }
      IconButton {
        glyph: root.popup ? "⤢" : "⤡"
        tip: root.popup ? "Open in tiled window (e)" : "Back to menu (e)"
        onClicked: root.svc.toggleExpanded()
      }
    }

    Rectangle {
      id: searchBox
      anchors { left: parent.left; right: sortChip.left; bottom: parent.bottom; leftMargin: 20; rightMargin: 8; bottomMargin: 12 }
      height: 32
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
      border.width: root.searching ? 1 : 0
      border.color: root.accent

      Text {
        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
        visible: !searchField.text && !root.searching
        text: "Press / to search"
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 1 }
      }
      TextInput {
        id: searchField
        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
        verticalAlignment: TextInput.AlignVCenter
        color: root.fg
        selectionColor: root.accent
        selectedTextColor: Color.popups.background
        font { family: root.fontFamily; pixelSize: root.fs }
        clip: true
        onTextChanged: root.query = text
        Keys.onPressed: function(e) {
          if (e.key === Qt.Key_Escape) {
            text = ""; root.searching = false; root.returnFocus(); e.accepted = true
          } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            root.searching = false; root.returnFocus(); root.openCurrent(); e.accepted = true
          } else if (e.key === Qt.Key_Down || (e.key === Qt.Key_N && (e.modifiers & Qt.ControlModifier))) {
            root.move(1); e.accepted = true
          } else if (e.key === Qt.Key_Up || (e.key === Qt.Key_P && (e.modifiers & Qt.ControlModifier))) {
            root.move(-1); e.accepted = true
          }
        }
        onActiveFocusChanged: if (!activeFocus) root.searching = false
      }
    }

    Rectangle {
      id: sortChip
      anchors { right: parent.right; rightMargin: 20; verticalCenter: searchBox.verticalCenter }
      width: sortText.implicitWidth + 20
      height: 32
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, sortArea.containsMouse ? 0.12 : 0.06)
      Text {
        id: sortText
        anchors.centerIn: parent
        text: "Sort: " + (root.svc ? root.svc.sort : "")
        color: root.fg
        font { family: root.fontFamily; pixelSize: root.fs - 2 }
      }
      MouseArea { id: sortArea; anchors.fill: parent; hoverEnabled: true; onClicked: root.cycleSort() }
    }
  }

  // ---- book list ----------------------------------------------------------
  ListView {
    id: list
    anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
    clip: true
    model: root.filtered
    currentIndex: 0
    boundsBehavior: Flickable.StopAtBounds
    highlightMoveDuration: 0
    keyNavigationEnabled: false
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
    spacing: 2

    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property var prog: root.svc ? root.svc.progressFor(modelData.key) : null
      readonly property bool current: ListView.isCurrentItem
      readonly property bool last: root.svc && root.svc.st.lastKey === modelData.key

      width: list.width
      height: root.compact ? 70 : 92

      Rectangle {
        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
        radius: Style.cornerRadius
        color: row.current ? Color.menu.selectedBackground
          : rowArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent"
        border.width: row.current ? 1 : 0
        border.color: root.accent
      }

      Rectangle {
        id: coverBox
        x: 20; anchors.verticalCenter: parent.verticalCenter
        width: root.compact ? 40 : 48; height: root.compact ? 60 : 72
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        radius: 2
        clip: true
        Image {
          anchors.fill: parent
          source: row.modelData.cover ? "file://" + row.modelData.cover : ""
          sourceSize: Qt.size(96, 144)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
        }
        Text {
          anchors.centerIn: parent
          visible: !row.modelData.cover
          text: row.modelData.title.charAt(0)
          textFormat: Text.PlainText
          color: root.dim
          font { family: root.fontFamily; pixelSize: 24; bold: true }
        }
      }

      Column {
        anchors {
          left: coverBox.right; leftMargin: 14
          right: parent.right; rightMargin: 24
          verticalCenter: parent.verticalCenter
        }
        spacing: 3
        Text {
          width: parent.width
          text: row.modelData.title
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: row.current ? Color.menu.selectedText : root.fg
          font { family: root.fontFamily; pixelSize: root.fs + 1; bold: true }
        }
        Text {
          width: parent.width
          text: row.modelData.authors
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font { family: root.fontFamily; pixelSize: root.fs - 1 }
        }
        Text {
          width: parent.width
          visible: row.modelData.series !== "" && !root.compact
          text: row.modelData.series + (row.modelData.seriesIndex ? " #" + row.modelData.seriesIndex : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font { family: root.fontFamily; pixelSize: root.fs - 3; italic: true }
        }
        Item {
          width: parent.width
          height: 14
          Rectangle {
            id: track
            visible: row.prog !== null
            anchors { left: parent.left; right: pct.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            height: 3
            radius: 1.5
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)
            Rectangle {
              width: parent.width * Math.max(0, Math.min(1, row.prog ? row.prog.progress : 0))
              height: parent.height
              radius: parent.radius
              color: root.accent
            }
          }
          Text {
            id: pct
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: row.prog !== null
            text: (row.last ? "Continue · " : "") + Math.round((row.prog ? row.prog.progress : 0) * 100) + "%"
            color: row.last ? root.accent : root.dim
            font { family: root.fontFamily; pixelSize: root.fs - 3 }
          }
        }
      }

      MouseArea {
        id: rowArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: { list.currentIndex = row.index; root.openCurrent() }
      }
    }

    Text {
      anchors.centerIn: parent
      width: parent.width - 60
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      visible: root.filtered.length === 0
      color: root.dim
      font { family: root.fontFamily; pixelSize: root.fs }
      text: !root.svc.library ? "Choose a Calibre library to begin"
        : root.svc.scanError ? root.svc.scanError
        : root.svc.scanning ? "Scanning library…"
        : root.query ? "No books match “" + root.query + "”"
        : "No EPUB books found in this library"
    }
  }

  // ---- footer -------------------------------------------------------------
  Item {
    id: footer
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 30
    Text {
      anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
      text: "↵ read   / search   c continue   s sort   ? help"
      color: root.dim
      elide: Text.ElideRight
      width: parent.width - 40
      font { family: root.fontFamily; pixelSize: root.fs - 3 }
    }
  }

  // ---- library picker -----------------------------------------------------
  Rectangle {
    id: picker
    anchors.fill: parent
    visible: root.picking
    color: Color.popups.background
    z: 5

    function apply(path) {
      root.svc.setLibrary(path)
      root.picking = false
      root.returnFocus()
    }

    function cancel() {
      root.picking = false
      if (!root.svc.library) root.svc.close()
      else root.returnFocus()
    }

    Column {
      anchors { fill: parent; margins: 20 }
      spacing: 10

      Text {
        text: "Calibre library"
        color: root.fg
        font { family: root.fontFamily; pixelSize: root.fs + 5; bold: true }
      }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "Pick a folder that contains metadata.db, or type a path."
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 1 }
      }

      Rectangle {
        width: parent.width
        height: 34
        radius: Style.cornerRadius
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
        border.width: 1
        border.color: pathField.activeFocus ? root.accent : "transparent"
        TextInput {
          id: pathField
          anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
          verticalAlignment: TextInput.AlignVCenter
          color: root.fg
          selectionColor: root.accent
          selectedTextColor: Color.popups.background
          font { family: root.fontFamily; pixelSize: root.fs }
          clip: true
          Keys.onPressed: function(e) {
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
              picker.apply(text); e.accepted = true
            } else if (e.key === Qt.Key_Down) {
              found.forceActiveFocus(); e.accepted = true
            } else if (e.key === Qt.Key_Escape) {
              picker.cancel(); e.accepted = true
            }
          }
        }
      }

      Text {
        visible: found.count > 0
        text: "Detected"
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 2 }
      }

      ListView {
        id: found
        width: parent.width
        height: Math.min(contentHeight, 240)
        clip: true
        model: root.svc ? root.svc.foundLibraries : []
        currentIndex: 0
        Keys.onPressed: function(e) {
          if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            if (currentIndex >= 0) picker.apply(model[currentIndex])
            e.accepted = true
          } else if (e.key === Qt.Key_J) { currentIndex = Math.min(count - 1, currentIndex + 1); e.accepted = true }
          else if (e.key === Qt.Key_K) { currentIndex = Math.max(0, currentIndex - 1); e.accepted = true }
          else if (e.key === Qt.Key_Escape) { picker.cancel(); e.accepted = true }
        }
        delegate: Rectangle {
          required property string modelData
          required property int index
          width: found.width
          height: 34
          radius: Style.cornerRadius
          color: ListView.isCurrentItem && found.activeFocus ? Color.menu.selectedBackground : "transparent"
          Text {
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
            text: parent.modelData
            color: root.fg
            font { family: root.fontFamily; pixelSize: root.fs }
          }
          MouseArea { anchors.fill: parent; onClicked: picker.apply(parent.modelData) }
        }
      }

      Text {
        text: "Enter select   ↓ detected list   Esc cancel"
        color: root.dim
        font { family: root.fontFamily; pixelSize: root.fs - 3 }
      }
    }
  }

  // ---- help ---------------------------------------------------------------
  HelpOverlay {
    anchors.fill: parent
    visible: root.showHelp
    heading: "Library"
    footnote: "Any key dismisses this."
    rows: [
      ["j / k, ↑ ↓", "move"],
      ["g / G", "first / last"],
      ["Enter, l", "open book"],
      ["c", "continue last book"],
      ["/", "search (Esc clears)"],
      ["s", "cycle sort"],
      ["r", "rescan library"],
      ["o", "choose library"],
      ["e", "menu ↔ tiled window"],
      ["Esc, q", "close"]
    ]
    onDismissed: root.showHelp = false
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
      anchors.centerIn: parent
      text: btn.glyph
      color: btn.active ? root.accent : root.fg
      font { family: root.fontFamily; pixelSize: root.fs + 2 }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: btn.clicked() }

    // Tooltip after a short hover. Right-aligned to the button because these
    // sit at the card's right edge, so it grows inward instead of off the card.
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
      anchors { top: parent.bottom; topMargin: 6; right: parent.right }
      width: tipText.implicitWidth + 16
      height: tipText.implicitHeight + 10
      radius: Style.cornerRadius
      color: Color.tooltip.background
      border.width: 1
      border.color: Color.tooltip.border
      Text {
        id: tipText
        anchors.centerIn: parent
        text: btn.tip
        textFormat: Text.PlainText
        color: Color.tooltip.text
        font { family: root.fontFamily; pixelSize: root.fs - 2 }
      }
    }
  }
}
