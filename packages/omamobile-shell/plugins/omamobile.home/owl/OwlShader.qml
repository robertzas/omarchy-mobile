// SPDX-License-Identifier: MIT
import QtQuick

// Shader: AGSL is Android's, and Qt compiles shaders ahead of time, so this
// draws the widget's `fallback` (surface by default), as older Android
// phones do.
OwlNodeBase {
  id: fallbackNode

  Rectangle {
    x: fallbackNode.innerX
    y: fallbackNode.innerY
    width: fallbackNode.innerW
    height: fallbackNode.innerH
    color: fallbackNode.p.fallback || fallbackNode.ink("surface")
  }
}
