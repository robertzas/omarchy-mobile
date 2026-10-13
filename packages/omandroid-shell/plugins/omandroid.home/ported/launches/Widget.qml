// SPDX-License-Identifier: MIT
// A countdown to the next rocket launch, from The Space Devs' Launch
// Library. Ported from simonschubert/launches in Simon Schubert's
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

  SystemClock { id: clock; precision: SystemClock.Seconds }
  SystemClock { id: minutesView; precision: SystemClock.Minutes }

  // { launches: [{ id, name, provider, where, status, at (ms), url }], at }
  property var reading: host && host.cached ? host.cached : null
  property bool failed: false

  // The free Launch Library API allows 15 requests an hour, so this checks hourly.
  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < 60 * 60000) return
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let launches = JSON.parse(xhr.responseText).results.map(function(l) {
          return { id: String(l.id), name: String(l.name || ""), provider: String(l.lsp_name || ""), where: String(l.location || ""),
                   status: l.status ? String(l.status.abbrev || "") : "", at: Date.parse(l.net),
                   url: "https://spacelaunchnow.me/launch/" + encodeURIComponent(String(l.slug || "")) }
        })
        widget.failed = false
        widget.reading = { launches: launches, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      } catch (e) {
        widget.failed = true
      }
    }
    xhr.open("GET", "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=8&mode=list")
    xhr.send()
  }

  Component.onCompleted: refresh(false)
  Timer { interval: 60 * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  readonly property real now: clock.date.getTime()
  // Recomputed once a minute, so the list below isn't rebuilt every second.
  readonly property var upcoming: {
    var t = minutesView.date.getTime()
    return reading ? reading.launches.filter(function(l) { return l.at > t - 3600000 }) : []
  }
  readonly property var next: upcoming.length ? upcoming[0] : null
  readonly property var later: upcoming.slice(1)
  readonly property string countdown: {
    if (!next) return widget.failed ? "offline" : "…"
    var t = Math.floor((next.at - now) / 1000)
    if (t <= 0) return "liftoff"
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    return "T-" + (t >= 86400 ? Math.floor(t / 86400) + "d " : "") + pad(Math.floor(t % 86400 / 3600)) + ":" + pad(Math.floor(t % 3600 / 60)) + ":" + pad(t % 60)
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
    spacing: Style.spacing.xs

    Row {
      width: parent.width
      Label { id: titleView; width: parent.width - statusView.width; text: "next launch"; color: widget.dim }
      Label {
        id: statusView
        text: widget.next ? widget.next.status : ""
        color: widget.next && widget.next.status === "Go" ? Commons.Color.accent : widget.dim
        font.pixelSize: Style.font.caption
      }
    }
    Label { width: parent.width; text: widget.next ? widget.next.name : ""; font.bold: true; font.pixelSize: Style.font.body }
    Label { id: countView; width: parent.width; text: widget.countdown; color: Commons.Color.accent; font.pixelSize: Style.font.title }
    Label {
      id: where
      width: parent.width
      text: widget.next ? widget.next.provider + " · " + widget.next.where : ""
      color: widget.dim
      font.pixelSize: Style.font.caption
    }
    ListView {
      width: parent.width
      height: Math.max(0, content.height - y)
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      model: widget.later
      delegate: Item {
        id: rowView
        required property var modelData
        width: ListView.view.width
        height: Math.max(28, nameView.implicitHeight)
        Label {
          id: whenView
          anchors.verticalCenter: parent.verticalCenter
          width: 88
          text: Qt.formatDate(new Date(rowView.modelData.at), "ddd d MMM")
          color: widget.dim
          font.pixelSize: Style.font.caption
        }
        Label {
          id: nameView
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: whenView.right
          anchors.right: parent.right
          text: rowView.modelData.name
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: Qt.openUrlExternally(rowView.modelData.url)
        }
      }
    }
  }

  // The headline opens the next launch (or the site).
  MouseArea {
    x: content.x
    y: content.y
    width: content.width
    height: where.y + where.height
    enabled: !widget.editing
    onClicked: Qt.openUrlExternally(widget.next ? widget.next.url : "https://spacelaunchnow.me")
  }
}
