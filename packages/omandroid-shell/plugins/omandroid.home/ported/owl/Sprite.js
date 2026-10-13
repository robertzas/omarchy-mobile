// SPDX-License-Identifier: MIT
// Pixel sprites as text: one letter per art pixel, "." for empty. Ported
// from simonschubert/owl in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).

// Rows of letters -> runs [column, row, letter, length], so a row takes a
// few rects, not one per pixel.
function runs(rows) {
  var out = []
  for (var j = 0; j < rows.length; j++) {
    var r = rows[j], i = 0
    while (i < r.length) {
      var c = r.charAt(i), k = i
      while (k < r.length && r.charAt(k) === c) k++
      if (c !== ".") out.push([i, j, c, k - i])
      i = k
    }
  }
  return out
}

// Draws runs at (x, y) with art pixels of p, colours from palette[letter];
// letters missing from the palette are skipped. dy(letter) shifts a letter.
function draw(ctx, cells, x, y, p, palette, dy) {
  for (var i = 0; i < cells.length; i++) {
    var c = cells[i], fill = palette[c[2]]
    if (fill === undefined) continue
    ctx.fillStyle = fill
    ctx.fillRect(x + c[0] * p, y + c[1] * p + (dy ? dy(c[2]) : 0), c[3] * p + 0.5, p + 0.5)
  }
}

if (typeof module !== "undefined") module.exports = { runs: runs, draw: draw }
