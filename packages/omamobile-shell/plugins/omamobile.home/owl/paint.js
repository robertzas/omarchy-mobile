.pragma library
// SPDX-License-Identifier: MIT
// Paints an OWL Canvas display list (runtime.js drawCalls) onto a QML
// Canvas 2D context, in dp (the context is scaled by dp first). Also the
// Ring and Sparkline drawings. Angles are degrees from 12 o'clock,
// clockwise, as the guide has them.

function n(v, fallback) { return typeof v === "number" && isFinite(v) ? v : fallback }
function toRad(deg) { return (deg - 90) * Math.PI / 180 }

// A fill or stroke: a colour string, or { gradient: {radial, coords, colors} }.
function style(ctx, value) {
  if (value === null || value === undefined) return null
  if (typeof value === "string") return value
  if (!value.gradient) return null
  var g = value.gradient
  var grad = g.radial
    ? ctx.createRadialGradient(g.coords[0], g.coords[1], 0, g.coords[0], g.coords[1], Math.max(g.coords[2], 0.001))
    : ctx.createLinearGradient(g.coords[0], g.coords[1], g.coords[2], g.coords[3])
  var stops = g.colors.length
  for (var i = 0; i < stops; i++) if (g.colors[i]) grad.addColorStop(stops === 1 ? 0 : i / (stops - 1), g.colors[i])
  return grad
}

// Fill and/or stroke the path `trace` makes. Without either, a shape is
// filled with `color` (or the foreground); a line is stroked with it.
function shape(ctx, op, ink, trace, strokeByDefault) {
  var fill = style(ctx, op.fill)
  var stroke = style(ctx, op.stroke)
  if (fill === null && stroke === null) {
    var plain = style(ctx, op.color) || ink.foreground
    if (strokeByDefault) stroke = plain
    else fill = plain
  }
  ctx.beginPath()
  trace()
  if (fill !== null) {
    ctx.fillStyle = fill
    ctx.fill()
  }
  if (stroke !== null) {
    ctx.strokeStyle = stroke
    ctx.lineWidth = n(op.width, 1)
    ctx.lineCap = op.cap === "round" || op.cap === "square" ? op.cap : "butt"
    ctx.lineJoin = op.cap === "round" ? "round" : "miter"
    ctx.stroke()
  }
}

function roundedRect(ctx, x, y, w, h, r) {
  if (w < 0) { x += w; w = -w }
  if (h < 0) { y += h; h = -h }
  var radius = Math.max(0, Math.min(r, w / 2, h / 2))
  if (radius <= 0) { ctx.rect(x, y, w, h); return }
  ctx.moveTo(x + radius, y)
  ctx.arcTo(x + w, y, x + w, y + h, radius)
  ctx.arcTo(x + w, y + h, x, y + h, radius)
  ctx.arcTo(x, y + h, x, y, radius)
  ctx.arcTo(x, y, x + w, y, radius)
  ctx.closePath()
}

// `pixel`: sprite rects land on whole device pixels, so no seams show.
function snapped(v, scale) { return Math.round(v * scale) / scale }

function paintList(ctx, ops, ink, font, images, scale) {
  for (var i = 0; i < ops.length; i++) paintOne(ctx, ops[i], ink, font, images, scale)
}

function group(ctx, op, ink, font, images, scale, setup) {
  ctx.save()
  setup()
  paintList(ctx, op.ops || [], ink, font, images, scale)
  ctx.restore()
}

function paintOne(ctx, op, ink, font, images, scale) {
  var a = op.args || []
  function arg(i) { return n(a[i], 0) }
  switch (op.op) {
  case "rect":
    if (op.pixel) {
      var x0 = snapped(arg(0), scale), y0 = snapped(arg(1), scale)
      var x1 = snapped(arg(0) + arg(2), scale), y1 = snapped(arg(1) + arg(3), scale)
      shape(ctx, op, ink, function() { ctx.rect(x0, y0, x1 - x0, y1 - y0) })
      return
    }
    shape(ctx, op, ink, function() { roundedRect(ctx, arg(0), arg(1), arg(2), arg(3), n(op.radius, 0)) })
    return
  case "circle":
    shape(ctx, op, ink, function() { ctx.arc(arg(0), arg(1), Math.max(arg(2), 0), 0, Math.PI * 2, false) })
    return
  case "arc": {
    var pie = (op.fill !== undefined && op.fill !== null) || op.stroke === undefined || op.stroke === null
    shape(ctx, op, ink, function() {
      if (pie) ctx.moveTo(arg(0), arg(1))
      ctx.arc(arg(0), arg(1), Math.max(arg(2), 0), toRad(arg(3)), toRad(arg(3) + arg(4)), arg(4) < 0)
      if (pie && (op.stroke === undefined || op.stroke === null)) ctx.closePath()
    })
    return
  }
  case "line":
    shape(ctx, { stroke: op.stroke || op.color || op.fill || null, width: op.width, cap: op.cap }, ink,
          function() { ctx.moveTo(arg(0), arg(1)); ctx.lineTo(arg(2), arg(3)) }, true)
    return
  case "path": {
    var pts = op.points || []
    if (!pts.length) return
    shape(ctx, op, ink, function() {
      ctx.moveTo(pts[0][0], pts[0][1])
      for (var k = 1; k < pts.length; k++) ctx.lineTo(pts[k][0], pts[k][1])
      if (op.closed) ctx.closePath()
    })
    return
  }
  case "text": {
    var size = n(op.size, 12)
    ctx.font = (op.bold ? "bold " : "") + size + "px \"" + font + "\""
    ctx.textAlign = op.align === "center" ? "center" : op.align === "end" ? "right" : "left"
    ctx.textBaseline = "middle"
    ctx.fillStyle = style(ctx, op.color || op.fill) || ink.foreground
    ctx.fillText(op.text, arg(1), arg(2))
    return
  }
  case "image": {
    var url = images ? images(op.src) : null
    if (url) ctx.drawImage(url, arg(1), arg(2), arg(3), arg(4))
    return
  }
  case "translate":
    group(ctx, op, ink, font, images, scale, function() { ctx.translate(arg(0), arg(1)) })
    return
  case "rotate":
    group(ctx, op, ink, font, images, scale, function() {
      ctx.translate(arg(1), arg(2))
      ctx.rotate(arg(0) * Math.PI / 180)
      ctx.translate(-arg(1), -arg(2))
    })
    return
  case "scale":
    group(ctx, op, ink, font, images, scale, function() {
      var sx = arg(0), sy = a.length > 1 ? arg(1) : sx
      ctx.translate(arg(2), arg(3))
      ctx.scale(sx, sy)
      ctx.translate(-arg(2), -arg(3))
    })
    return
  case "clip":
    group(ctx, op, ink, font, images, scale, function() {
      ctx.beginPath()
      ctx.rect(arg(0), arg(1), arg(2), arg(3))
      ctx.clip()
    })
    return
  case "layer":
    group(ctx, op, ink, font, images, scale, function() {
      ctx.globalAlpha = ctx.globalAlpha * Math.max(0, Math.min(1, n(a[0], 1)))
    })
    return
  }
}

// Every image a display list draws, so the Canvas can load them first.
function imageSources(ops, out) {
  var list = out || []
  for (var i = 0; i < ops.length; i++) {
    if (ops[i].op === "image" && ops[i].src && list.indexOf(ops[i].src) < 0) list.push(ops[i].src)
    if (ops[i].ops) imageSources(ops[i].ops, list)
  }
  return list
}

// Ring: a track and a value arc, `start`/`sweep` in degrees (a gauge is
// start 225, sweep 270), in pixels.
function ring(ctx, w, h, p, value, dp, ink) {
  var t = n(p.thickness, 6) * dp
  var r = Math.min(w, h) / 2 - t / 2
  if (r <= 0) return
  var start = n(p.start, 0), sweep = n(p.sweep, 360)
  var a0 = toRad(start)
  ctx.lineWidth = t
  ctx.lineCap = "round"
  ctx.strokeStyle = p.track || ink.surface
  ctx.beginPath()
  ctx.arc(w / 2, h / 2, r, a0, a0 + sweep * Math.PI / 180, false)
  ctx.stroke()
  if (value > 0) {
    ctx.strokeStyle = p.color || ink.accent
    ctx.beginPath()
    ctx.arc(w / 2, h / 2, r, a0, a0 + sweep * value * Math.PI / 180, false)
    ctx.stroke()
  }
}

// Sparkline: values scaled between min (0) and max (the peak plus
// headroom), an optional area under the line, in pixels.
function sparkline(ctx, w, h, p, dp, ink) {
  var values = Array.isArray(p.values) ? p.values : []
  var lo = n(p.min, 0)
  var hi = p.max
  if (typeof hi !== "number") {
    var peak = -Infinity
    values.forEach(function(v) { if (typeof v === "number") peak = Math.max(peak, v) })
    hi = Math.max(lo + (peak - lo) * 1.15, lo + 1)
  }
  if (!isFinite(hi) || hi <= lo) hi = lo + 1
  var count = values.length
  var pts = []
  for (var i = 0; i < count; i++) {
    if (typeof values[i] !== "number") continue
    pts.push([count > 1 ? i / (count - 1) * w : w / 2, h - (values[i] - lo) / (hi - lo) * h])
  }
  if (pts.length < 2) return
  var line = p.color || ink.accent
  if (p.area) {
    ctx.beginPath()
    ctx.moveTo(pts[0][0], h)
    pts.forEach(function(q) { ctx.lineTo(q[0], q[1]) })
    ctx.lineTo(pts[pts.length - 1][0], h)
    ctx.closePath()
    ctx.fillStyle = typeof p.area === "string" ? p.area : withAlpha(line, 0.2)
    ctx.fill()
  }
  ctx.beginPath()
  ctx.moveTo(pts[0][0], pts[0][1])
  pts.forEach(function(q) { ctx.lineTo(q[0], q[1]) })
  ctx.lineWidth = n(p.thickness, 2) * dp
  ctx.lineJoin = "round"
  ctx.lineCap = "round"
  ctx.strokeStyle = line
  ctx.stroke()
}

// "#aarrggbb" or "#rrggbb" with its alpha multiplied by `factor`.
function withAlpha(color, factor) {
  var s = String(color || "")
  var m = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(s)
  if (!m) return s
  var hex = m[1].length === 6 ? "ff" + m[1] : m[1]
  var a = Math.round(parseInt(hex.slice(0, 2), 16) * Math.max(0, Math.min(1, factor)))
  return "#" + (a < 16 ? "0" : "") + a.toString(16) + hex.slice(2)
}

if (typeof module !== "undefined") {
  module.exports = { paintList: paintList, imageSources: imageSources, ring: ring, sparkline: sparkline, withAlpha: withAlpha }
}
