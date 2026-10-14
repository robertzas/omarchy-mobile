// SPDX-License-Identifier: MIT
import QtQuick
import "paint.js" as Paint

// Slider: onChange gets the value when the finger lifts (or at every step
// with live: true).
OwlNodeBase {
  id: slider

  readonly property real low: slider.num(slider.p.min, 0)
  readonly property real high: Math.max(slider.num(slider.p.max, 100), low + 1e-9)
  property real dragged: NaN
  readonly property real current: isNaN(dragged) ? slider.num(slider.p.value, low) : dragged
  readonly property real fraction: Math.max(0, Math.min(1, (current - low) / (high - low)))
  readonly property color tone: slider.p.color || slider.ink("accent")

  function valueAt(px) {
    let v = low + Math.max(0, Math.min(1, px / Math.max(1, slider.innerW))) * (high - low)
    const step = slider.num(slider.p.step, 0)
    if (step > 0) v = low + Math.round((v - low) / step) * step
    return Math.max(low, Math.min(high, v))
  }

  Item {
    x: slider.innerX
    y: slider.innerY
    width: slider.innerW
    height: slider.innerH
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 4 * slider.dp
      radius: height / 2
      color: slider.p.track || Paint.withAlpha(slider.ink("foreground"), 0.15)
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * slider.fraction
      height: 4 * slider.dp
      radius: height / 2
      color: slider.tone
    }
    Rectangle {
      x: parent.width * slider.fraction - width / 2
      anchors.verticalCenter: parent.verticalCenter
      width: 16 * slider.dp
      height: width
      radius: width / 2
      color: slider.tone
    }
    MouseArea {
      anchors.fill: parent
      anchors.margins: -8
      enabled: !!slider.view && slider.view.interactive
      preventStealing: true
      onPressed: function(mouse) { slider.move(mouse.x - 8) }
      onPositionChanged: function(mouse) { slider.move(mouse.x - 8) }
      onReleased: {
        const v = slider.dragged
        slider.dragged = NaN
        if (slider.handlers.onChange && slider.view && !isNaN(v)) slider.view.changedValue(slider.handlers.onChange, v)
      }
    }
  }

  function move(px) {
    slider.dragged = slider.valueAt(px)
    if (slider.p.live === true && slider.handlers.onChange && slider.view) slider.view.changedValue(slider.handlers.onChange, slider.dragged)
  }
}
