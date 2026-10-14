// SPDX-License-Identifier: MIT
// L4 and L5 for every store widget rendered without data (all-jobs.js):
// writes render-all.json (one entry per widget) and side-by-sides of the
// ones that fail, for review.
//   node compare-all.js <out dir>
"use strict"
const fs = require("fs"), path = require("path"), cp = require("child_process")
const out = process.argv[2]
const dir = path.join(out, "all")
const skipped = JSON.parse(fs.readFileSync(path.join(dir, "skipped.json"), "utf8"))
const ids = Array.from(new Set(fs.readdirSync(dir).filter((f) => f.endsWith(".ours.json")).map((f) => f.replace(/\.ours\.json$/, ""))))
const results = []
fs.mkdirSync(path.join(out, "all-side-by-side"), { recursive: true })
for (const key of ids.sort()) {
  const id = key.replace(".", "/")
  const skip = skipped.find((s) => s.id === id)
  const r = { id, l4: { pass: false, worst: 0, why: "" }, l5: { diffPercent: null } }
  if (skip) { r.l4.why = "not rendered on the reference side: " + skip.why; results.push(r); continue }
  try {
    const ours = JSON.parse(fs.readFileSync(path.join(dir, key + ".ours.json"), "utf8"))
    const ref = JSON.parse(fs.readFileSync(path.join(dir, key + ".ref.json"), "utf8"))
    if (ours.length !== ref.length || ours.some((n, i) => n.kind !== ref[i].kind || n.path !== ref[i].path)) {
      const at = ours.findIndex((n, i) => !ref[i] || n.kind !== ref[i].kind || n.path !== ref[i].path)
      r.l4.why = `tree shape differs (${ours.length} nodes, reference ${ref.length})` + (at >= 0 ? ` at ${ours[at].path} ${ours[at].kind}` : "")
    } else {
      let worst = null
      ours.forEach((n, i) => {
        const tol = n.kind === "Text" ? 2 : 1
        for (const k of ["x", "y", "w", "h"]) {
          const d = Math.abs(n[k] - ref[i][k])
          r.l4.worst = Math.max(r.l4.worst, d)
          if (d > tol && (!worst || d > worst.d)) worst = { d, path: n.path, kind: n.kind, k, ours: n[k], ref: ref[i][k] }
        }
      })
      r.l4.pass = !worst
      if (worst) r.l4.why = `${worst.path} ${worst.kind} ${worst.k}: ${worst.ours.toFixed(1)} dp, reference ${worst.ref.toFixed(1)} dp`
    }
    const a = path.join(dir, key + ".ours.png"), b = path.join(dir, key + ".ref.png"), d = path.join(dir, key + ".diff.png")
    const res = cp.spawnSync("magick", ["compare", "-metric", "AE", "-fuzz", "10%", a, b, d], { encoding: "utf8" })
    const size = cp.execFileSync("magick", ["identify", "-format", "%w %h", a], { encoding: "utf8" }).split(" ").map(Number)
    r.l5.diffPercent = Math.round(parseFloat((res.stderr || "").trim().split(" ")[0]) / (size[0] * size[1]) * 10000) / 100
    if (!r.l4.pass || r.l5.diffPercent > 2)
      cp.execFileSync("magick", [a, "-bordercolor", "#808080", "-border", "6", b, "-border", "6", d, "-border", "6", "+append", "-resize", "50%",
        path.join(out, "all-side-by-side", key + ".png")])
  } catch (e) { r.l4.why = "not rendered: " + String(e.message).split("\n")[0] }
  results.push(r)
}
fs.writeFileSync(path.join(out, "render-all.json"), JSON.stringify(results, null, 1) + "\n")
const l4 = results.filter((r) => r.l4.pass).length
const l5 = results.filter((r) => r.l5.diffPercent !== null && r.l5.diffPercent <= 2).length
console.log("store widgets without data: L4 " + l4 + "/" + results.length + " within 1 dp (Text 2 dp), L5 " + l5 + "/" + results.length + " with 2% of pixels or fewer differing")
for (const r of results) if (!r.l4.pass || !(r.l5.diffPercent <= 2)) console.log("  not ok " + r.id + ": " + (r.l4.why || "L4 ok") + "; L5 " + r.l5.diffPercent + "%")
