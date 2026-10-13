// SPDX-License-Identifier: MIT
// Earthquakes of magnitude 4.5 and up worldwide in the last day, from the
// USGS. Ported from simonschubert/earthquakes in Simon Schubert's
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

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }
  readonly property real now: clock.date.getTime() / 1000

  // { quakes: [...], at: ms } from the last fetch.
  property var reading: host && host.cached ? host.cached : null
  property string failure: ""
  readonly property var quakes: reading ? reading.quakes : []
  readonly property real strongest: quakes.reduce(function (m, q) {
    return Math.max(m, q.mag);
  }, 0)

  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < 10 * 60000)
      return;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let list = (JSON.parse(xhr.responseText).features || []).map(function (f) {
          var p = f.properties || {};
          return {
            mag: Number(p.mag) || 0,
            place: String(p.place || "unknown"),
            at: Math.floor(Number(p.time) / 1000),
            url: String(p.url || ""),
            tsunami: p.tsunami === 1
          };
        });
        list.sort(function (a, b) {
          return b.at - a.at;
        });
        widget.failure = "";
        widget.reading = {
          quakes: list,
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.reading);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "couldn't read the USGS feed";
      }
    };
    xhr.open("GET", "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson");
    xhr.send();
  }

  function age(at) {
    var s = now - at;
    return s < 3600 ? Math.max(Math.floor(s / 60), 1) + "m" : Math.floor(s / 3600) + "h";
  }
  // Stronger quakes stand out more: urgent from 6, a mix from 5, accent below.
  function tint(mag) {
    return mag >= 6 ? Commons.Color.urgent : mag >= 5 ? Qt.tint(Commons.Color.accent, Util.alpha(Commons.Color.urgent, 0.5)) : Commons.Color.accent;
  }

  Component.onCompleted: refresh(false)
  Timer {
    interval: 10 * 60000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Row {
      id: headerPart
      width: parent.width
      Text {
        width: parent.width - summary.width
        textFormat: Text.PlainText
        text: "earthquakes · 24h"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        id: summary
        textFormat: Text.PlainText
        text: widget.reading ? widget.quakes.length + " · max " + (widget.quakes.length ? widget.strongest.toFixed(1) : "-") : "…"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        width: parent.width
        height: parent.height
        enabled: !widget.editing
        onClicked: widget.host.openUrl("https://earthquake.usgs.gov/earthquakes/map/")
      }
    }

    Text {
      width: parent.width
      visible: list.count === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : widget.reading ? "none in the last day" : "loading…"
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - headerPart.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.md
      model: widget.quakes

      delegate: Item {
        id: quake
        required property var modelData
        width: ListView.view.width
        height: Math.max(mag.implicitHeight, Style.font.body * 1.6)

        Text {
          id: mag
          width: Style.font.body * 2.6
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: quake.modelData.mag.toFixed(1)
          color: widget.tint(quake.modelData.mag)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          x: mag.width
          width: parent.width - mag.width - whenView.width - Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: (quake.modelData.tsunami ? "🌊 " : "") + quake.modelData.place
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          id: whenView
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: widget.age(quake.modelData.at)
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl(quake.modelData.url)
        }
      }
    }
  }
}
