// SPDX-License-Identifier: MIT
// Days until a list of dates, soonest first. Ported from
// simonschubert/countdown in Simon Schubert's omarchy-widgets (MIT,
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

  // "2026-12-24 christmas; 2027-03-01 trip". Without any, the next new year.
  readonly property var events: {
    var today = new Date(clock.date.getFullYear(), clock.date.getMonth(), clock.date.getDate())
    var out = []
    String(settings.dates || "").split(/[;\n]/).forEach(function(part) {
      var m = /^\s*(\d{4})-(\d{2})-(\d{2})\s*(.*?)\s*$/.exec(part)
      if (!m) return
      var at = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
      var days = Math.round((at - today) / 86400000)
      if (days >= 0) out.push({ days: days, label: m[4] || m[1] + "-" + m[2] + "-" + m[3] })
    })
    if (out.length === 0 && String(settings.dates || "").trim() === "") {
      let ny = new Date(today.getFullYear() + 1, 0, 1)
      out.push({ days: Math.round((ny - today) / 86400000), label: "new year" })
    }
    out.sort(function(a, b) { return a.days - b.days })
    return out.slice(0, Math.max(2, widget.cellsHigh * 2 + 1))
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md
    clip: true

    Text {
      textFormat: Text.PlainText
      text: "countdown"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      visible: widget.events.length === 0
      textFormat: Text.PlainText
      text: "no dates ahead: tap to add some"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Repeater {
      model: widget.events
      delegate: Row {
        required property var modelData
        required property int index
        width: parent.width
        spacing: Style.spacing.lg
        Text {
          id: countView
          width: Style.font.title * 3
          anchors.baseline: labelView.baseline
          textFormat: Text.PlainText
          text: parent.modelData.days === 0 ? "today" : parent.modelData.days + "d"
          color: parent.index === 0 ? Commons.Color.accent : widget.fg
          font.family: Style.font.family
          font.pixelSize: parent.index === 0 ? Style.font.title : Style.font.body
        }
        Text {
          id: labelView
          width: parent.width - countView.width - parent.spacing
          textFormat: Text.PlainText
          text: parent.modelData.label
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: if (widget.host) widget.host.openSettings()
  }
}
