// SPDX-License-Identifier: MIT
import QtQuick
import "paint.js" as Paint

// Sparkline: a line through `values`, optionally with the area under it.
OwlNodeBase {
  id: spark

  Canvas {
    x: spark.innerX
    y: spark.innerY
    width: spark.innerW
    height: spark.innerH
    readonly property var deps: [spark.p, width, height, spark.view ? spark.view.inkVersion : 0]
    onDepsChanged: requestPaint()
    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      Paint.sparkline(ctx, width, height, spark.p, spark.dp, { accent: spark.ink("accent") })
    }
  }
}
