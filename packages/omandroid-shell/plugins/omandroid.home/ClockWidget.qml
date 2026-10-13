// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Clock and date. Formats are Qt date formats from the widget's settings.
Item {
  id: widget

  property var home: null
  property var entry: null
  property bool editing: false
  readonly property var config: entry && entry.config ? entry.config : ({})

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  readonly property bool wide: width > height * 1.6

  Column {
    anchors.centerIn: parent
    width: widget.width - Style.spacing.xxl * 2
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: Qt.formatDateTime(clock.date, widget.config.timeFormat || "HH:mm")
      color: widget.home ? widget.home.foreground : "white"
      font.family: Style.font.family
      font.pixelSize: Math.max(Style.font.display, Math.min(widget.height * 0.46, widget.width * 0.26))
      font.weight: Font.Light
      fontSizeMode: Text.HorizontalFit
      minimumPixelSize: Style.font.title
    }

    Text {
      width: parent.width
      visible: widget.height >= 80
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: Qt.formatDateTime(clock.date, widget.config.dateFormat || "dddd d MMMM")
      color: widget.home ? widget.home.dimForeground : "white"
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      elide: Text.ElideRight
    }
  }
}
