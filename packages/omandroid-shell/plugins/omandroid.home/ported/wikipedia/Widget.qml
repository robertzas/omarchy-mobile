// SPDX-License-Identifier: MIT
// Wikipedia's featured article of the day, what everyone is reading, and on
// this day in history, from Wikimedia's daily feed. Ported from
// simonschubert/wikipedia in Simon Schubert's omarchy-widgets (MIT,
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

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  SystemClock {
    id: clock
    precision: SystemClock.Hours
  }
  readonly property string day: Qt.formatDate(new Date(clock.date.getTime() + clock.date.getTimezoneOffset() * 60000), "yyyy/MM/dd")

  // { tfa, read, onthisday, day, at: ms } from the last fetch.
  property var wp: host && host.cached ? host.cached : null
  property string failure: ""

  function refresh(force) {
    if (!force && wp && wp.day === day && Date.now() - wp.at < 3600000)
      return;
    var wanted = day;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let f = JSON.parse(xhr.responseText);
        let page = function (a) {
          return a.content_urls && a.content_urls.mobile ? String(a.content_urls.mobile.page) : "";
        };
        let tfa = f.tfa ? {
          title: String(f.tfa.titles ? f.tfa.titles.normalized : ""),
          text: String(f.tfa.extract || ""),
          url: page(f.tfa)
        } : null;
        let read = ((f.mostread && f.mostread.articles) || []).filter(function (a) {
          return a.namespace && a.namespace.id === 0;
        }).slice(0, 5).map(function (a) {
          return {
            title: String(a.titles ? a.titles.normalized : ""),
            views: Number(a.views) || 0,
            url: page(a)
          };
        });
        let otd = (f.onthisday || []).slice(0, 3).map(function (e) {
          return {
            year: String(e.year),
            text: String(e.text || "")
          };
        });
        widget.failure = "";
        widget.wp = {
          day: wanted,
          tfa: tfa,
          read: read,
          onthisday: otd,
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.wp);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "couldn't read Wikipedia";
      }
    };
    xhr.open("GET", "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/" + wanted);
    xhr.send();
  }

  function views(n) {
    return n >= 1000000 ? (n / 1000000).toFixed(1) + "M" : Math.round(n / 1000) + "k";
  }

  Component.onCompleted: refresh(false)
  Timer {
    interval: 3600000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

  component Heading: Text {
    textFormat: Text.PlainText
    color: Commons.Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: widget.wp ? "wikipedia" : widget.failure !== "" ? widget.failure : "wikipedia · loading…"
      color: widget.failure !== "" && !widget.wp ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: Qt.openUrlExternally("https://en.m.wikipedia.org")
      }
    }

    Flickable {
      width: parent.width
      height: parent.height - titleView.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      contentHeight: body.height

      Column {
        id: body
        width: parent.width
        spacing: Style.spacing.md

        Item {
          width: parent.width
          height: tfa.height
          visible: !!(widget.wp && widget.wp.tfa)
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: Qt.openUrlExternally(widget.wp.tfa.url)
          }
          Column {
            id: tfa
            width: parent.width
            spacing: Style.spacing.xxs
            Heading {
              text: "featured article"
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: widget.wp && widget.wp.tfa ? widget.wp.tfa.title : ""
              color: widget.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: widget.wp && widget.wp.tfa ? widget.wp.tfa.text : ""
              color: widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 4
              elide: Text.ElideRight
            }
          }
        }

        Heading {
          visible: !!(widget.wp && widget.wp.read.length)
          text: "most read"
        }
        Repeater {
          model: widget.wp ? widget.wp.read : []
          delegate: Item {
            id: article
            required property var modelData
            width: body.width
            height: Math.max(nameView.implicitHeight, Style.font.body * 1.8)
            Text {
              id: nameView
              width: parent.width - countView.width - Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: article.modelData.title
              color: widget.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              id: countView
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: widget.views(article.modelData.views)
              color: widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              anchors.fill: parent
              enabled: !widget.editing
              onClicked: Qt.openUrlExternally(article.modelData.url)
            }
          }
        }

        Heading {
          visible: !!(widget.wp && widget.wp.onthisday.length)
          text: "on this day"
        }
        Repeater {
          model: widget.wp ? widget.wp.onthisday : []
          delegate: Row {
            id: event
            required property var modelData
            width: body.width
            spacing: Style.spacing.md
            Text {
              id: yearView
              width: Style.font.bodySmall * 3
              textFormat: Text.PlainText
              text: event.modelData.year
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width - yearView.width - parent.spacing
              textFormat: Text.PlainText
              text: event.modelData.text
              color: widget.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
