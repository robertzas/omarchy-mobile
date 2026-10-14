// SPDX-License-Identifier: MIT
import QtQuick
import "ours" as Ours
import "ours/values.js" as V
import "ours/builtins.js" as B
import "ours/compiler.js" as C
import "ours/runtime.js" as R

// Our runtime's tile for the conformance render: the widget evaluated
// against its fixture exactly as the L3 walk does (sources set once, one
// sample), drawn by OwlView in the card's content box.
Rectangle {
  id: tile

  property var task: null
  readonly property var fx: tile.task.fixture
  readonly property real dp: tile.fx.dp
  property var program: null
  property var tree: null
  readonly property var view: owlView

  color: tile.task.cardColor

  function argb(n) { const s = (n >>> 0).toString(16); return "#" + "00000000".slice(s.length) + s }
  readonly property var theme: {
    const out = {}
    for (const k in tile.fx.theme) out[k] = tile.fx.theme[k] >>> 0
    return out
  }
  readonly property var ink: {
    const out = {}
    for (const k in tile.theme) out[k] = tile.argb(tile.theme[k])
    return out
  }

  Component.onCompleted: {
    B.setFirstDayOfWeek(tile.task.weekStart)
    tile.program = C.compile(tile.task.source)
    const host = {
      theme: function(n) { return tile.theme[n] === undefined ? null : tile.theme[n] },
      tile: function(n) { return tile.fx.tile[n] === undefined ? null : tile.fx.tile[n] },
      act: function() {}, runInto: function() {}, report: function(m) { console.log("report: " + m) }, changed: function() {}
    }
    const inst = new R.Instance(tile.program, host, {})
    inst.time = tile.fx.time
    tile.program.globals.forEach(function(g, slot) {
      if (!g || g.type !== "source") return
      const e = tile.fx.sources[g.name]
      if (!e) return
      if (e.value !== undefined) inst.values[slot] = V.fromPlain(e.value)
      else if (e.text !== undefined) {
        if (g.json) { try { inst.values[slot] = V.parseJson(e.text.trim()) } catch (x) { inst.values[slot] = null } }
        else inst.values[slot] = e.text.replace(/\s+$/, "")
      }
    })
    inst.invalidate()
    inst.sample()
    tile.tree = inst.render(false)
  }

  Ours.OwlView {
    id: owlView
    anchors.fill: parent
    anchors.margins: (tile.program ? tile.program.padding : 12) * tile.dp
    tree: tile.tree
    colors: tile.ink
    dp: tile.dp
    corners: 0
    monoFamily: tile.task.mono
    sansFamily: tile.task.sans
    iconFamily: tile.task.mono
    interactive: false
  }

  function dump() { return owlView.dump() }
  function contentItem() { return owlView }
}
