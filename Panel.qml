import QtQuick
import qs.Commons

// The surface content shared by the compact popup and the tiled window.
Item {
  id: root

  property var svc: null
  property bool popup: true

  function focusActive() {
    if (!svc) return
    if (svc.view === "reader" && readerLoader.item) readerLoader.item.forceActiveFocus()
    else shelf.forceActiveFocus()
  }

  Rectangle {
    anchors.fill: parent
    radius: root.popup ? Style.cornerRadius : 0
    color: Color.popups.background
    border.width: root.popup ? 2 : 0
    border.color: Color.popups.border
  }

  ShelfView {
    id: shelf
    anchors.fill: parent
    anchors.margins: root.popup ? 2 : 0
    svc: root.svc
    popup: root.popup
    visible: root.svc && root.svc.view === "shelf"
  }

  Loader {
    id: readerLoader
    anchors.fill: parent
    anchors.margins: root.popup ? 2 : 0
    active: root.svc && root.svc.view === "reader"
    onLoaded: item.forceActiveFocus()
    sourceComponent: ReaderView {
      svc: root.svc
      popup: root.popup
    }
  }

  Connections {
    target: root.svc
    function onViewChanged() { Qt.callLater(root.focusActive) }
  }

  Component.onCompleted: Qt.callLater(focusActive)
}
