// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io

// The phone's position for a weather widget: locate.sh asks GeoClue at city
// accuracy (no GNSS power-up) and rounds to about 1 km. One run takes up to
// ~15 s, so it runs at most once a minute, again every 30 minutes, and the
// script shares its answer between widgets for 30 minutes. `active` is the
// widget's "Use my location" with its internet use on: until then nothing
// runs. When there is no position, `failure` says why and the widget uses
// its typed place.
Item {
  id: geo
  visible: false

  property bool active: false
  // { lat, lon, accuracy, at } from the last good answer.
  property var fix: null
  property string failure: ""
  readonly property bool busy: proc.running
  readonly property string key: fix ? fix.lat + "," + fix.lon : ""

  readonly property string script: {
    var u = String(Qt.resolvedUrl("locate.sh"))
    return u.indexOf("file://") === 0 ? decodeURIComponent(u.slice(7))
      : "/usr/share/omandroid/shell/plugins/omandroid.home/locate.sh"
  }

  property real lastStart: 0
  function locate(force) {
    if (!active || proc.running) return
    if (Date.now() - lastStart < 60000) return
    if (!force && fix && Date.now() - fix.at * 1000 < 30 * 60000) return
    lastStart = Date.now()
    proc.command = ["timeout", "-k", "2", "25", "bash", script, force ? "60" : "1800"]
    proc.running = true
  }

  onActiveChanged: if (active) locate(false)
  Component.onCompleted: if (active) locate(false)
  Timer { interval: 30 * 60000; repeat: true; running: geo.active; onTriggered: geo.locate(true) }
  // A first answer that never comes (the script didn't start) still ends the wait.
  Timer {
    interval: 40000
    running: geo.active && !geo.fix && geo.failure === ""
    onTriggered: if (!geo.fix && geo.failure === "") geo.failure = "No location"
  }

  Process {
    id: proc
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    // Read when it stops (not onExited, whose QProcess::ExitStatus argument
    // the QML tooling can't type): the script prints JSON only on success.
    onRunningChanged: {
      if (running) return
      var parsed = null
      try { parsed = JSON.parse(String(out.text || "").trim()) } catch (e) { parsed = null }
      if (parsed && typeof parsed.lat === "number" && typeof parsed.lon === "number") {
        geo.failure = ""
        // Only a move of about 1 km or more changes the key and refetches.
        if (!geo.fix || geo.fix.lat !== parsed.lat || geo.fix.lon !== parsed.lon) geo.fix = parsed
      } else {
        geo.failure = String(err.text || "").trim().split("\n").pop() || "No location"
      }
    }
  }
}
