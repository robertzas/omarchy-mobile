// SPDX-License-Identifier: MIT
import QtQuick

// Progress: a track and a bar, value out of max (100).
OwlNodeBase {
  id: progress

  readonly property real target: Math.max(0, Math.min(1, progress.num(progress.p.value, 0) / Math.max(progress.num(progress.p.max, 100), 1e-9)))
  property real shown: target
  Behavior on shown {
    enabled: !!progress.anims.value
    NumberAnimation { duration: progress.ms(progress.anims.value); easing.type: progress.curve(progress.anims.value) }
  }

  Rectangle {
    x: progress.innerX
    y: progress.innerY
    width: progress.innerW
    height: progress.innerH
    color: progress.p.track || progress.ink("surface")
    Rectangle {
      width: parent.width * progress.shown
      height: parent.height
      color: progress.p.color && typeof progress.p.color === "string" ? progress.p.color : progress.ink("accent")
    }
  }
}
