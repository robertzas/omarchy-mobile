// SPDX-License-Identifier: MIT
// Writes tests/owl/fixtures/<author>.<name>.json for every case in
// cases.json: the walk fixture (theme, time, tile, canvas, sources) for the
// widget at its size on our home screen.
//
//   node make-fixtures.js <store widgets dir> <omarchy themes dir>
"use strict"
const fs = require("fs"), path = require("path")
const { load } = require(path.resolve(__dirname, "../../packages/omamobile-shell/test/owl-load.js"))
const C = load("compiler.js"), P = load("phone.js")
const G = require("./geometry.js")
const cases = require("./cases.json")
const [widgetsDir, themesDir] = process.argv.slice(2)

function theme(name) {
  const named = P.parseColorsToml(fs.readFileSync(path.join(themesDir, name, "colors.toml"), "utf8"))
  const p = P.palette(named)
  const out = {}
  // As signed 32-bit ints, the walk format's numbers.
  Object.keys(p).forEach((k) => { out[k] = p[k] | 0 })
  return out
}

const dark = theme(cases.theme), light = theme(cases.lightTheme)
for (const c of cases.widgets) {
  const src = fs.readFileSync(path.join(widgetsDir, c.id, "widget.owl"), "utf8")
  const program = C.compile(src)
  const t = G.tile(program)
  const fixture = {
    widget: c.id, cells: t.cells, dp: t.dp, card: [t.cardW, t.cardH],
    theme: dark, lightTheme: light, time: cases.time % 3600 + 0.5,
    canvas: t.content.map((v) => Math.round(v * 1000) / 1000),
    tile: t.vars, sources: c.sources
  }
  const file = path.join(__dirname, "fixtures", c.id.replace("/", ".") + ".json")
  fs.writeFileSync(file, JSON.stringify(fixture, null, 1) + "\n")
  console.log(c.id, "cells", t.cells.join("x"), "content", fixture.canvas.join("x"), "dp")
}
