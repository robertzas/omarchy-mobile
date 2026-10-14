// SPDX-License-Identifier: MIT
// Runs inside the conformance container only. Loads the reference runtime's
// language core (pinned, under /ref, never copied into this repository) as a
// black box and prints, per widget file, what its compiler says: accepted or
// rejected (with the formatted error), the name, sizes and the commands list.
//
//   node ref-compile.js <Owl.js> <widget.owl>...
"use strict"
const fs = require("fs"), Module = require("module"), path = require("path")
function load(file) {
  const m = new Module(file)
  m.filename = file
  m.paths = Module._nodeModulePaths(path.dirname(file))
  m._compile(fs.readFileSync(file, "utf8").replace(/^\.pragma library/, "//"), file)
  return m.exports
}
const Owl = load(path.resolve(process.argv[2]))
const out = {}
for (const f of process.argv.slice(3)) {
  const src = fs.readFileSync(f, "utf8")
  try {
    const p = Owl.compile(src)
    out[path.basename(f)] = { ok: true, name: p.name, size: p.size || null, minSize: p.minSize || null,
                              commands: p.commands, requires: p.requires, nodeCount: p.nodeCount, animated: !!p.animated }
  } catch (e) {
    const formatted = Owl.formatError(src, e)
    out[path.basename(f)] = { ok: false, message: String(e.message), pos: typeof e.pos === "number" ? e.pos : null, formatted }
  }
}
console.log(JSON.stringify(out, null, 1))
