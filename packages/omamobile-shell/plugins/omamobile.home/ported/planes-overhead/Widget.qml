// SPDX-License-Identifier: MIT
// Aircraft around you on a radar, from the OpenSky Network. Ported from
// simonschubert/planes-overhead in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// Positions are carried forward along each plane's track once a second
// between requests; the list of flights opens inside the card on a tap.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Wttr.js" as Wttr
import "../.." as Home

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

  // The place for wttr.in: the phone's position ("Use my location": GeoClue at
  // city accuracy, rounded to about 1 km; Omarchy Mobile's GeoLocation.qml) when
  // there is one, else the typed city, else wttr.in's guess from the address.
  // Nothing is fetched while the position is still being looked up.
  readonly property bool useLocation: settings.useLocation !== false
  Home.GeoLocation { id: geo; active: widget.useLocation }
  readonly property bool waiting: useLocation && !geo.fix && geo.failure === ""
  readonly property string city: useLocation && geo.fix ? geo.fix.lat + "," + geo.fix.lon : String(settings.city || "").trim()
  onWaitingChanged: if (!waiting) locate(false)
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // { city, area: { name, country, lat, lon }, at }, then { states, at } from OpenSky.
  property var place: host && host.cached ? host.cached.place : null
  property var sky: host && host.cached ? host.cached.sky : null
  property string problem: ""
  property bool detail: false
  property real now: Date.now()

  function get(url, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var j = null
      try { if (xhr.status === 200) j = JSON.parse(xhr.responseText) } catch (e) { j = null }
      done(j, xhr.status)
    }
    xhr.open("GET", url)
    xhr.send()
  }
  function remember() { if (host) host.setCached({ place: place, sky: sky }) }

  function locate(force) {
    if (widget.waiting) return
    if (!force && place && place.city === city && Date.now() - place.at < 30 * 60000) { listen(false); return }
    var wanted = city
    problem = ""
    get(Wttr.url(wanted), function(wx) {
      var a = wx && wx.nearest_area ? wx.nearest_area[0] : null
      if (!a || isNaN(Number(a.latitude))) { widget.problem = wx ? "location unknown" : "locating…"; return }
      widget.place = { city: wanted, name: Wttr.value(a.areaName), imperial: Wttr.imperial(a),
                       lat: Number(a.latitude), lon: Number(a.longitude), at: Date.now() }
      widget.remember()
      widget.listen(true)
    })
  }
  // Anonymous OpenSky allows 400 requests a day: every 2 minutes at most.
  function listen(force) {
    if (!place) return
    if (!force && sky && sky.lat === place.lat && sky.lon === place.lon && Date.now() - sky.at < 2 * 60000) return
    var lat = place.lat, lon = place.lon
    // A box a little larger than the radar (0.5° is 55 km); longitude degrees shrink toward the poles.
    var dLat = 0.5, dLon = 0.5 / Math.max(Math.cos(lat * Math.PI / 180), 0.2)
    var f3 = function(x) { return String(Math.round(x * 1000) / 1000) }
    get("https://opensky-network.org/api/states/all?lamin=" + f3(lat - dLat) + "&lomin=" + f3(lon - dLon)
        + "&lamax=" + f3(lat + dLat) + "&lomax=" + f3(lon + dLon), function(j, status) {
      if (!j) { widget.problem = status === 429 ? "opensky's daily limit is used up" : "opensky offline"; return }
      widget.problem = ""
      widget.sky = { lat: lat, lon: lon, states: j.states || [], at: Date.now() }
      widget.remember()
    })
  }

  Component.onCompleted: locate(false)
  onCityChanged: locate(true)
  Timer { interval: 2 * 60000; repeat: true; running: true; onTriggered: widget.place && widget.place.city === widget.city ? widget.listen(true) : widget.locate(true) }
  // The planes move once a second while there are any.
  Timer { interval: 1000; repeat: true; running: widget.flights.length > 0 || widget.detail; onTriggered: widget.now = Date.now() }

  readonly property bool imperial: place ? place.imperial : false
  // 45 km, or 30 miles, in three rings.
  readonly property real km: imperial ? 48.28 : 45
  readonly property string rangeText: imperial ? "30 mi" : "45 km"

  // OpenSky's state vectors: [icao24, callsign, country, time_position, last_contact, lon, lat,
  // baro_altitude, on_ground, velocity, true_track, vertical_rate, sensors, geo_altitude, ...].
  function flightsAt(t) {
    if (!sky || !place) return []
    var lat = place.lat, lon = place.lon, nowS = t / 1000, rad = Math.PI / 180, km = widget.km
    return sky.states.filter(function(s) { return !s[8] && s[5] !== null && s[6] !== null }).map(function(s) {
      var speed = s[9] || 0, track = s[10] || 0, age = Math.min(Math.max(nowS - (s[3] || nowS), 0), 180)
      var call = String(s[1] || "").trim()
      return {
        id: s[0], call: call === "" ? String(s[0]).toUpperCase() : call, country: String(s[2] || ""),
        alt: s[7] !== null ? s[7] : (s[13] || 0), speed: speed, track: track, climb: s[11] || 0,
        x: (s[5] - lon) * 111.32 * Math.cos(lat * rad) + Math.sin(track * rad) * speed * age / 1000,
        y: (s[6] - lat) * 110.57 + Math.cos(track * rad) * speed * age / 1000
      }
    }).filter(function(p) { return p.x * p.x + p.y * p.y <= km * km })
      .sort(function(a, b) { return (a.x * a.x + a.y * a.y) - (b.x * b.x + b.y * b.y) })
  }
  readonly property var flights: flightsAt(now)
  // The list in the details moves only with a new answer, so it keeps its scroll position.
  readonly property var listed: sky ? flightsAt(sky.at) : []
  readonly property string status: problem !== "" ? problem : !place ? "locating…" : !sky ? "listening…" : ""

  function distance(f) {
    var d = Math.sqrt(f.x * f.x + f.y * f.y)
    return imperial ? Math.round(d / 1.609) + " mi" : Math.round(d) + " km"
  }
  // Low planes are urgent, cruising ones the accent.
  function altTint(alt) {
    return alt < 3000 ? Commons.Color.urgent : alt < 8000 ? Qt.tint(Commons.Color.accent, Util.alpha(Commons.Color.urgent, 0.5)) : Commons.Color.accent
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  component Radar: Canvas {
    id: radar
    property bool labels: false
    property var list: widget.flights
    property real tick: widget.now
    property color surface: Util.alpha(Commons.Color.muted, 0.12)
    property color edge: Util.alpha(Commons.Color.muted, 0.5)
    property color faint: Util.alpha(Commons.Color.muted, 0.25)
    property color sweep: Commons.Color.accent
    property color text: widget.fg
    property color dimText: widget.dim
    onListChanged: requestPaint()
    onTickChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2, cy = height / 2, r = Math.min(width, height) / 2 - 2
      if (r < 4) return
      var s = r / widget.km, p = Math.max(r / 20, 3.5), rad = Math.PI / 180
      ctx.fillStyle = surface
      ctx.strokeStyle = edge
      ctx.lineWidth = 1
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.fill(); ctx.stroke()
      ctx.strokeStyle = faint
      ctx.beginPath(); ctx.arc(cx, cy, r * 2 / 3, 0, 2 * Math.PI); ctx.stroke()
      ctx.beginPath(); ctx.arc(cx, cy, r / 3, 0, 2 * Math.PI); ctx.stroke()
      ctx.beginPath(); ctx.moveTo(cx - r, cy); ctx.lineTo(cx + r, cy); ctx.moveTo(cx, cy - r); ctx.lineTo(cx, cy + r); ctx.stroke()
      // The sweep, a step a second.
      var a = (Math.floor(tick / 1000) * 30 % 360 - 90) * rad
      ctx.fillStyle = Util.alpha(sweep, 0.12)
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.arc(cx, cy, r, a - Math.PI / 4, a); ctx.closePath(); ctx.fill()
      ctx.strokeStyle = Util.alpha(sweep, 0.7)
      ctx.lineWidth = 1.5
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(cx + r * Math.cos(a), cy + r * Math.sin(a)); ctx.stroke()
      ctx.font = "10px \"" + Style.font.family + "\""
      if (labels) {
        ctx.fillStyle = dimText
        ctx.fillText(widget.imperial ? "10 mi" : "15 km", cx + 4, cy - r / 3 - 4)
        ctx.fillText(widget.imperial ? "20 mi" : "30 km", cx + 4, cy - r * 2 / 3 - 4)
        ctx.textAlign = "center"
        ctx.fillText("N", cx, cy - r + 12)
        ctx.textAlign = "start"
      }
      for (let i = 0; i < list.length; i++) {
        let f = list[i], px = cx + f.x * s, py = cy - f.y * s
        ctx.save()
        ctx.translate(px, py)
        ctx.rotate(f.track * rad)
        ctx.fillStyle = widget.altTint(f.alt)
        ctx.beginPath()
        ctx.moveTo(0, -p); ctx.lineTo(p * 0.7, p * 0.7); ctx.lineTo(0, p * 0.3); ctx.lineTo(-p * 0.7, p * 0.7)
        ctx.closePath(); ctx.fill()
        ctx.restore()
        if (labels) { ctx.fillStyle = text; ctx.fillText(f.call, px + p + 3, py + 3) }
      }
      ctx.fillStyle = text
      ctx.beginPath(); ctx.arc(cx, cy, 3, 0, 2 * Math.PI); ctx.fill()
    }
  }

  // ---------- the tile
  Column {
    visible: !widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.sm

    Row {
      id: head
      width: parent.width
      Label { id: titleView; width: parent.width - countView.width; text: "planes overhead"; color: widget.dim }
      Label { id: countView; text: widget.status === "" ? String(widget.flights.length) : ""; color: widget.dim }
    }
    Item {
      width: parent.width
      height: parent.height - head.height - parent.spacing - (nearest.visible ? nearest.height + parent.spacing : 0)
      Radar { anchors.fill: parent; labels: widget.cellsWide >= 3 && widget.cellsHigh >= 3 }
      Label {
        anchors.centerIn: parent
        visible: widget.status !== ""
        text: widget.status
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
    }
    Label {
      id: nearest
      visible: widget.cellsHigh >= 2
      width: parent.width
      text: widget.status !== "" ? "" : widget.flights.length === 0 ? "clear skies within " + widget.rangeText
        : widget.flights[0].call + " · " + widget.distance(widget.flights[0]) + " away"
      font.pixelSize: Style.font.caption
    }
  }


  // ---------- every flight
  Item {
    visible: widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl

    Item {
      id: detailHeader
      width: parent.width
      height: 44
      Label { anchors.verticalCenter: parent.verticalCenter; text: "‹ planes overhead"; color: Commons.Color.accent; font.pixelSize: Style.font.subtitle }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: widget.cycle()
      }
    }
    Label {
      id: summary
      anchors.top: detailHeader.bottom
      width: parent.width
      text: widget.status !== "" ? widget.status
        : widget.flights.length + (widget.flights.length === 1 ? " flight" : " flights") + " within " + widget.rangeText + " of " + widget.place.name.toLowerCase()
      color: widget.dim
      font.pixelSize: Style.font.caption
    }
    ListView {
      id: flightList
      anchors.top: summary.bottom
      anchors.topMargin: Style.spacing.md
      anchors.bottom: footerView.top
      width: parent.width
      clip: true
      // Scrolls only when it overflows, so a tap below a short list reaches
      // the card and goes to the next view.
      interactive: !widget.editing && contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.listed
      delegate: Item {
        id: rowView
        required property var modelData
        width: ListView.view.width
        height: Math.max(44, info.implicitHeight)
        Text {
          id: plane
          anchors.verticalCenter: parent.verticalCenter
          width: 24
          textFormat: Text.PlainText
          text: "▲"
          rotation: rowView.modelData.track
          color: widget.altTint(rowView.modelData.alt)
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
        Column {
          id: info
          anchors.left: plane.right
          anchors.leftMargin: Style.spacing.md
          anchors.right: numbers.left
          anchors.verticalCenter: parent.verticalCenter
          Label { width: parent.width; text: rowView.modelData.call; font.bold: true }
          Label { width: parent.width; text: rowView.modelData.country.toLowerCase(); color: widget.dim; font.pixelSize: Style.font.caption }
        }
        Column {
          id: numbers
          anchors.right: dist.left
          anchors.verticalCenter: parent.verticalCenter
          width: 96
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: (widget.imperial ? Math.round(rowView.modelData.alt * 3.281 / 100) * 100 + " ft" : Math.round(rowView.modelData.alt / 10) * 10 + " m")
              + (rowView.modelData.climb > 1 ? " ↑" : rowView.modelData.climb < -1 ? " ↓" : "")
            font.pixelSize: Style.font.caption
          }
          Label {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: widget.imperial ? Math.round(rowView.modelData.speed * 2.237) + " mph" : Math.round(rowView.modelData.speed * 3.6) + " km/h"
            color: widget.dim
            font.pixelSize: Style.font.caption
          }
        }
        Label {
          id: dist
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: 52
          horizontalAlignment: Text.AlignRight
          text: widget.distance(rowView.modelData)
          color: Commons.Color.accent
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl("https://globe.adsbexchange.com/?icao=" + rowView.modelData.id)
        }
      }
    }
    Row {
      id: footerView
      anchors.bottom: parent.bottom
      width: parent.width
      height: 44
      Label { id: credit; anchors.verticalCenter: parent.verticalCenter; width: parent.width - liveMap.width; text: "data: the opensky network"; color: widget.dim; font.pixelSize: Style.font.caption }
      Label {
        id: liveMap
        anchors.verticalCenter: parent.verticalCenter
        text: "live map ↗"
        color: widget.dim
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.spacing.lg
          enabled: !widget.editing && widget.place !== null
          onClicked: widget.host.openUrl("https://globe.adsbexchange.com/?lat=" + widget.place.lat + "&lon=" + widget.place.lon + "&zoom=9")
        }
      }
    }
  }
}
