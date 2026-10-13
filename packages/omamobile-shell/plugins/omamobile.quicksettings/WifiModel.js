// SPDX-License-Identifier: MIT
// Pure helpers for the Wi-Fi picker (WifiPanel.qml). Nothing here touches a
// QObject's methods: rows are plain snapshots, so the QML side can rebuild
// its list without holding live WifiNetwork wrappers (NetworkManager churn
// can destroy those under a delegate; Omarchy's network panel found the same).
// Node runs these in test/wifi-model.js through the module.exports below.

var ICONS = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]

// The Wi-Fi device by type, never by name: a connected one wins.
function findDevice(devices, wifiType) {
  var list = devices || []
  var fallback = null
  for (var i = 0; i < list.length; i++) {
    var device = list[i]
    if (!device || device.type !== wifiType) continue
    if (device.connected) return device
    if (!fallback) fallback = device
  }
  return fallback
}

// WifiNetwork.signalStrength is 0..1; rows carry a whole percentage.
function signalPercent(strength) {
  var value = Number(strength)
  if (!isFinite(value) || value <= 0) return 0
  return Math.max(0, Math.min(100, Math.round(value * 100)))
}

// 0..4 bars, the same buckets as the status bar and Omarchy's panel.
function signalBucket(percent) {
  var value = Number(percent) || 0
  return Math.max(0, Math.min(4, Math.ceil(value / 20) - 1))
}

function wifiIcon(percent) {
  return ICONS[signalBucket(percent)]
}

// Open and OWE (Enhanced Open) need no password. Unknown security counts as
// secured, the conservative side.
function requiresCredentials(security, openSecurity, oweSecurity) {
  return security !== openSecurity && security !== oweSecurity
}

// One list row from a WifiNetwork-shaped object; primitives only.
function wifiRow(network, openSecurity, oweSecurity) {
  if (!network || !network.name) return null
  return {
    ssid: String(network.name),
    signal: signalPercent(network.signalStrength),
    secured: requiresCredentials(network.security, openSecurity, oweSecurity),
    connected: !!network.connected,
    known: !!network.known,
    changing: !!network.stateChanging
  }
}

// Strongest first; equal signal falls back to the name so rows don't
// shuffle between scans.
function sortBySignal(rows) {
  var list = Array.isArray(rows) ? rows.slice() : []
  list.sort(function(a, b) {
    if (b.signal !== a.signal) return b.signal - a.signal
    return a.ssid.toLowerCase() < b.ssid.toLowerCase() ? -1 : a.ssid.toLowerCase() > b.ssid.toLowerCase() ? 1 : 0
  })
  return list
}

// Networks -> { connected: row|null, available: [rows] }. Hidden SSIDs are
// dropped; one SSID seen twice keeps the connected (else strongest) copy.
function buildRows(networks, openSecurity, oweSecurity) {
  var bySsid = {}
  var list = networks || []
  for (var i = 0; i < list.length; i++) {
    var row = wifiRow(list[i], openSecurity, oweSecurity)
    if (!row) continue
    var seen = bySsid[row.ssid]
    if (!seen || row.connected || (!seen.connected && row.signal > seen.signal)) bySsid[row.ssid] = row
  }
  var connected = null
  var available = []
  for (var ssid in bySsid) {
    if (bySsid[ssid].connected && !connected) connected = bySsid[ssid]
    else available.push(bySsid[ssid])
  }
  return { connected: connected, available: sortBySignal(available) }
}

// Split one `nmcli -t` line on unescaped colons; nmcli escapes ':' and '\'.
function splitTerse(line) {
  var fields = []
  var current = ""
  var text = String(line || "")
  for (var i = 0; i < text.length; i++) {
    var ch = text[i]
    if (ch === "\\" && i + 1 < text.length) { current += text[++i]; continue }
    if (ch === ":") { fields.push(current); current = ""; continue }
    current += ch
  }
  fields.push(current)
  return fields
}

// `nmcli -t -f NAME,UUID,TYPE connection show` -> saved Wi-Fi profiles.
function parseSavedConnections(text) {
  var saved = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i]) continue
    var fields = splitTerse(lines[i])
    if (fields.length < 3 || fields[2] !== "802-11-wireless" || !fields[0]) continue
    saved.push({ name: fields[0], uuid: fields[1] })
  }
  return saved
}

// Saved profiles with no network in range, by name. NetworkManager names a
// profile after its SSID unless someone renamed it, so the name is the match.
function savedOutOfRange(saved, rows) {
  var visible = {}
  var list = rows || []
  for (var i = 0; i < list.length; i++) if (list[i]) visible[list[i].ssid] = true
  var result = []
  var seen = {}
  var profiles = saved || []
  for (var j = 0; j < profiles.length; j++) {
    var name = profiles[j].name
    if (visible[name] || seen[name]) continue
    seen[name] = true
    result.push(profiles[j])
  }
  result.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
  return result
}

// What a tap on a row does: "details" (connected: the action sheet),
// "connect" (open or saved) or "password" (secured and unsaved).
function tapAction(row) {
  if (!row) return ""
  if (row.connected) return "details"
  if (!row.secured || row.known) return "connect"
  return "password"
}

// Long-press actions for a row, in sheet order.
function longPressActions(row) {
  var actions = []
  if (!row) return actions
  if (row.connected) actions.push("disconnect")
  if (row.known || row.connected) actions.push("forget")
  return actions
}

function rowStatus(row, busyKind, failure) {
  if (!row) return ""
  if (failure) return failure
  if (busyKind === "connect") return "Connecting…"
  if (busyKind === "disconnect") return "Disconnecting…"
  if (busyKind === "forget") return "Forgetting…"
  if (row.connected) return "Connected"
  if (row.known) return "Saved"
  return row.secured ? "Secured" : "Open"
}

// ConnectionFailReason -> message. `reasons` maps the enum's names to its
// values so this stays plain JS.
function failureMessage(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (needsCredentials && (reason === r.NoSecrets || reason === r.WifiAuthTimeout)) return "Wrong password"
  if (reason === r.WifiNetworkLost) return "Network out of range"
  if (reason === r.WifiClientDisconnected) return "Disconnected"
  if (reason === r.WifiClientFailed) return "Connection failed"
  return "Couldn't connect"
}

// A wrong password reopens the password sheet so it can be typed again.
function shouldReprompt(reason, needsCredentials, reasons) {
  var r = reasons || {}
  return !!needsCredentials && (reason === r.NoSecrets || reason === r.WifiAuthTimeout)
}

// The nmcli fallback for a Quickshell without WifiNetwork.connectWithPsk.
// The password is never an argument: `--ask` makes nmcli read it from stdin.
function nmcliConnectArgv(ssid, ifname) {
  var argv = ["nmcli", "--ask", "device", "wifi", "connect", String(ssid)]
  if (ifname) argv.push("ifname", String(ifname))
  return argv
}

function nmcliFailureMessage(stderr) {
  var text = String(stderr || "")
  if (/secrets were required|802-1x|psk|password|authentication/i.test(text)) return "Wrong password"
  if (/no network with ssid/i.test(text)) return "Network out of range"
  return "Couldn't connect"
}

// The picker's one flat list: section headers, network rows and saved
// profiles out of range. Every entry has every field, so delegates never
// read undefined.
function entry(kind, fields) {
  var e = { kind: kind, text: "", ssid: "", signal: 0, secured: false, connected: false, known: false, changing: false, uuid: "" }
  for (var key in fields) e[key] = fields[key]
  return e
}

function listEntries(rows, saved, wifiOn) {
  var entries = []
  if (!wifiOn) return entries
  var value = rows || { connected: null, available: [] }
  if (value.connected) {
    entries.push(entry("header", { text: "Connected" }))
    entries.push(entry("network", value.connected))
  }
  entries.push(entry("header", { text: "Available networks" }))
  var available = value.available || []
  for (var i = 0; i < available.length; i++) entries.push(entry("network", available[i]))
  if (available.length === 0) entries.push(entry("empty", { text: "Searching for networks…" }))
  var profiles = saved || []
  if (profiles.length > 0) {
    entries.push(entry("header", { text: "Saved, not in range" }))
    for (var j = 0; j < profiles.length; j++)
      entries.push(entry("saved", { ssid: profiles[j].name, uuid: profiles[j].uuid, known: true }))
  }
  return entries
}

// Rows reassign the list model only when something visible changed, so a
// row being pressed isn't rebuilt under the finger.
function sameRows(a, b) {
  return JSON.stringify(a || null) === JSON.stringify(b || null)
}

if (typeof module !== "undefined") {
  module.exports = {
    findDevice: findDevice,
    signalPercent: signalPercent,
    signalBucket: signalBucket,
    wifiIcon: wifiIcon,
    requiresCredentials: requiresCredentials,
    wifiRow: wifiRow,
    sortBySignal: sortBySignal,
    buildRows: buildRows,
    splitTerse: splitTerse,
    parseSavedConnections: parseSavedConnections,
    savedOutOfRange: savedOutOfRange,
    tapAction: tapAction,
    longPressActions: longPressActions,
    rowStatus: rowStatus,
    failureMessage: failureMessage,
    shouldReprompt: shouldReprompt,
    nmcliConnectArgv: nmcliConnectArgv,
    nmcliFailureMessage: nmcliFailureMessage,
    listEntries: listEntries,
    sameRows: sameRows
  }
}
