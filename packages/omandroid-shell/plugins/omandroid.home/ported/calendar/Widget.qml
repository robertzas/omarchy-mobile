// SPDX-License-Identifier: MIT
// This month's calendar with today highlighted. Ported from
// simonschubert/calendar in Simon Schubert's omarchy-widgets (MIT,
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

  SystemClock { id: clock; precision: SystemClock.Hours }

  readonly property bool sundayFirst: settings.firstDay === "Sunday"
  readonly property int day: clock.date.getDate()
  readonly property int offset: {
    var first = new Date(clock.date.getFullYear(), clock.date.getMonth(), 1).getDay()
    return sundayFirst ? first : (first + 6) % 7
  }
  readonly property int days: new Date(clock.date.getFullYear(), clock.date.getMonth() + 1, 0).getDate()
  readonly property var heads: sundayFirst ? ["S", "M", "T", "W", "T", "F", "S"] : ["M", "T", "W", "T", "F", "S", "S"]
  readonly property int rows: Math.ceil((offset + days) / 7) + 1
  readonly property real cellW: (width - Style.spacing.xl * 2) / 7
  readonly property real cellH: Math.max(8, (height - Style.spacing.xl * 2 - titleView.height - Style.spacing.md) / rows)
  readonly property int fontPx: Math.max(Style.font.caption, Math.min(Style.font.subtitle, Math.floor(Math.min(cellW, cellH) * 0.5)))

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: Qt.formatDate(clock.date, "MMMM yyyy")
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Grid {
      columns: 7
      Repeater {
        model: widget.heads
        delegate: Text {
          required property string modelData
          width: widget.cellW
          height: widget.cellH
          textFormat: Text.PlainText
          text: modelData
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Math.max(Style.font.caption, widget.fontPx - 2)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
      Repeater {
        model: widget.offset + widget.days
        delegate: Rectangle {
          required property int index
          readonly property int date: index - widget.offset + 1
          readonly property bool today: date === widget.day
          width: widget.cellW
          height: widget.cellH
          radius: Style.cornerRadius
          color: today ? Commons.Color.accent : Util.alpha(Commons.Color.accent, 0)
          Text {
            anchors.fill: parent
            textFormat: Text.PlainText
            text: parent.date > 0 ? String(parent.date) : ""
            color: parent.today ? Commons.Color.menu.background : widget.fg
            font.family: Style.font.family
            font.pixelSize: widget.fontPx
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
        }
      }
    }
  }
}
