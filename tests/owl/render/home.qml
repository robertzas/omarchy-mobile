// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "home" as Home
import "home/owl/phone.js" as OwlPhone

// The review screenshots: home pages with OWL widgets, the Widgets sheet and
// the approval sheet, as the phone draws them (480x1040 logical, scale 3),
// with the real OwlCell, OwlView and HomeSheets over MockHome. The status bar
// and the dock are drawn as plain stand-ins.
ShellRoot {
  id: shell

  FileView { id: jobFile; path: Quickshell.env("OWL_HOME_JOB"); blockLoading: true }
  readonly property var job: JSON.parse(jobFile.text())
  FileView { id: themeFile; path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"; blockLoading: true }
  property int index: -1
  readonly property var shot: shell.index >= 0 && shell.index < shell.job.shots.length ? shell.job.shots[shell.index] : null

  FloatingWindow {
    id: win
    implicitWidth: 480
    implicitHeight: 1040
    color: Commons.Color.background

    Item {
      id: screen
      anchors.fill: parent

      // Wallpaper stand-in: the theme's background with a little accent.
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0; color: Commons.Color.background }
          GradientStop { position: 1; color: Qt.tint(Commons.Color.background, Util.alpha(Commons.Color.accent, 0.25)) }
        }
      }

      // Status bar stand-in.
      Rectangle {
        id: bar
        width: parent.width
        height: 44
        color: Commons.Color.bar.background
        Text { x: 16; anchors.verticalCenter: parent.verticalCenter; text: "13:27"; color: Commons.Color.bar.text; font.family: Style.font.family; font.pixelSize: 15 }
        Text { anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; text: "󰁹 80%"; color: Commons.Color.bar.text; font.family: Style.font.family; font.pixelSize: 15 }
      }

      Item {
        id: surface
        y: 44
        width: parent.width
        height: 1040 - 44 - 72

        Item {
          id: page
          y: 8
          width: parent.width
          height: parent.height - 16
          readonly property real cellW: width / 4
          readonly property real cellH: height / 6
          Repeater {
            model: shell.shot ? shell.shot.cells : []
            delegate: Item {
              id: cell
              required property var modelData
              x: modelData.x * page.cellW
              y: modelData.y * page.cellH
              width: modelData.w * page.cellW
              height: modelData.h * page.cellH
              Rectangle {
                id: card
                anchors.fill: parent
                anchors.margins: Style.spacing.md
                radius: Math.max(Style.cornerRadius, 12)
                color: mock.cardColor
                clip: true
                Loader {
                  anchors.fill: parent
                  source: Qt.resolvedUrl("home/OwlCell.qml")
                  onLoaded: {
                    item.home = mock
                    item.entry = { id: "w" + cell.modelData.x + cell.modelData.y, kind: "widget", type: "user:" + cell.modelData.id,
                                   x: cell.modelData.x, y: cell.modelData.y, w: cell.modelData.w, h: cell.modelData.h, config: {} }
                  }
                }
              }
            }
          }
        }

        // Page dots.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          visible: !!shell.shot && shell.shot.pages > 1
          Repeater {
            model: shell.shot ? shell.shot.pages : 0
            delegate: Item {
              required property int index
              width: 22; height: 8
              Rectangle {
                anchors.centerIn: parent
                width: index === shell.shot.page ? 9 : 7
                height: width
                radius: width / 2
                color: index === shell.shot.page ? mock.foreground : mock.dimForeground
                opacity: index === shell.shot.page ? 1 : 0.6
              }
            }
          }
        }

        Home.HomeSheets {
          z: 100
          anchors.fill: parent
          home: mock
        }
      }

      // Dock stand-in: the launcher's search field.
      Rectangle {
        y: 1040 - 72
        width: parent.width
        height: 72
        color: Commons.Color.bar.background
        Rectangle {
          anchors.fill: parent
          anchors.margins: 12
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(Commons.Color.bar.text, 0.4)
          radius: Style.cornerRadius
          Text { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "󰍉  Search apps…"; color: Util.alpha(Commons.Color.bar.text, 0.6); font.family: Style.font.family; font.pixelSize: 15 }
        }
      }
    }
  }

  MockHome {
    id: mock
    widgets: shell.job.widgets
    fixtureTime: shell.job.time
    themeColors: OwlPhone.parseColorsToml(themeFile.text())
  }

  function next() {
    shell.index++
    if (shell.index >= shell.job.shots.length) { Qt.quit(); return }
    const s = shell.job.shots[shell.index]
    mock.shot = s
    mock.approvals = s.approvals
    mock.owlApproveId = s.approveId || ""
    mock.sheet = s.sheet || ""
    mock.editing = !!s.sheet
    settle.restart()
  }
  Timer { id: settle; interval: 2500; onTriggered: shell.capture() }
  function capture() {
    const s = shell.job.shots[shell.index]
    screen.grabToImage(function(result) {
      result.saveToFile(s.png)
      console.log("shot " + s.png)
      Qt.callLater(shell.next)
    })
  }
  Timer { interval: 1500; running: true; onTriggered: shell.next() }
}
