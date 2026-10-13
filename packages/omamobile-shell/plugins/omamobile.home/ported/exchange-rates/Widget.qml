// SPDX-License-Identifier: MIT
// Daily ECB exchange rates with a 30-day trend, from the Frankfurter API.
// Ported from simonschubert/exchange-rates in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
// ../../LICENSE-omarchy-widgets).
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

  function code(s) { return String(s || "").trim().toUpperCase().replace(/[^A-Z]/g, "").slice(0, 3) }
  readonly property string base: code(settings.base) || "USD"
  readonly property var targets: String(settings.currencies || "").split(/[\s,]+/).map(code)
    .filter(function(c, i, all) { return c.length === 3 && c !== widget.base && all.indexOf(c) === i }).slice(0, 6)
  readonly property string key: base + ":" + targets.join(",")

  // { key, rates: [{ code, rate, change, hist }], at }
  property var reading: host && host.cached ? host.cached : null
  property string problem: ""

  function refresh(force) {
    if (targets.length === 0) return
    if (!force && reading && reading.key === key && Date.now() - reading.at < 60 * 60000) return
    var wanted = key, to = targets
    var from = new Date(Date.now() - 30 * 86400000)
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let j = JSON.parse(xhr.responseText)
        let days = Object.keys(j.rates).sort().map(function(d) { return j.rates[d] })
        let now = days[days.length - 1], prev = days[days.length - 2] || now
        let rates = to.filter(function(c) { return now[c] }).map(function(c) {
          return { code: c, rate: now[c], change: (now[c] / prev[c] - 1) * 100,
                   hist: days.map(function(d) { return d[c] }).filter(function(v) { return v }) }
        })
        widget.problem = ""
        widget.reading = { key: wanted, rates: rates, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      } catch (e) {
        widget.problem = xhr.status === 0 ? "offline" : "no rates for " + widget.base
      }
    }
    xhr.open("GET", "https://api.frankfurter.dev/v1/" + Qt.formatDate(from, "yyyy-MM-dd") + "..?base=" + base + "&symbols=" + to.join(","))
    xhr.send()
  }

  Component.onCompleted: refresh(false)
  onKeyChanged: refresh(true)
  Timer { interval: 60 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var rates: reading && reading.key === key ? reading.rates : []

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  Label {
    visible: widget.rates.length === 0
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    wrapMode: Text.Wrap
    maximumLineCount: 3
    text: widget.targets.length === 0 ? "Tap to choose currencies." : widget.problem !== "" ? widget.problem : "…"
    color: widget.dim
  }

  Row {
    id: rates
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.xxl
    // As many columns as fit, about 100 px each.
    readonly property int shown: Math.max(1, Math.min(widget.rates.length, Math.floor((width + spacing) / (100 + spacing))))
    Repeater {
      model: widget.rates.slice(0, rates.shown)
      delegate: Column {
        id: col
        required property var modelData
        width: (rates.width - rates.spacing * (rates.shown - 1)) / rates.shown
        height: rates.height
        Label { id: pair; width: parent.width; text: widget.base + " → " + col.modelData.code; color: widget.dim; font.pixelSize: Style.font.caption }
        Label {
          id: rate
          width: parent.width
          text: col.modelData.rate >= 100 ? col.modelData.rate.toFixed(1) : col.modelData.rate >= 10 ? col.modelData.rate.toFixed(2) : col.modelData.rate.toFixed(4)
          font.pixelSize: Style.font.title
        }
        Label {
          id: change
          width: parent.width
          text: (col.modelData.change >= 0 ? "+" : "") + col.modelData.change.toFixed(2) + "%"
          color: col.modelData.change >= 0 ? Commons.Color.accent : Commons.Color.urgent
          font.pixelSize: Style.font.caption
        }
        Canvas {
          width: parent.width
          height: Math.max(0, col.height - pair.height - rate.height - change.height - Style.spacing.xs)
          property var values: col.modelData.hist
          property color line: Commons.Color.accent
          onValuesChanged: requestPaint()
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var v = values
            if (v.length < 2 || height < 4) return
            var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), span = Math.max(hi - lo, 1e-9)
            ctx.strokeStyle = line
            ctx.lineWidth = 1.5
            ctx.beginPath()
            v.forEach(function(x, i) {
              var px = i / (v.length - 1) * width, py = height - 1 - (x - lo) / span * (height - 2)
              if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
            })
            ctx.stroke()
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
