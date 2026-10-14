// SPDX-License-Identifier: MIT
import QtQuick

// What every OWL node shares: its box from layout.js (in dp), background,
// border and corners, opacity, rotation, scale and offset, clipping, and
// its tap and drag handlers. OwlView creates one per node and updates `box`
// in place when the widget redraws. Children of a container go into
// `container`.
Item {
  id: base

  property var view: null
  property var box: null

  readonly property var node: base.box ? base.box.node : null
  readonly property var p: base.node && base.node.p ? base.node.p : ({})
  readonly property var handlers: base.node && base.node.h ? base.node.h : ({})
  readonly property var anims: base.node && base.node.a ? base.node.a : ({})
  readonly property real dp: base.view ? base.view.dp : 1
  readonly property var pad: base.box && base.box.pad ? base.box.pad : [0, 0, 0, 0]
  readonly property real innerX: base.pad[0] * base.dp
  readonly property real innerY: base.pad[1] * base.dp
  readonly property real innerW: Math.max(0, base.width - (base.pad[0] + base.pad[2]) * base.dp)
  readonly property real innerH: Math.max(0, base.height - (base.pad[1] + base.pad[3]) * base.dp)
  // Where child nodes go (a scrolling Column replaces it with its content).
  property Item container: base

  function num(v, fallback) { return typeof v === "number" && isFinite(v) ? v : fallback }
  function ink(name) { return base.view ? base.view.ink(name) : "#ff888888" }
  // Bordered elements without a radius follow the corner style (0, 4 or 8 dp).
  readonly property real cornerRadius: base.p.radius !== undefined && base.p.radius !== null
    ? base.num(base.p.radius, 0) * base.dp
    : base.num(base.p.border, 0) > 0 && base.view ? 8 * base.view.corners * base.dp : 0

  // How long an `animate` takes: a tween's duration, or about how long a
  // spring takes to settle.
  function ms(a) {
    if (!a) return 0
    if (a.type === "tween") return Math.max(0, base.num(a.duration, 0.3)) * 1000
    var damping = Math.max(base.num(a.damping, 0.6), 0.05)
    var stiffness = Math.max(base.num(a.stiffness, 300), 1)
    return Math.min(1200, Math.max(120, 4000 / (damping * Math.sqrt(stiffness))))
  }
  function curve(a) {
    if (!a || a.type !== "tween") return a && base.num(a.damping, 0.6) < 1 ? Easing.OutBack : Easing.OutCubic
    return a.easing === "linear" ? Easing.Linear : a.easing === "in" ? Easing.InCubic
      : a.easing === "out" ? Easing.OutCubic : Easing.InOutCubic
  }

  x: base.box ? base.box.x * base.dp : 0
  y: base.box ? base.box.y * base.dp : 0
  width: base.box ? base.box.w * base.dp : 0
  height: base.box ? base.box.h * base.dp : 0
  visible: base.p.visible === undefined || base.p.visible === null || base.p.visible === true
  opacity: Math.max(0, Math.min(1, base.num(base.p.opacity, 1)))
  rotation: base.num(base.p.rotation, 0)
  scale: base.num(base.p.scale, 1)
  clip: base.p.clip === true
  transform: Translate {
    x: Array.isArray(base.p.offset) ? base.num(base.p.offset[0], 0) * base.dp : 0
    y: Array.isArray(base.p.offset) ? base.num(base.p.offset[1], 0) * base.dp : 0
  }

  Behavior on opacity {
    enabled: !!base.anims.opacity
    NumberAnimation { duration: base.ms(base.anims.opacity); easing.type: base.curve(base.anims.opacity) }
  }
  Behavior on rotation {
    enabled: !!base.anims.rotation
    NumberAnimation { duration: base.ms(base.anims.rotation); easing.type: base.curve(base.anims.rotation) }
  }
  Behavior on scale {
    enabled: !!base.anims.scale
    NumberAnimation { duration: base.ms(base.anims.scale); easing.type: base.curve(base.anims.scale) }
  }

  readonly property var background: base.p.background
  readonly property color backgroundColor: typeof base.background === "string" ? base.background
    : base.background && base.background.gradient && base.background.gradient.colors[0] ? base.background.gradient.colors[0]
    : "transparent"

  Rectangle {
    anchors.fill: parent
    visible: !!base.background || base.num(base.p.border, 0) > 0
    color: base.backgroundColor
    radius: base.cornerRadius
    border.width: base.num(base.p.border, 0) * base.dp
    border.color: base.p.borderColor || base.ink("border")
    Behavior on color {
      enabled: !!base.anims.background
      ColorAnimation { duration: base.ms(base.anims.background) }
    }
  }

  // Taps and drags. The hit area is at least 44 px, centred on the node, so
  // a small OWL button is still easy to hit; layout doesn't change. Inner
  // nodes sit above this, so a tap goes to the innermost node that wants it.
  Item {
    anchors.centerIn: parent
    width: Math.max(parent.width, 44)
    height: Math.max(parent.height, 44)
    enabled: !!base.view && base.view.interactive && (!!base.handlers.onTap || !!base.handlers.onDrag)
    TapHandler {
      enabled: !!base.handlers.onTap
      gesturePolicy: TapHandler.ReleaseWithinBounds
      onTapped: function(point) {
        if (base.view) base.view.tapped(base.handlers.onTap, point.position.x / base.dp, point.position.y / base.dp)
      }
    }
    DragHandler {
      enabled: !!base.handlers.onDrag
      target: null
      // Vertical first, so the sideways page swipe keeps working (plan §4.5).
      yAxis.enabled: true
      xAxis.enabled: true
      property point last: Qt.point(0, 0)
      onActiveChanged: if (active) last = Qt.point(0, 0)
      onTranslationChanged: {
        const dx = (translation.x - last.x) / base.dp
        const dy = (translation.y - last.y) / base.dp
        last = Qt.point(translation.x, translation.y)
        if (base.view) base.view.dragged(base.handlers.onDrag, dx, dy, centroid.position.x / base.dp, centroid.position.y / base.dp)
      }
    }
  }
}
