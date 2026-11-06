import QtQuick
import qs.Commons
import qs.Commons as Commons

// Cover list of the selected Calibre library.
FocusScope {
  id: root

  property var svc: null
  property bool popup: true
  readonly property bool compact: popup

  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Commons.Color.muted
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property int fs: Style.font.body

  property string query: ""
  property bool searching: false
  property bool picking: false
  property bool showHelp: false
  readonly property var sortModes: ["recent", "title", "author", "added"]

  // Both layouts show the same books and share one selection, so switching
  // between them keeps the book you were on.
  property int currentIndex: 0
  readonly property bool gridded: svc && svc.libraryView === "grid"
  readonly property int columns: gridView.columns

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
    if (currentIndex >= 0 && currentIndex < filtered.length)
      svc.openBook(filtered[currentIndex].key)
  }

  function setIndex(i) {
    if (!filtered.length) return
    currentIndex = Math.max(0, Math.min(filtered.length - 1, i))
  }

  function move(delta) { setIndex(currentIndex + delta) }

  // Down and up mean the next row, which is one book in the list and a whole
  // row of covers in the grid.
  function moveRow(delta) { setIndex(currentIndex + delta * (gridded ? columns : 1)) }

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
    if (currentIndex >= filtered.length) currentIndex = Math.max(0, filtered.length - 1)
  }

  Connections {
    target: root.svc
    function onLibraryPickRequested() { Qt.callLater(root.startPicking) }
  }

  Keys.onPressed: function(e) {
    var ctrl = e.modifiers & Qt.ControlModifier
    var shift = e.modifiers & Qt.ShiftModifier
    if (picking) return
    if (showHelp) { showHelp = false; e.accepted = true; return }
    switch (e.key) {
    case Qt.Key_Down: case Qt.Key_J: moveRow(1); break
    case Qt.Key_Up: case Qt.Key_K: moveRow(-1); break
    case Qt.Key_PageDown: moveRow(gridded ? 3 : 6); break
    case Qt.Key_PageUp: moveRow(gridded ? -3 : -6); break
    case Qt.Key_D: if (ctrl) moveRow(gridded ? 3 : 6); else return; break
    case Qt.Key_U: if (ctrl) moveRow(gridded ? -3 : -6); else return; break
    case Qt.Key_Home: case Qt.Key_G:
      if (e.key === Qt.Key_G && shift) setIndex(filtered.length - 1)
      else setIndex(0)
      break
    case Qt.Key_End: setIndex(filtered.length - 1); break
    case Qt.Key_Left: case Qt.Key_H:
      if (!gridded) return
      move(-1); break
    case Qt.Key_Right: case Qt.Key_L:
      if (gridded) move(1); else openCurrent(); break
    case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
      openCurrent(); break
    case Qt.Key_V: svc.toggleLibraryView(); break
    case Qt.Key_Comma: svc.showSettings(); break
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
      textFormat: Text.PlainText
      visible: !root.compact
      anchors { left: title.right; leftMargin: 10; baseline: title.baseline }
      text: root.svc ? (root.filtered.length + (root.query ? " of " + root.svc.books.length : "") + " books") : ""
      color: root.dim
      font { family: root.fontFamily; pixelSize: root.fs - 2 }
    }

    Row {
      anchors { right: parent.right; rightMargin: 14; top: parent.top; topMargin: 10 }
      spacing: 4
      IconButton {
        glyph: root.gridded ? "▤" : "▦"
        tip: root.gridded ? "Show as a list (v)" : "Show as a cover grid (v)"
        onClicked: root.svc.toggleLibraryView()
      }
      IconButton { glyph: "↻"; tip: "Rescan library folder (r)"; onClicked: root.svc.scan() }
      IconButton { glyph: "☰"; tip: "Choose library (o)"; onClicked: root.startPicking() }
      IconButton { glyph: "⚙"; tip: "Settings (,)"; onClicked: root.svc.showSettings() }
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
        textFormat: Text.PlainText
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
        selectedTextColor: Commons.Color.popups.background
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
        textFormat: Text.PlainText
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
  Item {
    id: shelfBody
    anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
    clip: true

    ListView {
      id: list
      anchors.fill: parent
      visible: !root.gridded
      model: root.filtered
      currentIndex: root.currentIndex
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
        readonly property bool current: root.currentIndex === index
        readonly property bool last: root.svc && root.svc.st.lastKey === modelData.key

        width: list.width
        height: root.compact ? 70 : 92

        Rectangle {
          anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
          radius: Style.cornerRadius
          color: row.current ? Commons.Color.menu.selectedBackground
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
            color: row.current ? Commons.Color.menu.selectedText : root.fg
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
              textFormat: Text.PlainText
              id: pct
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              visible: row.prog !== null
              text: (row.last ? "Continue \u00b7 " : "") + Math.round((row.prog ? row.prog.progress : 0) * 100) + "%"
              color: row.last ? root.accent : root.dim
              font { family: root.fontFamily; pixelSize: root.fs - 3 }
            }
          }
        }

        MouseArea {
          id: rowArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: { root.currentIndex = row.index; root.openCurrent() }
        }
      }
    }

    // Cover grid. The cell is sized from the panel width so the covers stay
    // the same shape at every panel size, and the title and author sit under
    // each one on fixed lines so no cell is taller than its neighbors.
    GridView {
      id: gridView
      anchors.fill: parent
      anchors.leftMargin: 12
      anchors.rightMargin: 12
      visible: root.gridded
      model: root.filtered
      currentIndex: root.currentIndex
      boundsBehavior: Flickable.StopAtBounds
      highlightMoveDuration: 0
      keyNavigationEnabled: false
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

      readonly property int minCell: root.compact ? 104 : 128
      readonly property int columns: Math.max(2, Math.floor(width / minCell))
      cellWidth: width > 0 ? Math.floor(width / columns) : minCell
      cellHeight: Math.round((cellWidth - 12) * 1.5) + 2 * root.fs + 22

      delegate: Item {
        id: cell
        required property var modelData
        required property int index
        readonly property var prog: root.svc ? root.svc.progressFor(modelData.key) : null
        readonly property bool current: root.currentIndex === index
        readonly property bool last: root.svc && root.svc.st.lastKey === modelData.key

        width: gridView.cellWidth
        height: gridView.cellHeight

        Rectangle {
          anchors { fill: parent; margins: 2 }
          radius: Style.cornerRadius
          color: cell.current ? Commons.Color.menu.selectedBackground
            : cellArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : "transparent"
          border.width: cell.current ? 1 : 0
          border.color: root.accent
        }

        Column {
          anchors { fill: parent; margins: 6 }
          spacing: 4

          Rectangle {
            id: art
            width: parent.width
            height: Math.round(width * 1.5)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            radius: 3
            clip: true
            Image {
              anchors.fill: parent
              source: cell.modelData.cover ? "file://" + cell.modelData.cover : ""
              sourceSize: Qt.size(200, 300)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
            }
            Text {
              anchors.centerIn: parent
              visible: !cell.modelData.cover
              text: cell.modelData.title.charAt(0)
              textFormat: Text.PlainText
              color: root.dim
              font { family: root.fontFamily; pixelSize: 28; bold: true }
            }
            // Progress sits on the cover itself, so a cell is the same height
            // whether or not the book has been opened.
            Rectangle {
              visible: cell.prog !== null
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              height: 4
              color: Qt.rgba(0, 0, 0, 0.45)
              Rectangle {
                width: parent.width * Math.max(0, Math.min(1, cell.prog ? cell.prog.progress : 0))
                height: parent.height
                color: cell.last ? root.accent : Qt.rgba(1, 1, 1, 0.75)
              }
            }
          }

          Text {
            width: parent.width
            height: root.fs + 4
            text: cell.modelData.title
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: cell.current ? Commons.Color.menu.selectedText : root.fg
            font { family: root.fontFamily; pixelSize: root.fs - 2; bold: true }
          }
          Text {
            width: parent.width
            height: root.fs
            text: cell.modelData.authors
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.dim
            font { family: root.fontFamily; pixelSize: root.fs - 4 }
          }
        }

        MouseArea {
          id: cellArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: { root.currentIndex = cell.index; root.openCurrent() }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      width: parent.width - 60
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      visible: root.filtered.length === 0
      color: root.dim
      font { family: root.fontFamily; pixelSize: root.fs }
      text: !root.svc.library ? "Choose a Calibre library to begin"
        : root.svc.scanError ? root.svc.scanError
        : root.svc.scanning ? "Scanning library\u2026"
        : root.query ? "No books match \u201c" + root.query + "\u201d"
        : "No EPUB books found in this library"
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
      text: "↵ read   / search   v view   , settings   ? help"
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
    color: Commons.Color.popups.background
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
        textFormat: Text.PlainText
        text: "Calibre library"
        color: root.fg
        font { family: root.fontFamily; pixelSize: root.fs + 5; bold: true }
      }
      Text {
        textFormat: Text.PlainText
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
          selectedTextColor: Commons.Color.popups.background
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
        textFormat: Text.PlainText
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
          color: ListView.isCurrentItem && found.activeFocus ? Commons.Color.menu.selectedBackground : "transparent"
          Text {
            textFormat: Text.PlainText
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
        textFormat: Text.PlainText
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
    rows: root.gridded ? [
      ["h / l, ← →", "previous / next book"],
      ["j / k, ↑ ↓", "up / down a row"],
      ["g / G", "first / last"],
      ["Enter, Space", "open book"],
      ["v", "back to the list"],
      ["c", "continue last book"],
      ["/", "search (Esc clears)"],
      ["s", "cycle sort"],
      ["r", "rescan library"],
      ["o", "choose library"],
      [",", "settings and about"],
      ["e", "menu ↔ tiled window"],
      ["Esc, q", "close"]
    ] : [
      ["j / k, ↑ ↓", "move"],
      ["g / G", "first / last"],
      ["Enter, l", "open book"],
      ["v", "cover grid"],
      ["c", "continue last book"],
      ["/", "search (Esc clears)"],
      ["s", "cycle sort"],
      ["r", "rescan library"],
      ["o", "choose library"],
      [",", "settings and about"],
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
      textFormat: Text.PlainText
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
      z: 20          // over the search field and the list it overhangs
      anchors { top: parent.bottom; topMargin: 6; right: parent.right }
      width: tipText.implicitWidth + 16
      height: tipText.implicitHeight + 10
      radius: Style.cornerRadius
      // The theme's tooltip color can be translucent, which reads as smeared
      // text over whatever the tip covers. Keep its hue, drop the alpha.
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
