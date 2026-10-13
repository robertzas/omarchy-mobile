// SPDX-License-Identifier: MIT
// Sunrise, sunset, daylight left and the moon, from wttr.in. Ported from
// simonschubert/sun-and-moon in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Wttr.js" as Wttr
import "../.." as Home

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  // The place for wttr.in: the phone's position ("Use my location": GeoClue at
  // city accuracy, rounded to about 1 km; Omarchy Mobile's GeoLocation.qml) when
  // there is one, else the typed city, else wttr.in's guess from the address.
  // Nothing is fetched while the position is still being looked up.
  readonly property bool useLocation: settings.useLocation !== false
  Home.GeoLocation { id: geo; active: widget.useLocation }
  readonly property bool waiting: useLocation && !geo.fix && geo.failure === ""
  readonly property string city: useLocation && geo.fix ? geo.fix.lat + "," + geo.fix.lon : String(settings.city || "").trim()
  onWaitingChanged: if (!waiting) refresh(false)
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text
  readonly property string timeFormat: host ? host.timeFormat : "HH:mm"

  SystemClock { id: clock; precision: SystemClock.Minutes }

  // { city, sky: { place, rise, set, next ([h, m] each), phase, illum }, at }
  property var reading: host && host.cached ? host.cached : null
  property bool failed: false

  function refresh(force) {
    if (widget.waiting) return
    if (!force && reading && reading.city === city && Date.now() - reading.at < 60 * 60000) return
    var wanted = city
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let j = JSON.parse(xhr.responseText)
        let a = j.weather[0].astronomy[0]
        let sky = {
          place: Wttr.value(j.nearest_area[0].areaName),
          rise: Wttr.clock(a.sunrise), set: Wttr.clock(a.sunset),
          next: Wttr.clock(j.weather[1].astronomy[0].sunrise),
          phase: String(a.moon_phase || ""), illum: Number(a.moon_illumination) || 0
        }
        if (!sky.rise || !sky.set || !sky.next) throw new Error("no sun times")
        widget.failed = false
        widget.reading = { city: wanted, sky: sky, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      } catch (e) {
        widget.failed = true
      }
    }
    xhr.open("GET", Wttr.url(wanted))
    xhr.send()
  }

  Component.onCompleted: refresh(false)
  onCityChanged: refresh(true)
  Timer { interval: 60 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var sky: reading && reading.city === city ? reading.sky : null

  // wttr.in gives local clock times; these are today's and tomorrow's.
  function at(hm, dayOffset) {
    var d = clock.date
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + dayOffset, hm[0], hm[1]).getTime()
  }
  readonly property real now: clock.date.getTime()
  readonly property real rise: sky ? at(sky.rise, 0) : 0
  readonly property real set: sky ? at(sky.set, 0) : 0
  readonly property real next: sky ? at(sky.next, 1) : 0
  readonly property bool day: sky !== null && now >= rise && now < set
  readonly property real progress: sky ? Math.min(1, Math.max(0, (now - rise) / Math.max(set - rise, 1))) : 0
  readonly property bool waxing: sky ? (sky.phase.indexOf("Waxing") >= 0 || sky.phase.indexOf("First") >= 0) : true

  function duration(ms) {
    var s = Math.max(0, Math.floor(ms / 1000))
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60)
    return h > 0 ? h + "h " + m + "m" : m + "m"
  }
  function time(ms) { return Qt.formatTime(new Date(ms), widget.timeFormat) }

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.sm

    Row {
      id: head
      width: parent.width
      Label { id: titleView; text: "sun & moon"; color: widget.dim }
      Label {
        width: parent.width - titleView.width
        horizontalAlignment: Text.AlignRight
        text: widget.sky ? widget.sky.place : ""
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
    }

    // The day as an arc from sunrise (left) to sunset (right).
    Canvas {
      id: arc
      width: parent.width
      height: Math.max(20, parent.height - head.height - times.height - leftView.height - moon.height - parent.spacing * 4)
      property real progress: widget.progress
      property bool day: widget.day
      property color sun: Commons.Color.accent
      property color track: Util.alpha(Commons.Color.muted, 0.5)
      property color off: Commons.Color.muted
      onProgressChanged: requestPaint()
      onDayChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var cx = width / 2, cy = height - 4
        var r = Math.max(4, Math.min(width / 2 - 8, height - 12))
        ctx.lineCap = "round"
        ctx.strokeStyle = track
        ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(4, cy); ctx.lineTo(width - 4, cy); ctx.stroke()
        ctx.lineWidth = 2
        ctx.beginPath(); ctx.arc(cx, cy, r, Math.PI, 2 * Math.PI); ctx.stroke()
        if (day) {
          ctx.strokeStyle = sun
          ctx.lineWidth = 3
          ctx.beginPath(); ctx.arc(cx, cy, r, Math.PI, Math.PI + Math.PI * progress); ctx.stroke()
        }
        var a = Math.PI + Math.PI * progress
        ctx.fillStyle = day ? sun : off
        ctx.beginPath(); ctx.arc(cx + r * Math.cos(a), cy + r * Math.sin(a), day ? 7 : 5, 0, 2 * Math.PI); ctx.fill()
      }
    }

    Row {
      id: times
      width: parent.width
      Label {
        width: parent.width / 2
        text: widget.sky ? "↑ " + widget.time(widget.now < widget.set ? widget.rise : widget.next) : (widget.failed ? "offline" : "…")
      }
      Label {
        width: parent.width / 2
        horizontalAlignment: Text.AlignRight
        text: widget.sky ? "↓ " + widget.time(widget.set) : ""
      }
    }
    Label {
      id: leftView
      width: parent.width
      color: widget.dim
      font.pixelSize: Style.font.caption
      text: !widget.sky ? ""
        : widget.now < widget.rise ? "sunrise in " + widget.duration(widget.rise - widget.now)
        : widget.day ? widget.duration(widget.set - widget.now) + " of daylight left"
        : "sunrise in " + widget.duration(widget.next - widget.now)
    }

    Row {
      id: moon
      width: parent.width
      spacing: Style.spacing.md
      // Lit part of the moon: the limb on one side, the terminator (an ellipse) on the other.
      Canvas {
        id: moonFace
        width: 22
        height: 22
        property real lit: widget.sky ? widget.sky.illum / 100 : 0
        property bool waxing: widget.waxing
        property color face: Util.alpha(Commons.Color.muted, 0.3)
        property color edge: Commons.Color.muted
        property color light: widget.fg
        onLitChanged: requestPaint()
        onWaxingChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var r = 10, c = 11, s = waxing ? 1 : -1, f = lit
          ctx.fillStyle = face
          ctx.strokeStyle = edge
          ctx.lineWidth = 1
          ctx.beginPath(); ctx.arc(c, c, r, 0, 2 * Math.PI); ctx.fill(); ctx.stroke()
          ctx.fillStyle = light
          ctx.beginPath()
          var i, y
          for (i = 0; i <= 20; i++) {
            y = -r + 2 * r * i / 20
            let x = c + s * Math.sqrt(Math.max(r * r - y * y, 0))
            if (i === 0) ctx.moveTo(x, c + y); else ctx.lineTo(x, c + y)
          }
          for (i = 20; i >= 0; i--) {
            y = -r + 2 * r * i / 20
            ctx.lineTo(c + s * Math.sqrt(Math.max(r * r - y * y, 0)) * (1 - 2 * f), c + y)
          }
          ctx.closePath()
          ctx.fill()
        }
      }
      Label {
        width: parent.width - moonFace.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        text: widget.sky ? widget.sky.phase.toLowerCase() + " · " + widget.sky.illum + "%" : ""
        font.pixelSize: Style.font.caption
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
