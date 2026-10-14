// SPDX-License-Identifier: MIT
// The phone's home-screen geometry (phone.json) and where an OWL widget's
// tile lands in it: card size, dp, tile variables, the content box.
"use strict"
const path = require("path")
const { load } = require(path.resolve(__dirname, "../../packages/omamobile-shell/test/owl-load.js"))
const P = load("phone.js")
const phone = require("./phone.json")

const pageWidth = phone.screen[0]
const pageHeight = phone.screen[1] - phone.bar - phone.dock - phone.pagerTop - phone.dots
const cellW = pageWidth / phone.grid.columns
const cellH = pageHeight / phone.grid.rows
const dp = P.dpFor(pageWidth)

// The tile of a compiled program at its own size (or `cells` [w, h]).
function tile(program, cells) {
  const spec = P.homeSpec(program, phone.grid, cellH, dp)
  const c = cells || spec.size
  const cardW = c[0] * cellW - phone.gap * 2
  const cardH = c[1] * cellH - phone.gap * 2
  const vars = P.tileVars(cardW, cardH, dp, pageWidth, phone.screen[1] - phone.bar - phone.dock, 0)
  const pad = program.padding
  return { cells: c, spec, cardW, cardH, dp, vars,
           content: [(cardW - 2 * pad * dp) / dp, (cardH - 2 * pad * dp) / dp] }
}

module.exports = { phone, pageWidth, pageHeight, cellW, cellH, dp, tile }
