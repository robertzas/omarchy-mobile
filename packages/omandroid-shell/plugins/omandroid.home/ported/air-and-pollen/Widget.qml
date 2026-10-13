// SPDX-License-Identifier: MIT
// Air quality and pollen from Open-Meteo (Copernicus), located through
// wttr.in. Ported from simonschubert/air-and-pollen in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
// ../../LICENSE-omarchy-widgets). A tap opens the details inside the card.
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
  readonly property string timeFormat: host ? host.timeFormat : "HH:mm"

  SystemClock { id: clock; precision: SystemClock.Minutes }

  // { city, area: { name, country, lat, lon }, air: <open-meteo answer>, at }
  property var reading: host && host.cached ? host.cached : null
  property string problem: ""
  property bool detail: false

  function get(url, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var j = null
      try { if (xhr.status === 200) j = JSON.parse(xhr.responseText) } catch (e) { j = null }
      done(j)
    }
    xhr.open("GET", url)
    xhr.send()
  }

  function refresh(force) {
    if (!force && reading && reading.city === city && Date.now() - reading.at < 30 * 60000) return
    var wanted = city
    // Where you are first (the same request as the today widget), then the air there.
    get(Wttr.url(wanted), function(wx) {
      var a = wx && wx.nearest_area ? wx.nearest_area[0] : null
      if (!a || isNaN(Number(a.latitude))) { widget.problem = wx ? "location unknown" : "wttr.in offline"; return }
      var area = { name: Wttr.value(a.areaName), country: Wttr.value(a.country), lat: Number(a.latitude), lon: Number(a.longitude) }
      widget.get("https://air-quality-api.open-meteo.com/v1/air-quality?latitude=" + area.lat + "&longitude=" + area.lon
        + "&current=european_aqi,us_aqi,pm2_5,pm10,ozone,nitrogen_dioxide,uv_index"
        + "&hourly=european_aqi,us_aqi,alder_pollen,birch_pollen,grass_pollen,mugwort_pollen,olive_pollen,ragweed_pollen"
        + "&forecast_days=2&timezone=auto&timeformat=unixtime", function(air) {
        if (!air || !air.current) { widget.problem = "open-meteo offline"; return }
        widget.problem = ""
        widget.reading = { city: wanted, area: area, air: air, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      })
    })
  }

  Component.onCompleted: refresh(false)
  onCityChanged: refresh(true)
  Timer { interval: 30 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property var latest: reading && reading.city === city ? reading : null
  readonly property var area: latest ? latest.area : null
  readonly property var cur: latest ? latest.air.current : null
  readonly property var hourly: latest ? latest.air.hourly : null
  // The US index there, Europe's everywhere else.
  readonly property bool us: area ? ["united states", "united states of america"].indexOf(area.country.trim().toLowerCase()) >= 0 : false
  readonly property string index: us ? "us_aqi" : "european_aqi"
  readonly property var aqi: cur && cur[index] !== null && cur[index] !== undefined ? Number(cur[index]) : null
  readonly property var steps: us ? [50, 100, 150, 200, 300] : [20, 40, 60, 80, 100]
  readonly property var names: us ? ["good", "moderate", "unhealthy for some", "unhealthy", "very unhealthy", "hazardous"]
    : ["good", "fair", "moderate", "poor", "very poor", "extremely poor"]
  readonly property var advice: ["ideal for being outside", "fine for your usual outdoor plans", "sensitive people may want to take it easy outside",
    "consider less intense activity outside", "cut down on activity outside", "avoid activity outside"]
  function levelOf(v) { return v === null ? -1 : steps.filter(function(s) { return v > s }).length }
  readonly property int level: levelOf(aqi)
  // Good is the accent, the worst the urgent colour, the levels between a mix of the two.
  function tintFor(lv) { return lv < 0 ? Commons.Color.muted : Qt.tint(Commons.Color.accent, Util.alpha(Commons.Color.urgent, Math.min(lv, 4) / 4)) }
  readonly property color tint: tintFor(level)

  // The next 24 hours, from the current one on.
  readonly property int start: {
    if (!hourly) return 0
    var nowS = clock.date.getTime() / 1000
    return Math.max(hourly.time.filter(function(t) { return t <= nowS }).length - 1, 0)
  }
  function next24(key) { return hourly && hourly[key] ? hourly[key].slice(start, start + 24) : [] }
  readonly property var hours: next24("time")
  readonly property var aqis: next24(index)

  // Pollen in grains/m³, rated none, low, moderate or high. Europe only: elsewhere it's null.
  readonly property var pollen: {
    var kinds = [["birch", [1, 15, 90]], ["alder", [1, 15, 90]], ["olive", [1, 15, 90]],
                 ["grass", [1, 20, 50]], ["mugwort", [1, 10, 50]], ["ragweed", [1, 5, 20]]]
    return kinds.map(function(k) {
      var values = widget.next24(k[0] + "_pollen")
      var real = values.filter(function(v) { return v !== null })
      var peak = real.length ? Math.max.apply(null, real) : null
      return { name: k[0], values: values, peak: peak, level: peak === null ? 0 : k[1].filter(function(x) { return peak >= x }).length }
    }).sort(function(a, b) { return (b.peak || 0) - (a.peak || 0) })
  }
  readonly property bool hasPollen: pollen.some(function(p) { return p.peak !== null })
  readonly property var flying: pollen.filter(function(p) { return p.level > 0 })
  readonly property var pollenWords: ["none", "low", "moderate", "high"]
  function pollenTint(lv) { return lv === 0 ? Commons.Color.muted : tintFor((lv - 1) * 2) }
  readonly property string status: latest ? "" : problem !== "" ? problem : "…"

  function round1(v) { return v === null || v === undefined ? "…" : String(Math.round(v * 10) / 10) }

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
  // The index on a 270° gauge.
  component Gauge: Item {
    id: gauge
    property bool big: false
    Canvas {
      id: ring
      anchors.fill: parent
      property real value: widget.aqi === null ? 0 : Math.min(widget.aqi / widget.steps[4], 1)
      property color tint: widget.tint
      property color track: Util.alpha(Commons.Color.muted, 0.2)
      onValueChanged: requestPaint()
      onTintChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var t = gauge.big ? 10 : 6, r = Math.min(width, height) / 2 - t / 2
        var a0 = 0.75 * Math.PI, sweep = 1.5 * Math.PI
        ctx.lineWidth = t
        ctx.lineCap = "round"
        ctx.strokeStyle = track
        ctx.beginPath(); ctx.arc(width / 2, height / 2, r, a0, a0 + sweep); ctx.stroke()
        if (value > 0) {
          ctx.strokeStyle = tint
          ctx.beginPath(); ctx.arc(width / 2, height / 2, r, a0, a0 + sweep * value); ctx.stroke()
        }
      }
    }
    Column {
      anchors.centerIn: parent
      Label {
        anchors.horizontalCenter: parent.horizontalCenter
        text: widget.aqi === null ? "…" : String(Math.round(widget.aqi))
        color: widget.tint
        font.bold: true
        font.pixelSize: gauge.big ? Style.font.displayLarge : Style.font.subtitle
      }
      Label {
        anchors.horizontalCenter: parent.horizontalCenter
        text: widget.us ? "us aqi" : "eu aqi"
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
    }
  }
  component PollenRow: Row {
    id: prow
    property var p: ({ name: "", level: 0 })
    width: parent ? parent.width : 0
    spacing: Style.spacing.md
    Label { width: prow.width - dots.width - word.width - prow.spacing * 2; text: prow.p.name }
    Row {
      id: dots
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      Repeater {
        model: 3
        delegate: Rectangle {
          required property int index
          width: 8; height: 4; radius: 2
          color: index < prow.p.level ? widget.pollenTint(prow.p.level) : Util.alpha(Commons.Color.muted, 0.25)
        }
      }
    }
    Label { id: word; width: 64; horizontalAlignment: Text.AlignRight; text: widget.pollenWords[prow.p.level]; color: widget.pollenTint(prow.p.level) }
  }

  // ---------- the tile
  Column {
    id: tile
    visible: !widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      Label { id: airTitle; text: "air"; color: widget.dim }
      Label {
        width: parent.width - airTitle.width
        horizontalAlignment: Text.AlignRight
        text: widget.area ? widget.area.name.toLowerCase() : ""
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
    }
    Label { visible: widget.status !== ""; text: widget.status; color: widget.dim }
    Row {
      id: summary
      visible: widget.status === ""
      width: parent.width
      spacing: Style.spacing.lg
      Gauge { id: smallGauge; width: 64; height: 64 }
      Column {
        width: parent.width - smallGauge.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        Label {
          width: parent.width
          text: widget.level >= 0 ? widget.names[widget.level] : ""
          color: widget.tint
          font.bold: true
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          maximumLineCount: 2
        }
        Label { width: parent.width; text: "pm2.5 " + (widget.cur ? Math.round(widget.cur.pm2_5) : "…") + " µg/m³"; color: widget.dim; font.pixelSize: Style.font.caption }
        Label {
          width: parent.width
          font.pixelSize: Style.font.caption
          // Too short for the pollen list: the worst one, or none.
          text: widget.cellsHigh >= 2 || !widget.hasPollen ? "uv " + (widget.cur ? Math.round(widget.cur.uv_index) : "…")
            : widget.flying.length === 0 ? "no pollen" : widget.flying[0].name + " pollen " + widget.pollenWords[widget.flying[0].level]
          color: widget.cellsHigh >= 2 || !widget.hasPollen ? widget.dim
            : widget.flying.length === 0 ? Commons.Color.accent : widget.pollenTint(widget.flying[0].level)
        }
      }
    }
    Rule { visible: widget.status === "" && widget.cellsHigh >= 2 }
    Label { visible: widget.status === "" && widget.cellsHigh >= 2; text: "pollen · next 24 h"; color: widget.dim; font.pixelSize: Style.font.caption }
    Label {
      visible: widget.status === "" && widget.cellsHigh >= 2 && (!widget.hasPollen || widget.flying.length === 0)
      width: parent.width
      text: !widget.hasPollen ? "no pollen forecast here (europe only)" : "none in the air"
      color: !widget.hasPollen ? widget.dim : Commons.Color.accent
      font.pixelSize: Style.font.caption
    }
    Repeater {
      model: widget.status === "" && widget.cellsHigh >= 2 ? widget.flying.slice(0, widget.cellsHigh >= 3 ? 5 : 3) : []
      delegate: PollenRow {
        required property var modelData
        p: modelData
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    visible: !widget.detail
    enabled: !widget.editing
    onClicked: widget.detail = true
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
      Label { anchors.verticalCenter: parent.verticalCenter; text: "‹ air and pollen"; color: Commons.Color.accent; font.pixelSize: Style.font.subtitle }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: widget.detail = false
      }
    }

    Flickable {
      anchors.top: detailHeader.bottom
      anchors.bottom: parent.bottom
      width: parent.width
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      contentHeight: details.implicitHeight

      Column {
        id: details
        width: parent.width
        spacing: Style.spacing.xl

        Label { visible: widget.status !== ""; text: widget.status; color: widget.dim }
        Row {
          visible: widget.status === ""
          width: parent.width
          spacing: Style.spacing.xl
          Gauge { id: bigGauge; big: true; width: 120; height: 120 }
          Column {
            width: parent.width - bigGauge.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs
            Label { width: parent.width; text: widget.level >= 0 ? widget.names[widget.level] : ""; color: widget.tint; font.pixelSize: Style.font.title; wrapMode: Text.Wrap; maximumLineCount: 2 }
            Label { width: parent.width; text: widget.level >= 0 ? widget.advice[widget.level] : ""; wrapMode: Text.Wrap; maximumLineCount: 3 }
            Label { width: parent.width; text: widget.area ? (widget.area.name + ", " + widget.area.country).toLowerCase() : ""; color: widget.dim; font.pixelSize: Style.font.caption }
          }
        }

        Rule { visible: widget.status === "" }
        Label { visible: widget.status === ""; text: "next 24 hours"; color: Commons.Color.accent }
        Canvas {
          id: chart
          visible: widget.status === ""
          width: parent.width
          height: 110
          property var aqis: widget.aqis
          property var hours: widget.hours
          property color dimText: widget.dim
          onAqisChanged: requestPaint()
          onWidthChanged: requestPaint()
          onPaint: { let v;
            var ctx = getContext("2d")
            ctx.reset()
            var n = Math.max(aqis.length, 1), w = width / n
            var real = aqis.filter(function(v) { return v !== null })
            var top = Math.max(real.length ? Math.max.apply(null, real) : 0, widget.steps[2])
            // The category lines, faint, so a bar's height reads as good, fair, ...
            for (let s = 0; s < 4; s++) {
              let v0 = widget.steps[s]
              if (v0 >= top) continue
              ctx.strokeStyle = Util.alpha(widget.tintFor(s + 1), 0.3)
              ctx.lineWidth = 1
              ctx.beginPath(); ctx.moveTo(0, 92 - v0 / top * 84); ctx.lineTo(width, 92 - v0 / top * 84); ctx.stroke()
            }
            ctx.font = "10px \"" + Style.font.family + "\""
            ctx.textAlign = "center"
            for (let i = 0; i < aqis.length; i++) {
              v = aqis[i]
              if (v !== null) {
                ctx.fillStyle = widget.tintFor(widget.levelOf(v))
                ctx.fillRect(i * w + 1, 92 - v / top * 84, Math.max(w - 2, 1), Math.max(v / top * 84, 1))
              }
              if (i % 6 === 0 && hours[i] !== undefined) {
                ctx.fillStyle = dimText
                ctx.fillText(i === 0 ? "now" : Qt.formatTime(new Date(hours[i] * 1000), widget.timeFormat), i * w + w / 2, 106)
              }
            }
          }
        }

        Rule { visible: widget.status === "" }
        Label { visible: widget.status === ""; text: "pollutants now · µg/m³"; color: Commons.Color.accent }
        Flow {
          visible: widget.status === ""
          width: parent.width
          spacing: Style.spacing.md
          Repeater {
            model: widget.cur ? [["pm2.5", widget.cur.pm2_5, 25], ["pm10", widget.cur.pm10, 50], ["ozone", widget.cur.ozone, 120],
                                 ["no₂", widget.cur.nitrogen_dioxide, 40], ["uv index", widget.cur.uv_index, 6]] : []
            delegate: Rectangle {
              id: cell
              required property var modelData
              width: (details.width - Style.spacing.md * 2) / 3
              height: cellCol.implicitHeight + Style.spacing.lg * 2
              color: Util.alpha(widget.fg, 0)
              radius: Style.cornerRadius
              border.width: 1
              border.color: Util.alpha(Commons.Color.muted, 0.3)
              Column {
                id: cellCol
                anchors.fill: parent
                anchors.margins: Style.spacing.lg
                Label { width: parent.width; text: cell.modelData[0]; color: widget.dim; font.pixelSize: Style.font.caption }
                Label {
                  width: parent.width
                  text: widget.round1(cell.modelData[1])
                  color: cell.modelData[1] > cell.modelData[2] ? Commons.Color.urgent : widget.fg
                  font.pixelSize: Style.font.title
                }
              }
            }
          }
        }

        Rule { visible: widget.status === "" }
        Label { visible: widget.status === ""; text: "pollen · next 24 hours"; color: Commons.Color.accent }
        Label {
          visible: widget.status === "" && !widget.hasPollen
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          text: "open-meteo only forecasts pollen in europe."
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
        Repeater {
          model: widget.status === "" && widget.hasPollen ? widget.pollen : []
          delegate: Column {
            id: pcol
            required property var modelData
            width: details.width
            spacing: Style.spacing.xs
            PollenRow { p: pcol.modelData }
            Canvas {
              visible: pcol.modelData.level > 0
              width: parent.width
              height: visible ? 24 : 0
              property var values: pcol.modelData.values
              property color tint: widget.pollenTint(pcol.modelData.level)
              onValuesChanged: requestPaint()
              onWidthChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var v = values.map(function(x) { return x || 0 }), top = Math.max(pcol.modelData.peak || 0, 1)
                if (v.length < 2) return
                ctx.beginPath()
                ctx.moveTo(0, height)
                v.forEach(function(x, i) { ctx.lineTo(i / (v.length - 1) * width, height - x / top * (height - 2)) })
                ctx.lineTo(width, height)
                ctx.closePath()
                ctx.fillStyle = Util.alpha(tint, 0.3)
                ctx.fill()
                ctx.strokeStyle = tint
                ctx.lineWidth = 1.5
                ctx.beginPath()
                v.forEach(function(x, i) { var y = height - x / top * (height - 2); if (i === 0) ctx.moveTo(0, y); else ctx.lineTo(i / (v.length - 1) * width, y) })
                ctx.stroke()
              }
            }
          }
        }
        Label {
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          text: "data: copernicus atmosphere monitoring service via open-meteo"
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
        Label {
          width: parent.width
          height: 44
          verticalAlignment: Text.AlignVCenter
          text: "change the city in settings"
          color: widget.dim
          font.pixelSize: Style.font.caption
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: if (widget.host) widget.host.openSettings()
          }
        }
      }
    }
  }
}
