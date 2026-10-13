// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Recent apps, after Android: every open window as a card with a live
// preview. Swipe sideways through them, tap one to switch to it, flick it up
// to close it. Home shows the home screen (an empty workspace) and leaves the
// apps open. Summoned by swiping up on the dock (omandroid.launcher).
//
// Windows come from the Wayland foreign-toplevel list, which gives each one
// activate() and close(), so nothing here needs Hyprland's dispatcher except
// Home.
Item {
  id: root

  // Injected by the host.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "omandroid.switcher"

  property bool opened: false

  // Newest first, like Android's recents.
  readonly property var windows: {
    var list = ToplevelManager.toplevels.values.slice()
    list.reverse()
    return list
  }

  // Host lifecycle (`shell summon` / `shell hide`).
  function open(payloadJson) { opened = true }
  function close() { opened = false }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function switchTo(toplevel) {
    if (toplevel) toplevel.activate()
    dismiss()
  }

  function goHome() {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"empty\" })"])
    // ...and the home screens (omandroid.home) back on their home page.
    Quickshell.execDetached(["qs", "ipc", "-p", Quickshell.shellDir, "call", "shell", "call", "omandroid.home", "goHome", ""])
    dismiss()
  }

  function closeAll() {
    var list = ToplevelManager.toplevels.values.slice()
    for (var i = 0; i < list.length; i++) list[i].close()
  }

  readonly property color foreground: Commons.Color.menu.text
  readonly property int touch: Math.max(44, Style.space(44))

  PanelWindow {
    id: overlay

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "omandroid-switcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onVisibleChanged: if (visible) cards.positionViewAtBeginning()

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.background
      opacity: 0.94
    }

    // Tapping empty space goes back to whatever was on screen.
    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      anchors.fill: parent
      focus: root.opened
      Keys.onEscapePressed: root.dismiss()
    }

    Text {
      anchors.centerIn: parent
      visible: root.windows.length === 0
      textFormat: Text.PlainText
      text: "No recent apps"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    ListView {
      id: cards

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -Style.space(24)
      height: Math.round(parent.height * 0.68)

      orientation: ListView.Horizontal
      spacing: Style.space(18)
      snapMode: ListView.SnapToItem
      highlightRangeMode: ListView.StrictlyEnforceRange
      preferredHighlightBegin: (width - cardWidth) / 2
      preferredHighlightEnd: (width + cardWidth) / 2
      boundsBehavior: Flickable.StopAtBounds
      model: root.windows

      readonly property int cardWidth: Math.round(width * 0.72)

      delegate: Item {
        id: slot
        required property var modelData
        required property int index

        width: cards.cardWidth
        height: cards.height

        // Title row: app and window title.
        Text {
          id: title
          anchors.left: card.left
          anchors.right: card.right
          anchors.bottom: card.top
          anchors.bottomMargin: Style.space(8)
          opacity: card.opacity
          textFormat: Text.PlainText
          text: (slot.modelData.appId || "") + (slot.modelData.title ? "  " + slot.modelData.title : "")
          elide: Text.ElideRight
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Rectangle {
          id: card

          width: parent.width
          height: parent.height - title.height - Style.space(8)
          y: title.height + Style.space(8) + drag.lift
          radius: Style.cornerRadius
          clip: true
          color: Commons.Color.background
          border.width: 2
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
          opacity: 1 - Math.min(0.8, Math.abs(drag.lift) / height)

          ScreencopyView {
            anchors.fill: parent
            anchors.margins: card.border.width
            captureSource: root.opened ? slot.modelData : null
            live: true
          }

          // Tap to switch.
          TapHandler { onTapped: root.switchTo(slot.modelData) }

          // Flick up to close; anything shorter springs back.
          DragHandler {
            id: drag
            target: null
            xAxis.enabled: false
            property real lift: 0
            onActiveTranslationChanged: lift = Math.min(0, activeTranslation.y)
            onActiveChanged: {
              if (active) return
              if (lift < -card.height * 0.25) {
                closeOut.start()
              } else {
                springBack.start()
              }
            }
          }

          NumberAnimation {
            id: springBack
            target: drag; property: "lift"; to: 0
            duration: 160; easing.type: Easing.OutCubic
          }

          SequentialAnimation {
            id: closeOut
            NumberAnimation { target: drag; property: "lift"; to: -card.height * 1.2; duration: 160; easing.type: Easing.InCubic }
            ScriptAction { script: { slot.modelData.close(); drag.lift = 0 } }
          }
        }
      }
    }

    // Bottom actions: clear everything, or go home.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(28)
      spacing: Style.space(16)

      Repeater {
        model: [
          { label: "Clear all", visible: root.windows.length > 0, action: "clear" },
          { label: "Home", visible: true, action: "home" }
        ]

        delegate: BorderSurface {
          required property var modelData
          visible: modelData.visible
          width: Math.max(root.touch * 2.6, label.implicitWidth + Style.space(32))
          height: root.touch
          radius: Style.cornerRadius
          color: tap.pressed ? Commons.Color.menu.selected || Commons.Color.background : Commons.Color.background

          Text {
            id: label
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.label
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          TapHandler {
            id: tap
            onTapped: modelData.action === "home" ? root.goHome() : root.closeAll()
          }
        }
      }
    }
  }
}
