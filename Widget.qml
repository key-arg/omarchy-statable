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
// stale figure. The processes run off the UI thread, so a slow call never
// freezes the bar, and an overlapping poll is skipped rather than stacked.
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

  function withSite(base) {
    return root.site === "" ? base : base.concat(["--site", root.site])
  }

  function pollNow() {
    if (!nowProc.running) nowProc.running = true
  }

  function loadPanel() {
    if (!statsProc.running) statsProc.running = true
    if (!pagesProc.running) pagesProc.running = true
  }

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

  Process {
    id: nowProc
    command: root.withSite(["statable", "now"])
    stdout: StdioCollector {
      id: nowOut
      waitForEnd: true
    }
    onExited: function (code) {
      if (code === 0) {
        root.nowCount = String(nowOut.text || "").trim()
        root.nowOk = root.nowCount !== ""
      } else {
        root.nowCount = ""
        root.nowOk = false
      }
    }
  }

  Process {
    id: statsProc
    command: root.withSite(["statable", "stats", "--range", "7d", "--compare", "previous", "--format", "json"])
    stdout: StdioCollector {
      id: statsOut
      waitForEnd: true
    }
    onExited: function (code) {
      if (code === 0) {
        try {
          root.stats = JSON.parse(String(statsOut.text || ""))
        } catch (e) {
          root.stats = null
        }
      } else {
        root.stats = null
      }
    }
  }

  Process {
    id: pagesProc
    command: root.withSite(["statable", "top", "pages", "--range", "7d", "--limit", "5", "--format", "json"])
    stdout: StdioCollector {
      id: pagesOut
      waitForEnd: true
    }
    onExited: function (code) {
      if (code === 0) {
        try {
          var a = JSON.parse(String(pagesOut.text || ""))
          root.pages = Array.isArray(a) ? a : []
        } catch (e) {
          root.pages = []
        }
      } else {
        root.pages = []
      }
    }
  }

  // ---- formatting helpers ----
  function fmtInt(n) {
    // Thousands with a thin space, matching the CLI's human output.
    var s = String(Math.round(n))
    return s.replace(/\B(?=(\d{3})+(?!\d))/g, " ")
  }
  function fmtDuration(secs) {
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
      { label: "Bounce rate", value: Math.round(s.bounce_rate) + "%", delta: fmtDelta(s.bounce_rate_change) },
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
