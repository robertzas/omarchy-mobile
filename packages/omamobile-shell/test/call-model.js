// SPDX-License-Identifier: MIT
// Node tests for plugins/omamobile.call/CallModel.js. Run by test/all.
"use strict"
const assert = require("assert")
const path = require("path")
const M = require(path.join(__dirname, "../plugins/omamobile.call/CallModel.js"))

const ring = { id: "/c/1", number: "+12025550123", name: "Ada Lovelace", direction: "incoming", state: "ringing-in", startedMs: 1000, answeredMs: 0 }
const active = { id: "/c/2", number: "2025550147", name: "", direction: "outgoing", state: "active", startedMs: 500, answeredMs: 2000 }
const line = (calls, extra) => JSON.stringify(Object.assign({ agent: true, calls: calls, muted: false, route: "earpiece", replies: ["I'll call you back."] }, extra || {}))

// Parsing
let s = M.parseLine(line([ring]))
assert.strictEqual(s.calls.length, 1)
assert.strictEqual(s.calls[0].name, "Ada Lovelace")
assert.deepStrictEqual(s.replies, ["I'll call you back."])
assert.strictEqual(M.parseLine("not json"), null, "a bad line keeps the old state")
assert.strictEqual(M.parseLine(line([{ number: "1" }])).calls.length, 0, "a call without an id is dropped")
assert.strictEqual(M.parseLine(JSON.stringify({ agent: true, replies: ["a", "", 3, "b"] })).replies.join(), "a,b")
console.log("ok - call model: parses the watcher's lines and drops bad calls")

// Modes
assert.strictEqual(M.mode(M.parseLine(line([ring])), true, false), "incoming")
assert.strictEqual(M.mode(M.parseLine(line([ring])), false, false), "heads-up")
assert.strictEqual(M.mode(M.parseLine(line([active])), true, false), "in-call")
assert.strictEqual(M.mode(M.parseLine(line([active])), true, true), "in-call-mini")
assert.strictEqual(M.mode(M.parseLine(line([active])), false, false), "chip")
const waiting = Object.assign({}, ring, { state: "waiting" })
assert.strictEqual(M.mode(M.parseLine(line([active, waiting])), true, false), "heads-up", "a waiting call never covers the call in progress")
assert.strictEqual(M.mode(M.parseLine(line([Object.assign({}, ring, { state: "terminated" })])), true, false), "none")
assert.strictEqual(M.mode(M.parseLine(JSON.stringify({ agent: false, calls: [ring] })), true, false), "none", "no agent, no card")
assert.strictEqual(M.mode(null, true, false), "none")
const quiet = Object.assign({}, ring, { silenced: true })
assert.strictEqual(M.mode(M.parseLine(line([quiet])), true, false), "none", "a silenced call gets no card")
assert.strictEqual(M.mode(M.parseLine(line([active, Object.assign({}, quiet, { state: "waiting" })])), true, false), "in-call", "nor a silenced waiting call")
console.log("ok - call model: incoming over the lock, heads-up when unlocked or waiting, in-call over the lock, a chip otherwise; silenced calls get none")

// Labels
assert.strictEqual(M.title(ring), "Ada Lovelace")
assert.strictEqual(M.subtitle(ring), "+1 202-555-0123")
assert.strictEqual(M.title(active), "202-555-0147")
assert.strictEqual(M.subtitle(active), "")
assert.strictEqual(M.title({ id: "x", number: "", name: "" }), "Unknown caller")
assert.strictEqual(M.formatNumber("+447700900123"), "+447700900123", "other numbers as given")
assert.strictEqual(M.initials(ring), "AL")
assert.strictEqual(M.initials({ name: "  cher " }), "C")
assert.strictEqual(M.initials(active), "#")
assert.strictEqual(M.initials({ name: "", number: "" }), "?")
assert.strictEqual(M.stateLabel(ring, 0), "Incoming call")
assert.strictEqual(M.stateLabel(waiting, 0), "Call waiting")
assert.strictEqual(M.stateLabel(active, 2000 + 65000), "1:05")
assert.strictEqual(M.duration(3723000), "1:02:03")
assert.strictEqual(M.duration(-5), "0:00")
console.log("ok - call model: names, numbers, initials, states and durations")

// Requests
assert.deepStrictEqual(M.answerArgv("/c/1"), ["busctl", "--user", "call", "org.omamobile.Phone1", "/org/omamobile/Phone1", "org.omamobile.Phone1", "Answer", "s", "/c/1"])
assert.strictEqual(M.declineArgv("/c/1")[6], "Decline")
assert.deepStrictEqual(M.hangupArgv().slice(-2), ["s", ""], "an empty id ends every call")
assert.deepStrictEqual(M.muteArgv(true).slice(-2), ["b", "true"])
assert.deepStrictEqual(M.routeArgv("speaker").slice(-1), ["speaker"])
assert.deepStrictEqual(M.routeArgv("bluetooth").slice(-1), ["earpiece"], "the card toggles earpiece and speaker only")
assert.deepStrictEqual(M.replyArgv("+12025550123", "On my way").slice(3, 10), ["org.omamobile.Messages1", "/org/omamobile/Messages1", "org.omamobile.Messages1", "Send", "ss", "+12025550123", "On my way"])
assert.deepStrictEqual(M.openPhoneArgv(ring), ["omaphone", "--incoming", "/c/1"])
assert.deepStrictEqual(M.openPhoneArgv(active), ["omaphone", "--in-call"])
assert.ok(M.answerArgv("x; rm -rf ~").every((a) => typeof a === "string"), "arguments stay argv entries")
console.log("ok - call model: busctl requests, never a shell, and no dialling")

// Swipe
assert.strictEqual(M.swipeResult(0.7), "answer")
assert.strictEqual(M.swipeResult(-0.65), "decline")
assert.strictEqual(M.swipeResult(0.3), "none")
console.log("ok - call model: swipe up answers, down declines, short drags spring back")
