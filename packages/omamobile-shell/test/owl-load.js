// SPDX-License-Identifier: MIT
// Loads the OWL runtime's QML JavaScript files (plugins/omamobile.home/owl/)
// under node: `.pragma library` goes, and each `.import "x.js" as X` becomes
// a variable holding that file's exports. Lines keep their numbers.
"use strict"
const fs = require("fs"), path = require("path"), Module = require("module")

const DIR = path.resolve(__dirname, "../plugins/omamobile.home/owl")
const cache = {}

function load(name) {
  if (cache[name]) return cache[name]
  const file = path.join(DIR, name)
  const src = fs.readFileSync(file, "utf8")
    .replace(/^\.pragma library[ \t]*$/m, "")
    .replace(/^\.import "([\w.-]+)" as (\w+)[ \t]*$/mg, (m, f, n) => `var ${n} = require(${JSON.stringify(__filename)}).load(${JSON.stringify(f)});`)
  const m = new Module(file, module)
  m.filename = file
  m.paths = Module._nodeModulePaths(DIR)
  cache[name] = {}
  m._compile(src, file)
  cache[name] = m.exports
  return m.exports
}

module.exports = { load, DIR }
