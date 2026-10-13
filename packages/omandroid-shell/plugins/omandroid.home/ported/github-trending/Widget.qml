// SPDX-License-Identifier: MIT
// The most-starred GitHub repositories created in the last week. Ported from
// simonschubert/github-trending in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// GitHub has no trending API; new repositories sorted by stars come closest.
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

  // { repos: [...], at: ms } from the last fetch; GitHub allows 10 searches a
  // minute without a token, so once an hour is far from it.
  property var reading: host && host.cached ? host.cached : null
  property string failure: ""

  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < 3600000)
      return;
    var since = Qt.formatDate(new Date(Date.now() - 7 * 86400000), "yyyy-MM-dd");
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let items = JSON.parse(xhr.responseText).items || [];
        widget.failure = "";
        widget.reading = {
          at: Date.now(),
          repos: items.map(function (r) {
            return {
              name: String(r.full_name),
              url: String(r.html_url),
              stars: Number(r.stargazers_count) || 0,
              lang: String(r.language || ""),
              desc: String(r.description || "")
            };
          })
        };
        if (widget.host)
          widget.host.setCached(widget.reading);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : xhr.status === 403 ? "rate limited by GitHub" : "couldn't read GitHub";
      }
    };
    xhr.open("GET", "https://api.github.com/search/repositories?q=created:%3E" + since + "&sort=stars&order=desc&per_page=15");
    xhr.setRequestHeader("Accept", "application/vnd.github+json");
    xhr.send();
  }

  function stars(n) {
    return n >= 1000 ? "★ " + (n / 1000).toFixed(1) + "k" : "★ " + n;
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

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: "github trending · this week"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: widget.host.openUrl("https://github.com/trending")
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
      model: widget.reading ? widget.reading.repos : []

      delegate: Item {
        id: repo
        required property var modelData
        width: ListView.view.width
        height: rowsView.height

        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl(repo.modelData.url)
        }

        Column {
          id: rowsView
          width: parent.width
          spacing: Style.spacing.xxs

          Row {
            width: parent.width
            spacing: Style.spacing.md
            Text {
              width: parent.width - countView.width - parent.spacing
              textFormat: Text.PlainText
              text: repo.modelData.name
              color: widget.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              id: countView
              textFormat: Text.PlainText
              text: widget.stars(repo.modelData.stars)
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: repo.modelData.desc
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Text {
            visible: text !== ""
            textFormat: Text.PlainText
            text: repo.modelData.lang
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
