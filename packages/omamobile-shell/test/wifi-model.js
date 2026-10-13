// SPDX-License-Identifier: MIT
// Node tests for plugins/omamobile.quicksettings/WifiModel.js. Run by test/all.
"use strict"
const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "../plugins/omamobile.quicksettings/WifiModel.js"))

// Stand-ins for the Quickshell.Networking enums.
const WIFI = 1, WIRED = 2
const OPEN = 10, OWE = 9, WPA2 = 3, UNKNOWN = 11
const REASONS = { NoSecrets: 1, WifiClientDisconnected: 2, WifiClientFailed: 3, WifiAuthTimeout: 4, WifiNetworkLost: 5 }

const tests = []
const test = (name, fn) => tests.push([name, fn])

const net = (name, strength, extra) => Object.assign({ name, signalStrength: strength, security: WPA2, connected: false, known: false, stateChanging: false }, extra)

test("finds the Wi-Fi device by type, preferring a connected one", () => {
  const wired = { type: WIRED, connected: true, name: "eth0" }
  const idle = { type: WIFI, connected: false, name: "wlan1" }
  const live = { type: WIFI, connected: true, name: "wlp1s0" }
  assert.strictEqual(M.findDevice([wired, idle], WIFI), idle)
  assert.strictEqual(M.findDevice([wired, idle, live], WIFI), live)
  assert.strictEqual(M.findDevice([wired], WIFI), null)
  assert.strictEqual(M.findDevice(null, WIFI), null)
})

test("signal strength becomes a clamped whole percentage", () => {
  assert.strictEqual(M.signalPercent(0.734), 73)
  assert.strictEqual(M.signalPercent(1.2), 100)
  assert.strictEqual(M.signalPercent(-1), 0)
  assert.strictEqual(M.signalPercent(undefined), 0)
  assert.strictEqual(M.signalPercent("x"), 0)
})

test("signal buckets match the status bar", () => {
  const cases = [[0, 0], [1, 0], [20, 0], [21, 1], [40, 1], [41, 2], [60, 2], [61, 3], [80, 3], [81, 4], [100, 4], [150, 4]]
  for (const [percent, bucket] of cases) assert.strictEqual(M.signalBucket(percent), bucket, "percent " + percent)
  assert.strictEqual(M.wifiIcon(100), "󰤨")
  assert.strictEqual(M.wifiIcon(0), "󰤯")
})

test("open and OWE need no password; unknown security does", () => {
  assert.strictEqual(M.requiresCredentials(OPEN, OPEN, OWE), false)
  assert.strictEqual(M.requiresCredentials(OWE, OPEN, OWE), false)
  assert.strictEqual(M.requiresCredentials(WPA2, OPEN, OWE), true)
  assert.strictEqual(M.requiresCredentials(UNKNOWN, OPEN, OWE), true)
})

test("rows are primitives and hidden SSIDs are dropped", () => {
  const row = M.wifiRow(net("Home", 0.5, { known: true }), OPEN, OWE)
  assert.deepStrictEqual(row, { ssid: "Home", signal: 50, secured: true, connected: false, known: true, changing: false })
  assert.strictEqual(M.wifiRow(net("", 0.9), OPEN, OWE), null)
  assert.strictEqual(M.wifiRow(null, OPEN, OWE), null)
})

test("connected goes on top, the rest by signal then name", () => {
  const rows = M.buildRows([
    net("Cafe", 0.4, { security: OPEN }),
    net("Home", 0.6, { connected: true, known: true }),
    net("attic", 0.9),
    net("Barn", 0.9),
    net("", 1.0)
  ], OPEN, OWE)
  assert.strictEqual(rows.connected.ssid, "Home")
  assert.deepStrictEqual(rows.available.map(r => r.ssid), ["attic", "Barn", "Cafe"])
  assert.strictEqual(rows.available[2].secured, false)
})

test("one SSID seen twice keeps the connected, else the strongest", () => {
  let rows = M.buildRows([net("Mesh", 0.3), net("Mesh", 0.8)], OPEN, OWE)
  assert.strictEqual(rows.available.length, 1)
  assert.strictEqual(rows.available[0].signal, 80)
  rows = M.buildRows([net("Mesh", 0.3, { connected: true }), net("Mesh", 0.8)], OPEN, OWE)
  assert.strictEqual(rows.connected.signal, 30)
  assert.strictEqual(rows.available.length, 0)
})

test("nmcli terse output: escapes, Wi-Fi profiles only", () => {
  assert.deepStrictEqual(M.splitTerse("a\\:b:c\\\\d:e"), ["a:b", "c\\d", "e"])
  const text = [
    "Home:0b1c-uuid:802-11-wireless",
    "Wired connection 1:aa-uuid:802-3-ethernet",
    "Cafe\\: guest:cc-uuid:802-11-wireless",
    "lo:dd-uuid:loopback",
    ""
  ].join("\n")
  assert.deepStrictEqual(M.parseSavedConnections(text), [
    { name: "Home", uuid: "0b1c-uuid" },
    { name: "Cafe: guest", uuid: "cc-uuid" }
  ])
  assert.deepStrictEqual(M.parseSavedConnections(""), [])
})

test("saved profiles in range are not listed again", () => {
  const saved = [{ name: "office", uuid: "1" }, { name: "Home", uuid: "2" }, { name: "Attic", uuid: "3" }, { name: "Home", uuid: "4" }]
  const out = M.savedOutOfRange(saved, [{ ssid: "Home" }])
  assert.deepStrictEqual(out.map(p => p.name), ["Attic", "office"])
})

test("tap and long-press actions", () => {
  const open = { secured: false, known: false, connected: false }
  const locked = { secured: true, known: false, connected: false }
  const saved = { secured: true, known: true, connected: false }
  const live = { secured: true, known: true, connected: true }
  assert.strictEqual(M.tapAction(open), "connect")
  assert.strictEqual(M.tapAction(saved), "connect")
  assert.strictEqual(M.tapAction(locked), "password")
  assert.strictEqual(M.tapAction(live), "details")
  assert.deepStrictEqual(M.longPressActions(open), [])
  assert.deepStrictEqual(M.longPressActions(saved), ["forget"])
  assert.deepStrictEqual(M.longPressActions(live), ["disconnect", "forget"])
})

test("row status text", () => {
  const row = { secured: true, known: false, connected: false }
  assert.strictEqual(M.rowStatus(row, "", ""), "Secured")
  assert.strictEqual(M.rowStatus(Object.assign({}, row, { secured: false }), "", ""), "Open")
  assert.strictEqual(M.rowStatus(Object.assign({}, row, { known: true }), "", ""), "Saved")
  assert.strictEqual(M.rowStatus(Object.assign({}, row, { connected: true }), "", ""), "Connected")
  assert.strictEqual(M.rowStatus(row, "connect", ""), "Connecting…")
  assert.strictEqual(M.rowStatus(row, "", "Wrong password"), "Wrong password")
})

test("failures: wrong password only for secured networks, and it reprompts", () => {
  assert.strictEqual(M.failureMessage(REASONS.NoSecrets, true, REASONS), "Wrong password")
  assert.strictEqual(M.failureMessage(REASONS.WifiAuthTimeout, true, REASONS), "Wrong password")
  assert.strictEqual(M.failureMessage(REASONS.WifiAuthTimeout, false, REASONS), "Couldn't connect")
  assert.strictEqual(M.failureMessage(REASONS.WifiNetworkLost, true, REASONS), "Network out of range")
  assert.strictEqual(M.failureMessage(REASONS.WifiClientFailed, true, REASONS), "Connection failed")
  assert.strictEqual(M.shouldReprompt(REASONS.WifiAuthTimeout, true, REASONS), true)
  assert.strictEqual(M.shouldReprompt(REASONS.NoSecrets, false, REASONS), false)
  assert.strictEqual(M.shouldReprompt(REASONS.WifiNetworkLost, true, REASONS), false)
})

test("the nmcli fallback never carries the password in argv", () => {
  const argv = M.nmcliConnectArgv("Home", "wlp1s0")
  assert.deepStrictEqual(argv, ["nmcli", "--ask", "device", "wifi", "connect", "Home", "ifname", "wlp1s0"])
  assert.strictEqual(M.nmcliConnectArgv.length, 2, "takes no secret")
  assert.deepStrictEqual(M.nmcliConnectArgv("Home", ""), ["nmcli", "--ask", "device", "wifi", "connect", "Home"])
  assert.strictEqual(M.nmcliFailureMessage("Error: Connection activation failed: Secrets were required, but not provided."), "Wrong password")
  assert.strictEqual(M.nmcliFailureMessage("Error: No network with SSID 'x' found."), "Network out of range")
  assert.strictEqual(M.nmcliFailureMessage("boom"), "Couldn't connect")
})

test("list entries: sections in order, uniform fields", () => {
  const rows = M.buildRows([net("Home", 0.6, { connected: true, known: true }), net("Cafe", 0.4)], OPEN, OWE)
  const entries = M.listEntries(rows, [{ name: "Attic", uuid: "u3" }], true)
  assert.deepStrictEqual(entries.map(e => e.kind + ":" + (e.text || e.ssid)),
    ["header:Connected", "network:Home", "header:Available networks", "network:Cafe", "header:Saved, not in range", "saved:Attic"])
  const keys = Object.keys(entries[0]).sort().join()
  for (const e of entries) assert.strictEqual(Object.keys(e).sort().join(), keys)
  assert.strictEqual(entries[5].uuid, "u3")
  assert.deepStrictEqual(M.listEntries(rows, [], false), [])
  const empty = M.listEntries({ connected: null, available: [] }, [], true)
  assert.deepStrictEqual(empty.map(e => e.kind), ["header", "empty"])
})

test("sameRows compares by value", () => {
  assert.strictEqual(M.sameRows([{ a: 1 }], [{ a: 1 }]), true)
  assert.strictEqual(M.sameRows([{ a: 1 }], [{ a: 2 }]), false)
  assert.strictEqual(M.sameRows(null, undefined), true)
})

let failed = 0
for (const [name, fn] of tests) {
  try {
    fn()
    console.log("ok - wifi model: " + name)
  } catch (error) {
    failed++
    console.error("not ok - wifi model: " + name + "\n  " + String(error && error.message || error).split("\n").join("\n  "))
  }
}
process.exit(failed ? 1 : 0)
