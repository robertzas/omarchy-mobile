// SPDX-License-Identifier: MIT
// The newest posts from the RSS and Atom feeds in the settings, merged,
// newest first (feeds.py in this folder reads them). Ported from
// simonschubert/feeds in Simon Schubert's omarchy-widgets (MIT,
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

  readonly property var urls: String(settings.feeds || "").split(/[\s,]+/).filter(function (u) {
    return /^https?:\/\//.test(u);
  })
  readonly property int minutes: Math.max(10, Number(settings.interval) || 30)
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }
  readonly property real now: clock.date.getTime() / 1000

  // { key, posts: [{ title, url, at, feed }], at: ms } from the last run.
  property var reading: host && host.cached ? host.cached : null
  readonly property var posts: reading && reading.key === urls.join(" ") ? reading.posts : []
  property string failure: ""

  function refresh(force) {
    var key = urls.join(" ");
    if (!host || host.busy)
      return;
    if (!force && reading && reading.key === key && Date.now() - reading.at < minutes * 60000)
      return;
    host.run(["python3", host.dir + "/feeds.py"].concat(urls), function (result) {
      try {
        if (result.code !== 0)
          throw new Error(result.stderr);
        widget.failure = "";
        widget.reading = {
          key: key,
          posts: JSON.parse(result.stdout),
          at: Date.now()
        };
        widget.host.setCached(widget.reading);
      } catch (e) {
        widget.failure = result.timedOut ? "the feeds took too long" : result.code === 127 ? "needs python" : "couldn't read the feeds";
      }
    }, {
      timeout: 30
    });
  }

  function age(at) {
    var s = now - at;
    if (!at)
      return "";
    return s < 3600 ? Math.max(Math.floor(s / 60), 1) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d";
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
        text: "feeds"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "edit"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      // The feed list is a setting, as the original's file was.
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: if (widget.host)
          widget.host.openSettings()
      }
    }

    Text {
      width: parent.width
      visible: list.count === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : widget.reading ? "nothing loaded: tap edit to check the feed list" : "loading…"
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.lg
      model: widget.posts

      delegate: Item {
        id: post
        required property var modelData
        width: ListView.view.width
        height: lines.height

        Column {
          id: lines
          width: parent.width
          spacing: Style.spacing.xxs
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: post.modelData.title
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Row {
            width: parent.width
            Text {
              width: parent.width - whenView.width
              textFormat: Text.PlainText
              text: post.modelData.feed
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Text {
              id: whenView
              textFormat: Text.PlainText
              text: widget.age(post.modelData.at)
              color: widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl(post.modelData.url)
        }
      }
    }
  }
}
