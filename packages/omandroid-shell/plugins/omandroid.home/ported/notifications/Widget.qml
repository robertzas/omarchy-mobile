// SPDX-License-Identifier: MIT
// Recent notifications from Omarchy's notification history, newest first,
// with a count per app. Ported from simonschubert/notifications in Simon
// Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and
// contributors; see
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
  readonly property var tints: [Commons.Color.accent, Qt.tint(Commons.Color.accent, Util.alpha(Commons.Color.urgent, 0.5)),
    Commons.Color.urgent, widget.fg, Qt.tint(widget.fg, Util.alpha(Commons.Color.accent, 0.5)), Commons.Color.muted]
  function tint(app) { return tints[String(app).length % tints.length] }

  // Omarchy's notification service keeps one JSON file per on-screen
  // notification and the last ten that left the screen in history/.
  readonly property string dir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  readonly property string listScript:
    'for f in "$1"/*.json "$1"/history/*.json; do\n' +
    '  [ -f "$f" ] || continue\n' +
    '  printf \'%s\\t\' "${f##*/}"; head -c 16000 "$f" | tr "\\n" " "; echo\n' +
    'done; exit 0'

  property var all: host && host.cached ? host.cached : []
  readonly property var hidden: Array.isArray(settings.hidden) ? settings.hidden : []
  readonly property var items: all.filter(function(i) { return hidden.indexOf(i.key) < 0 })
  readonly property var apps: {
    var out = []
    items.forEach(function(i) {
      var a = out.filter(function(x) { return x.app === i.app })[0]
      if (a) a.count++
      else out.push({ app: i.app, count: 1 })
    })
    return out
  }
  readonly property var grouped: {
    var out = []
    apps.forEach(function(a) {
      out.push({ heading: true, app: a.app, count: a.count, key: "app:" + a.app })
      items.forEach(function(i) { if (i.app === a.app) out.push(i) })
    })
    return out
  }
  property bool expanded: false
  property string failure: ""

  SystemClock { id: clock; precision: SystemClock.Minutes }

  function refresh() {
    if (!host || host.busy) return
    host.run(["sh", "-c", listScript, "sh", dir], function(result) {
      if (result.code !== 0) { widget.failure = "can't read the notification history"; return }
      var seen = {}, list = []
      result.stdout.split("\n").forEach(function(line) {
        var tab = line.indexOf("\t")
        if (tab < 0) return
        var key = line.slice(0, tab).replace(/\.json$/, "")
        if (seen[key]) return
        try {
          let e = JSON.parse(line.slice(tab + 1))
          let argv = []
          try { argv = e.execArgv ? JSON.parse(e.execArgv) : [] } catch (x) { argv = [] }
          if (!Array.isArray(argv) || !argv.every(function(a) { return typeof a === "string" })) argv = []
          seen[key] = true
          list.push({ key: key, app: String(e.app || "notification"), title: String(e.summary || ""),
                      text: String(e.body || "").replace(/<[^>]*>/g, ""), time: Number(e.timestamp) || 0, argv: argv })
        } catch (err) {
          // A torn write: skip it.
        }
      })
      list.sort(function(a, b) { return b.time - a.time })
      widget.failure = ""
      widget.all = list
      widget.host.setCached(list)
    }, { timeout: 5 })
  }

  function age(ms) {
    var s = (clock.date.getTime() - ms) / 1000
    return s < 60 ? "now" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d"
  }
  // Hides one on this widget; Omarchy's own history is left alone.
  function hide(key) {
    if (!host) return
    var keep = all.map(function(i) { return i.key })
    host.saveSettings({ hidden: hidden.filter(function(k) { return keep.indexOf(k) >= 0 }).concat([key]) })
  }

  // A tap anywhere on the card switches between the newest first and all of
  // them by app. A notification's own tap (its action) and its × keep theirs.
  function cycle() {
    widget.expanded = !widget.expanded
    widget.refresh()
    noteList.positionViewAtBeginning()
  }

  Component.onCompleted: refresh()
  Timer { interval: 120000; repeat: true; running: true; onTriggered: widget.refresh() }

  component Dot: Rectangle {
    property string app: ""
    width: 24
    height: 24
    radius: 12
    color: Util.alpha(widget.tint(app), 0.22)
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.app.charAt(0).toUpperCase()
      color: widget.tint(parent.app)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // The whole card is the switch (the list's own background covers the part
  // the list takes).
  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: widget.cycle()
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Item {
      id: headerPart
      width: parent.width
      height: 28
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: widget.expanded ? "󰁍 notifications" : "notifications"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Rectangle {
        visible: widget.items.length > 0
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(24, countText.implicitWidth + Style.spacing.lg * 2)
        height: 20
        radius: 10
        color: Util.alpha(Commons.Color.accent, 0.2)
        Text {
          id: countText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(widget.items.length)
          color: Commons.Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    // Per-app counts.
    Flow {
      id: chips
      width: parent.width
      visible: !widget.expanded && widget.apps.length > 1
      height: visible ? implicitHeight : 0
      spacing: Style.spacing.sm
      Repeater {
        model: widget.apps.slice(0, 4)
        delegate: Rectangle {
          id: chip
          required property var modelData
          width: Math.min(chipText.implicitWidth + Style.spacing.lg * 2, 150)
          height: chipText.implicitHeight + 4
          radius: Style.cornerRadius
          color: Util.alpha(widget.tint(modelData.app), 0.15)
          Text {
            id: chipText
            anchors.centerIn: parent
            width: parent.width - Style.spacing.lg * 2
            textFormat: Text.PlainText
            text: chip.modelData.app.toLowerCase() + " " + chip.modelData.count
            color: widget.tint(chip.modelData.app)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    Column {
      width: parent.width
      visible: widget.items.length === 0
      spacing: Style.spacing.sm
      topPadding: Style.spacing.xl
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: widget.failure !== "" ? "󰀦" : "󰄬"
        color: widget.failure !== "" ? Commons.Color.urgent : Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: widget.failure !== "" ? widget.failure : "all caught up"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }
    }

    ListView {
      id: noteList
      width: parent.width
      height: parent.height - headerPart.height - chips.height - parent.spacing * 2
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.lg
      // Expanded: everything, grouped by app under a heading each.
      model: widget.expanded ? widget.grouped : widget.items

      // Under the rows, as tall as the list: a Flickable keeps taps from the
      // card behind it, so taps on headings and empty space land here.
      MouseArea {
        y: noteList.originY
        z: -1
        width: noteList.width
        height: Math.max(noteList.contentHeight, noteList.height)
        enabled: !widget.editing
        onClicked: widget.cycle()
      }

      delegate: Item {
        id: rowView
        required property var modelData
        readonly property bool heading: rowView.modelData.heading === true
        width: ListView.view.width
        height: heading ? 32 : Math.max(44, body.implicitHeight)

        Dot { id: dot; app: rowView.modelData.app }
        Text {
          visible: rowView.heading
          anchors.left: dot.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: parent.right
          anchors.verticalCenter: dot.verticalCenter
          textFormat: Text.PlainText
          text: rowView.modelData.app + "  " + (rowView.modelData.count || "")
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        Column {
          id: body
          visible: !rowView.heading
          anchors.left: dot.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: close.left
          spacing: 0
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: rowView.modelData.app.toLowerCase() + " · " + widget.age(rowView.modelData.time)
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: rowView.modelData.title
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: rowView.modelData.text
            color: widget.expanded ? widget.fg : widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            maximumLineCount: widget.expanded ? 4 : 1
            elide: Text.ElideRight
          }
        }
        MouseArea {
          anchors.fill: body
          enabled: !widget.editing && !rowView.heading && rowView.modelData.argv.length > 0
          onClicked: if (widget.host) widget.host.launch(rowView.modelData.argv)
        }
        Item {
          id: close
          visible: !rowView.heading
          anchors.right: parent.right
          width: 36
          height: 36
          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "󰅖"
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: widget.hide(rowView.modelData.key)
          }
        }
      }
    }
  }
}
