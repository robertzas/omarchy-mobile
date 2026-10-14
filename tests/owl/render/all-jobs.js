// SPDX-License-Identifier: MIT
// Render tasks for every store widget without data (L4/L5 beyond the
// milestone's fixtures): ours and the reference's, dark theme, at the
// widget's own size on our home screen. Widgets with a Terminal are left
// out on the reference side: its Terminal starts the widget's program.
//   node all-jobs.js <out dir> <store widgets dir>
"use strict"
const fs = require("fs"), path = require("path")
const { load } = require(path.resolve(__dirname, "../../../packages/omamobile-shell/test/owl-load.js"))
const C = load("compiler.js")
const G = require("../geometry.js")
const [out, widgetsDir] = process.argv.slice(2)
const base = JSON.parse(fs.readFileSync(path.join(__dirname, "../fixtures/simonschubert.calendar.json"), "utf8"))
const tasks = [], skipped = []
for (const author of fs.readdirSync(widgetsDir).sort()) {
  for (const name of fs.readdirSync(path.join(widgetsDir, author)).sort()) {
    const id = author + "/" + name
    const file = path.join(widgetsDir, id, "widget.owl")
    if (!fs.existsSync(file)) continue
    const source = fs.readFileSync(file, "utf8")
    let program
    try { program = C.compile(source) } catch (e) { skipped.push({ id, why: "doesn't compile" }); continue }
    const t = G.tile(program)
    const fixture = { widget: id, cells: t.cells, dp: t.dp, card: [t.cardW, t.cardH], theme: base.theme, time: base.time,
                      canvas: t.content, tile: t.vars, sources: {} }
    const key = id.replace("/", ".")
    for (const side of program.terminal ? ["ours"] : ["ours", "ref"]) {
      tasks.push({ id, side, theme: "dark", file, source, fixture, card: fixture.card, cardColor: "#" + ((base.theme.background >>> 0) & 0xffffff).toString(16).padStart(6, "0"),
                   weekStart: 1, mono: "JetBrainsMono Nerd Font", sans: "sans-serif",
                   dump: path.join(out, "all", `${key}.${side}.json`), png: path.join(out, "all", `${key}.${side}.png`) })
    }
    if (program.terminal) skipped.push({ id, why: "has a Terminal: the reference's would start the widget's program" })
  }
}
fs.mkdirSync(path.join(out, "all"), { recursive: true })
fs.writeFileSync(path.join(out, "all", "skipped.json"), JSON.stringify(skipped, null, 1))
console.log(JSON.stringify(tasks))
