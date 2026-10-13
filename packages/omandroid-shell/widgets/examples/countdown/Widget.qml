// SPDX-License-Identifier: MIT
// Days until a date from the widget's settings. No commands, no network:
// a clock and arithmetic. An example of settings, sizes and theme tokens
// (/usr/share/omandroid/shell/WIDGETS.md).
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

  // Once an hour is plenty for a day count; nothing else ticks.
  SystemClock { id: clock; precision: SystemClock.Hours }

  readonly property var target: {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(settings.date || ""))
    return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null
  }
  readonly property int days: {
    if (!target) return 0
    var now = clock.date
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    return Math.round((target - today) / 86400000)
  }
  readonly property string count: {
    if (!target) return "?"
    var d = Math.abs(days)
    if (settings.showWeeks && d > 60) return Math.round(d / 7) + "w"
    return String(d)
  }
  readonly property string caption: {
    if (!target) return "Set a date"
    if (days === 0) return "Today: " + (settings.title || "")
    return (days < 0 ? "since " : "until ") + (settings.title || Qt.formatDate(target, "d MMM yyyy"))
  }
  readonly property bool tall: cellsHigh >= 2 || cellsWide === 1

  Grid {
    anchors.centerIn: parent
    columns: widget.tall ? 1 : 2
    spacing: Style.spacing.lg
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter

    Text {
      textFormat: Text.PlainText
      text: widget.count
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.min(widget.height * (widget.tall ? 0.42 : 0.6), Style.font.displayLarge * 2)
      font.weight: Font.Light
    }
    Text {
      width: Math.min(implicitWidth, widget.width - Style.spacing.xl * 2)
      textFormat: Text.PlainText
      text: widget.caption
      color: widget.host ? widget.host.dimForeground : Commons.Color.menu.text
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
