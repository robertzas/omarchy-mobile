// SPDX-License-Identifier: MIT
// The conformance walk (docs/WIDGET-INTEROP-PLAN.md §7.1, L3) of our OWL
// runtime: a widget evaluated against a fixture, every node's properties
// and every Canvas's drawing calls printed as JSON in the shared walk
// format, which the reference runtime's oracle prints too:
//
//   {"root": [{"kind", "props": {name: text}, "anim": {...}, "children" | "draw"}], "screen": [...]}
//
// A fixture is {theme: {name: argb}, time, canvas: [w, h], tile: {...},
// sources: {name: {value} | {text}}}.
//
//   node owl-walk.js <widget.owl> <fixture.json>
"use strict"
const fs = require("fs")
const { load } = require("./owl-load.js")
const V = load("values.js"), B = load("builtins.js"), C = load("compiler.js"), R = load("runtime.js")

function walk(src, fx) {
  // The reference oracle formats in en_US, where weeks start on Sunday.
  B.setFirstDayOfWeek(0)
  const program = C.compile(src)
  const host = {
    theme: (n) => fx.theme[n] === undefined ? null : fx.theme[n] >>> 0,
    tile: (n) => fx.tile[n] === undefined ? null : fx.tile[n],
    act() {}, runInto() {}, report: (m) => process.stderr.write("report: " + m + "\n"), changed() {}
  }
  const inst = new R.Instance(program, host, {})
  inst.time = fx.time
  program.globals.forEach((g, slot) => {
    if (g.type !== "source") return
    const e = fx.sources[g.name]
    if (!e) return
    if ("value" in e) inst.values[slot] = V.fromPlain(e.value)
    else if ("text" in e) {
      if (g.json) { try { inst.values[slot] = V.parseJson(e.text.trim()) } catch (x) { inst.values[slot] = null } }
      else inst.values[slot] = e.text.replace(/\s+$/, "")
    }
  })
  inst.invalidate()
  inst.sample()

  const q = (s) => JSON.stringify(s)
  const shown = (f, env) => { try { return q(V.display(C.evaluate(f, env))) } catch (e) { return q("ERROR " + C.messageOf(e)) } }
  const truthy = (f, env) => { try { return V.truthy(C.evaluate(f, env)) } catch (e) { return false } }
  const props = (p, env) => "{" + Object.keys(p).sort().map((k) => q(k) + ":" + shown(p[k], env)).join(",") + "}"
  const list = (f, env) => { let v; try { v = C.evaluate(f, env) } catch (e) { v = null } return V.listOf(v).slice(0, 1000) }
  const nodes = (items, env) => items.map((n) => node(n, env)).filter((s) => s !== "").join(",")
  function node(n, env) {
    switch (n.t) {
    case "lets": return nodes(n.children, env.withLets(n.values))
    case "if": return nodes(truthy(n.cond, env) ? n.then : n.otherwise, env)
    case "for": return list(n.list, env).map((it, i) => nodes(n.body, env.inner([it, i]))).filter((s) => s).join(",")
    case "use": {
      const args = n.args.map((a) => { try { return C.evaluate(a, env) } catch (e) { return null } })
      const inner = new C.Env(env.ctx, new C.Env(env.ctx, null, []), args)
      if (!Object.keys(n.wrapper).length) return nodes(n.body, inner)
      return '{"kind":"Box","props":' + props(n.wrapper, env) + ',"children":[' + nodes(n.body, inner) + "]}"
    }
    case "el": {
      let s = '{"kind":' + q(n.kind) + ',"props":' + props(n.props, env) + ',"anim":' + props(n.anims, env)
      if (n.kind === "Canvas") s += ',"draw":[' + draws(n.children, env.inner(fx.canvas)) + "]"
      else s += ',"children":[' + nodes(n.children, env) + "]"
      return s + "}"
    }
    }
    return ""
  }
  function draws(items, env) {
    return items.map((n) => {
      if (n.t === "lets") return draws(n.children, env.withLets(n.values))
      if (n.t === "if") return draws(truthy(n.cond, env) ? n.then : n.otherwise, env)
      if (n.t === "for") return list(n.list, env).map((it, i) => draws(n.body, env.inner([it, i]))).filter((s) => s).join(",")
      let s = '{"op":' + q(n.op) + ',"args":[' + n.args.map((a) => shown(a, env)).join(",") + '],"named":' + props(n.named, env)
      if (n.children) s += ',"ops":[' + draws(n.children, env) + "]"
      return s + "}"
    }).filter((s) => s !== "").join(",")
  }
  let out = '{"root":[' + nodes(program.root, inst.env) + "]"
  if (program.screen) out += ',"screen":[' + nodes(program.screen, inst.env) + "]"
  return out + "}"
}

if (require.main === module) {
  const src = fs.readFileSync(process.argv[2], "utf8")
  const fx = JSON.parse(fs.readFileSync(process.argv[3], "utf8"))
  console.log(walk(src, fx))
}

module.exports = { walk }
