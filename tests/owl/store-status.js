// SPDX-License-Identifier: MIT
// Which store widgets omamobile-owl-widgets may ship, and why not the rest:
// packages/omamobile-owl-widgets/status.json, from a conformance report
// (L1-L3 for every store widget, L4/L5 where rendered) and from what each
// widget needs that this phone serves only in part.
//   node store-status.js <report.json> [render-all.json] > status.json
"use strict"
const fs = require("fs"), path = require("path")
const { load } = require(path.resolve(__dirname, "../../packages/omamobile-shell/test/owl-load.js"))
const C = load("compiler.js"), P = load("phone.js")
const REF = "/ref/omarchy-widgets"
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
const renders = process.argv[3] && fs.existsSync(process.argv[3]) ? JSON.parse(fs.readFileSync(process.argv[3], "utf8")) : null
const failed = {}
for (const f of (report.store && report.store.failures) || []) failed[f.id] = f
const rendered = {}
for (const r of (renders || [])) rendered[r.id] = r

// What the phone answers only in part (docs/owl-review/README.md).
const PARTIAL = [
  [/android\.notifications/, "reads Android notifications, which this phone doesn't have"],
  [/androidApp\(/, "opens Android apps (no Android here until Waydroid)"],
  [/notification\(/, "acts on Android notifications"],
  [/android\.alarm/, "reads the next alarm, never set here"],
  [/"app:/, "draws Android app icons"],
  [/\bShader\b/, "draws a shader's fallback colour"],
  [/launcher\("linux"\)/, "offers to install Linux, which is always there"]
]
const out = { source: "omarchy-widgets " + (report.reference || ""), widgets: {} }
for (const author of fs.readdirSync(path.join(REF, "widgets")).sort()) {
  for (const name of fs.readdirSync(path.join(REF, "widgets", author)).sort()) {
    const id = author + "/" + name
    const file = path.join(REF, "widgets", id, "widget.owl")
    if (!fs.existsSync(file)) continue
    const text = fs.readFileSync(file, "utf8")
    const f = failed[id]
    if (f && (f.l1 || f.l2 || f.l3)) { out.widgets[id] = { status: "unsupported", note: "conformance: " + [f.l1, f.l2, f.l3].filter(Boolean).join("; ").slice(0, 200) }; continue }
    const r = rendered[id]
    if (r && !r.l4.pass) { out.widgets[id] = { status: "unsupported", note: "layout differs from the reference: " + r.l4.why }; continue }
    let caps
    try { caps = P.capabilities(C.compile(text)) } catch (e) { out.widgets[id] = { status: "unsupported", note: String(e.message) }; continue }
    if (caps.refusals.length) { out.widgets[id] = { status: "unsupported", note: caps.refusals.join("; ") }; continue }
    const partial = PARTIAL.filter((p) => p[0].test(text)).map((p) => p[1])
    const checked = r ? "L1-L5 checked" : "L1-L3 checked; layout not rendered yet"
    out.widgets[id] = partial.length ? { status: "partial", note: partial.join("; ") + " (" + checked + ")" } : { status: "ok", note: checked }
  }
}
process.stdout.write(JSON.stringify(out, null, 1) + "\n")
