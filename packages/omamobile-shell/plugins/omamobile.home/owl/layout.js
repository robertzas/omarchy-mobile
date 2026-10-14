.pragma library
// SPDX-License-Identifier: MIT
// Where every node of an OWL render tree goes, in dp. Pure JS: the
// renderer (OwlView.qml) only draws the boxes this returns, so node can
// check the rules without fonts.
//
// The rules are the guide's (Nodes, Tips) and Compose's measure order, as
// the Android launcher draws them (SPEC-NOTES N30-N38):
//   - a node is as big as its content unless it fills; Text without width,
//     weight or fill takes the full width; Progress, Sparkline, Grid, Slider
//     and Input take the width; Canvas, Shader and Terminal take all the
//     space unless sized; Ring is 64 dp
//   - a Row or Column measures its unweighted children first, in order,
//     each given what is left; weighted ones then share the rest by weight;
//     a child that fills a Column's height counts as weight 1
//   - justify places children only when nothing is weighted; align places
//     them across (a Row centres by default)
//
// `measure` answers for text: width(text, size, bold, font) and
// lineHeight(size) in dp, fontHeight(size) for a single line's own height
// (buttons, inputs), optionally image(src) -> [w, h] in dp or null, and
// `pixel`, logical pixels per dp (for what snaps to whole pixels).
//
// A box: { node, kind, key, x, y, w, h, lines, children, content } with x and y
// relative to the parent box's top-left corner. `content` is a scrolling
// Column's full height.

var DEFAULTS = {
  Progress: [60, 8], Ring: [64, 64], Sparkline: [80, 48], Slider: [120, 28]
}
// Text styles: [size in dp, muted]
var STYLES = { huge: [44, false], title: [20, false], body: [13, false], small: [11, false], muted: [13, true], label: [11, true] }

function num(v, fallback) { return typeof v === "number" && isFinite(v) ? v : fallback }
function props(n) { return n && n.p ? n.p : {} }
function shown(n) {
  var v = props(n).visible
  return v === undefined || v === null || v === true
}
function fixedW(p) { return num(p.width, num(p.size, -1)) }
function fixedH(p) { return num(p.height, num(p.size, -1)) }
function sized(p) {
  return ["width", "height", "size", "fill", "weight"].some(function(k) { return p[k] !== undefined && p[k] !== null })
}
function padding(v) {
  if (typeof v === "number") return [v, v, v, v]
  if (Array.isArray(v) && v.length === 2) return [num(v[0], 0), num(v[1], 0), num(v[0], 0), num(v[1], 0)]
  if (Array.isArray(v) && v.length === 4) return [num(v[0], 0), num(v[1], 0), num(v[2], 0), num(v[3], 0)]
  return [0, 0, 0, 0]
}
function isLinear(kind) { return kind === "Column" || kind === "Row" || kind === "Box" || kind === "Flow" }

function textStyle(p) { return STYLES[p.style] || STYLES.body }
function fontSize(p) { return num(p.fontSize, textStyle(p)[0]) }
// huge and title stay on one line instead of breaking mid-word.
function maxLines(p) {
  var n = num(p.maxLines, 0)
  if (n > 0) return n
  return p.style === "huge" || p.style === "title" ? 1 : 0
}

// Whether a node reaches for all the width ("w") or height ("h") it gets.
function wants(n, axis) {
  if (!n) return false
  var p = props(n)
  if (p.fill === true || p.fill === (axis === "w" ? "width" : "height")) return true
  if (axis === "w" && fixedW(p) >= 0) return false
  if (axis === "h" && fixedH(p) >= 0) return false
  var k = n.kind
  if (k === "Canvas" || k === "Shader" || k === "Terminal") return !sized(p)
  var kids = n.c || []
  if (axis === "h") {
    if (!isLinear(k)) return false
    return kids.some(function(c) { return (k === "Column" && num(props(c).weight, 0) > 0) || wants(c, "h") })
  }
  if (k === "Text") return p.weight === undefined || p.weight === null
  if (k === "Progress" || k === "Sparkline" || k === "Grid" || k === "Slider" || k === "Input") return !sized(p)
  if (isLinear(k)) return kids.some(function(c) { return (k === "Row" && num(props(c).weight, 0) > 0) || wants(c, "w") })
  return false
}

// How a child sits in its parent: fills, fixed sizes (or -1) and weights.
function placement(child, parentKind) {
  var p = props(child)
  var w = fixedW(p), h = fixedH(p)
  var weight = num(p.weight, 0)
  var out = { fillW: w < 0 && wants(child, "w"), fillH: h < 0 && wants(child, "h"), w: w, h: h, weightW: 0, weightH: 0 }
  if (parentKind === "Row" && weight > 0) { out.fillW = true; out.weightW = Math.round(weight * 100) / 100; if (w < 0) out.w = 0 }
  if (parentKind === "Column" && weight > 0) { out.fillH = true; out.weightH = Math.round(weight * 100) / 100; if (h < 0) out.h = 0 }
  if (parentKind === "Column" && weight <= 0 && out.fillH) { out.weightH = 1; if (h < 0) out.h = 0 }
  if (parentKind === "Grid" && w < 0) { out.fillW = true; out.w = 0 }
  return out
}

// ---------------------------------------------------------------- text

// Lines of `text` at `width` dp, wrapping at spaces (or anywhere a word is
// too long), at most `limit` lines (0: no limit).
function lineCount(text, size, bold, font, width, limit, measure) {
  var paragraphs = String(text).split("\n")
  if (limit === 1) return 1
  var lines = 0
  for (var i = 0; i < paragraphs.length; i++) {
    lines += wrapCount(paragraphs[i], size, bold, font, width, measure)
    if (limit > 0 && lines >= limit) return limit
  }
  return Math.max(1, lines)
}

function wrapCount(paragraph, size, bold, font, width, measure) {
  if (paragraph === "" || width <= 0) return 1
  if (measure.width(paragraph, size, bold, font) <= width + 0.01) return 1
  var words = paragraph.split(/( +)/)
  var lines = 1, current = ""
  for (var i = 0; i < words.length; i++) {
    var piece = words[i]
    if (piece === "") continue
    var candidate = current + piece
    if (measure.width(candidate.replace(/ +$/, ""), size, bold, font) <= width + 0.01) { current = candidate; continue }
    if (/^ +$/.test(piece)) { current = candidate; continue }
    if (current.replace(/ +$/, "") !== "") { lines++; current = "" }
    // A word longer than the line breaks anywhere.
    while (measure.width(piece, size, bold, font) > width + 0.01 && piece.length > 1) {
      var fit = 1
      while (fit < piece.length && measure.width(piece.slice(0, fit + 1), size, bold, font) <= width + 0.01) fit++
      piece = piece.slice(fit)
      lines++
    }
    current = piece
  }
  return lines
}

function textWidth(p, measure) {
  var t = p.text === undefined || p.text === null ? "…" : String(p.text)
  var size = fontSize(p)
  return Math.max.apply(null, t.split("\n").map(function(line) { return measure.width(line, size, p.bold === true, p.font) }))
}

// ---------------------------------------------------------------- natural sizes

// A node's own width (dp), padding included.
function naturalW(n, measure) {
  var p = props(n)
  var w = fixedW(p)
  if (w >= 0) return w
  var pad = padding(p.padding)
  return contentW(n, measure) + pad[0] + pad[2]
}

function contentW(n, measure) {
  var p = props(n)
  var kids = (n.c || []).filter(shown)
  switch (n.kind) {
  case "Text": return textWidth(p, measure)
  case "Button": return measure.width(p.text === undefined || p.text === null ? "…" : String(p.text), 13, false, "mono") + 20
  case "Input": return 120
  case "Image": { var im = measure.image ? measure.image(p.src) : null; return im ? im[0] : 0 }
  case "Column": return kids.reduce(function(m, c) { return Math.max(m, naturalW(c, measure)) }, 0)
  case "Box": return kids.reduce(function(m, c) { return Math.max(m, naturalW(c, measure)) }, 0)
  case "Row": {
    if (p.wrap === true) return flowNaturalW(n, measure)
    var gap = num(p.gap, 8)
    return kids.reduce(function(s, c) { return s + (num(props(c).weight, 0) > 0 ? 0 : naturalW(c, measure)) }, 0) + gap * Math.max(kids.length - 1, 0)
  }
  case "Flow": return flowNaturalW(n, measure)
  case "Grid": return 0
  }
  return DEFAULTS[n.kind] ? DEFAULTS[n.kind][0] : 0
}

function flowNaturalW(n, measure) {
  var kids = (n.c || []).filter(shown)
  var gap = num(props(n).gap, 8)
  return kids.reduce(function(s, c) { return s + naturalW(c, measure) }, 0) + gap * Math.max(kids.length - 1, 0)
}

// A node's own height (dp) at a given outer width, padding included.
function naturalH(n, width, measure) {
  var p = props(n)
  var h = fixedH(p)
  if (h >= 0) return h
  var pad = padding(p.padding)
  return contentH(n, Math.max(0, width - pad[0] - pad[2]), measure) + pad[1] + pad[3]
}

function contentH(n, width, measure) {
  var p = props(n)
  switch (n.kind) {
  case "Text": {
    var size = fontSize(p)
    var t = p.text === undefined || p.text === null ? "…" : String(p.text)
    return lineCount(t, size, p.bold === true, p.font, width, maxLines(p), measure) * measure.lineHeight(size)
  }
  case "Button": return measure.fontHeight(13) + 12
  case "Input": return measure.fontHeight(num(p.fontSize, 14)) + 12
  case "Image": {
    var im = measure.image ? measure.image(p.src) : null
    if (!im || im[0] <= 0) return 0
    return (width > 0 ? width : im[0]) * im[1] / im[0]
  }
  case "Column": case "Row": case "Box": case "Grid": case "Flow": {
    var inner = arrange(n, width, -1, measure)
    return inner.height
  }
  }
  return DEFAULTS[n.kind] ? DEFAULTS[n.kind][1] : 0
}

// ---------------------------------------------------------------- arranging

// Children of a container in a content box of `width` x `height` (height
// -1: as tall as they need). Returns { boxes: [{n, x, y, w, h}], height }.
function arrange(n, width, height, measure) {
  var p = props(n)
  switch (n.kind) {
  case "Column": return linear(n, false, width, height, measure)
  case "Row": return p.wrap === true ? flow(n, width, measure) : linear(n, true, width, height, measure)
  case "Flow": return flow(n, width, measure)
  case "Box": return stack(n, width, height, measure)
  case "Grid": return grid(n, width, measure)
  }
  return { boxes: [], height: 0 }
}

function linear(n, horizontal, width, height, measure) {
  var p = props(n)
  var kids = n.c || []
  var gap = num(p.gap, horizontal ? 8 : 4)
  var kind = horizontal ? "Row" : "Column"
  var places = kids.map(function(c) { return placement(c, kind) })
  var count = kids.filter(shown).length
  var gaps = gap * Math.max(count - 1, 0)
  var main = [], cross = []
  var i

  // Widths first in a Column (heights depend on them), heights last in a Row.
  function crossSizes(room, mainSizes) {
    var out = []
    for (var j = 0; j < kids.length; j++) {
      var pl = places[j]
      if (!shown(kids[j])) { out.push(0); continue }
      if (horizontal) {
        var nat = pl.h >= 0 ? pl.h : naturalH(kids[j], mainSizes[j], measure)
        out.push(pl.h >= 0 ? pl.h : pl.fillH && room >= 0 ? room : room >= 0 ? Math.min(nat, room) : nat)
      } else {
        var natW = pl.w >= 0 ? pl.w : naturalW(kids[j], measure)
        out.push(pl.w >= 0 ? pl.w : pl.fillW ? room : Math.min(natW, room))
      }
    }
    return out
  }

  function mainSizes(room, crossIn) {
    var out = [], total = 0
    var left = room - gaps
    for (var j = 0; j < kids.length; j++) {
      out.push(0)
      if (!shown(kids[j])) continue
      var pl = places[j]
      var weight = horizontal ? pl.weightW : pl.weightH
      if (weight > 0) { total += weight; continue }
      var own = horizontal ? pl.w : pl.h
      var fill = horizontal ? pl.fillW : pl.fillH
      var nat = horizontal ? naturalW(kids[j], measure) : naturalH(kids[j], crossIn[j], measure)
      var size = own >= 0 ? own : room < 0 ? nat : fill ? Math.max(left, 0) : Math.min(nat, Math.max(left, 0))
      out[j] = size
      left -= size
    }
    for (var k = 0; k < kids.length; k++) {
      var wk = horizontal ? places[k].weightW : places[k].weightH
      if (shown(kids[k]) && wk > 0) out[k] = room < 0 ? 0 : Math.max(left, 0) * wk / total
    }
    return out
  }

  if (horizontal) {
    main = mainSizes(width, null)
    cross = crossSizes(height, main)
  } else {
    cross = crossSizes(width, null)
    main = mainSizes(height, cross)
  }

  var used = 0, weighted = false
  for (i = 0; i < kids.length; i++) {
    if (!shown(kids[i])) continue
    used += main[i]
    if ((horizontal ? places[i].weightW : places[i].weightH) > 0) weighted = true
  }
  var room = horizontal ? width : height
  if (room < 0) room = used + gaps
  var j = weighted ? "start" : String(p.justify || "start")
  var spaced = j.indexOf("space") === 0
  var free = Math.max(room - used - (spaced ? 0 : gaps), 0)
  var at = j === "end" ? free : j === "center" ? free / 2 : j === "spaceAround" ? free / count / 2 : j === "spaceEvenly" ? free / (count + 1) : 0
  var step = j === "spaceBetween" ? (count > 1 ? free / (count - 1) : 0) : j === "spaceAround" ? free / count : j === "spaceEvenly" ? free / (count + 1) : gap
  var crossRoom = horizontal ? height : width
  if (crossRoom < 0) crossRoom = cross.reduce(function(m, v) { return Math.max(m, v) }, 0)
  var a = p.align
  var boxes = []
  for (i = 0; i < kids.length; i++) {
    var offset
    if (horizontal) offset = a === "top" || a === "start" ? 0 : a === "bottom" || a === "end" ? crossRoom - cross[i] : (crossRoom - cross[i]) / 2
    else offset = a === "center" ? (crossRoom - cross[i]) / 2 : a === "end" ? crossRoom - cross[i] : 0
    if (shown(kids[i])) boxes.push(horizontal ? { n: kids[i], x: at, y: offset, w: main[i], h: cross[i] } : { n: kids[i], x: offset, y: at, w: cross[i], h: main[i] })
    else boxes.push({ n: kids[i], x: 0, y: 0, w: 0, h: 0, hidden: true })
    if (shown(kids[i])) at += main[i] + step
  }
  var natural = horizontal ? cross.reduce(function(m, v) { return Math.max(m, v) }, 0)
    : kids.reduce(function(s, c, k) { return s + (!shown(c) || places[k].weightH > 0 ? 0 : main[k]) }, 0) + gaps
  return { boxes: boxes, height: natural }
}

function stack(n, width, height, measure) {
  var p = props(n)
  var align = String(p.align || "topStart")
  var kids = n.c || []
  var boxes = []
  var tallest = 0
  kids.forEach(function(c) {
    var pl = n.wrapper ? { fillW: true, fillH: true, w: -1, h: -1 } : placement(c, "Box")
    var w = pl.w >= 0 ? pl.w : pl.fillW ? width : Math.min(naturalW(c, measure), width)
    var nh = naturalH(c, w, measure)
    tallest = Math.max(tallest, nh)
    var room = height < 0 ? nh : height
    var h = pl.h >= 0 ? pl.h : pl.fillH && height >= 0 ? height : Math.min(nh, room)
    boxes.push({ n: c, w: w, h: h, x: 0, y: 0, hidden: !shown(c) })
  })
  var boxH = height < 0 ? tallest : height
  // A Box's children never get more room than the Box has, even a fixed
  // size (Compose's constraints; SPEC-NOTES N35).
  boxes.forEach(function(b) {
    b.w = Math.min(b.w, width)
    if (height >= 0) b.h = Math.min(b.h, height)
    b.x = /End$|^end$/.test(align) ? width - b.w : /Start$|^start$/.test(align) ? 0 : (width - b.w) / 2
    b.y = /^top/.test(align) ? 0 : /^bottom/.test(align) ? boxH - b.h : (boxH - b.h) / 2
  })
  return { boxes: boxes, height: tallest }
}

function grid(n, width, measure) {
  var p = props(n)
  var columns = Math.max(1, Math.round(num(p.columns, 2)))
  var gap = num(p.gap, 6)
  var kids = (n.c || []).filter(shown)
  var cell = Math.max(0, (width - gap * (columns - 1)) / columns)
  var boxes = []
  var y = 0
  for (var r = 0; r * columns < kids.length; r++) {
    var row = kids.slice(r * columns, r * columns + columns)
    // A grid's cells snap to whole pixels, rounding up (SPEC-NOTES N36).
    var px = measure.pixel || 0
    var sizes = row.map(function(c) {
      var pl = placement(c, "Grid")
      var w = pl.w > 0 ? pl.w : cell
      var h = pl.h >= 0 ? pl.h : naturalH(c, Math.min(w, cell), measure)
      return { w: Math.min(w, cell), h: px > 0 ? Math.ceil(h * px - 1e-6) / px : h }
    })
    var rowH = sizes.reduce(function(m, s) { return Math.max(m, s.h) }, 0)
    row.forEach(function(c, k) { boxes.push({ n: c, x: k * (cell + gap), y: y, w: sizes[k].w, h: sizes[k].h }) })
    y += rowH + gap
  }
  return { boxes: boxes, height: Math.max(0, y - gap) }
}

function flow(n, width, measure) {
  var gap = num(props(n).gap, 8)
  var kids = (n.c || []).filter(shown)
  var boxes = []
  var x = 0, y = 0, lineH = 0
  kids.forEach(function(c) {
    var w = naturalW(c, measure)
    var h = naturalH(c, w, measure)
    if (x > 0 && x + w > width + 0.01) { x = 0; y += lineH + gap; lineH = 0 }
    boxes.push({ n: c, x: x, y: y, w: w, h: h })
    x += w + gap
    lineH = Math.max(lineH, h)
  })
  return { boxes: boxes, height: kids.length ? y + lineH : 0 }
}

// ---------------------------------------------------------------- boxes

function boxFor(n, x, y, w, h, measure) {
  var p = props(n)
  var pad = padding(p.padding)
  var innerW = Math.max(0, w - pad[0] - pad[2])
  var innerH = Math.max(0, h - pad[1] - pad[3])
  var box = { node: n, kind: n.kind, key: n.key, x: x, y: y, w: w, h: h, pad: pad, lines: 0, children: [], content: 0 }
  if (n.kind === "Text") {
    var size = fontSize(p)
    var t = p.text === undefined || p.text === null ? "…" : String(p.text)
    box.lines = lineCount(t, size, p.bold === true, p.font, innerW, maxLines(p), measure)
    return box
  }
  if (!(isLinear(n.kind) || n.kind === "Grid")) return box
  var scroll = n.kind === "Column" && p.scroll === true
  var arranged
  if (scroll) {
    arranged = arrange(n, innerW, -1, measure)
    box.content = Math.max(arranged.height, innerH) + pad[1] + pad[3]
  } else {
    arranged = arrange(n, innerW, innerH, measure)
  }
  box.children = arranged.boxes.filter(function(b) { return !b.hidden }).map(function(b) {
    return boxFor(b.n, pad[0] + b.x, pad[1] + b.y, b.w, b.h, measure)
  })
  return box
}

// The whole tile: its root node fills the content area (several root
// nodes stack as a Column with no gap).
function layout(children, width, height, measure) {
  var root = children.length === 1 ? children[0]
    : { kind: "Column", key: "root", p: { gap: 0 }, h: {}, a: {}, c: children }
  return boxFor(root, 0, 0, width, height, measure)
}

// Every box in order, with its position on the tile: for the L4 dump.
function flatten(box, ox, oy, path, out) {
  out = out || []
  // `offset` moves a node where it is drawn, children with it.
  var off = props(box.node).offset
  var dx = Array.isArray(off) ? num(off[0], 0) : 0, dy = Array.isArray(off) ? num(off[1], 0) : 0
  var x = (ox || 0) + box.x + dx, y = (oy || 0) + box.y + dy
  out.push({ path: path || "0", kind: box.kind, x: x, y: y, w: box.w, h: box.h })
  box.children.forEach(function(c, i) { flatten(c, x, y, (path || "0") + "." + i, out) })
  return out
}

if (typeof module !== "undefined") {
  module.exports = { layout: layout, flatten: flatten, wants: wants, placement: placement, padding: padding,
                     fontSize: fontSize, maxLines: maxLines, textStyle: textStyle, STYLES: STYLES, lineCount: lineCount }
}
