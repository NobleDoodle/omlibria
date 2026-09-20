import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// Headless owner of everything Omlibria does: library scan, reading
// state, and the two surfaces (compact popup under the bar button / tiled
// window). Both surfaces show the same Panel.qml, so switching between them
// only swaps the window.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string helper: Qt.resolvedUrl("bin/omlibria").toString().replace("file://", "")
  readonly property string cacheRoot: home + "/.cache/omarchy/omlibria"

  // The helper caps its own output. This is the backstop for a helper that has
  // been replaced or has failed to: reading stops at the ceiling, before the
  // response is buffered any further or handed to JSON.parse, so a crafted
  // library cannot grow this long-lived shell process.
  readonly property int maxResponseBytes: 16 * 1024 * 1024

  // ---- persisted state ----------------------------------------------------
  // library, lastKey, lastView, fontSize, serif, sort,
  // books: { <key>: { spine, pos, progress, ts } }
  property var st: ({ books: ({}) })
  property bool stateReady: false

  readonly property string library: st.library || ""
  readonly property int fontSize: st.fontSize || 18
  readonly property bool serif: st.serif !== false
  readonly property string sort: st.sort || "recent"

  // ---- runtime state ------------------------------------------------------
  property string mode: "closed"          // closed | menu | window
  property string view: "shelf"           // shelf | reader
  property var books: []
  property string scanError: ""
  property bool scanning: false
  property var foundLibraries: []
  property string currentKey: ""
  property var book: null                 // result of `prepare` for currentKey
  property string bookError: ""
  property bool bookLoading: false
  property var reader: null               // live ReaderView, registered by itself
  property var targetScreen: null
  property var menuAnchor: ({ x: -1, h: 36, pos: "top" })  // where the popup drops from (x < 0: top right)

  readonly property var booksByKey: {
    var m = ({})
    for (var i = 0; i < books.length; i++) m[books[i].key] = books[i]
    return m
  }

  function progressFor(key) {
    return (st.books && st.books[key]) || null
  }

  function setState(patch) {
    var next = ({})
    for (var k in st) next[k] = st[k]
    for (var p in patch) next[p] = patch[p]
    st = next
    saveTimer.restart()
  }

  function savePosition(key, spine, pos, progress) {
    if (!key) return
    var all = ({})
    for (var k in st.books) all[k] = st.books[k]
    all[key] = { spine: spine, pos: pos, progress: progress, ts: Date.now() }
    setState({ books: all, lastKey: key })
  }

  // ---- open / close -------------------------------------------------------
  function pickScreen() {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function screenByName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  // Open the compact popup. With an anchor it drops directly under the bar
  // button. It resumes the book you were reading, unless `forceShelf`.
  function open(forceShelf, anchor) {
    if (mode !== "closed") return
    targetScreen = anchor && screenByName(anchor.screen) || pickScreen()
    if (anchor) menuAnchor = { x: anchor.x, h: anchor.h, pos: anchor.pos }
    refreshLibraries()
    if (library) scan()
    var resume = !forceShelf && st.lastView === "reader" && st.lastKey && library
    if (resume) {
      view = "reader"
      loadBook(st.lastKey)
    } else {
      view = "shelf"
    }
    mode = "menu"
  }

  function close() {
    if (mode === "closed") return
    try { if (reader) reader.saveNow() } catch (e) { console.warn("omlibria: save failed:", e) }
    setState({ lastView: view })
    mode = "closed"
    flushState()
  }

  function toggle(forceShelf, anchor) {
    if (mode === "closed") open(forceShelf === true, anchor)
    else close()
  }

  function showShelf() {
    if (mode === "closed") { open(true, null); return }
    if (reader) reader.saveNow()
    view = "shelf"
    setState({ lastView: "shelf" })
    if (library) scan()
  }

  function expand() {
    if (mode !== "menu") return
    if (reader) reader.saveNow()
    targetScreen = pickScreen()
    mode = "window"
  }

  function collapse() {
    if (mode !== "window") return
    if (reader) reader.saveNow()
    targetScreen = pickScreen()
    mode = "menu"
  }

  function toggleExpanded() {
    if (mode === "menu") expand()
    else if (mode === "window") collapse()
  }

  function openBook(key) {
    if (!key) return
    loadBook(key)
    view = "reader"
    setState({ lastKey: key, lastView: "reader" })
  }

  function loadBook(key) {
    if (book && currentKey === key) return
    currentKey = key
    book = null
    bookError = ""
    bookLoading = true
    prepProc.command = ["python3", helper, "prepare", library, key, cacheRoot]
    prepProc.running = false
    prepProc.running = true
  }

  function setLibrary(path) {
    path = String(path || "").trim().replace(/^~/, home)
    if (!path) return
    setState({ library: path, lastKey: "", lastView: "shelf", books: ({}) })
    books = []
    book = null
    currentKey = ""
    scan()
  }

  function scan() {
    if (!library) return
    scanning = true
    scanProc.command = ["python3", helper, "scan", library]
    scanProc.running = false
    scanProc.running = true
  }

  function refreshLibraries() {
    libsProc.running = false
    libsProc.running = true
  }

  function adjustFont(delta) {
    setState({ fontSize: Math.max(11, Math.min(40, fontSize + delta)) })
  }

  function resetFont() { setState({ fontSize: 18 }) }
  function toggleSerif() { setState({ serif: !serif }) }
  function setSort(s) { setState({ sort: s }) }

  // ---- processes ----------------------------------------------------------
  Process {
    id: scanProc
    stdout: StdioCollector {
      property bool overflowed: false
      onDataChanged: {
        if (!overflowed && data && data.byteLength > root.maxResponseBytes) {
          overflowed = true
          scanProc.running = false
        }
      }
      onStreamFinished: {
        root.scanning = false
        if (overflowed) {
          root.books = []
          root.scanError = "This library returned more data than Omlibria will read"
          overflowed = false
          return
        }
        try {
          var r = JSON.parse(text)
          root.books = r.books || []
          root.scanError = r.error || ""
        } catch (e) {
          root.scanError = "Could not read library"
        }
      }
    }
  }

  Process {
    id: prepProc
    stdout: StdioCollector {
      property bool overflowed: false
      onDataChanged: {
        if (!overflowed && data && data.byteLength > root.maxResponseBytes) {
          overflowed = true
          prepProc.running = false
        }
      }
      onStreamFinished: {
        root.bookLoading = false
        if (overflowed) {
          root.book = null
          root.bookError = "This book returned more data than Omlibria will read"
          overflowed = false
          return
        }
        try {
          var r = JSON.parse(text)
          if (r.error) { root.bookError = r.error; root.book = null }
          else root.book = r
        } catch (e) {
          root.bookError = "Could not open this book"
        }
      }
    }
  }

  Process {
    id: libsProc
    command: ["python3", root.helper, "libraries"]
    stdout: StdioCollector {
      property bool overflowed: false
      onDataChanged: {
        if (!overflowed && data && data.byteLength > root.maxResponseBytes) {
          overflowed = true
          libsProc.running = false
        }
      }
      onStreamFinished: {
        if (overflowed) { root.foundLibraries = []; overflowed = false; return }
        try { root.foundLibraries = JSON.parse(text) } catch (e) { root.foundLibraries = [] }
      }
    }
  }

  // ---- persistence --------------------------------------------------------
  function flushState() {
    saveTimer.stop()
    if (stateReady) stateFile.setText(JSON.stringify(st, null, 1))
  }

  Timer {
    id: saveTimer
    interval: 600
    onTriggered: root.flushState()
  }

  FileView {
    id: stateFile
    path: root.home + "/.local/state/omarchy/settings/omlibria.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (!s.books) s.books = ({})
        root.st = s
      } catch (e) {}
      root.stateReady = true
      if (root.library) root.scan()
    }
    onLoadFailed: {
      root.stateReady = true
    }
  }

  Component.onCompleted: {
    // Detect library candidates so first run can offer them.
    root.refreshLibraries()
  }

  // ---- surfaces -----------------------------------------------------------
  Loader {
    active: root.mode === "window"
    sourceComponent: windowComponent
  }

  Loader {
    active: root.mode === "menu"
    sourceComponent: menuComponent
  }

  Component {
    id: menuComponent

    Item {
      // Click-away layer. It covers the whole screen, the bar included, so a
      // press anywhere outside the card closes the popup. It sits on Top while
      // the card sits on Overlay, so the card is always above it.
      PanelWindow {
        screen: root.targetScreen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "omlibria-backdrop"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }

      PanelWindow {
        id: menu
        readonly property int cardWidth: 420
        readonly property int screenHeight: root.targetScreen ? root.targetScreen.height : 1080
        readonly property int screenWidth: root.targetScreen ? root.targetScreen.width : 1920
        readonly property bool atBottom: root.menuAnchor.pos === "bottom"

        screen: root.targetScreen
        anchors { left: true; top: !atBottom; bottom: atBottom }
        margins {
          left: root.menuAnchor.x < 0 ? screenWidth - cardWidth - Style.gapsOut
            : Math.max(Style.gapsOut, Math.min(screenWidth - cardWidth - Style.gapsOut,
                Math.round(root.menuAnchor.x - cardWidth / 2)))
          top: root.menuAnchor.h + Style.gapsOut
          bottom: root.menuAnchor.h + Style.gapsOut
        }
        implicitWidth: cardWidth
        implicitHeight: Math.min(600, screenHeight - root.menuAnchor.h - 4 * Style.gapsOut)
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        WlrLayershell.namespace: "omlibria-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        // Prime with Exclusive so the card has keys the moment it maps, then
        // drop to OnDemand. Exclusive makes Hyprland route *every* pointer
        // event to this surface wherever the cursor is, which would stop the
        // backdrop below from ever seeing the click that dismisses the popup.
        // Keyboard focus survives the switch because the backdrop covers the
        // windows underneath, so focus-follows-mouse cannot pull it away.
        property bool primed: true
        WlrLayershell.keyboardFocus: primed ? WlrKeyboardFocus.Exclusive
                                            : WlrKeyboardFocus.OnDemand

        Timer {
          running: true
          interval: 120
          onTriggered: { menu.primed = false; card.focusActive() }
        }

        Panel {
          id: card
          anchors.fill: parent
          svc: root
          popup: true
        }
      }
    }
  }

  Component {
    id: windowComponent

    FloatingWindow {
      id: win
      screen: root.targetScreen
      title: "Omlibria"
      color: Color.popups.background
      implicitWidth: 900
      implicitHeight: 900
      minimumSize: Qt.size(420, 360)

      onVisibleChanged: {
        if (!visible && root.mode === "window") root.close()
      }

      Panel {
        anchors.fill: parent
        svc: root
        popup: false
        Component.onCompleted: focusActive()
      }
    }
  }

  // ---- IPC ----------------------------------------------------------------
  // omarchy-shell omlibria <function>
  IpcHandler {
    target: "omlibria"

    // `menu` is what the bar button sends: it drops the popup under itself.
    function menu(screen: string, x: int, h: int, pos: string, shelf: bool): void {
      root.toggle(shelf, { screen: screen, x: x, h: h, pos: pos })
    }
    function toggle(): void { root.toggle(false, null) }
    function open(): void { root.open(false, null) }
    function close(): void { root.close() }
    function shelf(): void { root.showShelf() }
    function expand(): void { root.expand() }
    function collapse(): void { root.collapse() }
    function toggleExpanded(): void { root.toggleExpanded() }
    function next(): void { if (root.reader) root.reader.turnPage(1) }
    function prev(): void { if (root.reader) root.reader.turnPage(-1) }
    function library(path: string): void { root.setLibrary(path) }
  }
}
