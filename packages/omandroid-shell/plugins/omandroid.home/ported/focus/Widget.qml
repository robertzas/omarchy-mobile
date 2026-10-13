// SPDX-License-Identifier: MIT
// A pomodoro focus timer: start, stop and adjust in 5 minute steps.
// Ported from simonschubert/focus in Simon Schubert's omarchy-widgets (MIT,
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

  // { endsAt: ms, length: s }, kept across layout edits.
  property var timer: host && host.cached ? host.cached : ({ endsAt: 0, length: (Number(settings.minutes) || 25) * 60 })

  // Ticks every second only while a session runs.
  SystemClock { id: clock; precision: widget.running ? SystemClock.Seconds : SystemClock.Hours }

  readonly property int remaining: Math.max(0, Math.round((timer.endsAt - clock.date.getTime()) / 1000))
  readonly property bool running: timer.endsAt > Date.now() && remaining > 0

  function set(endsAt, length) {
    timer = { endsAt: endsAt, length: length }
    if (host) host.setCached(timer)
  }
  function pad(n) { return (n < 10 ? "0" : "") + n }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.lg

    Item {
      width: parent.width
      height: parent.height - buttonsView.height - parent.spacing

      Canvas {
        id: ring
        readonly property real size: Math.min(parent.width, parent.height)
        width: size
        height: size
        anchors.centerIn: parent
        property real value: widget.running ? widget.remaining / widget.timer.length : 1
        property color track: Util.alpha(widget.fg, 0.15)
        property color tint: widget.running ? Commons.Color.accent : Commons.Color.muted
        onValueChanged: requestPaint()
        onTintChanged: requestPaint()
        onSizeChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = 8, r = size / 2 - w
          if (r <= 0) return
          ctx.lineWidth = w
          ctx.lineCap = "round"
          ctx.beginPath()
          ctx.arc(size / 2, size / 2, r, 0, Math.PI * 2)
          ctx.strokeStyle = track
          ctx.stroke()
          ctx.beginPath()
          ctx.arc(size / 2, size / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0, Math.min(1, value)))
          ctx.strokeStyle = tint
          ctx.stroke()
        }
      }
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: widget.running ? widget.pad(Math.floor(widget.remaining / 60)) + ":" + widget.pad(widget.remaining % 60)
                             : Math.round(widget.timer.length / 60) + " min"
        color: widget.fg
        font.family: Style.font.family
        font.pixelSize: Math.max(Style.font.body, Math.min(Style.font.display, ring.size * 0.2))
      }
    }

    Row {
      id: buttonsView
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.spacing.md
      Repeater {
        model: [
          { label: widget.running ? "stop" : "start", act: "toggle" },
          { label: "-5", act: "less" },
          { label: "+5", act: "more" }
        ]
        delegate: Rectangle {
          id: buttonView
          required property var modelData
          width: Math.max(44, labelView.implicitWidth + Style.spacing.xl * 2)
          height: 44
          radius: Style.cornerRadius
          color: Util.alpha(widget.fg, 0.08)
          border.width: 1
          border.color: Util.alpha(widget.fg, 0.2)
          Text {
            id: labelView
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: buttonView.modelData.label
            color: buttonView.modelData.act === "toggle" ? widget.fg : widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          MouseArea {
            anchors.fill: parent
            enabled: !widget.editing
            onClicked: {
              var t = widget.timer
              if (buttonView.modelData.act === "toggle")
                widget.set(widget.running ? 0 : Date.now() + t.length * 1000, t.length)
              else
                widget.set(t.endsAt, Math.max(300, Math.min(3600, t.length + (buttonView.modelData.act === "more" ? 300 : -300))))
            }
          }
        }
      }
    }
  }
}
