// SPDX-License-Identifier: MIT
// A pixel lava lamp in the theme's colours. Ported from
// simonschubert/lava-lamp in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// The original is a GPU shader; this draws the same metaballs on a coarse
// pixel grid with a Canvas. The wax drifts a step once a second, and a tap
// (another wax colour) lets it flow smoothly for a few seconds.
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
  readonly property color bg: Commons.Color.menu.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  property int wax: Number(settings.wax) || 0
  // [wax, glow and liquid] per choice, all from the theme.
  readonly property var colors: [
    [accent, mix(accent, urgent, 0.5)],
    [mix(urgent, fg, 0.25), urgent],
    [mix(accent, fg, 0.45), accent],
    [mix(accent, urgent, 0.3), mix(fg, accent, 0.3)]
  ]
  readonly property var pick: colors[wax % colors.length]

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  // Seconds since the widget started: stepped once a second, smoothly
  // during the burst after a tap.
  readonly property real t0: Date.now()
  property real time: 0
  property real burst: 1
  function tick() { time = (Date.now() - t0) / 1000; lamp.requestPaint() }
  NumberAnimation { id: flowView; target: widget; property: "burst"; from: 0; to: 1; duration: 4000 }
  onBurstChanged: tick()
  Timer { interval: 1000; repeat: true; running: !flowView.running; onTriggered: widget.tick() }
  onPickChanged: lamp.requestPaint()

  Timer {
    id: saveLater
    interval: 4500
    onTriggered: if (widget.host) widget.host.saveSettings({ wax: widget.wax })
  }

  // The wax: six blobs bobbing at their own pace, a pool at the bottom and a
  // little stuck to the top. q is in fractions of the height.
  function field(qx, qy, t) {
    var f = 0
    for (let i = 0; i < 6; i++) {
      let y = 0.45 + 0.24 * Math.sin(t * (0.21 + 0.05 * i) + i * 1.7)
      let x = 0.045 * Math.sin(t * 0.13 + i * 2.3)
      let r = 0.032 + 0.011 * (i % 3)
      let dx = qx - x, dy = (qy - y) * 0.8
      f += r * r / Math.max(dx * dx + dy * dy, 1e-6)
    }
    var ax = qx * 0.55, ay = qy - 0.76
    f += 0.0064 / Math.max(ax * ax + ay * ay, 1e-6)
    var bx = qx * 0.7, by = qy - 0.15
    f += 0.0012 / Math.max(bx * bx + by * by, 1e-6)
    return f
  }

  Canvas {
    id: lamp
    anchors.fill: parent
    anchors.margins: Style.spacing.md
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: { let key, s;
      var ctx = getContext("2d")
      ctx.reset()
      var W = width, H = height
      if (W < 4 || H < 4) return
      var cell = Math.max(Math.floor(H / 56), 2)
      var cols = Math.ceil(W / cell), rows = Math.ceil(H / cell)
      var bg = widget.bg, fg = widget.fg, a = widget.pick[0], b = widget.pick[1]
      var t = widget.time
      // Every cell gets a small number naming its colour; each colour is
      // worked out once per paint.
      var memo = ({})
      var colour = function(key) {
        if (memo[key] !== undefined) return memo[key]
        var base = key % 100, mod = Math.floor(key / 100), c
        if (base < 20) c = widget.mix(bg, b, (base - 10) / 10)                        // glow
        else if (base < 30) c = widget.mix(bg, fg, 0.18 + 0.3 * (base - 20) / 4)    // metal bands
        else if (base === 30) c = widget.mix(bg, fg, 0.12)                           // the base's lip
        else if (base === 40) c = widget.mix(a, bg, 0.25)                            // wax rim
        else if (base < 50) c = widget.mix(a, fg, (base - 41) / 16)                  // wax, brighter inside
        else c = widget.mix(widget.mix(bg, b, base >= 55 ? 0.45 : 0.3), a, ((base - 50) % 5) / 4 * 0.3) // liquid
        if (mod === 1) c = widget.mix(c, fg, 0.2)
        else if (mod === 2) c = widget.mix(c, fg, 0.12)
        memo[key] = c
        return c
      }
      // Brushed metal in four flat bands, lighter on the left.
      var metal = function(s) { return 20 + Math.max(0, Math.min(4, Math.floor((0.6 - 0.4 * s) * 4))) }
      for (let j = 0; j < rows; j++) {
        let y = (j + 0.5) * cell / H
        let runKey = 0, runStart = 0
        for (let i = 0; i <= cols; i++) {
          key = 0
          if (i < cols) {
            let qx = ((i + 0.5) * cell - W / 2) / H
            let ax = Math.abs(qx)
            // The glow around the glass, in flat steps.
            let gy = Math.min(Math.max((y - 0.17) / 0.56, 0), 1)
            let ghw = 0.1 + 0.09 * Math.sin(gy * 2.6)
            let gd = Math.max(ax - ghw, 0) + Math.max(Math.abs(y - 0.48) - 0.25, 0)
            let halo = Math.floor(Math.exp(-gd * 14) * 2.2)
            if (halo > 0) key = 10 + halo
            if (y > 0.06 && y < 0.17) {
              let hw = 0.06 + 0.04 * (y - 0.06) / 0.11
              if (ax < hw) key = metal(qx / hw)
            } else if (y >= 0.17 && y < 0.73) {
              let hw2 = 0.1 + 0.09 * Math.sin((y - 0.17) / 0.56 * 2.6)
              if (ax < hw2) {
                s = qx / hw2
                let f = widget.field(qx, y, t)
                if (f > 1) key = f < 1.25 ? 40 : 41 + Math.floor(Math.min(f - 1.25, 1) * 4)
                else key = 50 + (y < 0.5 ? 0 : 5) + Math.floor(f * 4)
                if (s > -0.72 && s < -0.55) key += 100
                else if (Math.abs(s) > 0.88) key += 200
              }
            } else if (y >= 0.73 && y < 0.95) {
              let hw3 = 0.13 + 0.08 * (y - 0.73) / 0.22
              if (ax < hw3) key = y < 0.75 ? 30 : metal(qx / hw3)
            }
          }
          // Runs of one colour make one rect.
          if (key !== runKey) {
            if (runKey !== 0) {
              ctx.fillStyle = colour(runKey)
              ctx.fillRect(runStart * cell, j * cell, (i - runStart) * cell, cell)
            }
            runKey = key
            runStart = i
          }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: {
      widget.wax = (widget.wax + 1) % widget.colors.length
      flowView.restart()
      saveLater.restart()
    }
  }
}
