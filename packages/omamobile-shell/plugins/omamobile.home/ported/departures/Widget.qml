// SPDX-License-Identifier: MIT
// Live departures from a stop, from Transitous (open timetables). Ported
// from simonschubert/departures in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// The stop's name is a setting; the matching stops are listed in the card
// and the one tapped is kept (stopId, stopName) with the placement.
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
    if (widget.detail) { widget.detail = false; return }
    // No stop named yet: the settings, where it is typed.
    if (widget.query.length < 2) { if (widget.host) widget.host.openSettings(); return }
    widget.detail = true
    widget.refresh(false)
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
  readonly property string timeFormat: host ? host.timeFormat : "HH:mm"

  readonly property string query: String(settings.stop || "").trim()
  readonly property string stopId: String(settings.stopId || "")
  readonly property string stopName: String(settings.stopName || "")
  // A stop is picked for the name in the settings; a new name asks again.
  readonly property bool picked: stopId !== "" && String(settings.pickedFor || "") === query
  readonly property bool choosing: query.length >= 2 && !picked

  SystemClock { id: clock; precision: SystemClock.Minutes }

  // { stopId, rows, at } and { query, stops } from the last answers.
  property var board: host && host.cached ? host.cached.board : null
  property var found: host && host.cached ? host.cached.found : null
  property string problem: ""
  property bool detail: false

  function remember() { if (host) host.setCached({ board: board, found: found }) }

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

  function search() {
    if (!choosing || (found && found.query === query)) return
    var wanted = query
    get("https://api.transitous.org/api/v1/geocode?type=STOP&text=" + encodeURIComponent(wanted), function(j) {
      if (!j) { widget.problem = "transitous offline"; return }
      widget.problem = ""
      widget.found = { query: wanted, stops: j.slice(0, 8).map(function(s) {
        var areas = (s.areas || []).filter(function(a) { return a.default === true })
        return { id: String(s.id), name: String(s.name || ""), area: String(areas.length ? areas[0].name : (s.country || "")),
                 modes: (s.modes || []).slice(0, 3).join(", ").toLowerCase() }
      }) }
      widget.remember()
    })
  }

  function minuteOf(iso) { var t = Date.parse(String(iso || "")); return isNaN(t) ? null : t }

  // Live data: every 2 minutes, and on a tap.
  function refresh(force) {
    if (!picked) { search(); return }
    if (!force && board && board.stopId === stopId && Date.now() - board.at < 2 * 60000) return
    var wanted = stopId
    get("https://api.transitous.org/api/v6/stoptimes?stopId=" + encodeURIComponent(wanted) + "&n=20", function(j, status) {
      if (!j) { widget.problem = status === 429 ? "too many requests" : "transitous offline"; return }
      widget.problem = ""
      widget.board = { stopId: wanted, at: Date.now(), rows: (j.stopTimes || []).map(function(s) {
        var p = s.place || {}
        var line = s.routeShortName && s.routeShortName !== "?" ? s.routeShortName : (s.displayName || s.mode || "")
        return {
          key: String(s.tripId) + String(p.scheduledDeparture), line: String(line),
          to: String(s.headsign || (s.tripTo ? s.tripTo.name : "") || ""),
          at: widget.minuteOf(p.departure || p.arrival), planned: widget.minuteOf(p.scheduledDeparture || p.scheduledArrival),
          track: p.track || p.scheduledTrack || "", moved: !!p.track && !!p.scheduledTrack && p.track !== p.scheduledTrack,
          live: s.realTime === true, cancelled: s.cancelled === true || s.tripCancelled === true
        }
      }) }
      widget.remember()
    })
  }

  Component.onCompleted: refresh(false)
  onQueryChanged: refresh(true)
  onStopIdChanged: refresh(true)
  Timer { interval: 2 * 60000; repeat: true; running: widget.picked; onTriggered: widget.refresh(true) }

  function pick(stop) {
    if (host) host.saveSettings({ stopId: stop.id, stopName: stop.name, pickedFor: query })
  }

  readonly property real now: clock.date.getTime()
  readonly property var upcoming: board && board.stopId === stopId
    ? board.rows.filter(function(r) { return r.at !== null && r.at >= widget.now - 60000 }) : []
  readonly property bool narrow: cellsWide <= 1
  readonly property int fits: Math.max(1, Math.min(15, 1 + Math.floor((height - Style.spacing.xl * 2 - 70) / 26)))

  function minutesLeft(r) { return Math.max(0, Math.round((r.at - now) / 60000)) }
  function delay(r) { return r.planned === null ? 0 : Math.round((r.at - r.planned) / 60000) }
  // The countdown is what matters, coloured only by a live delay.
  function tint(r) {
    if (r.cancelled) return Commons.Color.urgent
    if (!r.live) return widget.fg
    var d = delay(r)
    return d >= 5 ? Commons.Color.urgent : d >= 2 ? Qt.tint(widget.fg, Util.alpha(Commons.Color.urgent, 0.5)) : widget.fg
  }
  function big(r) {
    var l = minutesLeft(r)
    return r.cancelled ? "×" : l === 0 ? "now" : l < 60 ? String(l) : Qt.formatTime(new Date(r.at), timeFormat)
  }
  function unit(r) { var l = minutesLeft(r); return r.cancelled || l === 0 || l >= 60 ? "" : "min" }

  component Label: Text {
    textFormat: Text.PlainText
    color: widget.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    maximumLineCount: 1
  }
  component Badge: Rectangle {
    id: badge
    property string line: ""
    width: 54
    height: badgeText.implicitHeight + 2
    radius: Math.min(4, Style.cornerRadius)
    color: Util.alpha(Commons.Color.accent, 0.25)
    Label { id: badgeText; anchors.centerIn: parent; width: parent.width - 6; horizontalAlignment: Text.AlignHCenter; text: badge.line; font.bold: true; font.pixelSize: Style.font.caption }
  }

  // ---------- the tile
  Column {
    id: tile
    visible: !widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.xxs

    Label {
      visible: widget.cellsHigh >= 2 || widget.height >= 120
      width: parent.width
      text: widget.picked && widget.stopName !== "" ? widget.stopName : "departures"
      color: widget.dim
      font.pixelSize: Style.font.caption
    }
    Label {
      visible: !widget.picked || widget.problem !== "" || widget.upcoming.length === 0
      width: parent.width
      wrapMode: Text.Wrap
      maximumLineCount: 2
      text: widget.query.length < 2 ? "Tap to set a stop."
        : widget.choosing ? (widget.problem !== "" ? widget.problem : "Tap to pick the stop.")
        : widget.problem !== "" ? widget.problem
        : !widget.board ? "…" : "no departures soon"
      color: widget.dim
    }
    Repeater {
      model: widget.picked && widget.problem === "" ? widget.upcoming.slice(0, widget.fits) : []
      // "14 min  M36  U Haselhorst": the minutes first and largest, then the line, then where it goes.
      delegate: Row {
        id: dep
        required property var modelData
        required property int index
        readonly property bool lead: index === 0
        width: tile.width
        spacing: widget.narrow ? Style.spacing.xs : Style.spacing.md
        Label {
          id: countView
          anchors.baseline: lineName.baseline
          text: widget.big(dep.modelData)
          color: widget.tint(dep.modelData)
          font.bold: true
          font.pixelSize: dep.lead ? Style.font.display : Style.font.subtitle
        }
        Label {
          visible: text !== ""
          anchors.baseline: lineName.baseline
          text: widget.unit(dep.modelData)
          color: dep.lead ? widget.fg : widget.dim
          font.pixelSize: Style.font.caption
        }
        Label {
          id: lineName
          width: widget.narrow ? Math.max(0, dep.width - x) : Math.min(implicitWidth, dep.width / 3)
          text: dep.modelData.line
          color: dep.lead ? widget.fg : widget.dim
          font.bold: true
          font.pixelSize: dep.lead ? Style.font.subtitle : Style.font.bodySmall
        }
        Label {
          visible: !widget.narrow
          anchors.baseline: lineName.baseline
          width: Math.max(0, dep.width - x)
          text: dep.modelData.to
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
      }
    }
  }


  // ---------- the board, or the stops to pick from
  Item {
    visible: widget.detail
    anchors.fill: parent
    anchors.margins: Style.spacing.xl

    Item {
      id: detailHeader
      width: parent.width
      height: 44
      Label {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        text: "‹ " + (widget.choosing ? "pick a stop" : widget.stopName !== "" ? widget.stopName : "departures")
        color: Commons.Color.accent
        font.pixelSize: Style.font.subtitle
      }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: widget.cycle()
      }
    }

    ListView {
      id: boardList
      anchors.top: detailHeader.bottom
      anchors.bottom: footerView.top
      width: parent.width
      clip: true
      // Scrolls only when it overflows, so a tap below a short list reaches
      // the card and goes to the next view.
      interactive: !widget.editing && contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.choosing ? (widget.found && widget.found.query === widget.query ? widget.found.stops : []) : widget.upcoming
      header: Label {
        width: ListView.view.width
        height: visible ? implicitHeight + Style.spacing.md : 0
        visible: widget.problem !== "" || boardList.count === 0
        text: widget.problem !== "" ? widget.problem : widget.choosing ? (widget.found ? "no stops called “" + widget.query + "”" : "searching…") : "no departures soon"
        color: widget.dim
      }
      delegate: Loader {
        id: rowView
        required property var modelData
        width: ListView.view.width
        sourceComponent: widget.choosing ? stopRow : departureRow
        // A departure has no action of its own: a tap on it goes to the next
        // view. A stop to pick keeps its own tap, above this one.
        MouseArea {
          anchors.fill: parent
          z: -1
          enabled: !widget.editing
          onClicked: widget.cycle()
        }
        Component {
          id: stopRow
          Item {
            height: Math.max(44, stopCol.implicitHeight)
            Column {
              id: stopCol
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              Label { width: parent.width; text: rowView.modelData.name; font.pixelSize: Style.font.body }
              Label { width: parent.width; text: [rowView.modelData.area, rowView.modelData.modes].filter(function(x) { return x !== "" }).join(" · "); color: widget.dim; font.pixelSize: Style.font.caption }
            }
            MouseArea {
              anchors.fill: parent
              enabled: !widget.editing
              onClicked: widget.pick(rowView.modelData)
            }
          }
        }
        Component {
          id: departureRow
          Row {
            height: 28
            spacing: Style.spacing.md
            Badge { anchors.verticalCenter: parent.verticalCenter; line: rowView.modelData.line }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, rowView.width - 54 - 28 - 52 - 52 - Style.spacing.md * 4)
              text: rowView.modelData.to
              color: rowView.modelData.cancelled ? widget.dim : widget.fg
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: 28
              horizontalAlignment: Text.AlignRight
              text: String(rowView.modelData.track)
              color: rowView.modelData.moved ? Commons.Color.urgent : widget.dim
              font.pixelSize: Style.font.caption
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: 52
              horizontalAlignment: Text.AlignRight
              text: Qt.formatTime(new Date(rowView.modelData.at), widget.timeFormat)
              color: widget.dim
              font.pixelSize: Style.font.caption
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              width: 52
              horizontalAlignment: Text.AlignRight
              text: widget.unit(rowView.modelData) === "" ? widget.big(rowView.modelData) : widget.big(rowView.modelData) + "′"
              color: widget.tint(rowView.modelData)
              font.bold: true
            }
          }
        }
      }
    }

    Row {
      id: footerView
      anchors.bottom: parent.bottom
      width: parent.width
      height: 44
      Label {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - change.width
        text: "data: Transitous, open timetables"
        color: widget.dim
        font.pixelSize: Style.font.caption
      }
      Label {
        id: change
        anchors.verticalCenter: parent.verticalCenter
        text: "change stop"
        color: Commons.Color.accent
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.spacing.lg
          enabled: !widget.editing
          onClicked: if (widget.host) widget.host.openSettings()
        }
      }
    }
  }
}
