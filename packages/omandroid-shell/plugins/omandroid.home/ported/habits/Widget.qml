// SPDX-License-Identifier: MIT
// A daily habit tracker: tap a habit to check it off for today, with the
// last week and the streak. Ported from simonschubert/habits in Simon
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

  SystemClock { id: clock; precision: SystemClock.Minutes }

  readonly property var habits: String(settings.habits || "").split(",")
    .map(function(h) { return h.trim() }).filter(function(h) { return h !== "" })
  // Check-ins as "habit@yyyy-MM-dd", stored with this placement's settings.
  readonly property var done: Array.isArray(settings.done) ? settings.done : []
  // The last 60 days, today first, counted back from noon so summer time
  // never skips or repeats a date.
  readonly property var days: {
    var noon = new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate(), 12)
    var out = []
    for (let i = 0; i < 60; i++) out.push(Qt.formatDate(new Date(noon.getTime() - i * 86400000), "yyyy-MM-dd"))
    return out
  }

  function toggle(habit, checked) {
    if (!host) return
    var key = habit + "@" + days[0]
    var next = checked ? done.filter(function(k) { return k !== key }) : done.concat([key])
    // Only check-ins from the last 60 days count; older ones go.
    var oldest = days[days.length - 1]
    next = next.filter(function(k) { return k.slice(k.lastIndexOf("@") + 1) >= oldest })
    host.saveSettings({ done: next })
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.lg

    Item {
      id: headerPart
      width: parent.width
      height: Math.max(titleView.implicitHeight, 24)
      Text {
        id: titleView
        textFormat: Text.PlainText
        text: "habits"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: "edit"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: if (widget.host) widget.host.openSettings()
      }
    }

    Text {
      visible: widget.habits.length === 0
      textFormat: Text.PlainText
      text: "tap edit to list your habits"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ListView {
      width: parent.width
      height: parent.height - headerPart.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.habits

      delegate: Item {
        id: rowView
        required property string modelData
        readonly property var hits: widget.days.map(function(d) { return widget.done.indexOf(rowView.modelData + "@" + d) >= 0 })
        // A streak still counts today until it's over: it runs up to
        // yesterday if today isn't checked yet.
        readonly property int streak: {
          var run = hits[0] ? hits : hits.slice(1)
          var i = run.indexOf(false)
          return i < 0 ? run.length : i
        }
        width: ListView.view.width
        height: 44

        Rectangle {
          id: box
          anchors.verticalCenter: parent.verticalCenter
          width: 20
          height: 20
          radius: Style.cornerRadius > 0 ? 4 : 0
          border.width: 2
          border.color: rowView.hits[0] ? Commons.Color.accent : Commons.Color.muted
          color: rowView.hits[0] ? Commons.Color.accent : Util.alpha(Commons.Color.accent, 0)
          Behavior on color { ColorAnimation { duration: 200 } }
        }
        Text {
          anchors.left: box.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: week.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.modelData
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Row {
          id: week
          visible: widget.cellsWide >= 3
          anchors.right: streakText.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3
          Repeater {
            model: 7
            delegate: Rectangle {
              required property int index
              width: 8
              height: 8
              radius: 4
              color: rowView.hits[6 - index] ? Commons.Color.accent : Util.alpha(Commons.Color.muted, 0.3)
            }
          }
        }
        Text {
          id: streakText
          width: Style.font.body * 2.5
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.streak > 0 ? rowView.streak + "d" : ""
          color: rowView.streak >= 7 ? Commons.Color.accent : widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.toggle(rowView.modelData, rowView.hits[0])
        }
      }
    }
  }
}
