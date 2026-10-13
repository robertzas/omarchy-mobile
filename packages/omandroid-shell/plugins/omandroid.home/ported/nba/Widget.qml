// SPDX-License-Identifier: MIT
// NBA from ESPN: live scores, results and kick-offs with crests, and the
// table. Ported from simonschubert/nba in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// Only `league` below differs between the league widgets.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Espn.js" as Espn

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property var league: ({"title": "NBA", "path": "basketball/nba", "days": [-1, 0, 1], "table": "us", "homeFirst": false, "gamesWord": "scores", "tableWord": "standings", "empty": "no games today", "cuts": [6, 10], "bLabel": "GB", "bStat": "gamesBehind", "logos": "nba"})

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text
  readonly property string timeFormat: host ? host.timeFormat : "HH:mm"
  readonly property bool wide: width >= 280
  readonly property bool soccer: league.table === "soccer"

  // { games, gamesAt, groups, groupsAt } from the last fetches.
  property var store: host && host.cached ? host.cached : ({})
  property string failure: ""
  property string view: "games"
  property bool expanded: false
  SystemClock { id: clock; precision: SystemClock.Minutes }

  readonly property var all: store.games || []
  readonly property int liveCount: all.filter(function(g) { return g.state === "in" }).length
  readonly property int cap: Math.max(5, Math.min(14, cellsHigh * 4 - 2))
  readonly property var listed: expanded ? all : Espn.picked(all, cap)
  readonly property var rowsModel: Espn.rows(view, listed, store.groups || [], league.cuts, league.bLabel, league.table)

  function keep(patch) {
    var next = {}
    for (let k in store) next[k] = store[k]
    for (let p in patch) next[p] = patch[p]
    store = next
    if (host) host.setCached(next)
  }

  function get(url, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var answer = null
      if (xhr.status === 200) {
        try { answer = JSON.parse(xhr.responseText) } catch (e) { answer = null }
      }
      done(answer, xhr.status)
    }
    xhr.open("GET", url)
    xhr.send()
  }

  function fetchGames(force) {
    if (!force && store.gamesAt && Date.now() - store.gamesAt < 5 * 60000) return
    var urls = Espn.scoreboardUrls(league.path, league.days, new Date())
    var answers = [], left = urls.length, offline = false
    urls.forEach(function(u, i) {
      widget.get(u, function(answer, statusView) {
        answers[i] = answer
        if (statusView === 0) offline = true
        if (--left > 0) return
        if (answers.every(function(a) { return a === null })) {
          widget.failure = offline ? "offline" : "couldn't reach ESPN"
          return
        }
        widget.failure = ""
        widget.keep({ games: Espn.games(answers, league.logos), gamesAt: Date.now() })
      })
    })
  }

  function fetchTable(force) {
    if (!force && store.groupsAt && Date.now() - store.groupsAt < 30 * 60000) return
    get(Espn.standingsUrl(league.path), function(answer) {
      if (!answer) return
      var groups = widget.soccer ? Espn.soccerTable(answer, league.logos) : Espn.usTable(answer, league.logos, league.bStat)
      widget.keep({ groups: groups, groupsAt: Date.now() })
    })
  }

  Component.onCompleted: { fetchGames(false); fetchTable(false) }
  Timer { interval: 5 * 60000; repeat: true; running: true; onTriggered: widget.fetchGames(true) }
  Timer { interval: 30 * 60000; repeat: true; running: true; onTriggered: widget.fetchTable(true) }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    // The title; a tap shows every game and the full table, or goes back.
    Item {
      id: headerPart
      width: parent.width
      height: titleView.implicitHeight

      Text {
        id: titleView
        width: parent.width - statusView.width - Style.spacing.md
        textFormat: Text.PlainText
        text: widget.league.title + (widget.expanded ? "  ‹" : "")
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        id: statusView
        anchors.right: parent.right
        anchors.verticalCenter: titleView.verticalCenter
        textFormat: Text.PlainText
        text: widget.liveCount > 0 ? widget.liveCount + " live" : Qt.formatDate(clock.date, "ddd d")
        color: widget.liveCount > 0 ? Commons.Color.accent : widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: widget.liveCount > 0
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: widget.expanded = !widget.expanded
      }
    }

    Row {
      id: tabs
      width: parent.width
      Repeater {
        model: [{ v: "games", label: widget.league.gamesWord }, { v: "table", label: widget.league.tableWord }]
        delegate: Item {
          id: tabView
          required property var modelData
          width: tabs.width / 2
          height: 36
          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: tabView.modelData.label
            color: widget.view === tabView.modelData.v ? Commons.Color.accent : widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.6
            height: 2
            visible: widget.view === tabView.modelData.v
            color: Commons.Color.accent
          }
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: widget.view = tabView.modelData.v
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: list.count === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure
        : widget.view === "games" ? (widget.store.games ? widget.league.empty : "loading…")
        : (widget.store.groups ? "no table yet" : "loading…")
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ListView {
      id: list
      width: parent.width
      height: Math.max(0, parent.height - headerPart.height - tabs.height - parent.spacing * 2)
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.rowsModel

      delegate: Item {
        id: line
        required property var modelData
        width: ListView.view.width
        height: modelData.kind === "game" ? game.implicitHeight
          : modelData.kind === "team" ? team.implicitHeight
          : modelData.kind === "head" ? head.implicitHeight + Style.spacing.sm
          : Style.spacing.md

        GameRow {
          id: game
          anchors.fill: parent
          visible: line.modelData.kind === "game"
          game: visible ? line.modelData.g : null
          homeFirst: widget.league.homeFirst
          wide: widget.wide
          timeFormat: widget.timeFormat
          fg: widget.fg
          dim: widget.dim
        }
        TeamRow {
          id: team
          anchors.fill: parent
          visible: line.modelData.kind === "team"
          team: visible ? line.modelData.t : null
          kind: widget.league.table
          wide: widget.wide
          full: widget.expanded
          fg: widget.fg
          dim: widget.dim
        }
        Row {
          anchors.bottom: parent.bottom
          width: parent.width
          visible: line.modelData.kind === "head"
          Text {
            id: head
            width: parent.width - bView.width
            textFormat: Text.PlainText
            text: line.modelData.kind === "head" ? line.modelData.text : ""
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            id: bView
            textFormat: Text.PlainText
            text: line.modelData.kind === "head" ? line.modelData.b : ""
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        // A line under the last playoff place.
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          visible: line.modelData.kind === "cut"
          width: 32
          height: 1
          color: Util.alpha(widget.fg, 0.3)
        }
      }
    }
  }
}
