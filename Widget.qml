import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Statable in the Omarchy bar: a live visitor pill, and a popup with the last
// seven days when you click it.
//
// The pill runs `statable now` on a timer. The popup runs `statable stats` and
// `statable top pages` when it opens (and on the same timer while open). Each
// command prints and exits, so the widget holds no long-running state and no
// daemon. Any non-zero exit — no key, no default site, the API unreachable,
// the binary off PATH — leaves that part blank rather than showing a wrong or
// stale figure. Each call has a deadline and an output cap (see Fetch), what
// it returns is validated before it is shown, and every value from the API
// is rendered as plain text. The processes run off the UI thread, so a slow
// call never freezes the bar, and an overlapping poll is skipped rather than
// stacked.
Panel {
  id: root
  moduleName: "com.statable.now"
  ipcTarget: "com.statable.now"
  manageIpc: true

  readonly property int refreshIntervalSec: Math.max(15, setting("refreshIntervalSec", 60))
  readonly property string site: setting("site", "")
  readonly property bool showIcon: setting("showIcon", true)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // nf-fa-users, nf-fa-eye — the bar font is a Nerd Font.
  readonly property string usersGlyph: "\uf0c0"

  // The bar draws the "panel is open" mark at this width/height; without it
  // the default is a short stub under a wide pill. Span the pill instead.
  readonly property real openPanelIndicatorWidth: button.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(2), Math.round(Style.bar.iconSlot * 0.12))

  // Pill state (the `now` count).
  property string nowCount: ""
  property bool nowOk: false

  // Popup state, loaded when the panel opens.
  property var stats: null
  property var pages: []

  // Bounds on what a CLI call may hand back. The CLI prints a few hundred
  // bytes and exits; a call that runs past the deadline or past the output
  // cap is killed and its output dropped, so a stalled or runaway response
  // can neither keep a process alive nor grow inside the shell.
  readonly property int fetchDeadlineMs: 15000
  readonly property int fetchCapChars: 65536
  readonly property int maxPages: 5
  readonly property int maxPathChars: 200

  function withSite(base) {
    return root.site === "" ? base : base.concat(["--site", root.site])
  }

  function pollNow() { nowF.start() }
  function loadPanel() { statsF.start(); pagesF.start() }
  function refresh() {
    pollNow()
    if (root.opened) loadPanel()
  }

  Component.onCompleted: pollNow()
  onOpenedChanged: if (root.opened) loadPanel()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // One `statable` call, bounded: a deadline, a cap on stdout while it
  // streams, and SIGKILL when either trips. `done` reports ok only for a
  // clean exit within both bounds, and the text is empty otherwise. A call
  // already running is not started again.
  component Fetch: Item {
    id: fetch
    property var command: []
    property string buf: ""
    property bool tripped: false
    signal done(bool ok, string text)
    function start() { if (!proc.running) proc.running = true }
    function trip() { fetch.tripped = true; proc.signal(9) }
    Process {
      id: proc
      command: fetch.command
      stdout: SplitParser {
        splitMarker: ""   // every chunk as it arrives, not whole lines
        onRead: function (data) {
          if (fetch.tripped) return
          fetch.buf += data
          if (fetch.buf.length > root.fetchCapChars) fetch.trip()
        }
      }
      onStarted: { fetch.buf = ""; fetch.tripped = false; deadline.restart() }
      onExited: function (code) {
        deadline.stop()
        var ok = code === 0 && !fetch.tripped
        var text = fetch.buf
        fetch.buf = ""
        fetch.done(ok, ok ? text : "")
      }
    }
    Timer { id: deadline; interval: root.fetchDeadlineMs; onTriggered: fetch.trip() }
  }

  // ---- what comes back is checked before it is shown ----
  function asCount(s) {                       // digits only, else "no data"
    var t = String(s || "").trim()
    return /^\d{1,12}$/.test(t) ? t : ""
  }
  function asNum(v) {                         // finite, non-negative, or null
    var n = Number(v)
    return (isFinite(n) && n >= 0 && n <= 1e12) ? n : null
  }
  function asChange(v) {                      // finite percent change, or null
    if (v === undefined || v === null) return null
    var n = Number(v)
    return (isFinite(n) && Math.abs(n) <= 1e6) ? n : null
  }
  function asText(v, max) {
    return String(v === undefined || v === null ? "" : v).slice(0, max)
  }

  Fetch {
    id: nowF
    command: root.withSite(["statable", "now"])
    onDone: function (ok, text) {
      root.nowCount = ok ? root.asCount(text) : ""
      root.nowOk = root.nowCount !== ""
    }
  }

  Fetch {
    id: statsF
    command: root.withSite(["statable", "stats", "--range", "7d", "--compare", "previous", "--format", "json"])
    onDone: function (ok, text) {
      var s = null
      try { if (ok) s = JSON.parse(text) } catch (e) { s = null }
      if (!s || typeof s !== "object" || Array.isArray(s)) { root.stats = null; return }
      root.stats = {
        visitors: root.asNum(s.visitors), visitors_change: root.asChange(s.visitors_change),
        pageviews: root.asNum(s.pageviews), pageviews_change: root.asChange(s.pageviews_change),
        bounce_rate: root.asNum(s.bounce_rate), bounce_rate_change: root.asChange(s.bounce_rate_change),
        visit_duration: root.asNum(s.visit_duration), visit_duration_change: root.asChange(s.visit_duration_change)
      }
    }
  }

  Fetch {
    id: pagesF
    command: root.withSite(["statable", "top", "pages", "--range", "7d", "--limit", String(root.maxPages), "--format", "json"])
    onDone: function (ok, text) {
      var a = []
      try { if (ok) a = JSON.parse(text) } catch (e) { a = [] }
      if (!Array.isArray(a)) a = []
      var out = []
      for (var i = 0; i < a.length && out.length < root.maxPages; i++) {
        var p = a[i]
        if (!p || typeof p !== "object") continue
        var n = root.asNum(p.visitors)
        if (n === null) continue
        out.push({ page: root.asText(p.page, root.maxPathChars), visitors: n })
      }
      root.pages = out
    }
  }

  // ---- formatting helpers ----
  function fmtInt(n) {
    if (n === null || n === undefined) return "—"
    // Thousands with a thin space, matching the CLI's human output.
    var s = String(Math.round(n))
    return s.replace(/\B(?=(\d{3})+(?!\d))/g, " ")
  }
  function fmtDuration(secs) {
    if (secs === null || secs === undefined) return "—"
    var s = Math.round(secs)
    var m = Math.floor(s / 60)
    var r = s % 60
    return m + "m " + (r < 10 ? "0" : "") + r + "s"
  }
  function fmtDelta(change) {
    if (change === undefined || change === null)
      return { text: "", up: false, down: false }
    var v = Number(change)
    if (!isFinite(v) || v === 0)
      return { text: "0%", up: false, down: false }
    var arrow = v > 0 ? "▲" : "▼"
    return { text: arrow + " " + Math.abs(v).toFixed(1) + "%", up: v > 0, down: v < 0 }
  }
  function statRows() {
    var s = root.stats
    if (!s)
      return []
    return [
      { label: "Visitors", value: fmtInt(s.visitors), delta: fmtDelta(s.visitors_change) },
      { label: "Pageviews", value: fmtInt(s.pageviews), delta: fmtDelta(s.pageviews_change) },
      { label: "Bounce rate", value: s.bounce_rate === null ? "—" : Math.round(s.bounce_rate) + "%", delta: fmtDelta(s.bounce_rate_change) },
      { label: "Avg visit", value: fmtDuration(s.visit_duration), delta: fmtDelta(s.visit_duration_change) }
    ]
  }

  // ---- the bar pill ----
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    text: root.nowOk ? (root.showIcon ? (root.usersGlyph + " " + root.nowCount) : root.nowCount) : ""
    tooltipText: root.nowOk ? (root.nowCount + " active now — click for the last 7 days") : ""

    onPressed: function (b) {
      if (b === Qt.MiddleButton)
        root.refresh()
      else
        root.toggle()
    }
  }

  visible: root.nowOk
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- the popup ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
        spacing: Style.space(16)

        // header
        Column {
          width: parent.width
          spacing: Style.space(2)
          Text {
            text: root.site !== "" ? root.site : "Statable"
            textFormat: Text.PlainText
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }
          Text {
            text: root.nowOk
                  ? (root.nowCount + " visitor" + (root.nowCount === "1" ? "" : "s") + " active now")
                  : "no data"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // last 7 days
        Column {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: "LAST 7 DAYS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.statRows()
            delegate: Item {
              width: column.width
              height: rowText.implicitHeight
              Text {
                id: rowLabel
                anchors.left: parent.left
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                id: rowText
                anchors.right: rowDelta.left
                anchors.rightMargin: Style.space(8)
                text: modelData.value
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                id: rowDelta
                anchors.right: parent.right
                text: modelData.delta.text
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
          Text {
            visible: root.stats === null
            text: "…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // top pages
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.pages.length > 0
          Text {
            text: "TOP PAGES · 7 DAYS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.pages
            delegate: Item {
              width: column.width
              height: pgName.implicitHeight
              Text {
                id: pgName
                anchors.left: parent.left
                anchors.right: pgCount.left
                anchors.rightMargin: Style.space(8)
                text: modelData.page
                textFormat: Text.PlainText
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                id: pgCount
                anchors.right: parent.right
                text: root.fmtInt(modelData.visitors)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }
    }
  }
}
