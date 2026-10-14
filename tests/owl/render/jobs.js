// SPDX-License-Identifier: MIT
// The render tasks for tiles.qml: every milestone widget, ours and the
// reference's in the dark theme, and ours in the light theme too.
//   node jobs.js <out dir> <store widgets dir>
"use strict"
const fs = require("fs"), path = require("path")
const cases = require("../cases.json")
const [out, widgets] = process.argv.slice(2)
const tasks = []
const only = process.env.OWL_ONLY || ""
for (const c of cases.widgets.filter((w) => !only || w.id.includes(only))) {
  const name = c.id.replace("/", ".")
  const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, "../fixtures", name + ".json"), "utf8"))
  const file = path.join(widgets, c.id, "widget.owl")
  const source = fs.readFileSync(file, "utf8")
  for (const [side, theme] of [["ours", "dark"], ["ref", "dark"], ["ours", "light"]]) {
    const fx = theme === "dark" ? fixture : Object.assign({}, fixture, { theme: fixture.lightTheme })
    const bg = fx.theme.background >>> 0
    tasks.push({
      id: c.id, side, theme, file, source, fixture: fx, card: fixture.card,
      cardColor: "#" + (bg & 0xffffff).toString(16).padStart(6, "0"),
      weekStart: 1, mono: "JetBrainsMono Nerd Font", sans: "sans-serif",
      dump: path.join(out, "tiles", `${name}.${side}.${theme}.json`),
      png: path.join(out, "tiles", `${name}.${side}.${theme}.png`)
    })
  }
}
fs.mkdirSync(path.join(out, "tiles"), { recursive: true })
console.log(JSON.stringify(tasks))
