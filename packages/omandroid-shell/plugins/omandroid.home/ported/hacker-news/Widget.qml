// SPDX-License-Identifier: MIT
// The Hacker News front page, from the Algolia HN API. Ported from
// simonschubert/hacker-news in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// The network the safe way: XMLHttpRequest, a polite poll,
// the last answer kept in host.cached, a list that scrolls inside the card.
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

  readonly property int minutes: Math.max(5, Number(settings.interval) || 15)
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  // { stories: [...], at: ms } from the last fetch.
  property var reading: host && host.cached ? host.cached : null
  property string failure: ""

  function site(url) {
    var m = /^https?:\/\/(?:www\.)?([^\/]+)/.exec(String(url || ""))
    return m ? m[1] : ""
  }

  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < minutes * 60000) return
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      try {
        if (xhr.status !== 200) throw new Error("HTTP " + xhr.status)
        let hits = JSON.parse(xhr.responseText).hits || []
        let stories = hits.map(function(h) {
          var item = "https://news.ycombinator.com/item?id=" + h.objectID
          return { id: String(h.objectID), title: String(h.title || ""), points: Number(h.points) || 0,
                   comments: Number(h.num_comments) || 0, url: h.url ? String(h.url) : item, item: item,
                   site: widget.site(h.url) }
        })
        widget.failure = ""
        widget.reading = { stories: stories, at: Date.now() }
        if (widget.host) widget.host.setCached(widget.reading)
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "couldn't read Hacker News"
      }
    }
    xhr.open("GET", "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=15")
    xhr.send()
  }

  Component.onCompleted: refresh(false)
  Timer { interval: widget.minutes * 60000; repeat: true; running: true; onTriggered: widget.refresh(true) }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: "hacker news"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: Qt.openUrlExternally("https://news.ycombinator.com")
      }
    }

    Text {
      width: parent.width
      visible: list.count === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : "loading…"
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - titleView.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.lg
      model: widget.reading ? widget.reading.stories : []

      delegate: Column {
        id: story
        required property var modelData
        width: ListView.view.width
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: story.modelData.title
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: Qt.openUrlExternally(story.modelData.url)
          }
        }
        Row {
          width: parent.width
          spacing: Style.spacing.lg
          Text {
            id: points
            textFormat: Text.PlainText
            text: story.modelData.points + " pts"
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            id: comments
            textFormat: Text.PlainText
            text: story.modelData.comments + " comments"
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.spacing.sm
              enabled: !widget.editing
              onClicked: Qt.openUrlExternally(story.modelData.item)
            }
          }
          Text {
            width: Math.max(0, parent.width - points.width - comments.width - parent.spacing * 2)
            textFormat: Text.PlainText
            text: story.modelData.site
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
