import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Paginated EPUB reader. Pages break on whole-line boundaries and turn with a
// short side-to-side slide. The reading position is stored as (spine index,
// character offset of the first line on the page), which survives resizing,
// switching menu <-> tiled, and changing the font size.
FocusScope {
  id: root

  property var svc: null
  property bool popup: true

  readonly property color fg: Color.popups.text
  readonly property color dim: Color.muted
  readonly property color accent: Color.accent
  readonly property string uiFont: Style.font.family
  readonly property string bodyFont: svc && svc.serif ? "serif" : Style.font.family
  readonly property int uiSize: Style.font.body
  readonly property int fontSize: svc ? svc.fontSize : 18
  readonly property real lineMult: 1.35
  readonly property real lineH: Math.max(12, Math.round(metrics.lineSpacing * lineMult))
  readonly property int pad: 20
  // A line box carries more empty space below its glyphs (descent plus the
  // extra leading) than above them, so splitting the padding unevenly is what
  // makes the ink sit with equal space above and below on a full page.
  readonly property int padBias: Math.max(0, Math.min(Math.round(pad / 2),
    Math.round((lineH - metrics.height) / 2 + metrics.descent / 2)))
  readonly property int padTop: pad + padBias
  readonly property int padBottom: pad - padBias
  readonly property int slideDistance: 48

  readonly property var book: svc ? svc.book : null
  readonly property var spine: book ? book.spine : []
  readonly property var toc: book ? book.toc : []
  readonly property var meta: svc && svc.currentKey ? svc.booksByKey[svc.currentKey] : null
  readonly property string bookTitle: meta ? meta.title : (book ? book.title : "")

  property int spineIndex: -1
  property int anchorPos: 0          // char offset of the page's first line; -2 = last page
  property bool chapterReady: false
  property bool showToc: false
  property bool showHelp: false
  property string chapterHtml: ""
  // True from the moment a chapter is requested until its text arrives. Clearing
  // the old text changes the document height, which schedules a layout pass; a
  // large chapter takes longer than that pass to convert, so without this the
  // pass runs against an empty document. It finds no link target, discards the
  // fragment and the requested page, and the real text then opens at the top.
  property bool awaitingHtml: false
  property int loadSerial: 0
  property int enterDir: 0           // slide direction for the next chapter to appear
  property string pendingFragment: ""
  property var linkStack: []         // where followed links came from, for "back"
  property int linkIndex: -1         // Tab-selected link on this chapter, -1 for none
  property int layoutTick: 0         // bumped after each layout, to refresh link geometry

  // The page's text. It is created fresh for every chapter (see `bodyHost`), so it
  // is null while a chapter is loading and everything that reads it must allow that.
  readonly property Item body: bodyHost.item

  // Every link in this chapter, in reading order. The helper brackets each one
  // with invisible sentinels, which is the only way to recover where a link
  // sits: rich text exposes no list of its anchors.
  readonly property var links: {
    var tick = layoutTick, text = body
    if (!text) return []
    var n = text.length
    var plain = text.getText(0, n), out = []
    var i = 0
    while (true) {
      var a = plain.indexOf("\u2062", i)
      if (a < 0) break
      var b = plain.indexOf("\u2064", a)
      if (b < 0) break
      out.push({ start: a, end: b })
      i = b + 1
    }
    return out
  }

  readonly property rect linkBox: {
    var tick = layoutTick
    if (!body || linkIndex < 0 || linkIndex >= links.length) return Qt.rect(0, 0, 0, 0)
    var a = body.positionToRectangle(links[linkIndex].start)
    var b = body.positionToRectangle(links[linkIndex].end)
    if (Math.abs(a.y - b.y) < 1)
      return Qt.rect(a.x, a.y, Math.max(4, b.x - a.x), a.height)
    return Qt.rect(0, a.y, body.width, b.y + b.height - a.y)   // wrapped onto another line
  }

  // Flickable content offsets where each page starts (whole-line boundaries).
  property var pageStarts: [0]
  property int pageIndex: 0
  readonly property int pageCount: pageStarts.length

  // Global position. Each spine entry carries a character weight, so how far
  // into the book we are is a character fraction, and the page number is that
  // weight divided by however many characters this chapter fits on a page.
  readonly property var charTotals: {
    var before = [], sum = 0
    for (var i = 0; i < spine.length; i++) {
      before.push(sum)
      sum += Math.max(0, spine[i].chars || 0)
    }
    return { before: before, total: sum }
  }
  readonly property bool hasWeights: charTotals.total > 0 && spineIndex >= 0
  readonly property real pageFraction: pageCount > 1 ? pageIndex / pageCount : 0
  readonly property real progress: {
    if (!hasWeights) {
      if (!spine.length || spineIndex < 0) return 0
      return Math.max(0, Math.min(1, (spineIndex + pageFraction) / spine.length))
    }
    var here = charTotals.before[spineIndex] + (spine[spineIndex].chars || 0) * pageFraction
    return Math.max(0, Math.min(1, here / charTotals.total))
  }
  // How many characters fit on one page, taken from the layout rather than
  // from the current chapter: a short chapter that fits on a single page would
  // otherwise inflate the figure and send the page number backwards. The 0.92
  // covers the ragged last line of each paragraph, and matches what chapters
  // long enough to fill several pages actually measure.
  readonly property real charsPerPage: {
    var perLine = metrics.averageCharacterWidth > 0
      ? textWidth / metrics.averageCharacterWidth : 40
    var lines = Math.max(1, Math.floor((flick.height - padTop - padBottom) / lineH))
    return Math.max(1, perLine * lines * 0.92)
  }
  readonly property int pageNow: hasWeights
    ? Math.round(charTotals.before[spineIndex] / charsPerPage) + pageIndex + 1
    : pageIndex + 1
  readonly property string chapterTitle: {
    if (spineIndex < 0 || spineIndex >= spine.length) return ""
    for (var i = spineIndex; i >= 0; i--) if (spine[i].title) return spine[i].title
    return ""
  }

  FontMetrics {
    id: metrics
    font { family: root.bodyFont; pixelSize: root.fontSize }
  }

  // ---- lifecycle ----------------------------------------------------------
  Component.onCompleted: { if (svc) svc.reader = root; startIfReady() }
  Component.onDestruction: { if (svc && svc.reader === root) svc.reader = null }

  // Deferred: `spine` is a dependent binding and may not have updated yet.
  onBookChanged: Qt.callLater(startIfReady)

  function startIfReady() {
    if (!book || spineIndex >= 0 || !svc) return
    var saved = svc.progressFor(svc.currentKey)
    var idx = saved ? Math.min(saved.spine, spine.length - 1) : 0
    loadChapter(idx, saved ? saved.pos : 0, 0, "")
  }

  // `pos` is a char offset (or -2 for the last page); `fragment` lands on a link target.
  // `keep` leaves the old text on screen while the new one loads (used for re-layout).
  function loadChapter(idx, pos, dir, fragment, keep) {
    if (idx < 0 || idx >= spine.length) return
    if (!keep) {                     // a new chapter: drop the old text and its item
      chapterHtml = ""
      bodyHost.active = false
    }
    linkIndex = -1
    spineIndex = idx
    anchorPos = pos
    enterDir = dir
    pendingFragment = fragment || ""
    chapterReady = false
    awaitingHtml = !keep
    loadSerial++
    chapterProc.serial = loadSerial
    var cmd = ["python3", svc.helper, "chapter", spine[idx].file,
               String(Math.round(textWidth)), String(Math.round(pageHeight))]
    if (fragment) cmd.push(fragment)
    chapterProc.command = cmd
    chapterProc.running = false
    chapterProc.running = true
  }

  Process {
    id: chapterProc
    property int serial: 0
    stdout: StdioCollector {
      property bool overflowed: false
      onDataChanged: {
        // Same ceiling the service applies: stop before the chapter is buffered
        // any further or turned into a document.
        if (!overflowed && data && svc && data.byteLength > svc.maxResponseBytes) {
          overflowed = true
          chapterProc.running = false
        }
      }
      onStreamFinished: {
        if (chapterProc.serial !== root.loadSerial) return
        root.awaitingHtml = false
        if (overflowed) {
          overflowed = false
          root.chapterHtml = "<p>This section is larger than Omlibria will read.</p>"
          bodyHost.active = true
          settle.restart()
          return
        }
        root.chapterHtml = text
        bodyHost.active = true       // a fresh text item, already holding the new text
        settle.restart()
      }
    }
  }

  // ---- geometry -----------------------------------------------------------
  readonly property real textWidth: Math.max(200, Math.min(flick.width - 2 * pad - (popup ? 0 : 40), 720))

  // Room for text on one page. Images are rendered no taller than this, so
  // one can always sit whole on a page.
  readonly property real pageHeight: Math.max(80, flick.height - padTop - padBottom)

  onTextWidthChanged: relayout.restart()
  onPageHeightChanged: relayout.restart()

  // Re-render on width change (image sizes depend on it); the anchor keeps the page.
  Timer {
    id: relayout
    interval: 180
    onTriggered: {
      if (root.spineIndex < 0 || !root.chapterReady) return
      root.loadChapter(root.spineIndex, root.anchorPos, 0, "", true)
    }
  }

  // Wait for the text layout to stop changing, then paginate and land on the anchor.
  Timer {
    id: settle
    interval: 60
    onTriggered: root.applyAnchor()
  }

  // Break the chapter into pages, each ending on a whole line.
  //
  // A page start is the body-local y of its first line, which is also the
  // Flickable contentY that puts that line `pad` below the top edge (the text
  // sits at body.y == padTop). So a page has `padTop` above its first line and
  // at least `padBottom` below its last one.
  function computePages() {
    var starts = [0]
    var total = body.contentHeight
    var usable = pageHeight                   // text room on one page
    var c = 0
    while (starts.length < 5000) {
      var bottom = c + usable                 // lowest a line box may reach
      if (bottom >= total) break              // the rest fits on this page
      var r = body.positionToRectangle(body.positionAt(2, bottom))
      var next
      // Cursor rects are glyph-sized, so a text line really occupies lineH;
      // a line holding an image reports that image's height instead, and
      // taking the larger of the two is what keeps an image off two pages.
      var boxH = Math.max(lineH, r.height)
      if (r.y + boxH <= bottom + 1) {
        // Landed in a paragraph gap: the next page starts at the following line.
        var r2 = body.positionToRectangle(body.positionAt(2, r.y + r.height + 1))
        next = r2.y > r.y + 1 ? r2.y : r.y + lineH
      } else {
        next = r.y                            // this line straddles the edge: push it over
      }
      if (next <= c + lineH / 2) next = c + usable   // taller than a page (image): hard break
      starts.push(next)
      c = next
    }
    pageStarts = starts
  }

  function pageFor(y) {
    var idx = 0
    for (var i = 0; i < pageStarts.length; i++) if (pageStarts[i] <= y + 1) idx = i
    return idx
  }

  function applyAnchor() {
    if (spineIndex < 0 || awaitingHtml || !body) return
    computePages()
    var pos = anchorPos
    if (pendingFragment) {
      var found = body.getText(0, body.length).indexOf("\u2063")
      pos = found >= 0 ? found : 0
      pendingFragment = ""
    }
    var idx = 0
    if (pos === -2) {
      idx = pageCount - 1
    } else if (pos > 0) {
      var r = body.positionToRectangle(Math.min(pos, Math.max(0, body.length - 1)))
      idx = pageFor(r.y)
    }
    setPage(idx)
    layoutTick++
    var first = !chapterReady
    chapterReady = true
    if (first && enterDir !== 0) {
      slideX = enterDir * slideDistance
      slideOp = 0
      enterAnim.restart()
    }
    enterDir = 0
  }

  function setPage(i) {
    i = Math.max(0, Math.min(pageCount - 1, i))
    pageIndex = i
    flick.contentY = pageStarts[i]
    capture()
  }

  function capture() {
    if (spineIndex < 0) return
    var c = pageStarts[pageIndex] || 0
    anchorPos = c <= 1 ? 0 : body.positionAt(2, c + lineH * 0.3)
  }

  function saveNow() {
    if (!svc || !svc.currentKey || spineIndex < 0 || !chapterReady) return
    svc.savePosition(svc.currentKey, spineIndex, anchorPos, progress)
  }

  Timer {
    id: saveSoon
    interval: 500
    onTriggered: root.saveNow()
  }

  // ---- page turning -------------------------------------------------------
  property real slideX: 0
  property real slideOp: 1
  property int slideDir: 0
  property int slideTarget: 0
  property bool sliding: false

  SequentialAnimation {
    id: turnAnim
    ScriptAction { script: root.sliding = true }
    ParallelAnimation {
      NumberAnimation { target: root; property: "slideX"; to: -root.slideDir * root.slideDistance; duration: 70; easing.type: Easing.InQuad }
      NumberAnimation { target: root; property: "slideOp"; to: 0; duration: 70 }
    }
    ScriptAction { script: { root.setPage(root.slideTarget); root.slideX = root.slideDir * root.slideDistance } }
    ParallelAnimation {
      NumberAnimation { target: root; property: "slideX"; to: 0; duration: 130; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "slideOp"; to: 1; duration: 130 }
    }
    ScriptAction { script: { root.sliding = false; saveSoon.restart() } }
  }

  ParallelAnimation {
    id: enterAnim
    NumberAnimation { target: root; property: "slideX"; to: 0; duration: 160; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "slideOp"; to: 1; duration: 160 }
  }

  function slideTo(i, dir) {
    if (i === pageIndex || sliding) return
    slideDir = dir
    slideTarget = i
    turnAnim.restart()
  }

  // Settle any turn still animating rather than dropping the press, so pages
  // keep up with someone reading quickly.
  function finishSlide() {
    if (!sliding) return
    turnAnim.stop()
    setPage(slideTarget)
    slideX = 0
    slideOp = 1
    sliding = false
  }

  function turnPage(dir) {
    if (!chapterReady) return
    linkIndex = -1
    finishSlide()
    var i = pageIndex + dir
    if (i >= pageCount) nextChapter()
    else if (i < 0) prevChapter(true)
    else slideTo(i, dir)
  }

  function nextChapter() {
    if (spineIndex >= spine.length - 1) return
    saveNow()
    loadChapter(spineIndex + 1, 0, 1, "")
  }

  // toEnd: land on the previous chapter's last page (paging backwards).
  function prevChapter(toEnd) {
    if (spineIndex <= 0) return
    saveNow()
    loadChapter(spineIndex - 1, toEnd ? -2 : 0, -1, "")
  }

  function jumpTo(idx) {
    saveNow()
    linkStack = []
    loadChapter(idx, 0, 0, "")
    closeToc()
  }

  // Handing focus back needs the list's own `focus` cleared first: a
  // FocusScope re-delegates to the child it remembers, so the hidden table of
  // contents would otherwise keep swallowing every key.
  function closeToc() {
    showToc = false
    tocList.focus = false
    root.forceActiveFocus()
  }

  function stepChapter(dir) {
    if (dir > 0) nextChapter()
    else if (pageIndex > 0) slideTo(0, -1)
    else prevChapter(false)
  }

  // A tap on a link follows it; otherwise the page edges turn pages.
  function tapAt(x, y) {
    if (!body) return
    var p = body.mapFromItem(input, x, y)
    var href = body.linkAt(p.x, p.y)
    if (href) followLink(href)
    else if (x > input.width * 0.65) turnPage(1)
    else if (x < input.width * 0.35) turnPage(-1)
  }

  // ---- links --------------------------------------------------------------
  function followLink(href) {
    if (!href) return
    if (/^https?:/.test(href)) { Quickshell.execDetached(["xdg-open", href]); return }
    if (href.indexOf("epub:") !== 0) return
    var rest = href.slice(5)
    var hash = rest.indexOf("#")
    var path = decodeURIComponent(hash < 0 ? rest : rest.slice(0, hash))
    var frag = hash < 0 ? "" : decodeURIComponent(rest.slice(hash + 1))
    var idx = -1
    for (var i = 0; i < spine.length; i++) if (spine[i].file === path) { idx = i; break }
    if (idx < 0) return
    saveNow()
    var stack = linkStack.slice()
    stack.push({ spine: spineIndex, pos: anchorPos })
    linkStack = stack
    loadChapter(idx, 0, 1, frag)
  }

  function pageOfLink(i) {
    return pageFor(body.positionToRectangle(links[i].start).y)
  }

  // Links are in reading order, so their pages only ever increase: a binary
  // search finds the edge of the current page without measuring every link.
  function linkOnPage(page, forward) {
    var lo = 0, hi = links.length - 1, found = -1
    while (lo <= hi) {
      var mid = (lo + hi) >> 1
      if (forward ? pageOfLink(mid) >= page : pageOfLink(mid) <= page) {
        found = mid
        if (forward) hi = mid - 1
        else lo = mid + 1
      } else {
        if (forward) lo = mid + 1
        else hi = mid - 1
      }
    }
    return found
  }

  // Tab / Shift+Tab walk the chapter's links, turning pages to follow them.
  function stepLink(delta) {
    var n = links.length
    if (!n || !chapterReady) return
    var next
    if (linkIndex < 0) {
      // Nothing selected yet: start from the page on screen rather than from
      // the top of the chapter.
      next = linkOnPage(pageIndex, delta > 0)
      if (next < 0) next = delta > 0 ? 0 : n - 1
    } else {
      next = linkIndex + delta
    }
    linkIndex = ((next % n) + n) % n
    var r = body.positionToRectangle(links[linkIndex].start)
    var page = pageFor(r.y)
    if (page !== pageIndex) slideTo(page, page > pageIndex ? 1 : -1)
  }

  function followFocusedLink() {
    if (linkIndex < 0 || linkIndex >= links.length) return false
    var r = body.positionToRectangle(links[linkIndex].start + 1)
    var href = body.linkAt(r.x + 2, r.y + r.height / 2)
    if (!href) return false
    followLink(href)
    return true
  }

  function linkBack() {
    if (!linkStack.length) return false
    var stack = linkStack.slice()
    var from = stack.pop()
    linkStack = stack
    loadChapter(from.spine, from.pos, -1, "")
    return true
  }

  function back() {
    saveNow()
    svc.showShelf()
  }

  function openToc() {
    showToc = true
    var cur = 0
    for (var i = 0; i < toc.length; i++) if (toc[i].spine <= spineIndex) cur = i
    tocList.currentIndex = cur
    tocList.positionViewAtIndex(cur, ListView.Center)
    tocList.forceActiveFocus()
  }

  Keys.onPressed: function(e) {
    var shift = e.modifiers & Qt.ShiftModifier
    var alt = e.modifiers & Qt.AltModifier
    if (showHelp) { showHelp = false; e.accepted = true; return }
    switch (e.key) {
    case Qt.Key_Space:
      turnPage(shift ? -1 : 1); break
    case Qt.Key_Right: case Qt.Key_L: case Qt.Key_PageDown: case Qt.Key_Down: case Qt.Key_J:
      if (alt && e.key === Qt.Key_Right) return
      turnPage(1); break
    case Qt.Key_Left: case Qt.Key_H: case Qt.Key_PageUp: case Qt.Key_Up: case Qt.Key_K:
      if (alt && e.key === Qt.Key_Left) { linkBack(); break }
      turnPage(-1); break
    case Qt.Key_BracketRight: stepChapter(1); break
    case Qt.Key_BracketLeft: case Qt.Key_P: stepChapter(-1); break
    case Qt.Key_Home: slideTo(0, -1); break
    case Qt.Key_End: slideTo(pageCount - 1, 1); break
    case Qt.Key_G: slideTo(shift ? pageCount - 1 : 0, shift ? 1 : -1); break
    case Qt.Key_U: linkBack(); break
    case Qt.Key_T: openToc(); break
    case Qt.Key_Tab: stepLink(shift ? -1 : 1); break
    case Qt.Key_Backtab: stepLink(-1); break
    case Qt.Key_Return: case Qt.Key_Enter: followFocusedLink(); break
    case Qt.Key_Plus: case Qt.Key_Equal: svc.adjustFont(1); break
    case Qt.Key_Minus: svc.adjustFont(-1); break
    case Qt.Key_0: svc.resetFont(); break
    case Qt.Key_F: svc.toggleSerif(); break
    case Qt.Key_E: svc.toggleExpanded(); break
    case Qt.Key_Question: showHelp = true; break
    case Qt.Key_Backspace: if (!linkBack()) back(); break
    case Qt.Key_B: case Qt.Key_Escape: back(); break
    case Qt.Key_Q: svc.close(); break
    default: return
    }
    e.accepted = true
  }

  // ---- header -------------------------------------------------------------
  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 44

    Row {
      id: leftButtons
      anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
      IconButton { glyph: "‹"; big: true; onClicked: root.back() }
      IconButton { glyph: "≡"; onClicked: root.openToc() }
    }
    Column {
      anchors {
        left: leftButtons.right; leftMargin: 8
        right: rightButtons.left; rightMargin: 8
        verticalCenter: parent.verticalCenter
      }
      Text {
        width: parent.width
        text: root.bookTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.fg
        font { family: root.uiFont; pixelSize: root.uiSize; bold: true }
      }
      Text {
        width: parent.width
        text: root.chapterTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.dim
        font { family: root.uiFont; pixelSize: root.uiSize - 3 }
      }
    }
    Row {
      id: rightButtons
      anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
      IconButton { glyph: "A−"; onClicked: root.svc.adjustFont(-1) }
      IconButton { glyph: "A+"; onClicked: root.svc.adjustFont(1) }
      IconButton {
        glyph: root.popup ? "⤢" : "⤡"
        onClicked: root.svc.toggleExpanded()
      }
    }
  }

  Rectangle {
    anchors { top: header.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
  }

  // ---- page ---------------------------------------------------------------
  Flickable {
    id: flick
    anchors { top: header.bottom; topMargin: 1; left: parent.left; right: parent.right; bottom: footer.top }
    clip: true
    interactive: false
    contentWidth: width
    // Slack below the text so the last page can start on a page boundary.
    contentHeight: (body ? body.height : 0) + root.padTop + root.padBottom + height
    boundsBehavior: Flickable.StopAtBounds
    opacity: root.slideOp
    transform: Translate { x: root.slideX }

    onHeightChanged: if (root.spineIndex >= 0) settle.restart()

    // Each chapter gets a brand-new TextEdit. A reused one can stop painting after its
    // document is swapped for another large one and the scroll position jumps: the
    // page numbers and geometry are all correct, but nothing is drawn until the text
    // happens to be laid out again. A newly created item always paints on first show,
    // which is why opening a book worked while following a link out of one did not.
    Loader {
      id: bodyHost
      active: false
      sourceComponent: TextEdit {
        x: Math.round((flick.width - width) / 2)
        y: root.padTop
        width: root.textWidth
        readOnly: true
        enabled: false                 // pure display; taps are handled by the overlay below
        selectByMouse: false
        textFormat: TextEdit.RichText
        wrapMode: TextEdit.Wrap
        color: root.fg
        selectedTextColor: root.fg
        font { family: root.bodyFont; pixelSize: root.fontSize }
        // TextEdit has no lineHeight property; Qt's rich text takes it from CSS.
        text: "<style>p, li, h1, h2, h3, h4, h5, h6, td, blockquote { line-height: " + Math.round(root.lineMult * 100)
          + "%; } p { margin-top: 0; margin-bottom: " + Math.round(root.fontSize * 0.55)
          + "px; } h1, h2, h3, h4 { margin-top: 12px; margin-bottom: 12px; }"
          + " a { color: " + root.accent + "; text-decoration: underline; }</style>" + root.chapterHtml
        onContentHeightChanged: if (root.spineIndex >= 0) settle.restart()
      }
    }

    // Inside the Flickable: linkBox is in the text's own coordinates, so the
    // ring has to scroll and clip with the text rather than sit over the
    // viewport, where it only lined up on the first page.
    Rectangle {
      visible: root.linkIndex >= 0 && root.linkBox.width > 0
      x: (body ? body.x : 0) + root.linkBox.x - 3
      y: (body ? body.y : 0) + root.linkBox.y - 1
      width: root.linkBox.width + 6
      height: root.linkBox.height + 2
      radius: 3
      color: "transparent"
      border.width: 1
      border.color: root.accent
    }
  }

  // The viewport is taller than the page's text on each side, so the
  // neighbouring lines' boxes reach into both margins. Paint the margins over
  // to leave exactly `pad` of clean space above the first line and below the
  // last one. The next page's first line begins where the bottom margin does.
  readonly property real pageBottom: pageIndex < pageCount - 1
    ? padTop + pageStarts[pageIndex + 1] - pageStarts[pageIndex] : flick.height

  Rectangle {
    x: flick.x
    y: flick.y
    width: flick.width
    height: root.padTop
    color: Color.popups.background
  }

  Rectangle {
    x: flick.x
    y: flick.y + root.pageBottom
    width: flick.width
    height: Math.max(0, flick.height - root.pageBottom)
    color: Color.popups.background
  }

  // Input layer. Kept outside the Flickable so coordinates are plain viewport
  // coordinates: links first, then the page edges turn pages.
  Item {
    id: input
    anchors.fill: flick

    TapHandler {
      onTapped: function(point) { root.tapAt(point.position.x, point.position.y) }
    }

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(ev) {
        if (wheelLock.running || ev.angleDelta.y === 0) return
        wheelLock.restart()
        root.turnPage(ev.angleDelta.y < 0 ? 1 : -1)
      }
    }

    Timer { id: wheelLock; interval: 220 }
  }

  Text {
    anchors.centerIn: flick
    visible: !root.chapterReady || !root.book
    text: root.svc.bookError ? root.svc.bookError : (root.book ? "" : "Opening book…")
    color: root.dim
    font { family: root.uiFont; pixelSize: root.uiSize }
  }

  // ---- footer -------------------------------------------------------------
  Item {
    id: footer
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 34

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 2
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
      Rectangle { width: parent.width * root.progress; height: parent.height; color: root.accent }
    }
    Text {
      anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
      text: "Page " + root.pageNow
      color: root.dim
      font { family: root.uiFont; pixelSize: root.uiSize - 3 }
    }
    Text {
      visible: root.linkStack.length > 0
      anchors.centerIn: parent
      text: "↩ back"
      color: root.accent
      font { family: root.uiFont; pixelSize: root.uiSize - 3; bold: true }
      MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: root.linkBack() }
    }
    Text {
      anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
      text: Math.round(root.progress * 100) + "%"
      color: root.dim
      font { family: root.uiFont; pixelSize: root.uiSize - 3 }
    }
  }

  // ---- table of contents --------------------------------------------------
  Rectangle {
    anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
    visible: root.showToc
    color: Color.popups.background
    z: 5

    ListView {
      id: tocList
      anchors { fill: parent; margins: 10 }
      clip: true
      model: root.toc
      keyNavigationEnabled: false
      // currentIndex moves under our own key handling, which does not scroll
      // the view on its own.
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      Keys.onPressed: function(e) {
        if (!root.showToc) return
        switch (e.key) {
        case Qt.Key_Down: case Qt.Key_J: currentIndex = Math.min(count - 1, currentIndex + 1); break
        case Qt.Key_Up: case Qt.Key_K: currentIndex = Math.max(0, currentIndex - 1); break
        case Qt.Key_PageDown: currentIndex = Math.min(count - 1, currentIndex + 8); break
        case Qt.Key_PageUp: currentIndex = Math.max(0, currentIndex - 8); break
        case Qt.Key_Home: case Qt.Key_G:
          currentIndex = (e.key === Qt.Key_G && (e.modifiers & Qt.ShiftModifier)) ? count - 1 : 0; break
        case Qt.Key_End: currentIndex = count - 1; break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_L: case Qt.Key_Right:
          if (currentIndex >= 0) root.jumpTo(root.toc[currentIndex].spine); break
        case Qt.Key_Tab:
          currentIndex = (e.modifiers & Qt.ShiftModifier)
            ? (currentIndex - 1 + count) % count : (currentIndex + 1) % count
          break
        case Qt.Key_Backtab: currentIndex = (currentIndex - 1 + count) % count; break
        case Qt.Key_Escape: case Qt.Key_T: case Qt.Key_Q: case Qt.Key_H: case Qt.Key_Left:
          root.closeToc(); break
        default: return
        }
        e.accepted = true
      }
      delegate: Rectangle {
        required property var modelData
        required property int index
        readonly property bool here: modelData.spine === root.spineIndex
        width: tocList.width
        height: 34
        radius: Style.cornerRadius
        color: ListView.isCurrentItem ? Color.menu.selectedBackground : "transparent"
        Text {
          anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          text: parent.modelData.title
          textFormat: Text.PlainText
          color: parent.here ? root.accent : root.fg
          font { family: root.uiFont; pixelSize: root.uiSize; bold: parent.here }
        }
        MouseArea { anchors.fill: parent; onClicked: root.jumpTo(parent.modelData.spine) }
      }
    }
  }

  // ---- help ---------------------------------------------------------------
  HelpOverlay {
    anchors.fill: parent
    visible: root.showHelp
    heading: "Reading"
    footnote: "Click the page edges to turn pages. Any key dismisses this."
    rows: [
      ["Space, →, l, j", "next page"],
      ["Shift+Space, ←, h, k", "previous page"],
      ["] / [", "next / previous chapter"],
      ["g / G", "chapter start / end"],
      ["t", "table of contents"],
      ["Tab / Shift+Tab", "select next / previous link"],
      ["Enter", "follow the selected link"],
      ["u, Backspace", "back after following a link"],
      ["+ / − / 0", "font size"],
      ["f", "serif / sans"],
      ["e", "menu ↔ tiled window"],
      ["Esc, b", "back to library"],
      ["q", "close (resumes here)"]
    ]
    onDismissed: root.showHelp = false
  }

  component IconButton: Rectangle {
    id: btn
    property string glyph: ""
    property bool big: false
    property bool active: false
    signal clicked()
    width: 32; height: 30
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, ma.containsMouse ? 0.12 : 0)
    Text {
      anchors.centerIn: parent
      text: btn.glyph
      color: btn.active ? root.accent : root.fg
      font { family: root.uiFont; pixelSize: root.uiSize + (btn.big ? 8 : 1) }
    }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: btn.clicked() }
  }
}
