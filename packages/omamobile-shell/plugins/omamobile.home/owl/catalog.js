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
  if (caps.terminal) parts.push("has a terminal")
  ;(caps.devices || []).forEach(function(d) { parts.push(d === "haptic" ? "vibrates" : "switches the torch") })
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

// ---------------------------------------------------------------- built-ins that were ports

// Whether a port's OWL original may be approved without asking: only when
// it needs nothing the port didn't have (HomeModel.portCapabilities): no
// commands where the port ran none, no internet or other hosts than the
// port's, no files, notifications, vibration or torch it didn't use, and no
// risk flag. -> { approve: record | null, extra: [what it needs beyond the port] }
function portApproval(port, info, enabled) {
  if (!port || !info || !info.ok) return { approve: null, extra: ["it doesn't compile"] }
  var c = info.caps
  var extra = []
  if (c.commands.length && !port.commands) extra.push("runs commands")
  if (c.network) {
    if (!port.network) extra.push("uses the internet")
    else if (port.hosts !== null) {
      var outside = c.hosts.filter(function(h) {
        return !port.hosts.some(function(p) { return h === p || h.slice(-(p.length + 1)) === "." + p })
      })
      if (outside.length) extra.push("talks to " + outside.join(", "))
      if (!c.hosts.length) extra.push("talks to addresses built while it runs")
    }
  }
  if (c.files.length) extra.push("reads files")
  if (c.notifications && !port.notifications) extra.push("reads notifications")
  if ((c.devices || []).length) extra.push(c.devices.join(" and "))
  if (c.terminal) extra.push("has a terminal")
  c.risks.forEach(function(r) { if (extra.indexOf(r.says) < 0 && r.id !== "notifications") extra.push(r.says) })
  if (extra.length) return { approve: null, extra: extra }
  return { approve: { commands: info.program.commands.slice(), devices: [], network: !!port.network && enabled === true, auto: true }, extra: [] }
}

// What the migration does with the approvals, as one pure step (Home.qml
// and tests/owl/migration-preview.js both run it): approves the ports'
// originals that pass portApproval, and withdraws an earlier automatic
// approval that no longer passes (an approval the user gave stays).
// `ports`: HomeModel.portPlacements; `infoFor(type)`: describe() of the
// original; `capsFor(port)`: HomeModel.portCapabilities.
// -> { approvals, decisions: [{ id, from, to, verdict: "approved"|"asks"|"kept", extra }], changed }
function migrationApprovals(ports, approvals, infoFor, capsFor) {
  var next = {}
  Object.keys(approvals || {}).forEach(function(k) { next[k] = approvals[k] })
  var changed = false
  var decisions = []
  ;(ports || []).forEach(function(p) {
    var v = portApproval(capsFor(p.from), infoFor(p.to), p.internet)
    var had = next[p.to]
    if (had && !had.auto) { decisions.push({ id: p.id, from: p.from, to: p.to, verdict: "kept", extra: [] }); return }
    if (v.approve) {
      if (!had) { v.approve.from = p.from; next[p.to] = v.approve; changed = true }
      decisions.push({ id: p.id, from: p.from, to: p.to, verdict: "approved", extra: [] })
    } else {
      if (had) { delete next[p.to]; changed = true }
      decisions.push({ id: p.id, from: p.from, to: p.to, verdict: "asks", extra: v.extra })
    }
  })
  return { approvals: next, decisions: decisions, changed: changed }
}

// Automatic approvals already stored, checked again with today's rules
// (a migrated layout has no ports left to look at): any that no longer
// passes is withdrawn, so the widget asks.
function recheckAutoApprovals(approvals, infoFor, capsFor) {
  var ports = []
  Object.keys(approvals || {}).forEach(function(type) {
    var a = approvals[type]
    if (a && a.auto && a.from) ports.push({ id: "", from: a.from, to: type, internet: a.network === true })
  })
  return migrationApprovals(ports, approvals, infoFor, capsFor)
}

// ---------------------------------------------------------------- the Store tab

var CATEGORIES = ["news", "dev", "productivity", "time", "world", "fun", "home", "system"]

function versionKey(v) {
  return String(v || "0").split(/[.-]/).map(function(p) { return /^[0-9]+$/.test(p) ? Number(p) : p })
}
function newer(a, b) {
  var x = versionKey(a), y = versionKey(b)
  for (var i = 0; i < Math.max(x.length, y.length); i++) {
    var p = x[i] === undefined ? 0 : x[i], q = y[i] === undefined ? 0 : y[i]
    if (p === q) continue
    if (typeof p === typeof q) return p > q
    return typeof p === "number"
  }
  return false
}

// The Store tab's rows, in the store's order: the package's index, with a
// newer version store-fetch downloaded when there is one, and what the user
// already has (`records`: the scan's OWL widgets, with their `store` origin).
// Each row: { id, widgetId, name, author, description, category, version,
//   sizeText, summary, status, note, owned, modified, update }.
function storeRows(index, fetched, records, grid, cellHeight, dp) {
  var fetchedBy = {}
  ;((fetched && fetched.widgets) || []).forEach(function(w) { fetchedBy[w.id] = w })
  var mine = {}
  ;(records || []).forEach(function(r) { if (r.store && r.store.id) mine[r.store.id] = r })
  return ((index && index.widgets) || []).map(function(w) {
    var widgetId = String(w.id).replace("/", ".")
    var own = mine[w.id] || null
    var latest = fetchedBy[w.id] && newer(fetchedBy[w.id].version, w.version) ? fetchedBy[w.id].version : w.version
    var modified = !!own && !!own.owl && own.owl.sha256 !== own.store.sha256
    var cells = w.size ? Phone.homeSpec({ size: w.size, minSize: w.minSize || [1, 1] }, grid, cellHeight, dp).size : null
    return {
      id: w.id, widgetId: widgetId, name: w.name || w.id, author: w.author || String(w.id).split("/")[0],
      description: w.description || "", category: w.category || "", version: latest || "",
      sizeText: cells ? cells[0] + "\u00d7" + cells[1] : "",
      summary: w.status === "unsupported" ? "not yet on this phone: " + (w.note || "") : summary(storeCaps(w)),
      status: w.status, note: w.note || "", owned: !!own, modified: modified,
      update: !!own && !modified && newer(latest, own.store.version)
    }
  })
}

function storeCaps(w) {
  var caps = w.capabilities || []
  return { commands: (w.commands || []).filter(function(c) { return !/^(http GET |read file |read Android)/.test(c) }),
           network: caps.indexOf("network") >= 0, hosts: w.hosts || [],
           files: (w.commands || []).filter(function(c) { return /^read file /.test(c) }),
           notifications: caps.indexOf("notifications") >= 0, devices: [], terminal: false }
}

if (typeof module !== "undefined") {
  module.exports = { describe: describe, summary: summary, shortCommand: shortCommand, cardState: cardState, ICON: ICON,
                     storeRows: storeRows, newer: newer, CATEGORIES: CATEGORIES, portApproval: portApproval,
                     migrationApprovals: migrationApprovals, recheckAutoApprovals: recheckAutoApprovals }
}
