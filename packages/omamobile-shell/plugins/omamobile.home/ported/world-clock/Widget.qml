// SPDX-License-Identifier: MIT
// Flip clocks with city nameplates. Ported from simonschubert/world-clock in
// Simon Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert
// and contributors; see
// ../../LICENSE-omarchy-widgets). Only the UTC offsets come from a
// command (date with TZ, every 5 minutes); the digits run off the clock.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text
  readonly property bool twelve: (host ? host.timeFormat : "HH:mm").indexOf("AP") >= 0

  SystemClock { id: clock; precision: SystemClock.Minutes }

  // "Name=Area/City" entries; zones only from the tz database's character set.
  readonly property var clocks: String(settings.clocks || "").split(",").map(function(entry) {
    var parts = entry.split("=")
    var zone = String(parts.length > 1 ? parts.slice(1).join("=") : parts[0]).trim()
    var label = parts.length > 1 ? parts[0].trim() : zone.split("/").pop().replace(/_/g, " ")
    return { label: label, zone: zone }
  }).filter(function(c) { return /^[A-Za-z0-9_+\/-]+$/.test(c.zone) }).slice(0, 6)
  readonly property var zones: clocks.map(function(c) { return c.zone })
  readonly property string zoneKey: zones.join(" ")

  // { zoneKey, offsets: { zone: seconds, local: seconds }, at }
  property var reading: host && host.cached ? host.cached : null
  property string problem: ""

  function refresh(force) {
    if (!host || host.busy || zones.length === 0) return
    if (!force && reading && reading.zoneKey === zoneKey && Date.now() - reading.at < 5 * 60000) return
    var wanted = zoneKey
    host.run(["sh", "-c",
      "echo \"local $(date +%z)\"\n" +
      "for z in \"$@\"; do [ -f \"/usr/share/zoneinfo/$z\" ] && echo \"$z $(TZ=\"$z\" date +%z)\"; done\n" +
      "exit 0", "sh"].concat(zones), function(result) {
      if (result.code !== 0) { widget.problem = result.timedOut ? "date took too long" : "couldn't read the time zones"; return }
      var offsets = {}
      result.stdout.trim().split("\n").forEach(function(line) {
        var w = line.trim().split(/\s+/)
        var m = /^([+-])(\d\d)(\d\d)$/.exec(w[1] || "")
        if (m) offsets[w[0]] = (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 3600 + Number(m[3]) * 60)
      })
      widget.problem = ""
      widget.reading = { zoneKey: wanted, offsets: offsets, at: Date.now() }
      widget.host.setCached(widget.reading)
    }, { timeout: 5 })
  }

  Component.onCompleted: refresh(false)
  onZoneKeyChanged: refresh(true)
  Timer { interval: 5 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var offsets: reading && reading.zoneKey === zoneKey ? reading.offsets : null
  readonly property var shown: offsets ? clocks.filter(function(c) { return offsets[c.zone] !== undefined }) : []
  // A tile taller than wide stacks the clocks instead of lining them up.
  readonly property bool tall: height > width * 1.3
  readonly property var days: ["thu", "fri", "sat", "sun", "mon", "tue", "wed"]

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  // A flip-clock card: two digits split across the middle. Cards where it's night go dark.
  component Card: Rectangle {
    id: card
    property int value: 0
    property bool night: false
    radius: Math.min(4, Style.cornerRadius)
    color: night ? Util.alpha(Commons.Color.menu.background, 0.9) : Util.alpha(Commons.Color.muted, 0.22)
    border.width: 1
    border.color: Util.alpha(Commons.Color.muted, 0.5)
    Label {
      anchors.centerIn: parent
      text: (card.value < 10 ? "0" : "") + card.value
      color: card.night ? widget.dim : widget.fg
      font.bold: true
      font.pixelSize: Math.max(8, Math.min(card.height, card.width) * 0.62)
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: Math.max(1, card.height * 0.025)
      color: card.night ? Util.alpha(Commons.Color.muted, 0.4) : Commons.Color.menu.background
    }
  }

  component City: Column {
    id: city
    property var c: ({ label: "", zone: "" })
    readonly property real secs: Math.floor(clock.date.getTime() / 1000) + (widget.offsets ? widget.offsets[c.zone] : 0)
    readonly property int hour: Math.floor(secs / 3600) % 24
    readonly property int minute: Math.floor(secs / 60) % 60
    readonly property bool night: hour < 6 || hour >= 18
    readonly property real diff: widget.offsets ? (widget.offsets[c.zone] - widget.offsets.local) / 3600 : 0
    spacing: Style.spacing.xs
    Item {
      id: face
      width: city.width
      height: Math.max(10, city.height - plate.height - info.height - city.spacing * 2)
      readonly property real gap: Math.max(6, width * 0.06)
      readonly property real cw: Math.min((width - gap) / 2, height * 1.1)
      readonly property real ch: Math.min(height, cw * 1.05)
      Card {
        x: (face.width - face.cw * 2 - face.gap) / 2
        y: (face.height - face.ch) / 2
        width: face.cw
        height: face.ch
        night: city.night
        value: widget.twelve ? (city.hour % 12 || 12) : city.hour
      }
      Card {
        x: (face.width - face.cw * 2 - face.gap) / 2 + face.cw + face.gap
        y: (face.height - face.ch) / 2
        width: face.cw
        height: face.ch
        night: city.night
        value: city.minute
      }
      Repeater {
        model: [0.36, 0.64]
        delegate: Rectangle {
          required property var modelData
          readonly property real size: Math.max(2.4, face.ch * 0.06)
          x: face.width / 2 - size / 2
          y: (face.height - face.ch) / 2 + face.ch * modelData - size / 2
          width: size
          height: size
          radius: size / 2
          color: city.night ? Commons.Color.muted : Commons.Color.accent
        }
      }
    }
    Rectangle {
      id: plate
      width: city.width
      height: plateText.implicitHeight + 4
      radius: Math.min(2, Style.cornerRadius)
      color: Util.alpha(Commons.Color.muted, 0.22)
      border.width: 1
      border.color: Util.alpha(Commons.Color.muted, 0.5)
      Label {
        id: plateText
        anchors.centerIn: parent
        width: parent.width - 8
        horizontalAlignment: Text.AlignHCenter
        text: city.c.label.toUpperCase()
        font.bold: true
        font.pixelSize: Style.font.caption
      }
    }
    Label {
      id: info
      width: city.width
      horizontalAlignment: Text.AlignHCenter
      text: widget.days[Math.floor(city.secs / 86400) % 7] + " "
        + (city.diff === 0 ? "local" : (city.diff > 0 ? "+" : "") + (city.diff % 1 === 0 ? city.diff : city.diff.toFixed(1)) + "h")
        + (widget.twelve ? (city.hour < 12 ? " am" : " pm") : "")
      color: widget.dim
      font.pixelSize: Style.font.caption
    }
  }

  Label {
    visible: widget.shown.length === 0
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    wrapMode: Text.Wrap
    maximumLineCount: 3
    text: widget.problem !== "" ? widget.problem : widget.clocks.length === 0 ? "no clocks yet, tap to add one" : widget.offsets ? "no known time zones, tap to fix" : "…"
    color: widget.dim
  }

  Grid {
    id: grid
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    columns: widget.tall ? 1 : Math.max(1, widget.shown.length)
    spacing: widget.tall ? Style.spacing.xl : Style.spacing.lg
    Repeater {
      model: widget.shown
      delegate: City {
        required property var modelData
        c: modelData
        width: widget.tall ? grid.width : (grid.width - grid.spacing * (grid.columns - 1)) / grid.columns
        height: widget.tall ? (grid.height - grid.spacing * (widget.shown.length - 1)) / widget.shown.length : grid.height
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
