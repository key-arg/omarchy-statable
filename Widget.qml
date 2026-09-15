import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Live visitor count from Statable, as a bar pill.
//
// Runs `statable now` on a timer and shows the integer it prints. The command
// prints one number and exits, so there is nothing to parse and no daemon to
// keep alive. Any non-zero exit — no key, no default site, the API
// unreachable, the binary not on PATH — leaves the pill blank rather than
// showing a wrong or stale figure.
//
// Quickshell runs the process off the UI thread, so even the pathological case
// (a locked keyring, which makes the CLI wait out its timeout) only delays the
// number; it never freezes the bar. Overlapping polls are guarded against, so
// a slow poll cannot stack behind the next tick.
BarWidget {
  id: root
  moduleName: "com.statable.now"

  readonly property int refreshIntervalSec: Math.max(15, setting("refreshIntervalSec", 60))
  readonly property string site: setting("site", "")
  readonly property bool showIcon: setting("showIcon", true)

  // nf-fa-users (U+F0C0). The bar uses a Nerd Font, so this renders as a glyph.
  readonly property string glyph: ""

  property string count: ""
  property bool ok: false

  function refresh() {
    if (!poll.running) poll.running = true
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: poll
    command: {
      var c = ["statable", "now"]
      if (root.site !== "") {
        c.push("--site")
        c.push(root.site)
      }
      return c
    }
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: {}
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.count = String(out.text || "").trim()
        root.ok = root.count !== ""
      } else {
        root.count = ""
        root.ok = false
      }
    }
  }

  // A blank pill takes no room in the bar, so an unconfigured or offline
  // widget disappears instead of showing an empty box.
  visible: root.ok
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    text: root.showIcon ? (root.glyph + " " + root.count) : root.count
    tooltipText: root.count === "" ? "" : (root.count + " visitor" + (root.count === "1" ? "" : "s") + " active now")

    onPressed: function (b) {
      // Middle click forces an immediate re-poll; left and right are left for
      // the bar's own handling.
      if (b === Qt.MiddleButton) root.refresh()
    }
  }
}
