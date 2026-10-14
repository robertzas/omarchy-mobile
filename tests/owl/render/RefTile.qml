// SPDX-License-Identifier: MIT
import QtQuick
import "ref" as Ref
import "ref/Owl.js" as RefJs

// The reference runtime's tile (pinned, inside the container only), driven
// as a black box: its OwlWidget compiles the file, the fixture's values are
// put into its instance as its own test walker does, and its OwlNode draws.
Rectangle {
  id: tile

  property var task: null
  readonly property var fx: tile.task.fixture
  readonly property real dp: tile.fx.dp
  property bool fed: false

  color: tile.task.cardColor

  readonly property var theme: {
    const out = {}
    for (const k in tile.fx.theme) out[k] = tile.fx.theme[k] >>> 0
    return out
  }

  Ref.OwlHost {
    id: refHost
    dp: tile.dp
    monoFamily: tile.task.mono
    sansFamily: tile.task.sans
    iconFamily: tile.task.mono
  }

  Ref.OwlWidget {
    id: widget
    anchors.fill: parent
    anchors.margins: (widget.program ? widget.program.padding : 12) * tile.dp
    path: tile.task.file
    host: refHost
    palette: tile.theme
    active: false
    cols: tile.fx.tile.cols
    rows: tile.fx.tile.rows
    dp: tile.dp
    screenWidth: tile.fx.tile.screenWidth * tile.dp
    screenHeight: tile.fx.tile.screenHeight * tile.dp
    onInstanceChanged: tile.feed()
  }

  function feed() {
    const inst = widget.instance
    if (!inst || tile.fed) return
    tile.fed = true
    inst.time = tile.fx.time
    widget.program.globals.forEach(function(g, slot) {
      if (!g || g.type !== "source") return
      const e = tile.fx.sources[g.name]
      if (!e) return
      if (e.value !== undefined) inst.values[slot] = tile.plainToRef(e.value)
      else if (e.text !== undefined) {
        if (g.json) { try { inst.values[slot] = tile.parse(e.text.trim()) } catch (x) { inst.values[slot] = null } }
        else inst.values[slot] = e.text.replace(/\s+$/, "")
      }
    })
    inst.invalidate()
    inst.sample()
    widget.render()
  }
  // The reference's own JSON helpers.
  function plainToRef(v) { return RefJs.fromJson(v) }
  function parse(t) { return RefJs.parseJson(t) }

  Ref.OwlNode {
    id: root
    anchors.fill: widget
    widget: widget
    node: !widget.tree ? null : widget.tree.children.length === 1 ? widget.tree.children[0]
      : { kind: "Column", p: { gap: 0 }, h: {}, a: {}, c: widget.tree.children }
  }

  // Every OwlNode under the root, depth first, with its box in dp.
  function dump() {
    const out = []
    function visit(item, path) {
      const x = item.mapToItem(root, 0, 0)
      out.push({ path: path, kind: String(item.kind), x: x.x / tile.dp, y: x.y / tile.dp, w: item.width / tile.dp, h: item.height / tile.dp })
      const kids = []
      function collect(it) {
        for (let i = 0; i < it.children.length; i++) {
          const c = it.children[i]
          if (c.kind !== undefined && c.node !== undefined && c.widget !== undefined) { if (c.node && c.visible) kids.push(c) }
          else collect(c)
        }
      }
      collect(item)
      kids.forEach(function(k, i) { visit(k, path + "." + i) })
    }
    if (root.node) visit(root, "0")
    return out
  }
  function contentItem() { return root }
}
