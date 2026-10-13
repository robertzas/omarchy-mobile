// SPDX-License-Identifier: MIT
// Up or down, HTTP status and response time for the sites you list. Ported
// from simonschubert/uptime in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
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

  readonly property var urls: String(settings.sites || "").split(/[\s,]+/).filter(function (u) {
    return /^https?:\/\//.test(u);
  })
  readonly property int minutes: Math.max(2, Number(settings.interval) || 5)
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // { key, sites: [{ url, code, ms }], at: ms } from the last round.
  property var reading: host && host.cached ? host.cached : null
  readonly property var sites: reading && reading.key === urls.join(" ") ? reading.sites : []
  readonly property int down: sites.filter(function (s) {
    return !widget.up(s);
  }).length
  property var pending: []

  function up(s) {
    return s.code > 0 && s.code < 400;
  }

  // Every site at once; what hasn't answered in 8 s counts as a timeout.
  function refresh(force) {
    var key = urls.join(" ");
    if (pending.length)
      return;
    if (!force && reading && reading.key === key && Date.now() - reading.at < minutes * 60000)
      return;
    var results = {};
    var left = urls.length;
    var finish = function () {
      var list = widget.urls.map(function (u) {
        return results[u] || {
          url: u,
          code: 0,
          ms: 0
        };
      });
      list.sort(function (a, b) {
        return a.url < b.url ? -1 : a.url > b.url ? 1 : 0;
      });
      widget.pending = [];
      deadline.stop();
      widget.reading = {
        key: key,
        sites: list,
        at: Date.now()
      };
      if (widget.host)
        widget.host.setCached(widget.reading);
    };
    if (left === 0) {
      finish();
      return;
    }
    var started = [];
    urls.forEach(function (u) {
      var xhr = new XMLHttpRequest();
      var t0 = Date.now();
      xhr.onreadystatechange = function () {
        if (xhr.readyState !== XMLHttpRequest.DONE || results[u])
          return;
        results[u] = {
          url: u,
          code: xhr.status,
          ms: Date.now() - t0
        };
        if (--left === 0)
          finish();
      };
      xhr.open("GET", u);
      xhr.send();
      started.push(xhr);
    });
    pending = started;
    deadline.done = finish;
    deadline.restart();
  }

  Timer {
    id: deadline
    property var done: null
    interval: 8000
    onTriggered: {
      widget.pending.forEach(function (x) {
        if (x.readyState !== XMLHttpRequest.DONE)
          x.abort();
      });
      if (done && widget.pending.length)
        done();
    }
  }

  Component.onCompleted: refresh(false)
  onUrlsChanged: refresh(false)
  Timer {
    interval: widget.minutes * 60000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Item {
      id: headerPart
      width: parent.width
      height: Math.max(titleView.implicitHeight, 24)
      Text {
        id: titleView
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "uptime"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: widget.urls.length === 0 ? "tap to add sites" : !widget.sites.length ? "…" : widget.down > 0 ? widget.down + " down" : "all up"
        color: widget.down > 0 ? Commons.Color.urgent : Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      // The list of sites is a setting, as the original's file was.
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: if (widget.host)
          widget.host.openSettings()
      }
    }

    ListView {
      width: parent.width
      height: parent.height - headerPart.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.sites

      delegate: Item {
        id: site
        required property var modelData
        readonly property bool ok: widget.up(site.modelData)
        width: ListView.view.width
        height: Math.max(nameView.implicitHeight, Style.font.body * 1.8)

        Rectangle {
          id: dot
          width: 8
          height: 8
          radius: 4
          anchors.verticalCenter: parent.verticalCenter
          color: site.ok ? Commons.Color.accent : Commons.Color.urgent
        }
        Text {
          id: nameView
          x: dot.width + Style.spacing.md
          width: parent.width - x - resultView.width - Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: site.modelData.url.replace(/^https?:\/\//, "")
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          id: resultView
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: site.ok ? site.modelData.ms + " ms" : site.modelData.code === 0 ? "timeout" : String(site.modelData.code)
          color: site.ok ? widget.dim : Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: Qt.openUrlExternally(site.modelData.url)
        }
      }
    }
  }
}
