// SPDX-License-Identifier: MIT
import QtQuick
import "values.js" as V
import "compiler.js" as Compiler
import "runtime.js" as Runtime

// One live OWL widget: compiles its text, keeps its instance (state,
// source values, history), runs its sources and triggers when the
// scheduler ticks, and hands the render tree to an OwlView.
//
// Everything that leaves the widget goes through `host` (OwlPhoneHost on
// the phone, a fixture host in tests): commands, web requests, files,
// actions, persisted state. So the phone's limits and checks live in one
// place, and this file needs no Quickshell types.
//
// host: runSource(widget, spec, arg, headers, done), android(widget, kind, done),
//       act(widget, name, args), runInto(widget, command, done),
//       loadState(key), saveState(key, data), report(widget, message)
Item {
  id: widget

  property string text: ""
  // Persisted state belongs to the placement (plan §1.4: settings per placement).
  property string stateKey: ""
  property var host: null
  // Theme name -> ARGB.
  property var themeColors: ({})
  // cols, rows, tileWidth, tileHeight, screenWidth, screenHeight, corners, linux.
  property var tileVars: ({})
  // Sources and `every` run only while the widget is shown (its page or a
  // neighbour, and the home screen not covered).
  property bool active: false
  // The approval this widget runs under ({ commands, network }), for the host.
  property var approval: null

  property var program: null
  property var instance: null
  property var tree: null
  property string error: ""
  property var problems: []
  readonly property bool animating: !!widget.tree && widget.tree.readsTime === true

  // ---------------------------------------------------------------- loading

  // Once every binding has its value (stateKey, host), not mid-way.
  onTextChanged: Qt.callLater(widget.load)
  Component.onCompleted: Qt.callLater(widget.load)

  function load() {
    widget.instance = null
    widget.tree = null
    widget.error = ""
    widget.problems = []
    widget.lastRun = ({})
    widget.lastEvery = ({})
    if (!widget.text) return
    try {
      widget.program = Compiler.compile(widget.text)
    } catch (e) {
      widget.program = null
      widget.error = Compiler.formatError(widget.text, e)
      return
    }
    const saved = widget.host && widget.stateKey ? widget.host.loadState(widget.stateKey) : null
    widget.instance = new Runtime.Instance(widget.program, widget.bridge, saved || {})
    widget.render()
    if (widget.active) widget.refresh()
  }

  // What the instance calls back into.
  readonly property var bridge: ({
    theme: function(name) {
      const v = widget.themeColors[name]
      return v === undefined ? null : v
    },
    tile: function(name) { return widget.tileVars ? widget.tileVars[name] : null },
    act: function(name, args) { widget.act(name, args) },
    runInto: function(command, slot) {
      if (widget.host) widget.host.runInto(widget, command, function(out) { if (widget.instance) widget.instance.setState(slot, out) })
    },
    report: function(message) { widget.report(message) },
    changed: function() { widget.changed() },
    allowTrigger: function(i) { return widget.allowTrigger(i) }
  })

  onThemeColorsChanged: if (widget.instance) { widget.instance.invalidate(); widget.render() }
  onTileVarsChanged: if (widget.instance) { widget.instance.invalidate(); widget.render() }
  onActiveChanged: if (widget.active) widget.refresh()

  // ---------------------------------------------------------------- drawing

  function changed() {
    widget.saveSoon()
    Qt.callLater(widget.render)
  }

  function render() {
    if (widget.instance) widget.tree = widget.instance.render(false)
  }

  function frame(seconds) {
    if (!widget.instance) return
    widget.instance.frame(seconds)
    if (widget.animating) widget.render()
  }

  // Handlers from the view: taps, drags, slider and input values.
  function runHandler(handler, args) {
    if (typeof handler !== "function") return
    handler.apply(null, args)
    // After an action, the widget refreshes its sources (the guide).
    widget.refreshSoon()
  }

  // ---------------------------------------------------------------- errors

  function report(message) {
    const line = String(message)
    const next = widget.problems.filter(function(p) { return p !== line })
    next.push(line)
    widget.problems = next.slice(-20)
    if (widget.host) widget.host.report(widget, line)
  }

  // ---------------------------------------------------------------- triggers

  // At most 10 runs of one trigger a second; more is held back and reported.
  property var triggerRuns: ({})
  function allowTrigger(i) {
    const now = Date.now()
    const runs = (widget.triggerRuns[i] || []).filter(function(t) { return now - t < 1000 })
    if (runs.length >= 10) {
      widget.report("a trigger ran more than 10 times in a second and was held back")
      return false
    }
    runs.push(now)
    widget.triggerRuns[i] = runs
    return true
  }

  // ---------------------------------------------------------------- sources

  property var lastRun: ({})
  property var lastEvery: ({})
  property var running: ({})

  // Called by the scheduler about once a second. `at` triggers tick even
  // while the widget is hidden; sources and `every` only while it shows.
  function tick(now) {
    if (!widget.instance) return
    widget.instance.tick(now)
    if (!widget.active) return
    const specs = widget.instance.sources()
    for (let i = 0; i < specs.length; i++) {
      const s = specs[i]
      const every = widget.host ? widget.host.interval(s) : s.every
      const last = widget.lastRun[s.slot]
      // Aligned to the period: `every 1m` turns over on the minute.
      if (last === undefined || Math.floor(now / every) !== Math.floor(last / every)) widget.runSource(s, now)
    }
    const triggers = widget.instance.everyTriggers()
    for (let k = 0; k < triggers.length; k++) {
      const t = triggers[k]
      const before = widget.lastEvery[t.index]
      if (before === undefined) { widget.lastEvery[t.index] = now; continue }
      if (now - before >= t.seconds) {
        widget.lastEvery[t.index] = now
        widget.instance.fire(t.index)
      }
    }
  }

  function refresh() {
    widget.lastRun = ({})
    // A host may fix the clock (the screenshot harness does).
    widget.tick(widget.host && widget.host.now ? widget.host.now() : Date.now() / 1000)
  }
  function refreshSoon() { refreshTimer.restart() }
  Timer { id: refreshTimer; interval: 250; onTriggered: widget.refresh() }

  function runSource(s, now) {
    widget.lastRun[s.slot] = now
    if (s.kind === "clock") {
      widget.instance.setSource(s.slot, Math.floor(now))
      return
    }
    if (!widget.host || widget.running[s.slot]) return
    widget.running[s.slot] = true
    const finish = function(result) {
      widget.running[s.slot] = false
      if (!widget.instance || !result) return
      if (result.error) { widget.report(s.name + ": " + result.error); return }
      if (result.value !== undefined) { widget.instance.setSource(s.slot, V.fromPlain(result.value)); return }
      if (s.status) {
        let out = result.out
        if (s.json) { try { out = V.parseJson(String(out).trim()) } catch (e) { out = null } }
        else out = String(out).replace(/\s+$/, "")
        widget.instance.setSource(s.slot, new Map([["out", out], ["err", String(result.err || "").replace(/\s+$/, "")],
                                                   ["code", result.code], ["ok", !!result.ok]]))
        return
      }
      if (!result.ok && result.err) widget.report(s.name + ": " + String(result.err).split("\n")[0])
      widget.instance.setSource(s.slot, String(result.out === undefined ? "" : result.out))
    }
    if (s.kind.indexOf("android.") === 0) widget.host.android(widget, s.kind.slice(8), finish)
    else widget.host.runSource(widget, s, s.arg(), s.headers(), finish)
  }

  // ---------------------------------------------------------------- actions

  function act(name, args) {
    if (name === "refresh") { widget.refreshSoon(); return }
    if (widget.host) widget.host.act(widget, name, args)
  }

  // ---------------------------------------------------------------- persisted state

  function saveSoon() { if (widget.stateKey) saveTimer.restart() }
  Timer {
    id: saveTimer
    interval: 1000
    onTriggered: if (widget.instance && widget.host && widget.stateKey) widget.host.saveState(widget.stateKey, widget.instance.persisted())
  }
  Component.onDestruction: if (widget.instance && widget.host && widget.stateKey && saveTimer.running) widget.host.saveState(widget.stateKey, widget.instance.persisted())
}
