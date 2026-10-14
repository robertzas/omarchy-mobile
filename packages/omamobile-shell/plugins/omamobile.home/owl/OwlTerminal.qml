// SPDX-License-Identifier: MIT
import QtQuick
import "terminal.js" as Term
import "extrakeys.js" as Keys

// Terminal (owl 2): a command (default: the login shell) in a
// pseudo-terminal, its output as text and a line to type into. The tile is
// inert until tapped, so swipes still turn pages; a tap gives it the
// keyboard. It keeps running while its page is off screen and ends with
// the widget. A program that exited offers a restart. The command is on
// the approval sheet like any other. While it has the keyboard, a row of
// extra keys (Esc, Tab, Ctrl, Alt, arrows, | / - ~ :) sits at its foot,
// above squeekboard, and sends their bytes straight to the pty.
OwlNodeBase {
  id: term

  property var screenState: Term.empty()
  property var session: null
  property bool exited: false
  property bool armed: false
  readonly property real fontPx: term.num(term.p.fontSize, 8) * 1.333 * term.dp

  function start() {
    if (!term.view || !term.view.terminals || term.session) return
    term.exited = false
    term.screenState = Term.empty()
    term.session = term.view.terminals.start(term.p.command === undefined || term.p.command === null ? "" : String(term.p.command),
      function(chunk) { term.screenState = Term.feed(term.screenState, chunk) },
      function() { term.exited = true; term.session = null })
  }
  Component.onCompleted: term.start()
  Component.onDestruction: if (term.session) term.session.stop()

  Rectangle {
    x: term.innerX
    y: term.innerY
    width: term.innerW
    height: term.innerH
    color: "transparent"
    border.width: term.armed ? Math.max(1, term.dp) : 0
    border.color: term.ink("accent")
    clip: true

    Flickable {
      id: scroller
      anchors.fill: parent
      anchors.bottomMargin: (line.visible ? line.height : 0) + (keys.visible ? keys.height : 0)
      contentHeight: output.implicitHeight
      contentY: Math.max(0, contentHeight - height)
      interactive: term.armed
      Text {
        id: output
        width: scroller.width
        textFormat: Text.PlainText
        text: Term.text(term.screenState) + (term.exited ? "\n[exited: tap to restart]" : "")
        color: term.ink("foreground")
        font.family: term.view ? term.view.family("mono") : "monospace"
        font.pixelSize: Math.max(6, Math.round(term.fontPx))
        wrapMode: Text.WrapAnywhere
      }
    }

    OwlExtraKeys {
      id: keys
      visible: term.armed && !term.exited
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: line.top
      height: visible ? implicitHeight : 0
      keyHeight: Math.max(36, 30 * term.dp)
      foreground: term.ink("foreground")
      accent: term.ink("accent")
      background: term.ink("background")
      fontFamily: term.view ? term.view.family("mono") : "monospace"
      onPressed: function(key, mods) { if (term.session) term.session.write(Keys.bytes(key, mods)) }
    }

    TextInput {
      id: line
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      visible: term.armed && !term.exited
      color: term.ink("accent")
      font: output.font
      clip: true
      // With Ctrl or Alt held, the next character typed goes out at once with it.
      onTextEdited: {
        if (!keys.held.ctrl && !keys.held.alt) return
        const typed = line.text.slice(-1)
        line.text = line.text.slice(0, -1)
        if (typed) keys.tapKey(typed)
      }
      onAccepted: {
        if (term.session) term.session.write(line.text + "\n")
        line.text = ""
      }
      onActiveFocusChanged: if (term.view) term.view.fieldFocused(activeFocus)
    }

    MouseArea {
      anchors.fill: parent
      enabled: !!term.view && term.view.interactive
      onClicked: {
        if (term.exited) { term.start(); return }
        term.armed = true
        line.forceActiveFocus()
      }
    }
  }
}
