// SPDX-License-Identifier: MIT
// The latest xkcd comic with its title and alt text. Ported from
// simonschubert/xkcd in Simon Schubert's omarchy-widgets (MIT,
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

  // { num, title, alt, img, at: ms } from the last fetch.
  property var comic: host && host.cached ? host.cached : null
  property string failure: ""

  function refresh(force) {
    if (!force && comic && Date.now() - comic.at < 3600000)
      return;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let c = JSON.parse(xhr.responseText);
        widget.failure = "";
        widget.comic = {
          num: Number(c.num) || 0,
          title: String(c.safe_title || c.title || ""),
          alt: String(c.alt || ""),
          img: String(c.img || ""),
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.comic);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "couldn't reach xkcd";
      }
    };
    xhr.open("GET", "https://xkcd.com/info.0.json");
    xhr.send();
  }

  Component.onCompleted: refresh(false)
  Timer {
    interval: 3600000
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
        width: parent.width - numberView.width
        textFormat: Text.PlainText
        text: widget.comic ? widget.comic.title : widget.failure !== "" ? widget.failure : "loading…"
        color: widget.failure !== "" && !widget.comic ? Commons.Color.urgent : widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        id: numberView
        textFormat: Text.PlainText
        text: widget.comic ? "#" + widget.comic.num : ""
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Image {
      width: parent.width
      height: Math.max(0, parent.height - headerPart.height - alt.height - parent.spacing * 2)
      source: widget.comic ? widget.comic.img : ""
      sourceSize.width: width
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
    }

    Text {
      id: alt
      width: parent.width
      textFormat: Text.PlainText
      text: widget.comic ? widget.comic.alt : ""
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: widget.host.openUrl(widget.comic ? "https://xkcd.com/" + widget.comic.num + "/" : "https://xkcd.com/")
  }
}
