// SPDX-License-Identifier: MIT
import QtQuick

// One clock for every OWL widget on the home screen (plan §2.6): a tick on
// each second boundary for sources, `every` and `at` triggers, and a frame
// clock capped at 30 fps that runs only while a shown widget animates and
// the home screen isn't paused (covered by an app, or off). A widget whose
// frames take too long drops to half rate (15 fps), as the guide says.
// Widgets register with add() and leave with remove().
Item {
  id: scheduler

  property bool paused: false
  property var clients: []
  property var animating: ({})
  readonly property bool framesWanted: Object.keys(scheduler.animating).length > 0
  // `time` for animations: seconds since the shell started (small numbers
  // keep sin() and friends precise).
  readonly property real epoch: Date.now() / 1000
  property int frameCount: 0

  // A client is { tick(now), frame(time), active, key }.
  function add(client) {
    if (scheduler.clients.indexOf(client) < 0) scheduler.clients = scheduler.clients.concat([client])
  }
  function remove(client) {
    scheduler.clients = scheduler.clients.filter(function(c) { return c !== client })
    scheduler.setAnimating(client, false)
  }
  function setAnimating(client, on) {
    const id = String(client.key)
    if (!!scheduler.animating[id] === on) return
    const next = Object.assign({}, scheduler.animating)
    if (on) next[id] = client
    else delete next[id]
    scheduler.animating = next
  }

  // Resuming runs a tick at once, so nothing shows hours-old data.
  onPausedChanged: if (!scheduler.paused) scheduler.tick()

  function tick() {
    const now = Date.now() / 1000
    const list = scheduler.clients
    for (let i = 0; i < list.length; i++) {
      try { list[i].tick(now, scheduler.paused) } catch (e) { console.warn("owl: tick: " + e) }
    }
  }

  Timer {
    id: seconds
    running: true
    // Restarted on the next second boundary each time.
    interval: 1000 - Date.now() % 1000 + 5
    onTriggered: {
      scheduler.tick()
      seconds.interval = 1000 - Date.now() % 1000 + 5
      seconds.restart()
    }
  }

  property var slow: ({})
  Timer {
    interval: 33
    repeat: true
    running: !scheduler.paused && scheduler.framesWanted
    onTriggered: {
      scheduler.frameCount++
      const t = Date.now() / 1000 - scheduler.epoch
      for (const id in scheduler.animating) {
        const client = scheduler.animating[id]
        if (!client.active) continue
        if (scheduler.slow[id] && scheduler.frameCount % 2 === 1) continue
        const began = Date.now()
        try { client.frame(t) } catch (e) { console.warn("owl: frame: " + e) }
        scheduler.slow[id] = Date.now() - began > 20
      }
    }
  }
}
