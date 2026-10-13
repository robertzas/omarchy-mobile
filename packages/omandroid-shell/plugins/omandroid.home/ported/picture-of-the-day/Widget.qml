// SPDX-License-Identifier: MIT
// Wikimedia Commons' picture of the day with its caption. Ported from
// simonschubert/picture-of-the-day in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
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
    precision: SystemClock.Hours
  }
  // The feed is per UTC day.
  readonly property string day: Qt.formatDate(new Date(clock.date.getTime() + clock.date.getTimezoneOffset() * 60000), "yyyy/MM/dd")
  onDayChanged: refresh(false)

  // { day, image, url, caption, artist, at: ms } from the last fetch.
  property var pic: host && host.cached ? host.cached : null
  property string failure: ""

  function plain(html) {
    return String(html || "").replace(/<[^>]*>/g, "").trim();
  }

  function refresh(force) {
    if (!force && pic && pic.day === day)
      return;
    var wanted = day;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let image = JSON.parse(xhr.responseText).image;
        if (!image)
          throw new Error("no picture today");
        let title = String(image.title || "").replace(/^File:/, "").replace(/\.[A-Za-z]+$/, "");
        widget.failure = "";
        widget.pic = {
          day: wanted,
          image: String(image.thumbnail ? image.thumbnail.source : ""),
          url: String(image.file_page || ""),
          caption: widget.plain(image.description && image.description.text) || title,
          artist: widget.plain(image.artist && image.artist.text),
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.pic);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "no picture today";
      }
    };
    xhr.open("GET", "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/" + wanted);
    xhr.send();
  }

  Component.onCompleted: refresh(false)
  // A retry every hour when the day's picture didn't come.
  Timer {
    interval: 3600000
    repeat: true
    running: true
    onTriggered: widget.refresh(false)
  }

  Image {
    anchors.fill: parent
    source: widget.pic ? widget.pic.image : ""
    sourceSize.width: width
    sourceSize.height: height
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    clip: true
  }

  Text {
    anchors.centerIn: parent
    visible: !widget.pic
    textFormat: Text.PlainText
    text: widget.failure !== "" ? widget.failure : "loading…"
    color: widget.dim
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    visible: !!widget.pic
    height: captionColumn.height + Style.spacing.md * 2
    color: Util.alpha(Commons.Color.menu.background, 0.75)

    Column {
      id: captionColumn
      x: Style.spacing.xl
      y: Style.spacing.md
      width: parent.width - Style.spacing.xl * 2
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: widget.pic ? widget.pic.caption : ""
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: widget.pic ? widget.pic.artist : ""
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: Qt.openUrlExternally(widget.pic && widget.pic.url ? widget.pic.url : "https://commons.wikimedia.org/wiki/Commons:Picture_of_the_day")
  }
}
