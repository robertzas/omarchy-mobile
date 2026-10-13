// SPDX-License-Identifier: MIT
// An analog clock on a Canvas, ticking every second. Ported from
// simonschubert/analog-clock in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
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
  readonly property bool seconds: settings.seconds !== false

  // Once a second with the second hand, once a minute without it.
  SystemClock { id: clock; precision: widget.seconds ? SystemClock.Seconds : SystemClock.Minutes }

  Canvas {
    id: face
    anchors.fill: parent
    anchors.margins: Style.spacing.xl

    property date now: clock.date
    property color fg: widget.fg
    property color dim: widget.dim
    property color hand: Commons.Color.urgent
    property color dot: Commons.Color.accent
    onNowChanged: requestPaint()
    onFgChanged: requestPaint()
    onDotChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    function line(ctx, deg, from, to, color, w) {
      var a = (deg - 90) * Math.PI / 180
      var cx = width / 2, cy = height / 2
      ctx.beginPath()
      ctx.moveTo(cx + Math.cos(a) * from, cy + Math.sin(a) * from)
      ctx.lineTo(cx + Math.cos(a) * to, cy + Math.sin(a) * to)
      ctx.strokeStyle = color
      ctx.lineWidth = w
      ctx.lineCap = "round"
      ctx.stroke()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2, cy = height / 2
      var r = Math.min(width, height) / 2 - 4
      if (r <= 8) return
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.strokeStyle = Util.alpha(fg, 0.35)
      ctx.lineWidth = 2
      ctx.stroke()
      for (let i = 0; i < 12; i++)
        line(ctx, i * 30, r - 4, r - (i % 3 === 0 ? 14 : 9), i % 3 === 0 ? fg : dim, 2)
      var h = now.getHours(), m = now.getMinutes(), s = now.getSeconds()
      line(ctx, (h % 12 + m / 60) * 30, 0, r * 0.5, fg, 5)
      line(ctx, (m + s / 60) * 6, 0, r * 0.75, fg, 3)
      if (widget.seconds) line(ctx, s * 6, -r * 0.15, r * 0.85, hand, 1.5)
      ctx.beginPath()
      ctx.arc(cx, cy, 4, 0, Math.PI * 2)
      ctx.fillStyle = dot
      ctx.fill()
    }
  }
}
