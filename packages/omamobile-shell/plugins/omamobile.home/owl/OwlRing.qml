// SPDX-License-Identifier: MIT
import QtQuick
import "paint.js" as Paint

// Ring: circular progress, value out of max (1), from `start` through
// `sweep` degrees.
OwlNodeBase {
  id: ring

  readonly property real target: Math.max(0, Math.min(1, ring.num(ring.p.value, 0) / Math.max(ring.num(ring.p.max, 1), 1e-9)))
  property real shown: target
  Behavior on shown {
    enabled: !!ring.anims.value
    NumberAnimation { duration: ring.ms(ring.anims.value); easing.type: ring.curve(ring.anims.value) }
  }

  Canvas {
    id: art
    x: ring.innerX
    y: ring.innerY
    width: ring.innerW
    height: ring.innerH
    readonly property var deps: [ring.shown, ring.p, width, height, ring.view ? ring.view.inkVersion : 0]
    onDepsChanged: requestPaint()
    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      Paint.ring(ctx, width, height, ring.p, ring.shown, ring.dp, { surface: ring.ink("surface"), accent: ring.ink("accent") })
    }
  }
}
