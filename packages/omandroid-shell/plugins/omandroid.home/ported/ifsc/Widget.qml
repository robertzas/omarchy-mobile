// SPDX-License-Identifier: MIT
// The IFSC Climbing World Cup: the next event with a countdown, the latest
// podiums, live results and the cup standings. Ported from simonschubert/ifsc
// in Simon Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon
// Schubert and contributors; see
// ../../LICENSE-omarchy-widgets). ifsc.results.info answers only
// with a Referer, so ifsc.py (next to this file) fetches it as a command.
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
  readonly property bool wide: width >= 300

  // { info, infoAt, cup, cupAt }
  property var store: host && host.cached ? host.cached : ({})
  property string failure: ""
  property bool expanded: false
  property string tab: "results"
  property int pick: 0
  SystemClock { id: clock; precision: SystemClock.Minutes }

  readonly property var info: store.info || null
  readonly property var events: info ? info.events : []
  readonly property var latest: info ? info.latest : null
  readonly property bool live: latest !== null && latest.state === "live"
  readonly property var next: {
    for (let i = 0; i < events.length; i++) if (events[i].state === "next") return events[i]
    return null
  }
  readonly property var results: latest ? latest.results : []
  readonly property var standings: store.cup || []
  readonly property int nowSec: Math.floor(clock.date.getTime() / 1000)
  // Lines below the divider: the latest winners, then cup leaders if 2+ fit.
  readonly property int slots: Math.max(2, Math.floor((height - 130) / 22))
  readonly property var shown: results.slice(0, slots)
  readonly property var leaders: slots - shown.length - 1 >= 2 ? standings.slice(0, slots - shown.length - 1) : []

  function kindColor(kind) {
    return kind === "boulder" ? Commons.Color.accent : kind === "speed" ? Commons.Color.urgent : fg
  }
  function rankColor(rank) {
    return rank === 1 ? Commons.Color.accent : rank === 2 ? fg : rank === 3 ? Util.alpha(Commons.Color.urgent, 0.8) : dim
  }
  function flag(code) {
    return /^[A-Z]{3}$/.test(String(code || "")) ? "https://d1n1qj9geboqnb.cloudfront.net/flags/" + code + ".png" : ""
  }
  function until(t) {
    var s = t - nowSec
    if (s > 86400) return "in " + Math.ceil(s / 86400) + "d"
    if (s <= 0) return "now"
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60)
    return "in " + (h > 0 ? h + "h " : "") + m + "m"
  }

  function refresh(force) {
    if (!host || host.busy) return
    var infoFresh = store.infoAt && Date.now() - store.infoAt < 10 * 60000
    var cupFresh = store.cupAt && Date.now() - store.cupAt < 60 * 60000
    if (!force && infoFresh && cupFresh) return
    var withCup = !cupFresh
    host.run(["python3", host.dir + "/ifsc.py"].concat(withCup ? ["cup"] : []), function(result) {
      var answer = null
      try { answer = result.code === 0 ? JSON.parse(result.stdout) : null } catch (e) { answer = null }
      if (!answer) {
        widget.failure = result.timedOut ? "ifsc.results.info took too long"
          : result.code === 127 ? "needs python" : (result.stderr.trim() || "couldn't reach ifsc.results.info")
        return
      }
      widget.failure = ""
      var next = {}
      for (let k in widget.store) next[k] = widget.store[k]
      next.info = { season: answer.season, events: answer.events, latest: answer.latest }
      next.infoAt = Date.now()
      if (answer.cup) { next.cup = answer.cup; next.cupAt = Date.now() }
      widget.store = next
      widget.host.setCached(next)
    }, { timeout: 30 })
  }

  Component.onCompleted: refresh(false)
  Timer { interval: 10 * 60000; repeat: true; running: true; onTriggered: widget.refresh(false) }

  // The detail list: results, standings or the calendar.
  readonly property var detailRows: {
    var out = []
    if (tab === "results") {
      if (!latest) return out
      out.push({ kind: "title", text: latest.full, sub: latest.dates + (live ? "  · live" : "") })
      results.forEach(function(c) {
        out.push({ kind: "cat", text: c.name.toLowerCase(), color: c.kind,
                   status: c.status === "finished" ? "final" : (c.round || c.status || "") })
        c.top.forEach(function(a) { out.push({ kind: "athlete", a: a }) })
      })
      out.push({ kind: "link", text: "full results on ifsc.results.info", url: "https://ifsc.results.info/event/" + latest.id })
    } else if (tab === "cup") {
      let s = standings[pick]
      if (!s) return out
      s.top.forEach(function(a) { out.push({ kind: "athlete", a: a }) })
    } else {
      events.forEach(function(e) { out.push({ kind: "event", e: e }) })
    }
    return out
  }

  // ---------- the tile
  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Item {
      id: headerPart
      width: parent.width
      height: titleView.implicitHeight
      Text {
        id: titleView
        width: parent.width - badge.width - Style.spacing.md
        textFormat: Text.PlainText
        text: "IFSC World Cup" + (widget.expanded ? "  ‹" : "")
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        id: badge
        anchors.right: parent.right
        anchors.verticalCenter: titleView.verticalCenter
        textFormat: Text.PlainText
        text: widget.live ? "● live" : (widget.info ? String(widget.info.season || "") : "")
        color: widget.live ? Commons.Color.accent : widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: widget.live
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: widget.expanded = !widget.expanded
      }
    }

    // ---------- summary
    Column {
      id: summary
      visible: !widget.expanded
      width: parent.width
      spacing: Style.spacing.md

      Text {
        width: parent.width
        visible: !widget.info
        textFormat: Text.PlainText
        text: widget.failure !== "" ? widget.failure : "loading…"
        color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // The live event, or the next one with its countdown.
      Item {
        width: parent.width
        height: nextName.implicitHeight + nextDates.implicitHeight
        visible: widget.live || widget.next !== null
        Text {
          id: nextName
          width: parent.width - countdown.width - Style.spacing.md
          textFormat: Text.PlainText
          text: widget.live ? widget.latest.name : widget.next ? "next · " + widget.next.name : ""
          color: widget.live ? Commons.Color.accent : widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          id: nextDates
          anchors.top: nextName.bottom
          width: nextName.width
          textFormat: Text.PlainText
          text: (widget.live ? widget.latest.dates : widget.next ? widget.next.dates : "")
            + (widget.wide ? "  ·  " + (widget.live ? widget.latest.kinds : widget.next ? widget.next.kinds : []).join(" ") : "")
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          id: countdown
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !widget.live && widget.next !== null
          textFormat: Text.PlainText
          text: widget.next ? widget.until(widget.next.start) : ""
          color: Commons.Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
        }
      }
      Text {
        width: parent.width
        visible: widget.info !== null && !widget.live && widget.next === null
        textFormat: Text.PlainText
        text: "season over"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle { width: parent.width; height: 1; color: Util.alpha(widget.dim, 0.3) }

      Text {
        width: parent.width
        visible: widget.latest !== null
        textFormat: Text.PlainText
        text: widget.latest ? (widget.live ? "now" : "last") + " · " + widget.latest.name : ""
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Repeater {
        model: widget.shown
        delegate: Winner { required property var modelData; category: modelData }
      }
      Text {
        width: parent.width
        visible: widget.leaders.length > 0
        textFormat: Text.PlainText
        text: "cup leaders"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Repeater {
        model: widget.leaders
        delegate: Winner { required property var modelData; category: modelData }
      }
    }

    // ---------- everything: results, standings, calendar
    Row {
      id: tabs
      visible: widget.expanded
      width: parent.width
      Repeater {
        model: [{ v: "results", label: widget.live ? "live" : "results" }, { v: "cup", label: "standings" }, { v: "calendar", label: "calendar" }]
        delegate: Item {
          id: tabItem
          required property var modelData
          width: tabs.width / 3
          height: 36
          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: tabItem.modelData.label
            color: widget.tab === tabItem.modelData.v ? Commons.Color.accent : widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: { widget.tab = tabItem.modelData.v; widget.pick = 0 }
          }
        }
      }
    }
    Flow {
      id: chips
      visible: widget.expanded && widget.tab === "cup"
      width: parent.width
      spacing: Style.spacing.md
      Repeater {
        model: widget.standings
        delegate: Text {
          id: chip
          required property var modelData
          required property int index
          height: 32
          textFormat: Text.PlainText
          text: chip.modelData.short
          color: widget.pick === chip.index ? widget.kindColor(chip.modelData.kind) : widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: widget.pick === chip.index
          verticalAlignment: Text.AlignVCenter
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.spacing.sm
            enabled: !widget.editing
            onClicked: widget.pick = chip.index
          }
        }
      }
    }
    ListView {
      id: list
      visible: widget.expanded
      width: parent.width
      height: Math.max(0, parent.height - headerPart.height - tabs.height - (chips.visible ? chips.height + parent.spacing : 0) - parent.spacing * 2)
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.expanded ? widget.detailRows : []

      delegate: Item {
        id: line
        required property var modelData
        readonly property string kind: modelData.kind
        width: ListView.view.width
        height: kind === "athlete" ? 22
          : kind === "event" ? 36
          : kind === "title" ? titleText.implicitHeight + subText.implicitHeight
          : 28

        Athlete {
          id: athlete
          width: parent.width
          visible: line.kind === "athlete"
          athlete: visible ? line.modelData.a : null
        }
        Column {
          visible: line.kind === "title"
          width: parent.width
          Text {
            id: titleText
            width: parent.width
            textFormat: Text.PlainText
            text: line.kind === "title" ? line.modelData.text : ""
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.Wrap
            maximumLineCount: 2
          }
          Text {
            id: subText
            width: parent.width
            textFormat: Text.PlainText
            text: line.kind === "title" ? line.modelData.sub : ""
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Item {
          visible: line.kind === "cat"
          anchors.fill: parent
          Text {
            anchors.bottom: parent.bottom
            textFormat: Text.PlainText
            text: line.kind === "cat" ? line.modelData.text : ""
            color: widget.kindColor(line.kind === "cat" ? line.modelData.color : "")
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: line.kind === "cat" ? line.modelData.status : ""
            color: line.kind === "cat" && line.modelData.status === "final" ? widget.dim : Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          visible: line.kind === "link"
          anchors.fill: parent
          textFormat: Text.PlainText
          text: line.kind === "link" ? line.modelData.text : ""
          color: Commons.Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          verticalAlignment: Text.AlignVCenter
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing && line.kind === "link"
            onClicked: Qt.openUrlExternally(line.modelData.url)
          }
        }
        Row {
          id: eventRow
          visible: line.kind === "event"
          anchors.fill: parent
          spacing: Style.spacing.lg
          readonly property var ev: line.kind === "event" ? line.modelData.e : null
          Rectangle {
            width: 3
            height: 30
            radius: 1.5
            anchors.verticalCenter: parent.verticalCenter
            color: !eventRow.ev ? widget.dim : eventRow.ev.state === "live" ? Commons.Color.accent
              : eventRow.ev.state === "next" ? Util.alpha(widget.fg, 0.6) : Util.alpha(widget.dim, 0.4)
          }
          Column {
            width: parent.width - 3 - stateText.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: eventRow.ev ? eventRow.ev.name + "  " + eventRow.ev.kinds.join(" ") : ""
              color: eventRow.ev && eventRow.ev.state === "done" ? widget.dim : widget.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: eventRow.ev ? eventRow.ev.dates : ""
              color: widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            id: stateText
            width: 64
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: !eventRow.ev ? "" : eventRow.ev.state === "next" ? widget.until(eventRow.ev.start) : eventRow.ev.state === "live" ? "live" : "✓"
            color: eventRow.ev && eventRow.ev.state !== "done" ? Commons.Color.accent : widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }

  // One category's winner on the tile.
  component Winner: Row {
    id: winner
    property var category: null
    readonly property var first: category && category.top.length ? category.top[0] : null
    width: summary.width
    height: 22
    spacing: Style.spacing.md
    Text {
      width: widget.wide ? 72 : 60
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: winner.category ? winner.category.short : ""
      color: widget.kindColor(winner.category ? winner.category.kind : "")
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Flag { code: winner.first ? winner.first.country : ""; anchors.verticalCenter: parent.verticalCenter }
    Text {
      width: parent.width - (widget.wide ? 72 : 60) - 21 - (widget.wide ? 72 + parent.spacing : 0) - parent.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: winner.first ? winner.first.name : ""
      color: widget.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Text {
      visible: widget.wide
      width: 72
      anchors.verticalCenter: parent.verticalCenter
      readonly property string status: winner.category && winner.category.status !== undefined ? String(winner.category.status) : ""
      textFormat: Text.PlainText
      text: !winner.first ? "" : status === "" || status === "null" ? winner.first.score + " pts"
        : status === "finished" ? winner.first.score : (winner.category.round || "live")
      color: status === "" || status === "null" || status === "finished" ? widget.dim : Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  // A rank, flag, name and score line.
  component Athlete: Row {
    id: rowView
    property var athlete: null
    height: 22
    spacing: Style.spacing.md
    Text {
      width: 18
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.athlete ? String(rowView.athlete.rank) : ""
      color: widget.rankColor(rowView.athlete ? rowView.athlete.rank : 0)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: rowView.athlete !== null && rowView.athlete.rank <= 3
      horizontalAlignment: Text.AlignRight
    }
    Flag { code: rowView.athlete ? rowView.athlete.country : ""; anchors.verticalCenter: parent.verticalCenter }
    Text {
      width: rowView.width - 18 - 21 - 64 - rowView.spacing * 3
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.athlete ? rowView.athlete.name : ""
      color: widget.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Text {
      width: 64
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: rowView.athlete ? rowView.athlete.score : ""
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  component Flag: Item {
    id: flagItem
    property string code: ""
    width: 21
    height: 14
    Image {
      anchors.fill: parent
      visible: source !== ""
      source: widget.flag(flagItem.code)
      sourceSize.width: 42
      sourceSize.height: 28
      fillMode: Image.PreserveAspectFit
      asynchronous: true
    }
  }
}
