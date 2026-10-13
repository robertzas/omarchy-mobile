// SPDX-License-Identifier: MIT
// Open items from a Markdown checklist; tap one to check it off. Ported
// from simonschubert/todo in Simon Schubert's omarchy-widgets (MIT,
// Copyright (c) 2026 Simon Schubert and contributors; see
// ../../LICENSE-omarchy-widgets).
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

Item {
  id: widget

  property var host: null
  property var settings: ({})
  property bool editing: false
  property int cellsWide: 1
  property int cellsHigh: 1

  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  readonly property string path: {
    var p = String(settings.path || "~/notes/todo.md").trim()
    return p === "" || p === "~" ? Quickshell.env("HOME") + "/notes/todo.md" : p.replace(/^~\//, Quickshell.env("HOME") + "/")
  }

  // [{ line, text }] of the open "- [ ] " items, kept across layout edits.
  property var items: host && host.cached && host.cached.path === path ? host.cached.items : null
  property string failure: ""

  // Makes the file on first use (as the original does), then lists the
  // open items as "line:text". The path is passed as $1, never spliced.
  readonly property string listScript:
    'f=$1; mkdir -p "${f%/*}" || exit 1\n' +
    '[ -f "$f" ] || printf \'# todo\\n\\n- [ ] tap an item to check it off\\n- [ ] tap the title to edit this list\\n\' > "$f"\n' +
    'grep -n \'^[[:space:]]*[-*] \\[ \\] \' "$f" | sed \'s/^\\([0-9]*\\):[[:space:]]*[-*] \\[ \\] /\\1:/\'\n' +
    'exit 0'

  function refresh() {
    if (!host || host.busy) return
    host.run(["sh", "-c", listScript, "sh", path], function(result) {
      if (result.code !== 0) {
        widget.failure = result.timedOut ? "reading the list took too long" : (result.stderr.trim() || "can't read " + widget.path)
        return
      }
      widget.failure = ""
      var list = []
      result.stdout.split("\n").forEach(function(l) {
        var i = l.indexOf(":")
        if (i > 0) list.push({ line: parseInt(l.slice(0, i), 10), text: l.slice(i + 1) })
      })
      widget.items = list
      widget.host.setCached({ path: widget.path, items: list })
    }, { timeout: 5 })
  }

  function check(line) {
    if (!host || host.busy || !(line > 0)) return
    // Only the line's "[ ]" becomes "[x]"; the line number is an integer.
    var ok = host.run(["sed", "-i", Math.floor(line) + "s/\\[ \\]/[x]/", path], function(result) {
      if (result.code !== 0) widget.failure = result.stderr.trim() || "couldn't check it off"
      again.restart()
    }, { timeout: 5 })
    if (ok) widget.items = widget.items.filter(function(it) { return it.line !== line })
  }

  Component.onCompleted: refresh()
  onPathChanged: refresh()
  // Commands start at most every 2 s: read back after a check-off.
  Timer { id: again; interval: 2100; onTriggered: widget.refresh() }
  Timer { interval: 120000; repeat: true; running: true; onTriggered: widget.refresh() }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Item {
      id: headerPart
      width: parent.width
      height: Math.max(titleView.implicitHeight, 24)
      Text {
        id: titleView
        textFormat: Text.PlainText
        text: "todo"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: widget.items ? String(widget.items.length) : ""
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      // The title opens the file in Omarchy's editor.
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: if (widget.host) widget.host.launch(["omarchy-launch-editor", widget.path])
      }
    }

    Text {
      width: parent.width
      visible: widget.failure !== "" || (widget.items !== null && widget.items.length === 0)
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : "all done"
      color: widget.failure !== "" ? Commons.Color.urgent : Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    ListView {
      width: parent.width
      height: parent.height - headerPart.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      model: widget.items || []
      delegate: Item {
        id: rowView
        required property var modelData
        width: ListView.view.width
        height: Math.max(40, labelView.implicitHeight + Style.spacing.md * 2)
        Rectangle {
          id: box
          anchors.verticalCenter: parent.verticalCenter
          width: 16
          height: 16
          radius: Style.cornerRadius > 0 ? 3 : 0
          color: Util.alpha(widget.fg, 0)
          border.width: 1
          border.color: Commons.Color.muted
        }
        Text {
          id: labelView
          anchors.left: box.right
          anchors.leftMargin: Style.spacing.lg
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rowView.modelData.text
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.check(rowView.modelData.line)
        }
      }
    }
  }
}
