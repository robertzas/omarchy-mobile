// SPDX-License-Identifier: MIT
// The review screenshots home.qml takes, for one theme.
//   node home-jobs.js <out dir> <store widgets dir> <theme name>
"use strict"
const fs = require("fs"), path = require("path")
const cases = require("../cases.json")
const [out, widgetsDir, theme] = process.argv.slice(2)
const widgets = cases.widgets.map((c) => ({
  id: c.id.replace("/", "."),
  text: fs.readFileSync(path.join(widgetsDir, c.id, "widget.owl"), "utf8"),
  fixture: { sources: c.sources }
}))
for (const f of fs.readdirSync(path.join(__dirname, "extra")).sort())
  widgets.push({ id: f.replace(/\.owl$/, ""), text: fs.readFileSync(path.join(__dirname, "extra", f), "utf8"), fixture: { sources: { pic: { text: "" } } } })

// Every store widget approved, with the internet on; the made-up ones not.
const approved = {}
const C = require(path.resolve(__dirname, "../../../packages/omamobile-shell/test/owl-load.js")).load("compiler.js")
for (const w of widgets) if (!w.id.startsWith("shared.") && !w.id.startsWith("my.")) approved[w.id] = { commands: C.compile(w.text).commands, network: true }

const s = (id, x, y, w, h) => ({ id, x, y, w, h })
const pages = [
  [s("simonschubert.analog-clock", 0, 0, 2, 2), s("simonschubert.calendar", 2, 0, 2, 2), s("derekross.bitcoin", 0, 2, 4, 1),
   s("simonschubert.exchange-rates", 0, 3, 4, 1), s("simonschubert.focus", 0, 4, 2, 2), s("simonschubert.year-progress", 2, 4, 2, 2)],
  [s("simonschubert.earthquakes", 0, 0, 4, 2), s("simonschubert.hacker-news", 0, 2, 4, 2), s("simonschubert.countdown", 0, 4, 2, 2), s("simonschubert.todo", 2, 4, 2, 2)],
  [s("simonschubert.koi-pond", 0, 0, 4, 2), s("simonschubert.habits", 0, 2, 4, 2), s("lucassynnott.year-left", 0, 4, 2, 2)],
  [s("simonschubert.xkcd", 0, 0, 4, 3), s("shared.wallpaper-of-the-day", 0, 3, 2, 2), s("my.moon-phase", 2, 3, 2, 2)]
]
const shots = pages.map((cells, i) => ({ png: path.join(out, `home-page${i + 1}-${theme}.png`), cells, page: i, pages: pages.length, approvals: approved }))
const withoutQuakes = Object.assign({}, approved)
delete withoutQuakes["simonschubert.earthquakes"]
shots.push({ png: path.join(out, `widgets-sheet-${theme}.png`), cells: pages[0], page: 0, pages: pages.length, approvals: withoutQuakes, sheet: "widgets" })
shots.push({ png: path.join(out, `approve-earthquakes-${theme}.png`), cells: pages[0], page: 0, pages: pages.length, approvals: withoutQuakes, sheet: "owl-approve", approveId: "simonschubert.earthquakes" })
shots.push({ png: path.join(out, `approve-risky-${theme}.png`), cells: pages[3], page: 3, pages: pages.length, approvals: approved, sheet: "owl-approve", approveId: "shared.wallpaper-of-the-day" })
console.log(JSON.stringify({ time: cases.time, widgets, shots }))
