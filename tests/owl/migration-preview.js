// SPDX-License-Identifier: MIT
// What the home screen will do with a layout's ports, exactly: the same
// HomeModel.portPlacements and owl/catalog.js migrationApprovals that
// Home.qml runs. For runbook step M1 (read-only).
//   node migration-preview.js <home.json> <store widgets dir> [widget-approvals.json]
"use strict"
const fs = require("fs"), path = require("path")
const { load } = require(path.resolve(__dirname, "../../packages/omamobile-shell/test/owl-load.js"))
const H = require(path.resolve(__dirname, "../../packages/omamobile-shell/plugins/omamobile.home/HomeModel.js"))
const K = load("catalog.js")
const [layoutFile, storeDir, approvalsFile] = process.argv.slice(2)
const raw = JSON.parse(fs.readFileSync(layoutFile, "utf8"))
const approvals = approvalsFile && fs.existsSync(approvalsFile) ? JSON.parse(fs.readFileSync(approvalsFile, "utf8")) : {}
const infoFor = (t) => K.describe(t, fs.readFileSync(path.join(storeDir, H.owlStoreId(t), "widget.owl"), "utf8"), H.GRID, 908 / 6, 480 / 6 / 69)
const ports = H.portPlacements(raw)
const r = K.migrationApprovals(ports, approvals, infoFor, H.portCapabilities)
const re = K.recheckAutoApprovals(r.approvals, infoFor, H.portCapabilities)
for (const d of r.decisions) console.log(`${d.id.padEnd(5)} ${d.from.padEnd(16)} -> ${d.to.padEnd(36)} ${d.verdict}${d.extra.length ? ": " + d.extra.join("; ") : ""}`)
for (const type of Object.keys(r.approvals)) if (!re.approvals[type]) console.log(`stored automatic approval of ${type} withdrawn: it no longer passes`)
const after = H.parse(JSON.stringify(raw), {})
const moved = []
raw.pages.forEach((p, i) => (p.items || []).forEach((it) => {
  let found = null
  after.pages.forEach((q, j) => q.items.forEach((x) => { if (x.id === it.id) found = Object.assign({ page: j }, x) }))
  if (!found || found.page !== i || found.x !== it.x || found.y !== it.y || found.w !== it.w || found.h !== it.h) moved.push(it.id)
}))
console.log(moved.length ? "moved or missing: " + moved.join(", ") : "every item keeps its page, place and size")
