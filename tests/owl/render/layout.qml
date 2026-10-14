// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// One page of a home layout, as the phone draws it, for the before/after
// pictures of the OWL built-ins: `home/` is the plugin of the tree being
// drawn (main's, with the QML ports, or this branch's). Widgets load as
// Home.qml loads them; apps are drawn as plain stand-ins (no desktop entries
// here). $OWL_LAYOUT_JOB: { side, shots: [{ png, items, page, pages }], ... }.
ShellRoot {
  id: shell
  FileView { id: jobFile; path: Quickshell.env("OWL_LAYOUT_JOB"); blockLoading: true }
  readonly property var job: JSON.parse(jobFile.text())
  FileView { id: themeFile; path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"; blockLoading: true }
  property int index: -1
  readonly property var shot: shell.index >= 0 && shell.index < shell.job.shots.length ? shell.job.shots[shell.index] : null
  readonly property bool after: shell.job.side === "after"

  FloatingWindow {
    implicitWidth: 480
    implicitHeight: 1040
    color: Commons.Color.background
    Item {
      id: screen
      anchors.fill: parent
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0; color: Commons.Color.background }
          GradientStop { position: 1; color: Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.accent, 0.25)) }
        }
      }
      Rectangle {
        width: parent.width; height: 44; color: Commons.Color.bar.background
        Text { x: 16; anchors.verticalCenter: parent.verticalCenter; text: "13:27"; color: Commons.Color.bar.text; font.family: Style.font.family; font.pixelSize: 15 }
        Text { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: "󰁹 80%"; color: Commons.Color.bar.text; font.family: Style.font.family; font.pixelSize: 15 }
      }
      Item {
        id: page
        y: 52
        width: parent.width
        height: 1040 - 44 - 72 - 16
        readonly property real cellW: width / 4
        readonly property real cellH: height / 6
        Repeater {
          model: shell.shot ? shell.shot.items : []
          delegate: Item {
            id: cell
            required property var modelData
            readonly property bool isApp: modelData.kind === "app"
            x: modelData.x * page.cellW
            y: modelData.y * page.cellH
            width: modelData.w * page.cellW
            height: modelData.h * page.cellH
            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.md
              visible: !cell.isApp
              radius: Math.max(Style.cornerRadius, 12)
              color: Util.alpha(Commons.Color.menu.background, 0.8)
              clip: true
              Loader {
                anchors.fill: parent
                source: cell.isApp ? "" : String(cell.modelData.type).indexOf("owl:") === 0 ? Qt.resolvedUrl("home/OwlCell.qml")
                  : Qt.resolvedUrl("home/" + cell.modelData.type.charAt(0).toUpperCase() + cell.modelData.type.slice(1) + "Widget.qml")
                onLoaded: {
                  item.home = shell.after ? afterHome.item : beforeHome.item
                  item.entry = cell.modelData
                }
              }
            }
            // An app, drawn plainly: a rounded square with its name.
            Column {
              visible: cell.isApp
              anchors.centerIn: parent
              spacing: 6
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 52; height: 52; radius: 14
                color: Util.alpha(Commons.Color.accent, 0.35)
                Text { anchors.centerIn: parent; text: cell.modelData.app ? cell.modelData.app.split(".").slice(-1)[0].charAt(0).toUpperCase() : ""; color: Commons.Color.menu.text; font.pixelSize: 22; font.family: Style.font.family }
              }
              Text { anchors.horizontalCenter: parent.horizontalCenter; text: cell.modelData.app ? cell.modelData.app.split(".").slice(-1)[0] : ""; color: Commons.Color.bar.text; font.pixelSize: 12; font.family: Style.font.family }
            }
          }
        }
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 1040 - 72 - 14
        Repeater {
          model: shell.shot ? shell.shot.pages : 0
          delegate: Item {
            required property int index
            width: 22; height: 8
            Rectangle { anchors.centerIn: parent; width: index === shell.shot.page ? 9 : 7; height: width; radius: width / 2; color: Commons.Color.menu.text; opacity: index === shell.shot.page ? 1 : 0.5 }
          }
        }
      }
      Rectangle {
        y: 1040 - 72; width: parent.width; height: 72; color: Commons.Color.bar.background
        Rectangle {
          anchors.fill: parent; anchors.margins: 12; color: "transparent"; border.width: 1
          border.color: Util.alpha(Commons.Color.bar.text, 0.4); radius: Style.cornerRadius
          Text { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "󰍉  Search apps…"; color: Util.alpha(Commons.Color.bar.text, 0.6); font.family: Style.font.family; font.pixelSize: 15 }
        }
      }
    }
  }

  Loader { id: beforeHome; active: !shell.after; source: "BeforeHome.qml" }
  Loader {
    id: afterHome
    active: shell.after
    source: "MockHome.qml"
    onLoaded: {
      item.widgets = shell.job.widgets
      item.fixtureTime = shell.job.time
      item.approvals = shell.job.approvals
      item.themeColors = shell.job.themeColors || ({})
    }
  }

  function next() {
    shell.index++
    if (shell.index >= shell.job.shots.length) { Qt.quit(); return }
    settle.restart()
  }
  Timer { id: settle; interval: 3500; onTriggered: screen.grabToImage(function(r) { r.saveToFile(shell.shot.png); console.log("shot " + shell.shot.png); Qt.callLater(shell.next) }) }
  Timer { interval: 1500; running: true; onTriggered: shell.next() }
}
