.pragma library
.import "values.js" as V
.import "builtins.js" as B
.import "compiler.js" as C
// SPDX-License-Identifier: MIT
// One live OWL widget: the values of its sources and states, its lets and
// samples, its triggers, and the render tree the renderer draws. Pure JS.
//
// The host (OwlWidget.qml on the phone, or a test) passes in:
//   theme(name)         ARGB of a theme colour, or null
//   tile(name)          cols, rows, tileWidth, tileHeight, screenWidth,
//                       screenHeight, corners, linux
//   act(name, args)     an action (url, run, terminal, notify, ...)
//   runInto(cmd, slot)  run a command and later call setState(slot, output)
//   report(message)     a run-time error, for the error log
//   changed()           something a render reads has changed
//
// Resource caps (plan §2.3): a step budget per update, lists of 1000, 2000
// drawing calls per frame, 1000 items per `for`, and triggers that set off
// more triggers at most 4 deep. A cap that is hit is a widget error: the
// value shows "…" and the message is reported.

var STEP_BUDGET = 200000
var MAX_DRAW_CALLS = 2000
var MAX_FOR_ITEMS = 1000
var MAX_TEXT = 100000

function Budget(limit) {
  this.limit = limit
  this.steps = 0
  this.depth = 0
}
Budget.prototype.run = function(work) {
  if (this.depth++ === 0) this.steps = 0
  try { return work() } finally { this.depth-- }
}
Budget.prototype.spend = function(n) {
  this.steps += n === undefined ? 1 : n
  if (this.steps > this.limit) throw new V.RuntimeError("too much work in one update (over " + this.limit + " steps)")
}

var COLOR_PROPS = ["color", "background", "borderColor", "track", "tint", "fallback"]

function Instance(program, host, persisted) {
  var self = this
  this.program = program
  this.host = host
  this.values = []
  this.letCache = []
  this.letReadsTime = []
  this.samples = []
  this.time = 0
  this.timeFrames = []
  this.readsTime = false
  this.triggerLast = []
  this.triggerDepth = 0
  this.budget = new Budget(STEP_BUDGET)
  this.drawBudget = new Budget(STEP_BUDGET)
  this.ctx = this.bridge(this.budget)
  this.drawCtx = this.bridge(this.drawBudget)
  this.env = new C.Env(this.ctx, null, [])
  var saved = persisted || {}
  program.globals.forEach(function(g, slot) {
    self.values[slot] = null
    self.letCache[slot] = undefined
    if (g.type === "state") {
      if (g.persist && Object.prototype.hasOwnProperty.call(saved, g.name)) self.values[slot] = V.fromPlain(saved[g.name])
      else self.values[slot] = self.guard("state " + g.name, function() { return C.evaluate(g.init, self.env) }, null)
    } else if (g.type === "sampled") {
      self.samples[slot] = g.persist && Array.isArray(saved[g.name]) ? saved[g.name].map(V.fromPlain) : []
    } else if (g.type === "asset") {
      self.values[slot] = "data:" + assetType(g.base64) + ";base64," + g.base64
    }
  })
  this.triggerLast = program.triggers.map(function(t) {
    return t.kind === "every" || t.kind === "at" ? null : self.guard(t.kind, function() { return C.evaluate(t.expr, self.env) }, null)
  })
}

function assetType(b64) {
  var kinds = [["iVBOR", "image/png"], ["/9j/", "image/jpeg"], ["R0lG", "image/gif"], ["UklGR", "image/webp"],
               ["PHN2", "image/svg+xml"], ["PD94", "image/svg+xml"]]
  for (var i = 0; i < kinds.length; i++) if (b64.indexOf(kinds[i][0]) === 0) return kinds[i][1]
  return "application/octet-stream"
}

Instance.prototype = {
  // What compiled closures call (env.ctx).
  bridge: function(budget) {
    var self = this
    return {
      spend: function(n) { budget.spend(n) },
      guarded: function(work) { return budget.run(work) },
      read: function(slot) { return self.read(slot) },
      write: function(slot, v) { self.write(slot, v) },
      theme: function(name) { return self.host.theme(name) },
      time: function() { self.noteTime(); return self.time },
      tile: function(name) {
        var v = self.host.tile(name)
        if (name === "linux") return v !== false
        return v === undefined ? null : v
      },
      act: function(name, args) { self.host.act(name, args) },
      runInto: function(command, slot) { self.host.runInto(command, slot) },
      report: function(message) { self.host.report(message) }
    }
  },

  guard: function(what, work, fallback) {
    try {
      return this.budget.run(work)
    } catch (e) {
      this.host.report(what + ": " + C.messageOf(e))
      return fallback
    }
  },

  noteTime: function() {
    this.readsTime = true
    for (var i = 0; i < this.timeFrames.length; i++) this.timeFrames[i].time = true
  },

  read: function(slot) {
    var g = this.program.globals[slot]
    if (g.type === "let") {
      var cached = this.letCache[slot]
      if (cached !== undefined) {
        if (this.letReadsTime[slot]) this.noteTime()
        return cached
      }
      var frame = { time: false }
      this.timeFrames.push(frame)
      var v
      try { v = C.evaluate(g.value, this.env) } finally { this.timeFrames.pop() }
      this.letCache[slot] = v
      this.letReadsTime[slot] = frame.time
      if (frame.time) this.noteTime()
      return v
    }
    if (g.type === "sampled") {
      var samples = this.samples[slot]
      if (g.prev) return samples.length >= 2 ? samples[samples.length - 2] : null
      return samples.slice()
    }
    var value = this.values[slot]
    return value === undefined ? null : value
  },

  invalidate: function() {
    for (var i = 0; i < this.letCache.length; i++) this.letCache[i] = undefined
  },

  write: function(slot, v) {
    if (V.same(this.values[slot], v)) return
    this.values[slot] = v
    this.invalidate()
    this.changed()
  },

  setState: function(slot, v) { this.write(slot, v) },

  stateSlot: function(name) {
    for (var i = 0; i < this.program.globals.length; i++) {
      var g = this.program.globals[i]
      if (g && g.type === "state" && g.name === name) return i
    }
    return -1
  },

  // A source's new value: text (cmd, stream, http, file) or a value
  // already (clock, android.*, a status map).
  setSource: function(slot, raw) {
    var g = this.program.globals[slot]
    var v = raw
    if (typeof raw === "string") {
      v = raw.replace(/\s+$/, "")
      if (g.json) {
        try {
          v = V.parseJson(raw.trim())
        } catch (e) {
          this.host.report(g.name + ": not JSON: " + C.messageOf(e))
          v = null
        }
      }
    }
    this.values[slot] = v
    this.invalidate()
    this.sample()
    this.changed()
  },

  // history() and prev() take a sample whenever a source updates.
  sample: function() {
    var self = this
    this.program.globals.forEach(function(g, slot) {
      if (g.type !== "sampled") return
      var v = self.guard(g.name, function() { return C.evaluate(g.of, self.env) }, null)
      var list = self.samples[slot]
      list.push(v)
      if (list.length > g.keep) list.splice(0, list.length - g.keep)
    })
    this.invalidate()
  },

  // An animation frame: what read `time` is stale.
  frame: function(seconds) {
    this.time = seconds
    for (var i = 0; i < this.letCache.length; i++) if (this.letReadsTime[i]) this.letCache[i] = undefined
  },

  changed: function() {
    this.checkTriggers()
    if (this.host.changed) this.host.changed()
  },

  // `on` and `when`. A trigger that sets off triggers is cut off at 4 deep;
  // the host's rate limit (10 a second) catches the rest.
  checkTriggers: function() {
    var self = this
    if (this.triggerDepth > 4) return
    this.triggerDepth++
    try {
      this.program.triggers.forEach(function(t, i) {
        if (t.kind !== "on" && t.kind !== "when") return
        var v = self.guard(t.kind, function() { return C.evaluate(t.expr, self.env) }, null)
        var old = self.triggerLast[i]
        self.triggerLast[i] = v
        // `on`: not for the first value, and null (loading) is no change (SPEC-NOTES N8).
        if (t.kind === "on" && v !== null && old !== null && !V.same(v, old)) self.fireTrigger(i, [v, old])
        if (t.kind === "when" && V.truthy(v) && !V.truthy(old)) self.fireTrigger(i, [])
      })
    } finally {
      this.triggerDepth--
    }
  },

  // The host may hold a trigger back (more than 10 runs a second).
  fireTrigger: function(i, values) {
    if (this.host.allowTrigger && !this.host.allowTrigger(i)) return
    this.program.triggers[i].action.run(this.env, values)
  },

  // `every N { }`, timed by the host.
  fire: function(i) { this.fireTrigger(i, []) },

  // `at t { }`: the host calls this with the wall clock about once a second,
  // whether or not the page is shown. A time that passed while the shell
  // was not running fires at the first tick.
  tick: function(now) {
    var self = this
    this.program.triggers.forEach(function(t, i) {
      if (t.kind !== "at") return
      var v = self.guard("at", function() { return C.evaluate(t.expr, self.env) }, null)
      var due = null
      if (typeof v === "number") due = v
      else if (typeof v === "string" && /^[0-9]{1,2}:[0-9]{2}$/.test(v.trim())) {
        var hm = v.trim().split(":")
        var d = new Date(now * 1000)
        d.setHours(parseInt(hm[0], 10), parseInt(hm[1], 10), 0, 0)
        due = d.getTime() / 1000
      }
      var last = self.triggerLast[i]
      self.triggerLast[i] = now
      if (due !== null && due > 0 && (last === null ? due <= now : last < due && now >= due)) self.fireTrigger(i, [])
    })
  },

  persisted: function() {
    var self = this
    var out = {}
    this.program.globals.forEach(function(g, slot) {
      if (g.type === "state" && g.persist) out[g.name] = V.toPlain(self.values[slot])
      if (g.type === "sampled" && g.persist) out[g.name] = self.samples[slot].map(V.toPlain)
    })
    return out
  },

  // What the host runs: one entry per source, with its command, URL or
  // path evaluated now (it may read state).
  sources: function() {
    var self = this
    var out = []
    this.program.globals.forEach(function(g, slot) {
      if (g.type !== "source") return
      out.push({
        slot: slot, name: g.name, kind: g.kind, every: g.every, json: g.json, timeout: g.timeout,
        status: g.status, optional: g.optional,
        arg: function() { return g.arg ? self.guard(g.name, function() { return V.display(C.evaluate(g.arg, self.env)) }, "") : "" },
        headers: function() {
          if (!g.headers) return {}
          var h = self.guard(g.name, function() { return C.evaluate(g.headers, self.env) }, null)
          return h instanceof Map ? V.toPlain(h) : {}
        }
      })
    })
    return out
  },

  everyTriggers: function() {
    var out = []
    this.program.triggers.forEach(function(t, i) { if (t.kind === "every") out.push({ index: i, seconds: t.expr.value }) })
    return out
  },

  hasAt: function() { return this.program.triggers.some(function(t) { return t.kind === "at" }) },

  colorText: function(v) {
    var argb = B.resolveArgb(v, this.host.theme)
    return argb === null ? null : V.hex8(argb)
  },

  safely: function(f, env) {
    try {
      return C.evaluate(f, env)
    } catch (e) {
      this.host.report(C.messageOf(e))
      return null
    }
  },

  // The tile (or the screen) as plain objects:
  //   { children, readsTime, padding, background, onTap, title }
  // and each node { kind, key, p: props, h: handlers, a: animations, c: children, draw }.
  render: function(screen) {
    var self = this
    this.readsTime = false
    var out = []
    var nodes = screen ? this.program.screen : this.program.root
    this.guard("render", function() { self.renderList(nodes || [], self.env, out, "") }, null)
    var result = {
      children: out,
      readsTime: this.readsTime,
      padding: this.program.padding,
      background: this.program.background ? this.prop("background", this.program.background, this.env) : null,
      onTap: this.program.onTap ? this.handlerFor(this.program.onTap, this.env) : null
    }
    if (screen) result.title = this.program.screenTitle ? V.textOf(this.safely(this.program.screenTitle, this.env)) : this.program.name
    return result
  },

  handlerFor: function(action, env) {
    return function() { action.run(env, Array.prototype.slice.call(arguments)) }
  },

  renderList: function(list, env, out, path) {
    for (var i = 0; i < list.length; i++) this.renderNode(list[i], env, out, path + "." + i)
  },

  renderNode: function(n, env, out, path) {
    var self = this
    switch (n.t) {
    case "lets": return this.renderList(n.children, env.withLets(n.values), out, path)
    case "if":
      return V.truthy(this.safely(n.cond, env)) ? this.renderList(n.then, env, out, path + "t") : this.renderList(n.otherwise, env, out, path + "e")
    case "for": {
      var items = V.listOf(this.safely(n.list, env))
      for (var i = 0; i < items.length && i < MAX_FOR_ITEMS; i++) {
        var inner = env.inner([items[i], i])
        var key = n.key ? this.safely(n.key, inner) : null
        this.renderList(n.body, inner, out, path + "[" + (key === null ? "#" + i : V.display(key)) + "]")
      }
      return
    }
    case "use": {
      var args = n.args.map(function(a) { return self.safely(a, env) })
      var scope = new C.Env(env.ctx, new C.Env(env.ctx, null, []), args)
      if (!Object.keys(n.wrapper).length) return this.renderList(n.body, scope, out, path + n.component)
      var kids = []
      this.renderList(n.body, scope, kids, path + n.component)
      var p = {}
      for (var w in n.wrapper) p[w] = this.prop(w, n.wrapper[w], env)
      out.push({ kind: "Box", key: path + "~", p: p, h: {}, a: {}, c: kids, wrapper: true })
      return
    }
    case "el": {
      var props = {}
      for (var name in n.props) props[name] = this.prop(name, n.props[name], env)
      var handlers = {}
      for (var h in n.handlers) handlers[h] = this.handlerFor(n.handlers[h], env)
      var anims = {}
      for (var a in n.anims) anims[a] = V.toPlain(this.safely(n.anims[a], env))
      var node = { kind: n.kind, key: path + n.kind, p: props, h: handlers, a: anims, c: [] }
      if (n.kind === "Canvas") {
        var drawn = n.children
        node.draw = function(width, height) { return self.drawCalls(drawn, env, width, height) }
      } else {
        this.renderList(n.children, env, node.c, path)
      }
      out.push(node)
    }
    }
  },

  // A property ready to draw: colours as "#aarrggbb", text as it reads.
  prop: function(name, f, env) {
    var self = this
    var v = this.safely(f, env)
    if (COLOR_PROPS.indexOf(name) >= 0) {
      if (v instanceof V.Gradient) return { gradient: this.gradientOf(v) }
      return this.colorText(v)
    }
    if (name === "area" && typeof v !== "boolean") return v === null ? false : this.colorText(v)
    if (name === "text") {
      var t = V.textOf(v)
      return t.length > MAX_TEXT ? t.slice(0, MAX_TEXT) : t
    }
    if (name === "placeholder") return v === null ? "" : V.textOf(v)
    if (name === "uniforms") {
      var u = {}
      if (v instanceof Map) v.forEach(function(value, key) { u[key] = self.uniform(value) })
      return u
    }
    return plain(v)
  },

  uniform: function(v) {
    if (v instanceof V.Color || (typeof v === "string" && B.asColor(v) !== null)) {
      var n = B.resolveArgb(v, this.host.theme)
      return n === null ? null : [((n >>> 16) & 255) / 255, ((n >>> 8) & 255) / 255, (n & 255) / 255, ((n >>> 24) & 255) / 255]
    }
    return plain(v)
  },

  gradientOf: function(g) {
    var self = this
    return { radial: g.radial, coords: g.coords.slice(), colors: g.colors.map(function(c) { return self.colorText(c) }) }
  },

  // One frame of a Canvas: a display list in dp, groups nested.
  drawCalls: function(list, env, width, height) {
    var self = this
    var out = []
    var count = { n: 0 }
    // Whether this frame read `time`: then the Canvas animates.
    var frame = { time: false }
    this.timeFrames.push(frame)
    try {
      // A frame is one update for the widget's lets too: those it reads are
      // worked out on the main budget, which nothing else resets while only
      // the Canvas animates (the koi pond ran out after 8 s).
      this.budget.run(function() {
        self.drawBudget.run(function() {
          self.drawList(list, new C.Env(self.drawCtx, env, [width, height]), out, count)
        })
      })
    } catch (e) {
      this.host.report("Canvas: " + C.messageOf(e))
    } finally {
      this.timeFrames.pop()
    }
    out.readsTime = frame.time
    return out
  },

  drawList: function(list, env, out, count) {
    for (var i = 0; i < list.length; i++) {
      var n = list[i]
      if (n.t === "lets") this.drawList(n.children, env.withLets(n.values), out, count)
      else if (n.t === "if") this.drawList(V.truthy(C.evaluate(n.cond, env)) ? n.then : n.otherwise, env, out, count)
      else if (n.t === "for") {
        var items = V.listOf(C.evaluate(n.list, env))
        for (var j = 0; j < items.length && j < MAX_FOR_ITEMS; j++) this.drawList(n.body, env.inner([items[j], j]), out, count)
      } else if (n.t === "draw") this.drawOne(n, env, out, count)
    }
  },

  drawOne: function(n, env, out, count) {
    var self = this
    if (++count.n > MAX_DRAW_CALLS) throw new V.RuntimeError("more than " + MAX_DRAW_CALLS + " drawing calls in one frame")
    var args = n.args.map(function(a) { return C.evaluate(a, env) })
    var named = {}
    for (var k in n.named) named[k] = C.evaluate(n.named[k], env)
    var op = { op: n.op, args: args.map(V.toNumber) }
    function paint(v) {
      if (v === null || v === undefined) return null
      if (v instanceof V.Gradient) return { gradient: self.gradientOf(v) }
      return self.colorText(v)
    }
    if (named.fill !== undefined) op.fill = paint(named.fill)
    if (named.stroke !== undefined) op.stroke = paint(named.stroke)
    if (named.color !== undefined) op.color = paint(named.color)
    if (named.width !== undefined) op.width = V.toNumber(named.width)
    if (named.cap !== undefined) op.cap = V.display(named.cap)
    if (named.radius !== undefined) op.radius = V.toNumber(named.radius)
    if (named.closed !== undefined) op.closed = V.truthy(named.closed)
    if (named.size !== undefined) op.size = V.toNumber(named.size)
    if (named.align !== undefined) op.align = V.display(named.align)
    if (named.bold !== undefined) op.bold = V.truthy(named.bold)
    if (n.op === "path") {
      op.points = V.listOf(args[0]).map(function(p) {
        if (Array.isArray(p)) return [V.toNumber(p[0]) || 0, V.toNumber(p[1]) || 0]
        if (p instanceof Map) return [V.toNumber(p.get("x")) || 0, V.toNumber(p.get("y")) || 0]
        return [0, 0]
      })
      op.args = []
    } else if (n.op === "text") {
      op.text = V.textOf(args[0])
      op.args = [null, V.toNumber(args[1]), V.toNumber(args[2])]
    } else if (n.op === "image") {
      op.src = args[0] === null ? "" : V.display(args[0])
    } else if (n.op === "sprite") {
      this.sprite(args, named, op, out)
      return
    }
    if (n.children) {
      op.ops = []
      this.drawList(n.children, env, op.ops, count)
    }
    out.push(op)
  },

  // sprite(rows, x, y, pixel, palette: {letter: colour}): each run of one
  // letter in a row is one rect, with edges on whole pixels when drawn.
  sprite: function(args, named, op, out) {
    var palette = named.palette instanceof Map ? named.palette : new Map()
    var rows = Array.isArray(args[0]) ? args[0].map(V.textOf) : typeof args[0] === "string" ? spriteRows(args[0]) : []
    var x0 = V.toNumber(args[1]) || 0, y0 = V.toNumber(args[2]) || 0, px = V.toNumber(args[3]) || 1
    var fallback = op.fill || op.color || null
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r]
      for (var c = 0; c < row.length;) {
        var letter = row.charAt(c)
        var e = c + 1
        while (e < row.length && row.charAt(e) === letter) e++
        if (letter !== "." && letter !== " ") {
          var colour = palette.has(letter) ? this.colorText(palette.get(letter)) : fallback
          out.push({ op: "rect", args: [x0 + c * px, y0 + r * px, (e - c) * px, px], fill: colour, pixel: true })
        }
        c = e
      }
    }
  }
}

function spriteRows(s) {
  var rows = s.split(/\r\n|\n|\r/).map(function(l) { return l.trim() })
  while (rows.length && rows[0] === "") rows.shift()
  while (rows.length && rows[rows.length - 1] === "") rows.pop()
  return rows
}

// A value for QML: maps become objects, colours their names or hex.
function plain(v) {
  if (v === null || v === undefined) return null
  if (Array.isArray(v)) return v.map(plain)
  if (v instanceof Map) {
    var o = {}
    v.forEach(function(value, key) { o[key] = plain(value) })
    return o
  }
  if (v instanceof V.Color) return v.name !== null ? v.name : V.hex8(v.argb)
  if (v instanceof V.Lambda) return null
  return v
}

if (typeof module !== "undefined") {
  module.exports = { Instance: Instance, STEP_BUDGET: STEP_BUDGET, MAX_DRAW_CALLS: MAX_DRAW_CALLS, plain: plain }
}
