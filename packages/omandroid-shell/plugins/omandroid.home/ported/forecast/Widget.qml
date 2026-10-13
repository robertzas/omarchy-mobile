// SPDX-License-Identifier: MIT
// A three-day forecast with an hourly temperature curve, from wttr.in.
// Ported from simonschubert/forecast in Simon Schubert's omarchy-widgets
// (MIT, Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Wttr.js" as Wttr

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property string city: String(settings.city || "").trim()
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // { city, w: { place, now: { temp, desc }, days: [{ date, max, min, hours }] }, at }
  property var reading: host && host.cached ? host.cached : null
  property bool failed: false

  function refresh(force) {
    if (!force && reading && reading.city === city && Date.now() - reading.at < 30 * 60000) return
    var wanted = city
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let j = JSON.parse(xhr.responseText)
        // Only what's drawn is kept from wttr.in's ~50 KB.
        let w = {
          place: Wttr.value(j.nearest_area[0].areaName),
          now: { temp: j.current_condition[0].temp_C, desc: Wttr.value(j.current_condition[0].weatherDesc) },
          days: j.weather.map(function(d) {
            return { date: d.date, max: d.maxtempC, min: d.mintempC, hours: d.hourly.map(function(h) { return Number(h.tempC) }) }
          })
        }
        widget.failed = false
        widget.reading = { city: wanted, w: w, at: Date.now() }
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
  Timer { interval: 30 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var w: reading && reading.city === city ? reading.w : null
  readonly property var hours: w ? [].concat.apply([], w.days.map(function(d) { return d.hours })) : []

  function weekday(date, i) {
    if (i === 0) return "today"
    var m = /^(\d+)-(\d+)-(\d+)$/.exec(String(date))
    return m ? Qt.formatDate(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])), "ddd").toLowerCase() : ""
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  Column {
    id: content
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.sm

    Row {
      id: head
      width: parent.width
      spacing: Style.spacing.lg
      Label {
        id: temp
        text: widget.w ? widget.w.now.temp + "°" : (widget.failed ? "offline" : "…")
        color: widget.w ? widget.fg : widget.dim
        font.pixelSize: Style.font.title
        anchors.verticalCenter: parent.verticalCenter
      }
      Column {
        width: parent.width - temp.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        Label { width: parent.width; text: widget.w ? widget.w.now.desc : "" }
        Label { width: parent.width; text: widget.w ? widget.w.place : ""; color: widget.dim; font.pixelSize: Style.font.caption }
      }
    }

    Row {
      id: days
      width: parent.width
      Repeater {
        model: widget.w ? widget.w.days : []
        delegate: Column {
          id: dayCol
          required property var modelData
          required property int index
          width: days.width / Math.max(widget.w.days.length, 1)
          Label { width: parent.width; text: widget.weekday(dayCol.modelData.date, dayCol.index); color: widget.dim; font.pixelSize: Style.font.caption }
          Label { width: parent.width; text: dayCol.modelData.max + "° / " + dayCol.modelData.min + "°" }
        }
      }
    }

    // 8 readings a day, every 3 hours; the dots mark noon.
    Canvas {
      id: curveView
      width: parent.width
      height: Math.max(0, parent.height - head.height - days.height - parent.spacing * 2)
      property var hours: widget.hours
      property color line: Commons.Color.accent
      onHoursChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var h = hours
        if (h.length < 2 || height < 10) return
        var lo = Math.min.apply(null, h) - 2, hi = Math.max.apply(null, h) + 2
        var pts = h.map(function(t, i) { return [i / (h.length - 1) * width, height - 4 - (t - lo) / (hi - lo) * (height - 8)] })
        ctx.strokeStyle = line
        ctx.fillStyle = line
        ctx.lineWidth = 2
        ctx.beginPath()
        pts.forEach(function(p, i) { if (i === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]) })
        ctx.stroke()
        pts.forEach(function(p, i) {
          if (i % 8 !== 4) return
          ctx.beginPath(); ctx.arc(p[0], p[1], 3, 0, 2 * Math.PI); ctx.fill()
        })
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: Qt.openUrlExternally("https://wttr.in/" + Wttr.encodeCity(widget.city))
  }
}
