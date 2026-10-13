// SPDX-License-Identifier: MIT
// A pixel-art koi pond in the theme's colours. Ported from
// simonschubert/koi-pond in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
// Tap the water to feed the koi: they turn and swim to the food, then
// drift home. Idle, the pond moves a step once a second; after a tap it
// swims smoothly for a few seconds.
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Pond.js" as Pond

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
  readonly property color warm: mix(urgent, fg, 0.3)

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  // Paths in fractions of the pond; `spots` are [segment, side] patches.
  readonly property var koi: [
    { cx: 0.46, cy: 0.50, rx: 0.32, ry: 0.30, ratio: 1, ph: 0.3, speed: 0.22, dir: 1, body: fg, spot: urgent,
      spots: [[0, 0], [2, 1], [3, 0], [6, -1], [7, 1]] },
    { cx: 0.50, cy: 0.48, rx: 0.38, ry: 0.36, ratio: 1, ph: -0.4, speed: 0.18, dir: -1, body: warm, spot: fg,
      spots: [[2, -1], [5, 1]] }
  ]

  // ---------- time: a step a second, smooth for a moment after a tap
  readonly property real t0: Date.now()
  property real time: 0
  property real burst: 1
  NumberAnimation { id: swim; target: widget; property: "burst"; from: 0; to: 1; duration: 6000 }
  onBurstChanged: tick()
  function tick() { time = (Date.now() - t0) / 1000; pond.requestPaint() }
  Timer { interval: 1000; repeat: true; running: !swim.running; onTriggered: widget.tick() }

  // The last feeding: when (in `time`), where, and where the food and each
  // koi's pull were, so another tap carries on from there.
  property var feed: ({ at: -100, x: 0, y: 0, fromX: 0, fromY: 0, from: [0, 0] })

  function feedAt(x, y) {
    tick()
    var pulls = Pond.pullsNow(koi.length, time, feed)
    var since = time >= feed.at ? time - feed.at : 1000
    var g = Math.min(Math.max(since / 1.6, 0), 1)
    g = g * g * (3 - 2 * g)
    var busy = Math.max.apply(null, pulls) > 0.01
    feed = {
      at: time, x: x, y: y, from: pulls,
      fromX: busy ? feed.fromX + (feed.x - feed.fromX) * g : x,
      fromY: busy ? feed.fromY + (feed.y - feed.fromY) * g : y
    }
    swim.restart()
  }

  Canvas {
    id: pond
    anchors.fill: parent
    anchors.margins: Style.spacing.sm
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: { let b, hy, hy0, py, row, v, x, y;
      var ctx = getContext("2d")
      ctx.reset()
      var W = width, H = height, w = widget, time = w.time, feed = w.feed
      if (W < 10 || H < 10) return
      var p = Math.min(Math.max(Math.round(Math.min(W, H) / 70), 2), 5)
      var rect = function(x, y, rw, rh, c) { ctx.fillStyle = c; ctx.fillRect(x, y, rw, rh) }
      var fed = time >= feed.at ? time - feed.at : 1000
      var k, q, side

      // Food: a ring of ripples where it landed, and pellets the koi nibble away.
      if (fed < 2.5) {
        for (q = 0; q < 20; q++) {
          let qa = q * 18 * Math.PI / 180
          rect(Math.floor((feed.x + Math.cos(qa) * fed * 14 * p) / p) * p, Math.floor((feed.y + Math.sin(qa) * fed * 14 * p) / p) * p, p, p,
               Util.alpha(w.accent, 0.8 * (1 - fed / 2.5)))
        }
      }
      if (fed < 6) {
        for (q = 0; q < 5 - fed; q++) {
          let pa = (q * 72 + 20) * Math.PI / 180
          rect(Math.floor((feed.x + Math.cos(pa) * 3 * p) / p) * p, Math.floor((feed.y + Math.sin(pa) * 3 * p) / p) * p, p, p, w.mix(w.fg, w.warm, 0.4))
        }
      }

      var profile = Pond.PROFILE
      for (let i = 0; i < w.koi.length; i++) {
        let f = w.koi[i]
        let body = Pond.body(f, i, time, W, H, p, feed)
        let sway = Math.sin(time * (3 + body[0][2] * 2) + i * 2)
        let fin = w.mix(f.body, w.bg, 0.25)
        // Tail first, so the head lands on top.
        for (k = profile.length - 1; k >= 0; k--) {
          x = body[k][0]; y = body[k][1]
          let a = body[Math.max(k - 1, 0)]; b = body[k + 1]
          let hx0 = a[0] - b[0]; hy0 = a[1] - b[1]
          let hl = Math.max(Math.sqrt(hx0 * hx0 + hy0 * hy0), 0.001)
          let hx = hx0 / hl; hy = hy0 / hl
          let px = Math.floor(x / p) * p; py = Math.floor(y / p) * p
          let h = profile[k]
          if (k === profile.length - 1) {
            // The tail: two lobes of small blocks fanning out.
            for (let j = 1; j < 5; j++) {
              for (side = -1; side <= 1; side += 2) {
                let spread = j * 0.7 * side + sway * j * 0.4
                let sz = (j < 3 ? 2 : 1) * p
                rect(Math.floor((x - hx * j * p * 1.1 - hy * spread * p) / p) * p, Math.floor((y - hy * j * p * 1.1 + hx * spread * p) / p) * p, sz, sz, fin)
              }
            }
          }
          if (k === 2) {
            // Pectoral fins swept back from each side.
            for (side = -1; side <= 1; side += 2) {
              for (let m = 1; m < 3; m++) {
                let out = h + m * 1.2 + sway * 0.4 * side
                rect(Math.floor((x - hy * side * out * p - hx * (m * 1.3) * p) / p) * p, Math.floor((y + hx * side * out * p - hy * (m * 1.3) * p) / p) * p,
                     (3 - m % 2) * p, (2 - m % 2) * p, fin)
              }
            }
          }
          if (h > 0) {
            // A blocky disc: two overlapping rects make a pixel circle.
            rect(px - h * p, py - (h - 1) * p, (2 * h + 1) * p + 0.5, (2 * h - 1) * p + 0.5, f.body)
            rect(px - (h - 1) * p, py - h * p, (2 * h - 1) * p + 0.5, (2 * h + 1) * p + 0.5, f.body)
          } else {
            rect(px, py, p, p, f.body)
          }
          for (let s = 0; s < f.spots.length; s++) {
            let sp = f.spots[s]
            if (sp[0] !== k) continue
            let sx = Math.floor((x - hy * sp[1] * h * 0.4 * p) / p) * p
            let sy = Math.floor((y + hx * sp[1] * h * 0.4 * p) / p) * p
            let sh = Math.max(h - 1, 1)
            rect(sx - sh * p, sy - (sh - 1) * p, (2 * sh + 1) * p, (2 * sh - 1) * p, f.spot)
            rect(sx - (sh - 1) * p, sy - sh * p, (2 * sh - 1) * p, (2 * sh + 1) * p, f.spot)
          }
          if (k === 0) {
            for (side = -1; side <= 1; side += 2)
              rect(Math.floor((x + hx * p - hy * side * 1.5 * p) / p) * p, Math.floor((y + hy * p + hx * side * 1.5 * p) / p) * p, p, p, w.bg)
          }
        }
      }

      // The lily pad floats above the fish, drifting a pixel or two.
      var leaf = w.mix(w.mix(w.accent, w.fg, 0.3), w.bg, 0.3)
      var rim = w.mix(leaf, w.bg, 0.5)
      var cx = Math.floor(W * 0.66 / p), cy = Math.floor(H * 0.38 / p), r = Math.round(0.13 * Math.min(W, H) / p)
      var slope = 0.8
      var drift = Math.round(Math.sin(time * 0.07) * 2) * p
      for (row = 1 - r; row < r; row++) {
        let half = Math.floor(Math.sqrt(r * r - row * row) + 0.5)
        if (row > 0) {
          // A slit runs down and right from the centre, widening to the edge.
          let slit = cx + Math.round(slope * row), sw = 1 + Math.floor(row * 1.5 / r)
          rect((cx - half) * p + drift, (cy + row) * p, Math.max(slit - cx + half, 0) * p, p + 0.5, leaf)
          rect((slit + sw) * p + drift, (cy + row) * p, Math.max(cx + half - slit - sw + 1, 0) * p, p + 0.5, leaf)
        } else {
          rect((cx - half) * p + drift, (cy + row) * p, (2 * half + 1) * p, p + 0.5, leaf)
        }
      }
      // A darker rim below the lower half's edge.
      for (row = 0; row < r; row++) {
        let h1 = Math.floor(Math.sqrt(r * r - row * row) + 0.5)
        let h2 = row + 1 < r ? Math.floor(Math.sqrt(r * r - (row + 1) * (row + 1)) + 0.5) : -1
        if (h2 >= h1) continue
        rect((cx - h1) * p + drift, (cy + row + 1) * p, (h1 - h2) * p, p, rim)
        rect((cx + h2 + 1) * p + drift, (cy + row + 1) * p, (h1 - h2) * p, p, rim)
      }
      // Faint veins, and a highlight along the top-left edge.
      var norm = Math.sqrt(1 + slope * slope)
      var veins = [[-1, slope], [-slope, -1], [1, -slope]]
      for (v = 0; v < veins.length; v++)
        for (q = 3; q < r - 2; q++)
          rect((cx + Math.round(veins[v][0] * q / norm)) * p + drift, (cy + Math.round(veins[v][1] * q / norm)) * p, p, p, w.mix(leaf, w.bg, 0.1))
      for (q = -3; q < 4; q++) {
        let ang = (q * 9 - 115) * Math.PI / 180
        rect((cx + Math.round(Math.cos(ang) * (r - 2))) * p + drift, (cy + Math.round(Math.sin(ang) * (r - 2))) * p, p, p, w.mix(leaf, w.fg, 0.2))
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: !widget.editing
      onClicked: function(mouse) { widget.feedAt(mouse.x, mouse.y) }
    }
  }
}
