// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io
import "HomeModel.js" as HomeModel
import "owl/phone.js" as Phone

// Everything an OWL widget reaches outside itself goes through here
// (docs/WIDGET-INTEROP-PLAN.md §2.5, §3.3, §3.4): its commands (`bash -c`,
// as the language defines them, under `timeout`, output cut at 64 KiB),
// web requests (GET, timeout, 1 MB), files (1 MB), the android.* sources
// answered from Linux, actions, persisted state and the error log. One
// instance serves the whole home screen; the checks and limits live here.
//
// A widget only gets here once its exact list of commands, URLs and files
// is approved (OwlCell). Commands and requests that use the internet run
// only when that approval turned the internet on.
QtObject {
  id: host

  // Set by Home.qml.
  property var home: null
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omamobile/owl"

  // ---------------------------------------------------------------- policy

  function approvalOf(widget) { return widget && widget.approval ? widget.approval : null }
  function networkAllowed(widget) {
    const a = host.approvalOf(widget)
    return !!a && a.network === true
  }
  // Whether a command reaches the network (curl, wget, ...): then it waits
  // for the internet to be turned on.
  function usesNetwork(command) {
    return Phone.capabilities({ commands: [String(command)], requires: {} }).network
  }

  // The phone's minimum intervals (plan §3.3).
  function interval(spec) { return Phone.sourceLimits(spec, false).every }

  // ---------------------------------------------------------------- sources

  property int streams: 0

  function runSource(widget, spec, arg, headers, done) {
    if (spec.kind === "http") {
      if (!host.networkAllowed(widget)) { done({ error: "the internet is off for this widget" }); return }
      host.get(arg, headers, Phone.sourceLimits(spec, false).timeout, spec, done)
      return
    }
    if (spec.kind === "file") { host.readFile(arg, done); return }
    if (spec.kind === "cmd") {
      if (host.usesNetwork(arg) && !host.networkAllowed(widget)) { done({ error: "the internet is off for this widget" }); return }
      host.command(widget, arg, Phone.sourceLimits(spec, false).timeout, done)
      return
    }
    // stream: not served in this milestone; it reads as a command once.
    if (spec.kind === "stream") { done({ error: "stream sources aren't served on the phone yet" }); return }
    done({ error: "unknown source " + spec.kind })
  }

  function command(widget, text, seconds, done) {
    const proc = processComponent.createObject(host, {
      command: ["timeout", "-k", "2", String(Math.max(1, Math.min(Phone.LIMITS.timeoutMax, seconds))), "bash", "-c", String(text)]
    })
    proc.done = function(code, out, err) {
      done({ code: code, ok: code === 0, out: out.slice(0, Phone.LIMITS.cmdOutput), err: err.slice(0, Phone.LIMITS.cmdOutput) })
    }
    proc.running = true
  }

  function get(url, headers, seconds, spec, done) {
    const xhr = new XMLHttpRequest()
    let finished = false
    const timer = timerComponent.createObject(host, { interval: seconds * 1000 })
    timer.triggered.connect(function() {
      if (finished) return
      finished = true
      xhr.abort()
      timer.destroy()
      done(spec.status ? { code: 124, ok: false, out: "", err: "timed out" } : { error: "timed out" })
    })
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || finished) return
      finished = true
      timer.destroy()
      const body = String(xhr.responseText || "")
      if (body.length > Phone.LIMITS.bodyBytes) { done({ error: "the answer is over 1 MB" }); return }
      const ok = xhr.status >= 200 && xhr.status < 300
      done({ code: xhr.status, ok: ok, out: body, err: ok ? "" : "HTTP " + xhr.status })
    }
    xhr.open("GET", url)
    for (const name in headers) xhr.setRequestHeader(name, String(headers[name]))
    timer.start()
    xhr.send()
  }

  function readFile(path, done) {
    const p = String(path).indexOf("~/") === 0 ? Quickshell.env("HOME") + String(path).slice(1) : String(path)
    const reader = fileComponent.createObject(host, { path: p })
    reader.done = function(text) {
      done({ code: 0, ok: true, out: text.slice(0, Phone.LIMITS.bodyBytes), err: "" })
      reader.destroy()
    }
  }

  // android.*, answered from Linux: battery from the kernel's power supply,
  // the rest as the guide's shapes with what this phone can say so far.
  function android(widget, kind, done) {
    if (kind === "battery") {
      host.command(widget, "cat /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/status 2>/dev/null", 5, function(r) {
        const lines = String(r.out || "").trim().split("\n")
        const level = parseInt(lines[0], 10)
        done({ value: { level: isFinite(level) ? level : null, charging: /Charging|Full/.test(lines[1] || ""), status: String(lines[1] || "").toLowerCase() || null,
                        temp: null, voltage: null, health: null, plugged: null, technology: null, cycles: null } })
      })
      return
    }
    if (kind === "alarm") { done({ value: { set: false, time: null, app: null } }); return }
    if (kind === "notifications") { done({ value: { available: false, count: 0, items: [] } }); return }
    if (kind === "modes") { done({ value: { dnd: false, saver: false, ringer: "normal", torch: null } }); return }
    if (kind === "media") { done({ value: { available: false, playing: false } }); return }
    if (kind === "device") { done({ value: { model: "Pixel 7 Pro", maker: "Google", android: null, sdk: null, soc: "gs201" } }); return }
    done({ value: null })
  }

  // ---------------------------------------------------------------- actions

  // One action start per second per widget (plan §3.3).
  property var lastAction: ({})
  function act(widget, name, args) {
    const key = widget ? widget.stateKey : ""
    const now = Date.now()
    if (now - (host.lastAction[key] || 0) < Phone.LIMITS.actionGap * 1000) {
      if (widget) widget.report(name + ": held back (one action a second)")
      return
    }
    host.lastAction[key] = now
    const a = args || []
    const s = function(i) { return a[i] === undefined || a[i] === null ? "" : String(a[i]) }
    switch (name) {
    case "url":
      if (/^https?:\/\//i.test(s(0))) Quickshell.execDetached(HomeModel.urlLaunchArgv(s(0)))
      else if (widget) widget.report("url: only web links open here for now")
      return
    case "terminal":
      Quickshell.execDetached(HomeModel.commandLaunchArgv(["xdg-terminal-exec", "bash", "-c", s(0)]))
      return
    case "app":
      Quickshell.execDetached(HomeModel.commandLaunchArgv(["bash", "-c", s(0)]))
      return
    case "run":
      if (host.usesNetwork(s(0)) && !host.networkAllowed(widget)) { if (widget) widget.report("run: the internet is off for this widget"); return }
      host.command(widget, s(0), Phone.LIMITS.timeoutMax, function() { if (widget) widget.refreshSoon() })
      return
    case "notify": Quickshell.execDetached(["notify-send", s(0), s(1)]); return
    case "copy": Quickshell.execDetached(["wl-copy", "--", s(0)]); return
    case "share":
      Quickshell.execDetached(["wl-copy", "--", s(0)])
      Quickshell.execDetached(["notify-send", "Copied", "Sharing isn't here yet, so it's on the clipboard"])
      return
    case "volume": {
      const word = s(0)
      const argv = word === "up" ? ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+"]
        : word === "down" ? ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"]
        : word === "mute" ? ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"]
        : word === "unmute" ? ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"]
        : word === "toggle" ? ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]
        : ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", Math.max(0, Math.min(100, Number(word) || 0)) + "%"]
      Quickshell.execDetached(argv)
      return
    }
    case "media":
      Quickshell.execDetached(["playerctl", s(0) === "toggle" ? "play-pause" : s(0)])
      return
    case "launcher":
      if (host.home && (s(0) === "store" || s(0) === "drawer")) host.home.showSheet("widgets")
      else if (s(0) === "style" || s(0) === "themes") Quickshell.execDetached(["omarchy-menu", "summon", "style"])
      return
    case "screen": case "close":
      if (widget) widget.report(name + ": full-screen views aren't served on the phone yet")
      return
    default:
      // haptic, torch, androidApp, notification: not on this phone yet
      // (haptics and the torch get announced before their first test).
      if (widget) widget.report(name + ": not available on this phone yet")
    }
  }

  function runInto(widget, text, done) {
    if (host.usesNetwork(text) && !host.networkAllowed(widget)) { widget.report("run: the internet is off for this widget"); return }
    host.command(widget, text, Phone.LIMITS.timeoutMax, function(r) { done(String(r.out || "").replace(/\s+$/, "")) })
  }

  // ---------------------------------------------------------------- state and errors

  function statePath(key) { return host.stateDir + "/" + key.replace(/[^A-Za-z0-9._-]/g, "_") + ".json" }

  function loadState(key) {
    const view = stateComponent.createObject(host, { path: host.statePath(key) })
    let data = {}
    try { data = JSON.parse(view.text() || "{}") || {} } catch (e) { data = {} }
    view.destroy()
    return data
  }

  function saveState(key, data) {
    host.ensureDir()
    const view = stateComponent.createObject(host, { path: host.statePath(key) })
    view.setText(JSON.stringify(data) + "\n")
    view.destroy()
  }

  // The last 20 problems per widget, for its card and for an agent fixing it
  // (~/.local/state/omamobile/owl/errors/<id>.txt; outside the widget's
  // folder, so writing it doesn't trigger a rescan).
  function report(widget, message) {
    if (!widget || !widget.stateKey) return
    console.warn("omamobile.home: owl " + widget.stateKey + ": " + message)
    host.ensureDir()
    const view = stateComponent.createObject(host, { path: host.stateDir + "/errors/" + widget.stateKey.replace(/[^A-Za-z0-9._-]/g, "_") + ".txt" })
    view.setText(widget.problems.join("\n") + "\n")
    view.destroy()
  }

  property bool madeDir: false
  function ensureDir() {
    if (host.madeDir) return
    host.madeDir = true
    Quickshell.execDetached(["mkdir", "-p", host.stateDir + "/errors"])
  }

  // ---------------------------------------------------------------- parts

  property Component processComponent: Component {
    Process {
      id: proc
      property var done: null
      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector { id: err; waitForEnd: true }
      onExited: function(code) {
        const finish = proc.done
        proc.done = null
        if (finish) finish(code, String(out.text || ""), String(err.text || ""))
        proc.destroy()
      }
    }
  }

  property Component timerComponent: Component { Timer { } }

  property Component fileComponent: Component {
    FileView {
      id: file
      property var done: null
      printErrors: false
      onLoaded: if (file.done) file.done(file.text())
      onLoadFailed: if (file.done) file.done("")
    }
  }

  property Component stateComponent: Component {
    FileView {
      blockLoading: true
      blockWrites: true
      atomicWrites: true
      printErrors: false
    }
  }
}
