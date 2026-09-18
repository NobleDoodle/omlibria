import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Thin launcher for the Omlibria service. The service owns the popup and
// tiled window (one per session, not one per monitor), so the bar button only
// sends it IPC.
BarWidget {
  id: root
  moduleName: "io.github.nobledoodle.omlibria"

  // Drop the compact menu directly under this button.
  function openMenu(shelf) {
    var win = root.QsWindow.window
    var p = button.mapToItem(null, button.width / 2, 0)
    Quickshell.execDetached(["omarchy-shell", "omlibria", "menu",
      win && win.screen ? win.screen.name : "",
      String(Math.round(p.x)),
      String(win ? Math.round(win.height) : 36),
      root.bar && root.bar.position === "bottom" ? "bottom" : "top",
      shelf ? "true" : "false"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    tooltipText: "Omlibria"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.openMenu(false)
      else if (b === Qt.RightButton) root.openMenu(true)
    }
  }
}
