// SPDX-License-Identifier: MIT
// L4 and L5 for the rendered tiles (docs/WIDGET-INTEROP-PLAN.md §7.1):
//   L4  every node's box within 1 dp of the reference's (2 dp for Text,
//       whose glyphs differ in hinting), when both trees have the same shape
//   L5  the share of pixels that differ by more than 10% (ImageMagick AE
//       with fuzz), and a side-by-side picture (ours | reference | diff)
//       for review by eye. Never accepted automatically.
//   node compare.js <out dir>
"use strict"
const fs = require("fs"), path = require("path"), cp = require("child_process")
const cases = require("../cases.json")
const out = process.argv[2]
const tiles = path.join(out, "tiles")
const sides = path.join(out, "side-by-side")
fs.mkdirSync(sides, { recursive: true })
const results = []
const only = process.env.OWL_ONLY || ""
for (const c of cases.widgets.filter((w) => !only || w.id.includes(only))) {
  const name = c.id.replace("/", ".")
  const f = (side, theme, ext) => path.join(tiles, `${name}.${side}.${theme}.${ext}`)
  const r = { id: c.id, l4: { pass: false, nodes: 0, worst: 0, why: "" }, l5: { diffPercent: null } }
  try {
    const ours = JSON.parse(fs.readFileSync(f("ours", "dark", "json"), "utf8"))
    const ref = JSON.parse(fs.readFileSync(f("ref", "dark", "json"), "utf8"))
    r.l4.nodes = ref.length
    if (ours.length !== ref.length || ours.some((n, i) => n.kind !== ref[i].kind || n.path !== ref[i].path)) {
      const at = ours.findIndex((n, i) => !ref[i] || n.kind !== ref[i].kind || n.path !== ref[i].path)
      r.l4.why = `tree shape differs (${ours.length} nodes, reference ${ref.length})` + (at >= 0 ? ` at ${ours[at].path} ${ours[at].kind} vs ${ref[at] ? ref[at].path + " " + ref[at].kind : "nothing"}` : "")
    } else {
      let worst = 0, where = ""
      ours.forEach((n, i) => {
        const tol = n.kind === "Text" ? 2 : 1
        for (const k of ["x", "y", "w", "h"]) {
          const d = Math.abs(n[k] - ref[i][k])
          if (d - tol > worst - (where ? (where.kind === "Text" ? 2 : 1) : 0) && d > tol) { worst = d; where = { path: n.path, kind: n.kind, k, ours: n[k], ref: ref[i][k] } }
          r.l4.worst = Math.max(r.l4.worst, d)
        }
      })
      r.l4.pass = !where
      if (where) r.l4.why = `${where.path} ${where.kind} ${where.k}: ${where.ours.toFixed(1)} dp, reference ${where.ref.toFixed(1)} dp`
    }
  } catch (e) { r.l4.why = "no dump: " + e.message }
  try {
    const a = f("ours", "dark", "png"), b = f("ref", "dark", "png"), d = path.join(sides, `${name}.diff.png`)
    const res = cp.spawnSync("magick", ["compare", "-metric", "AE", "-fuzz", "10%", a, b, d], { encoding: "utf8" })
    const differing = parseFloat((res.stderr || "").trim().split(" ")[0])
    const size = cp.execFileSync("magick", ["identify", "-format", "%w %h", a], { encoding: "utf8" }).split(" ").map(Number)
    r.l5.diffPercent = Math.round(differing / (size[0] * size[1]) * 10000) / 100
    cp.execFileSync("magick", [a, "-bordercolor", "#808080", "-border", "6", b, "-border", "6", d, "-border", "6", "+append",
      path.join(sides, `${name}.png`)])
  } catch (e) { r.l5.why = String(e.message).split("\n")[0] }
  results.push(r)
}
fs.writeFileSync(path.join(out, "render-report.json"), JSON.stringify(results, null, 1) + "\n")
console.log("L4 layout: " + results.filter((r) => r.l4.pass).length + "/" + results.length + " within 1 dp (Text 2 dp)")
for (const r of results) console.log("  " + (r.l4.pass ? "ok    " : "not ok") + " " + r.id + "  L4 worst " + r.l4.worst.toFixed(1) + " dp" + (r.l4.why ? " (" + r.l4.why + ")" : "") + "  L5 " + r.l5.diffPercent + "% pixels differ")
