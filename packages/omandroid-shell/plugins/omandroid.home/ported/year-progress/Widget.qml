// SPDX-License-Identifier: MIT
// How much of today, this week, this month and this year has passed.
// Ported from simonschubert/year-progress in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
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

  readonly property var bars: {
    var now = clock.date
    var y = now.getFullYear(), mo = now.getMonth(), d = now.getDate()
    var dayStart = new Date(y, mo, d)
    var dayP = (now - dayStart) / (new Date(y, mo, d + 1) - dayStart)
    var weekday = (now.getDay() + 6) % 7   // 0 is Monday
    var monthDays = new Date(y, mo + 1, 0).getDate()
    var yearStart = new Date(y, 0, 1)
    var yearP = (now - yearStart) / (new Date(y + 1, 0, 1) - yearStart)
    return [
      { label: "day", p: dayP },
      { label: "week", p: (weekday + dayP) / 7 },
      { label: "month", p: (d - 1 + dayP) / monthDays },
      { label: "year", p: yearP }
    ]
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Math.max(Style.spacing.sm, (height - headerPart.height - 4 * barH) / 4)
    readonly property real barH: Style.font.caption + Style.spacing.xs + 6

    Item {
      id: headerPart
      width: parent.width
      height: Style.font.title * 1.3
      Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        textFormat: Text.PlainText
        text: String(clock.date.getFullYear())
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }
      Text {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        textFormat: Text.PlainText
        text: (widget.bars[3].p * 100).toFixed(1) + "%"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Repeater {
      model: widget.bars
      delegate: Column {
        id: bar
        required property var modelData
        width: parent.width
        spacing: Style.spacing.xs
        Item {
          width: parent.width
          height: Style.font.caption * 1.2
          Text {
            textFormat: Text.PlainText
            text: bar.modelData.label
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: Math.floor(bar.modelData.p * 100) + "%"
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Rectangle {
          width: parent.width
          height: 6
          radius: Style.cornerRadius > 0 ? 3 : 0
          color: Util.alpha(widget.fg, 0.15)
          Rectangle {
            width: parent.width * Math.max(0, Math.min(1, bar.modelData.p))
            height: parent.height
            radius: parent.radius
            color: bar.modelData.label === "year" ? Commons.Color.accent : widget.fg
          }
        }
      }
    }
  }
}
