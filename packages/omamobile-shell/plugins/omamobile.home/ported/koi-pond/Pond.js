// SPDX-License-Identifier: MIT
// The koi's swimming, without QML. Ported from simonschubert/koi-pond in
// Simon Schubert's omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert
// and contributors; see
// ../../LICENSE-omarchy-widgets).
//
// Every koi is a function of time: the head swims a loop, x = sin(t),
// y = cos(ratio * t + ph), and the body lies along the path the head took,
// a fixed distance apart. When fed, each loop glides over to the food and
// tightens around it, then drifts home.

// Body half-width per segment in art pixels, head first.
var PROFILE = [2, 3, 3, 3, 3, 3, 3, 2, 2, 2, 1, 1, 1, 1, 0]

function clamp(x, lo, hi) { return Math.min(Math.max(x, lo), hi) }
function lerp(a, b, t) { return a + (b - a) * t }
function ease(g) { return g * g * (3 - 2 * g) }

// How strongly a koi is drawn to the food: from its pull at the last tap
// up to 1 over 2.4 s, then back to 0 after 10 s.
function pull(from, sinceTap) {
  return Math.min(lerp(from, 1, clamp(sinceTap / 2.4, 0, 1)), clamp((10 - sinceTap) / 2.5, 0, 1))
}

// f: { cx, cy, rx, ry, ratio, ph, speed, dir } in fractions of the pond.
// feed: { at, x, y, fromX, fromY, from: [pull per koi] } in pond time and px.
// Returns PROFILE.length + 1 points [x, y, pull], head first.
function body(f, i, time, width, height, p, feed) {
  var ds = 1.5 * p
  var cxw = f.cx * width, cyw = f.cy * height, rxw = f.rx * width, ryw = f.ry * height
  var n = PROFILE.length + 1, k, out = []
  var since = time >= feed.at ? time - feed.at : 1000

  if (since >= 25) {
    // Idle: step back along the loop by its speed, so the body keeps its
    // length where the loop speeds up or slows down.
    var th = f.ph + f.dir * time * f.speed
    var speedAt = function(m) {
      return Math.max(Math.sqrt(Math.pow(rxw * Math.cos(m), 2) + Math.pow(ryw * f.ratio * Math.sin(f.ratio * m + f.ph), 2)), 1)
    }
    var thStep = ds / speedAt(th)
    for (k = 0; k < n; k++) {
      var mid = th - f.dir * k * thStep / 2
      var t = th - f.dir * k * ds / speedAt(mid)
      out.push([cxw + rxw * Math.sin(t), cyw + ryw * Math.cos(f.ratio * t + f.ph), 0])
    }
    return out
  }

  // Feeding: where the head is at time tau, as [x, y, pull].
  var fe = feed.from[i] || 0
  var fr = (12 + i * 6) * p
  var lo = fr + 4 * p
  var at = function(tau) {
    var e = ease(pull(fe, tau - feed.at - i * 0.4))
    var g = ease(clamp((tau - feed.at) / 1.6, 0, 1))
    var a = f.ph + f.dir * tau * f.speed
    return [
      lerp(cxw, clamp(lerp(feed.fromX, feed.x, g), lo, width - lo), e) + lerp(rxw, fr, e) * Math.sin(a),
      lerp(cyw, clamp(lerp(feed.fromY, feed.y, g), lo, height - lo), e) + lerp(ryw, fr, e) * Math.cos(f.ratio * a + f.ph),
      e
    ]
  }
  // Sample the head's recent path over a window sized from its speed, then
  // walk along it.
  var p0 = at(time), p1 = at(time - 0.1)
  var speed = Math.sqrt(Math.pow(p0[0] - p1[0], 2) + Math.pow(p0[1] - p1[1], 2)) / 0.1
  var steps = 24
  var win = 2 * PROFILE.length * ds / Math.max(speed, 3)
  var path = []
  for (k = 0; k <= steps; k++) path.push(at(time - k * win / steps))
  var along = [0]
  for (k = 0; k < steps; k++)
    along.push(along[k] + Math.max(Math.sqrt(Math.pow(path[k][0] - path[k + 1][0], 2) + Math.pow(path[k][1] - path[k + 1][1], 2)), 0.001))
  var j = 0
  for (k = 0; k < n; k++) {
    var d = k * ds
    while (j < steps - 1 && along[j + 1] <= d) j++
    var u = clamp((d - along[j]) / (along[j + 1] - along[j]), 0, 1)
    out.push([lerp(path[j][0], path[j + 1][0], u), lerp(path[j][1], path[j + 1][1], u), path[j][2]])
  }
  return out
}

// The pulls at time `time`, for a tap that comes now.
function pullsNow(count, time, feed) {
  var since = time >= feed.at ? time - feed.at : 1000
  var out = []
  for (var i = 0; i < count; i++) out.push(pull(feed.from[i] || 0, since - i * 0.4))
  return out
}

if (typeof module !== "undefined") module.exports = { body: body, pullsNow: pullsNow, PROFILE: PROFILE }
