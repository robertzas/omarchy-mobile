// SPDX-License-Identifier: MIT
import QtQuick

// Column, Row, Flow, Box, Grid and Spacer: layout.js has placed the
// children, so this only holds them. A `scroll: true` Column holds them in
// a Flickable.
OwlNodeBase {
  id: block

  readonly property bool scrolls: block.node !== null && block.node.kind === "Column" && block.p.scroll === true
  container: block.scrolls ? flick.contentItem : block

  Flickable {
    id: flick
    visible: block.scrolls
    enabled: block.scrolls
    anchors.fill: parent
    contentWidth: width
    contentHeight: block.box ? block.box.content * block.dp : 0
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: block.scrolls && contentHeight > height + 1
  }
}
