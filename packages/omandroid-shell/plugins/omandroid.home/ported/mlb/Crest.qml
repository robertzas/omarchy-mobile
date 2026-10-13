// SPDX-License-Identifier: MIT
// A club crest or team logo, or empty space of the same size.
import QtQuick

Item {
  id: crest
  property string url: ""
  property int px: 18
  width: px
  height: px

  Image {
    anchors.fill: parent
    visible: crest.url !== ""
    source: crest.url
    sourceSize.width: crest.px * 2
    sourceSize.height: crest.px * 2
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    cache: true
  }
}
