// SPDX-License-Identifier: MIT
// Pure helpers for the phone launcher: settings merging and the rule that
// decides whether the bottom bar's text is an app search or a prompt for the
// coding agent.

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// Manifest defaults, overlaid with the plugin's entry in shell.json
// (`plugins: [{ "id": "omamobile.launcher", "columns": 5, ... }]`).
function mergedSettings(defaults, config, pluginId) {
  var out = {}
  var base = isPlainObject(defaults) ? defaults : {}
  for (var key in base) out[key] = base[key]
  var plugins = isPlainObject(config) && Array.isArray(config.plugins) ? config.plugins : []
  for (var i = 0; i < plugins.length; i++) {
    var entry = plugins[i]
    if (!isPlainObject(entry) || entry.id !== pluginId) continue
    for (var k in entry) if (k !== "id") out[k] = entry[k]
  }
  return out
}

function argv(value, fallback) {
  if (Array.isArray(value)) return value.map(function(part) { return String(part) })
  if (typeof value === "string" && value.trim()) return value.trim().split(/\s+/)
  return fallback.slice()
}

function wordCount(query) {
  var text = String(query || "").trim()
  return text ? text.split(/\s+/).length : 0
}

// A short query that names an app is a search. Text reads as a prompt once it
// has enough words to be a sentence, ends like one, or matches no app at all.
function looksLikePrompt(query, appMatches, sentenceWords) {
  var text = String(query || "").trim()
  if (!text) return false
  if (wordCount(text) >= Math.max(2, sentenceWords || 3)) return true
  if (/[?.!]$/.test(text)) return true
  return appMatches === 0
}

// Display names for the agents omarchy-default-agent knows, as Omarchy
// names them. Anything else shows its id.
var AGENT_NAMES = {
  pi: "Pi", omp: "Oh My Pi", opencode: "OpenCode", claude: "Claude Code",
  codex: "Codex", crush: "Crush", grok: "Grok", gemini: "Gemini",
  openclaw: "OpenClaw", hermes: "Hermes", copilot: "GitHub Copilot",
  muse: "Muse Code", "cursor-agent": "Cursor CLI"
}

// The agent id from ~/.config/omarchy/defaults/agent (first line), or "".
function agentId(fileText) {
  return String(fileText || "").split("\n")[0].trim()
}

function agentName(id) {
  return id ? (AGENT_NAMES[id] || id) : ""
}

// Every launch goes through omamobile-launch (bin/), which gives what it
// starts a new empty workspace of its own, or focuses an app that is already
// open there: one app per screen, as on Android.
var LAUNCH = "omamobile-launch"

function appArgv(desktopId) {
  return [LAUNCH, "app", String(desktopId || "")]
}

// Omarchy launches the user's chosen agent, in its own terminal, with the
// prompt as one argument. Without a chosen agent, open Omarchy's picker.
function promptArgv(prompt) {
  return [LAUNCH, "cmd", "--", "omarchy-agent-prompt", String(prompt || "").trim()]
}

var PICK_AGENT_ARGV = ["omarchy", "menu", "summon", "setup.default.agent"]

if (typeof module !== "undefined") {
  module.exports = {
    mergedSettings: mergedSettings,
    argv: argv,
    wordCount: wordCount,
    looksLikePrompt: looksLikePrompt,
    agentId: agentId,
    agentName: agentName,
    LAUNCH: LAUNCH,
    appArgv: appArgv,
    promptArgv: promptArgv,
    PICK_AGENT_ARGV: PICK_AGENT_ARGV
  }
}
