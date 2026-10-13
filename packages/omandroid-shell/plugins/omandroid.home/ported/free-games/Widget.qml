// SPDX-License-Identifier: MIT
// Games free to keep on the Epic Games Store now, and the ones coming next.
// Ported from simonschubert/free-games in Simon Schubert's omarchy-widgets
// (MIT, Copyright (c) 2026 Simon Schubert and contributors; see
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

  // { games: [{ title, url, state, from, until }], at: ms }
  property var reading: host && host.cached ? host.cached : null
  property string failure: ""
  readonly property var games: reading ? reading.games : []
  readonly property var live: games.filter(function (g) {
    return g.state === "now" && g.until > widget.now;
  })
  readonly property var soon: games.filter(function (g) {
    return g.state === "next" && g.from > widget.now;
  })
  // One list for the view: the free ones, a "next" heading, the coming ones.
  readonly property var rows: {
    var out = live.map(function (g) {
      return {
        kind: "now",
        game: g
      };
    });
    if (soon.length > 0)
      out.push({
        kind: "heading",
        game: null
      });
    return out.concat(soon.map(function (g) {
      return {
        kind: "next",
        game: g
      };
    }));
  }

  // A giveaway is a promotion with a 0% price.
  function free(offers, state, titleView, url) {
    var out = [];
    (offers || []).forEach(function (o) {
      (o.promotionalOffers || []).forEach(function (p) {
        if (!p.discountSetting || p.discountSetting.discountPercentage !== 0)
          return;
        out.push({
          title: titleView,
          url: url,
          state: state,
          from: Date.parse(p.startDate) / 1000,
          until: Date.parse(p.endDate) / 1000
        });
      });
    });
    return out;
  }

  function refresh(force) {
    if (!force && reading && Date.now() - reading.at < 3600000)
      return;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let elements = JSON.parse(xhr.responseText).data.Catalog.searchStore.elements || [];
        let out = [];
        elements.forEach(function (g) {
          var mapping = (g.catalogNs && g.catalogNs.mappings || [])[0];
          var slug = (mapping && mapping.pageSlug) || g.productSlug || g.urlSlug || "";
          var url = "https://store.epicgames.com/p/" + slug;
          var promos = g.promotions || {};
          out = out.concat(widget.free(promos.promotionalOffers, "now", String(g.title || ""), url), widget.free(promos.upcomingPromotionalOffers, "next", String(g.title || ""), url));
        });
        out.sort(function (a, b) {
          return (a.state === "now" ? 0 : 1) - (b.state === "now" ? 0 : 1) || a.until - b.until;
        });
        widget.failure = "";
        widget.reading = {
          games: out,
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.reading);
      } catch (e) {
        widget.failure = xhr.status === 0 ? "offline" : "couldn't read the Epic store";
      }
    };
    xhr.open("GET", "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=en-US&country=US");
    xhr.send();
  }

  function duration(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d > 0 ? d + "d " + h + "h" : h > 0 ? h + "h " + m + "m" : m + "m";
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
      text: "free games · epic"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: Qt.openUrlExternally("https://store.epicgames.com/free-games")
      }
    }

    Text {
      width: parent.width
      visible: widget.live.length === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : widget.reading ? "nothing free right now" : "loading…"
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ListView {
      width: parent.width
      height: parent.height - titleView.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.md
      model: widget.rows

      delegate: Item {
        id: rowView
        required property var modelData
        width: ListView.view.width
        height: rowView.modelData.kind === "now" ? nowColumn.height : nextRow.height

        Column {
          id: nowColumn
          width: parent.width
          visible: rowView.modelData.kind === "now"
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: rowView.modelData.game ? rowView.modelData.game.title : ""
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            text: rowView.modelData.game ? "free for " + widget.duration(rowView.modelData.game.until - widget.now) : ""
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: nextRow
          width: parent.width
          visible: rowView.modelData.kind !== "now"
          Text {
            width: parent.width - dateView.width
            textFormat: Text.PlainText
            text: rowView.modelData.kind === "heading" ? "next" : rowView.modelData.game.title
            color: rowView.modelData.kind === "heading" ? widget.dim : widget.fg
            font.family: Style.font.family
            font.pixelSize: rowView.modelData.kind === "heading" ? Style.font.caption : Style.font.bodySmall
            elide: Text.ElideRight
          }
          Text {
            id: dateView
            textFormat: Text.PlainText
            text: rowView.modelData.kind === "next" ? Qt.formatDate(new Date(rowView.modelData.game.from * 1000), "ddd d MMM") : ""
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing && rowView.modelData.kind !== "heading"
          onClicked: Qt.openUrlExternally(rowView.modelData.game.url)
        }
      }
    }
  }
}
