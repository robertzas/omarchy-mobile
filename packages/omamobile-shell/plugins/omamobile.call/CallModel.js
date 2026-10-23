// SPDX-License-Identifier: MIT
// The call card's state and its requests to the agent, kept free of QML so
// test/call-model.js runs it under Node through the module.exports below.
//
// The card follows omatel's agent (org.omamobile.Phone1, through
// bin/omamobile-call-watch): it shows what the calls and the lock call for,
// and asks the agent to answer, decline, hang up, mute or switch the route.
// It never dials (only the Phone app does, with its emergency checks) and
// offers nothing but call actions over the lock.

var PHONE_NAME = "org.omamobile.Phone1"
var PHONE_PATH = "/org/omamobile/Phone1"
var PHONE_IFACE = "org.omamobile.Phone1"
var MESSAGES_NAME = "org.omamobile.Messages1"
var MESSAGES_PATH = "/org/omamobile/Messages1"
var MESSAGES_IFACE = "org.omamobile.Messages1"

var RINGING = ["ringing-in", "waiting"]
var LIVE = ["dialing", "ringing-out", "active", "held"]

function emptyState() {
  return { agent: false, calls: [], muted: false, route: "earpiece", audioRouting: false, replies: [] }
}

// One line from omamobile-call-watch: the agent's whole state. A line that
// doesn't parse leaves the state as it was (null).
function parseLine(line) {
  var v
  try { v = JSON.parse(String(line || "")) } catch (e) { return null }
  if (!v || typeof v !== "object") return null
  var s = emptyState()
  s.agent = v.agent === true
  s.muted = v.muted === true
  s.audioRouting = v.audioRouting === true
  if (typeof v.route === "string" && v.route.length) s.route = v.route
  if (Array.isArray(v.replies))
    s.replies = v.replies.filter(function(r) { return typeof r === "string" && r.length > 0 }).slice(0, 6)
  if (Array.isArray(v.calls)) {
    s.calls = v.calls.filter(function(c) { return c && typeof c.id === "string" && c.id.length > 0 }).map(function(c) {
      return {
        id: c.id,
        number: typeof c.number === "string" ? c.number : "",
        name: typeof c.name === "string" ? c.name : "",
        direction: c.direction === "outgoing" ? "outgoing" : "incoming",
        state: typeof c.state === "string" ? c.state : "unknown",
        startedMs: Number(c.startedMs) || 0,
        answeredMs: Number(c.answeredMs) || 0,
        silenced: c.silenced === true
      }
    })
  }
  return s
}

function isRinging(call) { return !!call && RINGING.indexOf(call.state) !== -1 }
function isLive(call) { return !!call && LIVE.indexOf(call.state) !== -1 }

// The call that rings (the newest), or null. A call the agent silenced
// (Do Not Disturb, or an unknown caller) gets no card: it keeps its quiet
// notification, as on Android.
function ringing(calls) {
  var r = null
  for (var i = 0; i < calls.length; i++)
    if (isRinging(calls[i]) && !calls[i].silenced && (!r || calls[i].startedMs >= r.startedMs)) r = calls[i]
  return r
}

// The call in progress (active first, then held, dialing or ringing out), or null.
function current(calls) {
  var order = ["active", "held", "dialing", "ringing-out"]
  for (var o = 0; o < order.length; o++)
    for (var i = 0; i < calls.length; i++)
      if (calls[i].state === order[o]) return calls[i]
  return null
}

// What the shell shows:
//   "none"      nothing;
//   "incoming"  a call rings on a locked phone: the full-screen card;
//   "heads-up"  a call rings on an unlocked phone, or a second call waits
//               during one: the card at the top;
//   "in-call"   a call is in progress on a locked phone: full-screen
//               controls over the lock (they fold away to "in-call-mini" so
//               the lock's own unlock is reachable);
//   "chip"      a call is in progress on an unlocked phone: only the status
//               bar's chip (the Phone app has the in-call screen).
function mode(state, locked, folded) {
  if (!state || !state.agent) return "none"
  var ring = ringing(state.calls)
  var live = current(state.calls)
  if (ring && !live) return locked ? "incoming" : "heads-up"
  if (ring && live) return "heads-up"
  if (live) {
    if (!locked) return "chip"
    return folded ? "in-call-mini" : "in-call"
  }
  return "none"
}

// The caller as shown: the contact's name, else the number, else "Unknown".
function title(call) {
  if (!call) return ""
  if (call.name) return call.name
  if (call.number) return formatNumber(call.number)
  return "Unknown caller"
}

// The line under the title: the number when a name is shown.
function subtitle(call) {
  if (!call || !call.name || !call.number) return ""
  return formatNumber(call.number)
}

// A light grouping for North American numbers, the rest as given. The
// agent already hides nothing; this is only spacing.
function formatNumber(n) {
  var s = String(n || "")
  var m = s.match(/^\+1(\d{3})(\d{3})(\d{4})$/)
  if (m) return "+1 " + m[1] + "-" + m[2] + "-" + m[3]
  m = s.match(/^(\d{3})(\d{3})(\d{4})$/)
  if (m) return m[1] + "-" + m[2] + "-" + m[3]
  return s
}

// Up to two letters for the avatar; "#" for a bare number, "?" for nothing.
function initials(call) {
  if (!call) return "?"
  var name = String(call.name || "").trim()
  if (!name) return call.number ? "#" : "?"
  var words = name.split(/\s+/).filter(function(w) { return /[A-Za-z0-9À-￿]/.test(w.charAt(0)) })
  if (!words.length) return name.charAt(0).toUpperCase()
  var a = words[0].charAt(0), b = words.length > 1 ? words[words.length - 1].charAt(0) : ""
  return (a + b).toUpperCase()
}

// The state line: "Incoming call", "Call waiting", "Calling…", "On hold",
// or the elapsed time of an answered call.
function stateLabel(call, nowMs) {
  if (!call) return ""
  switch (call.state) {
  case "ringing-in": return "Incoming call"
  case "waiting": return "Call waiting"
  case "dialing": return "Calling…"
  case "ringing-out": return "Ringing…"
  case "held": return "On hold"
  case "active": return call.answeredMs > 0 ? duration(nowMs - call.answeredMs) : "Connected"
  case "terminated": return "Call ended"
  }
  return ""
}

// "0:07", "12:34", "1:02:03".
function duration(ms) {
  var t = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
  var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
  var ss = (s < 10 ? "0" : "") + s
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
  return m + ":" + ss
}

// ---------------------------------------------------------------- requests
// busctl, never a shell; the agent checks every id itself.

function phoneArgv(method, signature, args) {
  return ["busctl", "--user", "call", PHONE_NAME, PHONE_PATH, PHONE_IFACE, method].concat(signature ? [signature] : [], args || [])
}

function answerArgv(id) { return phoneArgv("Answer", "s", [String(id)]) }
function declineArgv(id) { return phoneArgv("Decline", "s", [String(id)]) }
function hangupArgv(id) { return phoneArgv("Hangup", "s", [String(id || "")]) }
function muteArgv(on) { return phoneArgv("SetMute", "b", [on ? "true" : "false"]) }

// Earpiece and speaker toggle; Bluetooth is left to the Phone app.
function routeArgv(route) { return phoneArgv("SetRoute", "s", [route === "speaker" ? "speaker" : "earpiece"]) }

// A canned reply goes to the caller's number, and the call is declined.
function replyArgv(number, text) {
  return ["busctl", "--user", "call", MESSAGES_NAME, MESSAGES_PATH, MESSAGES_IFACE, "Send", "ss", String(number), String(text)]
}

// The Phone app's in-call screen, for an unlocked phone.
function openPhoneArgv(call) {
  if (call && isRinging(call)) return ["omaphone", "--incoming", String(call.id)]
  return ["omaphone", "--in-call"]
}

// Answer when the handle was dragged up past `threshold` (0..1 of the
// travel), decline when dragged down past it, otherwise spring back.
function swipeResult(fraction, threshold) {
  var t = threshold || 0.6
  if (fraction >= t) return "answer"
  if (fraction <= -t) return "decline"
  return "none"
}

if (typeof module !== "undefined") {
  module.exports = {
    PHONE_NAME: PHONE_NAME, PHONE_PATH: PHONE_PATH, MESSAGES_NAME: MESSAGES_NAME,
    emptyState: emptyState, parseLine: parseLine, isRinging: isRinging, isLive: isLive,
    ringing: ringing, current: current, mode: mode, title: title, subtitle: subtitle,
    formatNumber: formatNumber, initials: initials, stateLabel: stateLabel, duration: duration,
    answerArgv: answerArgv, declineArgv: declineArgv, hangupArgv: hangupArgv, muteArgv: muteArgv,
    routeArgv: routeArgv, replyArgv: replyArgv, openPhoneArgv: openPhoneArgv, swipeResult: swipeResult
  }
}
