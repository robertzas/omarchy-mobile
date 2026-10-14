.pragma library
.import "compiler.js" as Compiler
.import "phone.js" as Phone
// SPDX-License-Identifier: MIT
// What the home screen knows about one OWL widget before it runs: whether
// it compiles, its sizes in our cells, what it may do (derived from the
// compiler's list, plan §3.1), what stops it running here, and the words
// the Widgets sheet and the approval sheet show. Pure JS.

var ICON = "󰕰"

// `text` is the widget.owl; `grid`, `cellHeight` and `dp` are the home
// screen's. -> { ok, error, program, spec, caps, refusals, name }
function describe(id, text, grid, cellHeight, dp) {
  var program
  try {
    program = Compiler.compile(String(text || ""))
  } catch (e) {
    return { ok: false, error: Compiler.formatError(String(text || ""), e), program: null, spec: null,
             caps: null, refusals: [], name: id }
  }
  var caps = Phone.capabilities(program)
  var sizes = Phone.homeSpec(program, grid, cellHeight, dp)
  var meta = program.meta || {}
  var spec = {
    name: program.name, icon: ICON, size: sizes.size, min: sizes.min, max: sizes.max,
    network: caps.network, capabilities: Phone.capabilityList(caps), config: {}, schema: [], user: true, owl: true,
    description: typeof meta.description === "string" ? meta.description : ""
  }
  return { ok: true, error: "", program: program, spec: spec, caps: caps, refusals: caps.refusals, name: program.name }
}

function plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

// "runs 1 command, uses the internet (2 sites), reads 1 file"
function summary(caps) {
  if (!caps) return ""
  var parts = []
  if (caps.commands.length) parts.push("runs " + plural(caps.commands.length, "command", "commands"))
  if (caps.network) parts.push("uses the internet" + (caps.hosts.length ? " (" + caps.hosts.join(", ") + ")" : ""))
  if (caps.files.length) parts.push("reads " + plural(caps.files.length, "file", "files"))
  if (caps.notifications) parts.push("reads your notifications")
  return parts.length ? parts.join(", ") : "runs nothing, reaches nothing"
}

// The first line of a command, for lists; the full text is on the sheet.
function shortCommand(line, max) {
  var limit = max || 70
  var first = String(line).split("\n")[0]
  var more = String(line).indexOf("\n") >= 0
  return first.length > limit ? first.slice(0, limit - 1) + "…" : more ? first + " …" : first
}

// What a placed OWL widget shows: { state, message } with state "ok" (it
// runs), "approve" (waiting for the user's OK), "error", "missing",
// "waiting" (no scan yet) or "off" (the feature flag).
function cardState(enabled, scanned, record, info, approval, crashedHash) {
  if (!enabled) return { state: "off", message: "OWL widgets are turned off on this phone (owlWidgets in ~/.config/omamobile/features.json)." }
  if (!scanned) return { state: "waiting", message: "Looking for your widgets\u2026" }
  if (!record) return { state: "missing", message: "No such widget in ~/.config/omamobile/widgets" }
  if (record.status !== "ok") return { state: "error", message: record.errors.length ? record.errors.join("\n") : "This widget has an error" }
  if (!info || !info.ok) return { state: "error", message: info ? info.error : "It doesn't compile" }
  if (info.refusals.length) return { state: "error", message: "Can't run on this phone: " + info.refusals.join("; ") }
  if (crashedHash && crashedHash === record.hash)
    return { state: "error", message: "This widget crashed the shell, so it's off. Edit it to try again." }
  if (!Phone.approvalMatches(approval, info.program))
    return { state: "approve", message: (approval ? "It changed what it runs. " : "") + "Before it runs: " + summary(info.caps) + "." }
  return { state: "ok", message: "" }
}

if (typeof module !== "undefined") {
  module.exports = { describe: describe, summary: summary, shortCommand: shortCommand, cardState: cardState, ICON: ICON }
}
