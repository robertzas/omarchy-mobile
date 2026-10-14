// SPDX-License-Identifier: MIT
import QtQuick

// Image: a local file (~/ or /), an asset (data:), never a web address
// (that would be a network fetch nobody approved). With `tint`, the picture
// is recoloured once into a Canvas, not by a live effect (plan §2.3).
OwlNodeBase {
  id: imageNode

  readonly property string url: imageNode.view ? imageNode.view.imageUrl(imageNode.p.src) : ""
  readonly property bool tinted: !!imageNode.p.tint

  Image {
    id: picture
    x: imageNode.innerX
    y: imageNode.innerY
    width: imageNode.innerW
    height: imageNode.innerH
    visible: !imageNode.tinted
    source: imageNode.url
    asynchronous: true
    smooth: true
    mipmap: true
    sourceSize.width: Math.max(1, width * (imageNode.view ? imageNode.view.devicePixelRatio : 1))
    fillMode: imageNode.p.fit === "cover" ? Image.PreserveAspectCrop : imageNode.p.fit === "fill" ? Image.Stretch : Image.PreserveAspectFit
    onStatusChanged: if (status === Image.Ready && imageNode.view) imageNode.view.noteImage(String(imageNode.p.src), implicitWidth, implicitHeight)
  }

  Canvas {
    id: tintCanvas
    x: imageNode.innerX
    y: imageNode.innerY
    width: imageNode.innerW
    height: imageNode.innerH
    visible: imageNode.tinted
    readonly property var deps: [imageNode.url, imageNode.p.tint, width, height]
    onDepsChanged: if (imageNode.tinted) { if (imageNode.url && !isImageLoaded(imageNode.url)) loadImage(imageNode.url); requestPaint() }
    onImageLoaded: requestPaint()
    onPaint: {
      const ctx = getContext("2d")
      ctx.reset()
      if (!imageNode.url || !isImageLoaded(imageNode.url)) return
      ctx.drawImage(imageNode.url, 0, 0, width, height)
      ctx.globalCompositeOperation = "source-in"
      ctx.fillStyle = imageNode.p.tint
      ctx.fillRect(0, 0, width, height)
    }
  }
}
