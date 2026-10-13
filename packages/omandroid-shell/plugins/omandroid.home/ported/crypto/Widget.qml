// SPDX-License-Identifier: MIT
// Bitcoin from CoinGecko: price, changes, the day's range and a 7-day
// chart; a tap opens the market details inside the card. Ported from
// simonschubert/crypto in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

Item {
  id: widget

  // A tap anywhere on the card goes to the next view (tile, details, back to
  // the tile); links and buttons keep their own taps. Not in edit mode.
  function cycle() {
    if (widget.editing) return
    widget.detail = !widget.detail
  }
  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: widget.cycle()
  }

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // { b: CoinGecko's market entry, at }
  property var reading: host && host.cached ? host.cached : null
  property string problem: ""
  property bool detail: false

  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < 5 * 60000) return
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let b = JSON.parse(xhr.responseText)[0]
        if (!b || !b.current_price) throw new Error("no price")
        widget.problem = ""
        widget.reading = { b: b, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      } catch (e) {
        widget.problem = xhr.status === 429 ? "coingecko is busy, retrying" : "coingecko offline"
      }
    }
    xhr.open("GET", "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=bitcoin&sparkline=true&price_change_percentage=1h,24h,7d")
    xhr.send()
  }

  Component.onCompleted: refresh(false)
  Timer { interval: 5 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var b: reading ? reading.b : null
  readonly property var week: b && b.sparkline_in_7d ? b.sparkline_in_7d.price : []
  readonly property var hour: b ? b.price_change_percentage_1h_in_currency : null
  readonly property var day: b ? b.price_change_percentage_24h_in_currency : null
  readonly property var days7: b ? b.price_change_percentage_7d_in_currency : null
  // CoinGecko updates the day's low and high less often than the price, so the price can be outside them.
  readonly property real low: b ? Math.min(b.low_24h, b.current_price) : 0
  readonly property real high: b ? Math.max(b.high_24h, b.current_price) : 0
  readonly property real at: high > low ? (b.current_price - low) / (high - low) : 0.5
  readonly property string status: b ? "" : problem !== "" ? problem : "…"

  // Whole dollars with thousands separators: $82,612.
  function usd(n) {
    if (n === null || n === undefined) return "…"
    return "$" + String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }
  // Trillions and billions: $1.66T, $33.5B.
  function big(n) { return n === null || n === undefined ? "…" : n >= 1e12 ? "$" + (n / 1e12).toFixed(2) + "T" : "$" + (n / 1e9).toFixed(1) + "B" }
  function pct(p) { return p === null || p === undefined ? "…" : (p >= 0 ? "+" : "") + p.toFixed(1) + "%" }
  function pctTint(p) { return p === null || p === undefined ? widget.dim : p >= 0 ? Commons.Color.accent : Commons.Color.urgent }

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }
  component Rule: Rectangle {
    width: parent ? parent.width : 0
    height: 1
    color: Util.alpha(Commons.Color.muted, 0.25)
  }
  component Change: Column {
    id: change
    property string label: ""
    property var p: null
    property int size: Style.font.bodySmall
    Label { width: change.width; text: change.label; color: widget.dim; font.pixelSize: Style.font.caption }
    Label { width: change.width; text: widget.pct(change.p); color: widget.pctTint(change.p); font.bold: true; font.pixelSize: change.size }
  }
  // Where the price sits between the day's low and high.
  component Range: Column {
    id: range
    property int size: Style.font.caption
    width: parent ? parent.width : 0
    spacing: 2
    Item {
      width: parent.width
      height: 8
      Rectangle { y: 2.5; width: parent.width; height: 3; radius: 1.5; color: Util.alpha(Commons.Color.muted, 0.3) }
      Rectangle { y: 2.5; width: parent.width * widget.at; height: 3; radius: 1.5; color: Util.alpha(Commons.Color.accent, 0.6) }
      Rectangle { x: parent.width * widget.at - 4; width: 8; height: 8; radius: 4; color: Commons.Color.accent }
    }
    Row {
      width: parent.width
      Label { width: parent.width * 0.4; text: widget.usd(widget.low); color: widget.dim; font.pixelSize: range.size }
      Label { width: parent.width * 0.2; text: "24h"; color: widget.dim; font.pixelSize: range.size; horizontalAlignment: Text.AlignHCenter }
      Label { width: parent.width * 0.4; text: widget.usd(widget.high); color: widget.dim; font.pixelSize: range.size; horizontalAlignment: Text.AlignRight }
    }
  }
  component Chart: Canvas {
    id: chart
    property bool labels: false
    property var values: widget.week
    property color line: widget.days7 !== null && widget.days7 < 0 ? Commons.Color.urgent : Commons.Color.accent
    property color dimText: widget.dim
    onValuesChanged: requestPaint()
    onLineChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var v = values
      if (v.length < 2 || height < 6) return
      var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), n = v.length - 1
      var top = labels ? 16 : 1, h = labels ? height - 40 : height - 2
      var pts = v.map(function(x, i) { return [i / n * width, top + (hi - x) / Math.max(hi - lo, 1) * h] })
      var grad = ctx.createLinearGradient(0, top, 0, top + h)
      grad.addColorStop(0, Util.alpha(line, 0.35))
      grad.addColorStop(1, Util.alpha(line, 0))
      ctx.fillStyle = grad
      ctx.beginPath()
      pts.forEach(function(p, i) { if (i === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]) })
      ctx.lineTo(width, top + h); ctx.lineTo(0, top + h); ctx.closePath(); ctx.fill()
      ctx.strokeStyle = line
      ctx.lineWidth = 2
      ctx.lineCap = "round"
      ctx.beginPath()
      pts.forEach(function(p, i) { if (i === 0) ctx.moveTo(p[0], p[1]); else ctx.lineTo(p[0], p[1]) })
      ctx.stroke()
      if (!labels) return
      ctx.fillStyle = dimText
      ctx.font = "10px \"" + Style.font.family + "\""
      ctx.fillText(widget.usd(hi), 0, 10)
      ctx.fillText(widget.usd(lo), 0, top + h + 12)
      ctx.textAlign = "center"
      for (let d = 0; d < 8; d++) ctx.fillText(d === 7 ? "now" : (7 - d) + "d", 12 + d / 7 * (width - 24), height - 4)
    }
  }
  component Stat: Rectangle {
    id: stat
    property string label: ""
    property string value: ""
    property string note: ""
    property color noteColor: widget.dim
    width: (parent ? parent.width : 0) / 2 - Style.spacing.sm
    height: statCol.implicitHeight + Style.spacing.lg * 2
    color: Util.alpha(widget.fg, 0)
    radius: Style.cornerRadius
    border.width: 1
    border.color: Util.alpha(Commons.Color.muted, 0.3)
    Column {
      id: statCol
      anchors.fill: parent
      anchors.margins: Style.spacing.lg
      Label { width: parent.width; text: stat.label; color: widget.dim; font.pixelSize: Style.font.caption }
      Label { width: parent.width; text: stat.value; font.bold: true; font.pixelSize: Style.font.body }
      Label { width: parent.width; text: stat.note; color: stat.noteColor; font.pixelSize: Style.font.caption }
    }
  }

  // ---------- the tile
  Column {
    id: tile
    visible: !widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.sm

    Row {
      id: head
      width: parent.width
      Label { width: parent.width - dayPct.width; text: "bitcoin"; color: widget.dim }
      Label { id: dayPct; text: widget.pct(widget.day); color: widget.pctTint(widget.day); font.bold: true }
    }
    Label { id: tileStatus; visible: widget.status !== ""; width: parent.width; text: widget.status; color: widget.dim }
    Label { id: price; visible: widget.b !== null; width: parent.width; text: widget.usd(widget.b ? widget.b.current_price : null); font.pixelSize: Style.font.title }
    Chart {
      visible: widget.b !== null
      width: parent.width
      height: Math.max(0, tile.height - head.height - price.height - (lower.visible ? lower.height + tile.spacing : 0) - tile.spacing * 2)
    }
    Column {
      id: lower
      visible: widget.b !== null && widget.cellsHigh >= 2
      width: parent.width
      spacing: Style.spacing.sm
      Range { }
      Row {
        width: parent.width
        spacing: Style.spacing.lg
        Change { width: (parent.width - parent.spacing * 2) / 3; label: "1h"; p: widget.hour }
        Change { width: (parent.width - parent.spacing * 2) / 3; label: "24h"; p: widget.day }
        Change { width: (parent.width - parent.spacing * 2) / 3; label: "7d"; p: widget.days7 }
      }
    }
  }


  // ---------- the details
  Item {
    visible: widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl

    Item {
      id: detailHeader
      width: parent.width
      height: 44
      Label { anchors.verticalCenter: parent.verticalCenter; text: "‹ bitcoin"; color: Commons.Color.accent; font.pixelSize: Style.font.subtitle }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: widget.cycle()
      }
    }
    Flickable {
      id: detailFlick
      anchors.top: detailHeader.bottom
      anchors.bottom: parent.bottom
      width: parent.width
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      contentHeight: details.implicitHeight

      // Taps on the details' empty space and plain rows go to the next view too.
      MouseArea {
        width: detailFlick.width
        height: Math.max(detailFlick.height, detailFlick.contentHeight)
        enabled: !widget.editing
        onClicked: widget.cycle()
      }

      Column {
        id: details
        width: parent.width
        spacing: Style.spacing.xl

        Label { visible: widget.status !== ""; text: widget.status; color: widget.dim }
        Label { visible: widget.b !== null; text: widget.usd(widget.b ? widget.b.current_price : null); font.bold: true; font.pixelSize: Style.font.displayLarge }
        Row {
          visible: widget.b !== null
          width: parent.width
          spacing: Style.spacing.xxl
          Change { width: (parent.width - parent.spacing * 2) / 3; label: "1 hour"; p: widget.hour; size: Style.font.subtitle }
          Change { width: (parent.width - parent.spacing * 2) / 3; label: "24 hours"; p: widget.day; size: Style.font.subtitle }
          Change { width: (parent.width - parent.spacing * 2) / 3; label: "7 days"; p: widget.days7; size: Style.font.subtitle }
        }
        Rule { visible: widget.b !== null }
        Label { visible: widget.b !== null; text: "last 7 days"; color: Commons.Color.accent }
        Chart { visible: widget.b !== null; labels: true; width: parent.width; height: 184 }
        Range { visible: widget.b !== null; size: Style.font.bodySmall }
        Rule { visible: widget.b !== null }
        Label { visible: widget.b !== null; text: "market"; color: Commons.Color.accent }
        Flow {
          visible: widget.b !== null
          width: parent.width
          spacing: Style.spacing.md
          Stat {
            label: "market cap"
            value: widget.big(widget.b ? widget.b.market_cap : null)
            note: widget.b ? widget.pct(widget.b.market_cap_change_percentage_24h) + " today" : ""
            noteColor: widget.pctTint(widget.b ? widget.b.market_cap_change_percentage_24h : null)
          }
          Stat {
            label: "24h volume"
            value: widget.big(widget.b ? widget.b.total_volume : null)
            note: widget.b ? (widget.b.total_volume / widget.b.market_cap * 100).toFixed(1) + "% of the cap" : ""
          }
          Stat {
            label: "all-time high"
            value: widget.usd(widget.b ? widget.b.ath : null)
            note: widget.b ? widget.b.ath_change_percentage.toFixed(1) + "% · " + String(widget.b.ath_date).slice(0, 10) : ""
            noteColor: widget.pctTint(widget.b ? widget.b.ath_change_percentage : null)
          }
          Stat { label: "rank"; value: widget.b ? "#" + widget.b.market_cap_rank : ""; note: "by market cap" }
        }
        Rule { visible: widget.b !== null }
        Label { visible: widget.b !== null; text: "supply"; color: Commons.Color.accent }
        Column {
          id: supply
          visible: widget.b !== null && widget.b.max_supply > 0
          width: parent.width
          spacing: Style.spacing.sm
          readonly property real mined: widget.b && widget.b.max_supply ? widget.b.circulating_supply / widget.b.max_supply : 0
          Row {
            width: parent.width
            Label { width: parent.width / 2; text: widget.b ? (widget.b.circulating_supply / 1e6).toFixed(2) + "M mined" : ""; font.pixelSize: Style.font.body }
            Label { width: parent.width / 2; horizontalAlignment: Text.AlignRight; text: widget.b ? "of " + Math.round(widget.b.max_supply / 1e6) + "M" : ""; color: widget.dim; font.pixelSize: Style.font.body }
          }
          Rectangle {
            width: parent.width
            height: 6
            radius: 3
            color: Util.alpha(Commons.Color.muted, 0.25)
            Rectangle { width: parent.width * supply.mined; height: parent.height; radius: 3; color: Commons.Color.accent }
          }
          Label {
            width: parent.width
            text: widget.b ? (supply.mined * 100).toFixed(2) + "% mined, " + Math.round((widget.b.max_supply - widget.b.circulating_supply) / 1000) + "k btc to go" : ""
            color: widget.dim
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          width: parent.width
          height: 44
          radius: Style.cornerRadius
          color: Util.alpha(Commons.Color.accent, 0.15)
          border.width: 1
          border.color: Commons.Color.accent
          Label { anchors.centerIn: parent; text: "open on coingecko"; color: Commons.Color.accent }
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: widget.host.openUrl("https://www.coingecko.com/en/coins/bitcoin")
          }
        }
        Label {
          visible: widget.b !== null
          text: widget.b ? "data: coingecko · updated " + String(widget.b.last_updated).slice(11, 16) + " utc" : ""
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
