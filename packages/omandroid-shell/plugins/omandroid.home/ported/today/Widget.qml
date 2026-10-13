// SPDX-License-Identifier: MIT
// The date and the weather where you are, from wttr.in. Ported from
// simonschubert/today in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// A tap opens the details (next 24 hours, three days, wind, UV, sun and
// moon) inside the card; a tap on their header comes back.
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

  // { city, wx, at } from the last fetch.
  property var reading: host && host.cached ? host.cached : null
  property bool failed: false
  property bool detail: false

  function refresh(force) {
    if (!force && reading && reading.city === city && Date.now() - reading.at < 30 * 60000) return
    var wanted = city
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let wx = JSON.parse(xhr.responseText)
        if (!wx.current_condition) throw new Error("no weather")
        widget.failed = false
        widget.reading = { city: wanted, wx: wx, at: Date.now() }
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

  readonly property var wx: reading && reading.city === city ? reading.wx : null
  readonly property var cur: wx ? wx.current_condition[0] : null
  readonly property var day: wx && wx.weather ? wx.weather[0] : null
  readonly property var area: wx && wx.nearest_area ? wx.nearest_area[0] : null
  readonly property bool imperial: Wttr.imperial(area)
  readonly property string unit: imperial ? "F" : "C"
  readonly property bool night: cur ? Wttr.value(cur.weatherIconUrl).indexOf("_night") >= 0 : false
  // Clear or partly cloudy gets the accent; everything else stays neutral.
  readonly property color sky: cur && (cur.weatherCode === "113" || cur.weatherCode === "116") ? Commons.Color.accent : fg
  readonly property var sunrise: day ? Wttr.clock(day.astronomy[0].sunrise) : null
  readonly property var sunset: day ? Wttr.clock(day.astronomy[0].sunset) : null
  readonly property string place: area ? Wttr.value(area.areaName).toLowerCase() : ""
  readonly property string status: wx ? "" : failed ? "weather offline" : "weather…"

  function temp(obj, key) { return obj ? String(obj[key + unit]) + "°" : "…" }
  function desc(obj) { return obj ? Wttr.value(obj.weatherDesc).trim().toLowerCase() : "" }
  function maxRain(d) {
    return d ? Math.max.apply(null, d.hourly.map(function(h) { return Number(h.chanceofrain) || 0 })) : 0
  }
  function dayName(offset) {
    var d = new Date(clock.date.getTime() + offset * 86400000)
    return Qt.formatDate(d, "ddd").toLowerCase()
  }

  // The next 24 hours in wttr's 3-hour steps, from today's and tomorrow's forecasts.
  readonly property var steps: {
    if (!wx || !wx.weather) return []
    var hourNow = clock.date.getHours(), out = []
    for (let i = 0; i < 2 && i < wx.weather.length; i++) {
      (wx.weather[i].hourly || []).forEach(function(h) {
        var hr = i * 24 + Number(h.time) / 100
        if (hr > hourNow - 3) out.push({ hr: hr, t: Number(h["temp" + widget.unit]), rain: Number(h.chanceofrain) || 0, code: h.weatherCode })
      })
    }
    return out.slice(0, 8)
  }
  readonly property var range: {
    if (!wx || !wx.weather) return [0, 1]
    var lo = Math.min.apply(null, wx.weather.map(function(d) { return Number(d["mintemp" + widget.unit]) }))
    var hi = Math.max.apply(null, wx.weather.map(function(d) { return Number(d["maxtemp" + widget.unit]) }))
    return [lo, Math.max(hi, lo + 1)]
  }

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
  component Stat: Rectangle {
    id: stat
    property string glyph: ""
    property string label: ""
    property string value: ""
    property color tint: widget.fg
    width: (parent ? parent.width : 0) / 2 - Style.spacing.sm
    height: statRow.implicitHeight + Style.spacing.lg * 2
    color: Util.alpha(widget.fg, 0)
    border.width: 1
    border.color: Util.alpha(Commons.Color.muted, 0.3)
    radius: Style.cornerRadius
    Row {
      id: statRow
      anchors.fill: parent
      anchors.margins: Style.spacing.lg
      spacing: Style.spacing.lg
      Label { id: statGlyph; text: stat.glyph; color: stat.tint; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter }
      Column {
        width: parent.width - statGlyph.width - parent.spacing
        Label { width: parent.width; text: stat.label; color: widget.dim; font.pixelSize: Style.font.caption }
        Label { width: parent.width; text: stat.value; font.pixelSize: Style.font.body }
      }
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
      width: parent.width
      spacing: Style.spacing.lg
      Label {
        id: dayNumber
        text: Qt.formatDate(clock.date, "d")
        font.pixelSize: Style.font.displayLarge
        font.weight: Font.Light
      }
      Column {
        anchors.verticalCenter: dayNumber.verticalCenter
        width: parent.width - dayNumber.width - parent.spacing
        Label { width: parent.width; text: Qt.formatDate(clock.date, "dddd").toLowerCase(); color: Commons.Color.accent }
        Label { width: parent.width; text: Qt.formatDate(clock.date, "MMMM yyyy").toLowerCase(); color: widget.dim; font.pixelSize: Style.font.caption }
      }
    }
    Rule { visible: widget.cellsHigh >= 2 || widget.cellsWide >= 2 }

    Label { visible: widget.status !== ""; text: widget.status; color: widget.dim }

    Row {
      visible: widget.cur !== null
      width: parent.width
      spacing: Style.spacing.md
      Label {
        id: nowIcon
        text: widget.cur ? Wttr.weatherIcon(widget.cur.weatherCode, widget.night) : ""
        color: widget.sky
        font.pixelSize: Style.font.display
        anchors.verticalCenter: parent.verticalCenter
      }
      Label {
        id: nowTemp
        text: widget.temp(widget.cur, "temp_")
        color: Commons.Color.accent
        font.pixelSize: Style.font.display
        anchors.verticalCenter: parent.verticalCenter
      }
      Column {
        width: parent.width - nowIcon.width - nowTemp.width - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        Label { width: parent.width; horizontalAlignment: Text.AlignRight; text: widget.desc(widget.cur) }
        Label {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: "↑" + widget.temp(widget.day, "maxtemp") + " ↓" + widget.temp(widget.day, "mintemp")
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
      }
    }
    Label {
      visible: widget.cur !== null
      width: parent.width
      text: "feels " + widget.temp(widget.cur, "FeelsLike") + " · " + widget.place
      color: widget.dim
      font.pixelSize: Style.font.caption
    }
    Rule { visible: widget.cur !== null && widget.cellsHigh >= 2 }

    // The next two days (icon from the noon reading), then sunrise and sunset.
    Row {
      visible: widget.cur !== null && widget.cellsHigh >= 2
      width: parent.width
      Repeater {
        model: widget.wx && widget.wx.weather ? widget.wx.weather.slice(1, 3) : []
        delegate: Column {
          id: nextDay
          required property var modelData
          required property int index
          width: tile.width / 3.2
          Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: widget.dayName(nextDay.index + 1); color: widget.dim; font.pixelSize: Style.font.caption }
          Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: Wttr.weatherIcon(nextDay.modelData.hourly[4].weatherCode, false); font.pixelSize: Style.font.icon }
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: nextDay.modelData["maxtemp" + widget.unit] + "° " + nextDay.modelData["mintemp" + widget.unit] + "°"
            font.pixelSize: Style.font.caption
          }
        }
      }
      Column {
        width: tile.width - tile.width / 3.2 * 2
        spacing: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter
        Label { width: parent.width; text: " " + Wttr.formatClock(widget.sunrise, widget.timeFormat); font.pixelSize: Style.font.caption }
        Label { width: parent.width; text: " " + Wttr.formatClock(widget.sunset, widget.timeFormat); font.pixelSize: Style.font.caption }
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

    Row {
      id: detailHeader
      width: parent.width
      height: Math.max(44, backView.implicitHeight)
      spacing: Style.spacing.md
      Label { id: backView; anchors.verticalCenter: parent.verticalCenter; text: "‹ weather"; color: Commons.Color.accent; font.pixelSize: Style.font.subtitle }
      Label {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - backView.width - parent.spacing
        horizontalAlignment: Text.AlignRight
        text: widget.city === "" ? "located by IP" : widget.city
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        x: 0; y: 0
        width: detailHeader.width; height: detailHeader.height
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
          visible: widget.cur !== null
          width: parent.width
          spacing: Style.spacing.xl
          Label { id: bigIcon; text: widget.cur ? Wttr.weatherIcon(widget.cur.weatherCode, widget.night) : ""; color: widget.sky; font.pixelSize: Style.font.displayLarge }
          Column {
            width: parent.width - bigIcon.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            Label { text: widget.temp(widget.cur, "temp_") + widget.unit; color: Commons.Color.accent; font.pixelSize: Style.font.displayLarge }
            Label { width: parent.width; text: widget.desc(widget.cur); wrapMode: Text.Wrap; maximumLineCount: 2 }
          }
        }
        Label {
          visible: widget.cur !== null
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          text: "feels " + widget.temp(widget.cur, "FeelsLike") + " · ↑" + widget.temp(widget.day, "maxtemp") + " ↓" + widget.temp(widget.day, "mintemp")
            + " · " + widget.place + (widget.area ? ", " + Wttr.value(widget.area.country).toLowerCase() : "")
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
        Rule { visible: widget.cur !== null }

        Flow {
          visible: widget.cur !== null
          width: parent.width
          spacing: Style.spacing.md
          Stat {
            glyph: ""
            label: "wind " + (widget.cur ? String(widget.cur.winddir16Point).toLowerCase() : "")
            value: widget.cur ? (widget.imperial ? widget.cur.windspeedMiles + " mph" : widget.cur.windspeedKmph + " km/h") : ""
            tint: Commons.Color.accent
          }
          Stat { glyph: ""; label: "humidity"; value: widget.cur ? widget.cur.humidity + "%" : ""; tint: Commons.Color.accent }
          Stat {
            glyph: ""
            label: "rain today"
            value: widget.cur ? widget.maxRain(widget.day) + "% · " + (widget.imperial ? widget.cur.precipInches + " in" : widget.cur.precipMM + " mm") : ""
            tint: Commons.Color.accent
          }
          Stat {
            readonly property int uv: widget.cur ? Number(widget.cur.uvIndex) || 0 : 0
            glyph: ""
            label: "uv index"
            value: uv + " " + (uv >= 8 ? "very high" : uv >= 6 ? "high" : uv >= 3 ? "moderate" : "low")
            tint: uv >= 6 ? Commons.Color.urgent : uv >= 3 ? widget.fg : Commons.Color.accent
          }
          Stat { glyph: ""; label: "pressure"; value: widget.cur ? (widget.imperial ? widget.cur.pressureInches + " inHg" : widget.cur.pressure + " hPa") : "" }
          Stat { glyph: ""; label: "visibility"; value: widget.cur ? (widget.imperial ? widget.cur.visibilityMiles + " mi" : widget.cur.visibility + " km") : "" }
        }
        Rule { visible: widget.cur !== null }

        // The next 24 hours: time, icon and rain chance per step, with the temperature curve under them.
        Label { visible: widget.cur !== null; text: "next 24 hours"; color: Commons.Color.accent }
        Row {
          visible: widget.cur !== null
          width: parent.width
          Repeater {
            model: widget.steps
            delegate: Column {
              id: step
              required property var modelData
              width: details.width / Math.max(widget.steps.length, 1)
              readonly property int hour: step.modelData.hr % 24
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: step.modelData.hr === clock.date.getHours() - clock.date.getHours() % 3 ? "now" : (step.hour < 10 ? "0" : "") + step.hour
                color: widget.dim
                font.pixelSize: Style.font.caption
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Wttr.weatherIcon(step.modelData.code, widget.sunrise && widget.sunset && (step.hour < widget.sunrise[0] || step.hour >= widget.sunset[0]))
                font.pixelSize: Style.font.icon
              }
            }
          }
        }
        Canvas {
          id: curveView
          visible: widget.cur !== null
          width: parent.width
          height: 84
          property var steps: widget.steps
          property color line: Commons.Color.accent
          property color text: widget.fg
          property color dimText: widget.dim
          property color track: Util.alpha(Commons.Color.muted, 0.2)
          onStepsChanged: requestPaint()
          onWidthChanged: requestPaint()
          onPaint: { let i;
            var ctx = getContext("2d")
            ctx.reset()
            var s = steps, n = Math.max(s.length, 1)
            if (s.length === 0) return
            var temps = s.map(function(x) { return x.t })
            var lo = Math.min.apply(null, temps), hi = Math.max.apply(null, temps)
            var xs = s.map(function(x, i) { return (i + 0.5) * width / n })
            var ys = temps.map(function(t) { return 22 + (hi - t) / Math.max(hi - lo, 1) * 26 })
            ctx.strokeStyle = line
            ctx.lineWidth = 2
            ctx.beginPath()
            for (i = 0; i < n; i++) i === 0 ? ctx.moveTo(xs[i], ys[i]) : ctx.lineTo(xs[i], ys[i])
            ctx.stroke()
            ctx.font = "12px \"" + Style.font.family + "\""
            ctx.textAlign = "center"
            for (i = 0; i < n; i++) {
              ctx.fillStyle = line
              ctx.beginPath(); ctx.arc(xs[i], ys[i], 3, 0, 2 * Math.PI); ctx.fill()
              ctx.fillStyle = text
              ctx.fillText(s[i].t + "°", xs[i], ys[i] - 8)
              ctx.fillStyle = track
              ctx.fillRect(xs[i] - 10, height - 12, 20, 4)
              ctx.fillStyle = line
              ctx.fillRect(xs[i] - 10, height - 12, 20 * s[i].rain / 100, 4)
              ctx.fillStyle = s[i].rain >= 30 ? line : dimText
              ctx.font = "10px \"" + Style.font.family + "\""
              ctx.fillText(s[i].rain + "%", xs[i], height - 18)
              ctx.font = "12px \"" + Style.font.family + "\""
            }
          }
        }
        Rule { visible: widget.cur !== null }

        // Three days: icon, rain chance and the day's low to high on a shared scale.
        Label { visible: widget.cur !== null; text: "3 days"; color: Commons.Color.accent }
        Repeater {
          model: widget.wx && widget.wx.weather ? widget.wx.weather : []
          delegate: Row {
            id: dayRow
            required property var modelData
            required property int index
            readonly property real lo: Number(modelData["mintemp" + widget.unit])
            readonly property real hi: Number(modelData["maxtemp" + widget.unit])
            width: details.width
            spacing: Style.spacing.md
            Label { width: 52; text: dayRow.index === 0 ? "today" : widget.dayName(dayRow.index) }
            Label { width: 26; text: Wttr.weatherIcon(dayRow.modelData.hourly[4].weatherCode, false); font.pixelSize: Style.font.icon; horizontalAlignment: Text.AlignHCenter }
            Label { width: 40; text: widget.maxRain(dayRow.modelData) + "%"; color: Commons.Color.accent; horizontalAlignment: Text.AlignRight; font.pixelSize: Style.font.caption }
            Label { width: 36; text: dayRow.lo + "°"; color: widget.dim; horizontalAlignment: Text.AlignRight; font.pixelSize: Style.font.caption }
            Rectangle {
              id: bar
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(10, dayRow.width - 52 - 26 - 40 - 36 - 36 - dayRow.spacing * 5)
              height: 6
              radius: Math.min(3, Style.cornerRadius)
              color: Util.alpha(Commons.Color.muted, 0.2)
              readonly property real span: Math.max(widget.range[1] - widget.range[0], 1)
              Rectangle {
                x: (dayRow.lo - widget.range[0]) / bar.span * bar.width
                width: Math.max((dayRow.hi - dayRow.lo) / bar.span * bar.width, 6)
                height: parent.height
                radius: parent.radius
                color: Commons.Color.accent
              }
            }
            Label { width: 36; text: dayRow.hi + "°"; font.pixelSize: Style.font.caption }
          }
        }
        Rule { visible: widget.cur !== null }

        Flow {
          visible: widget.cur !== null
          width: parent.width
          spacing: Style.spacing.md
          Stat { glyph: ""; label: "sunrise"; value: Wttr.formatClock(widget.sunrise, widget.timeFormat); tint: Commons.Color.accent }
          Stat { glyph: ""; label: "sunset"; value: Wttr.formatClock(widget.sunset, widget.timeFormat); tint: Commons.Color.accent }
          Stat {
            width: details.width
            glyph: widget.day ? (Wttr.moonIcons[widget.day.astronomy[0].moon_phase] || "") : ""
            label: "moon"
            value: widget.day ? String(widget.day.astronomy[0].moon_phase).toLowerCase() + " · " + widget.day.astronomy[0].moon_illumination + "% lit" : ""
          }
        }

        // yr.no (Norwegian Meteorological Institute), opened at wttr's coordinates.
        Label {
          visible: widget.area !== null
          width: parent.width
          height: 44
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: Text.AlignRight
          text: "open yr.no ↗"
          color: widget.dim
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: Qt.openUrlExternally("https://www.yr.no/en/forecast/daily-table/" + widget.area.latitude + "," + widget.area.longitude)
          }
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
