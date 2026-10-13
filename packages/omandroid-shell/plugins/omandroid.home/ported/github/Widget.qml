// SPDX-License-Identifier: MIT
// Unread GitHub notifications, reviews waiting on you and your open pull
// requests, through the GitHub CLI (github.sh in this folder). Ported from
// simonschubert/github in Simon Schubert's omarchy-widgets (MIT,
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

  // github.sh's answer plus `at` (ms), kept across layout edits.
  property var gh: host && host.cached ? host.cached : null
  property string failure: ""

  function refresh(force) {
    if (!host || host.busy)
      return;
    if (!force && gh && Date.now() - gh.at < 5 * 60000)
      return;
    host.run(["sh", host.dir + "/github.sh"], function (result) {
      try {
        if (result.code !== 0)
          throw new Error(result.stderr);
        let answer = JSON.parse(result.stdout);
        answer.at = Date.now();
        widget.failure = "";
        widget.gh = answer;
        widget.host.setCached(answer);
      } catch (e) {
        widget.failure = result.timedOut ? "GitHub took too long" : "couldn't ask GitHub";
      }
    }, {
      timeout: 30
    });
  }

  Component.onCompleted: refresh(false)
  Timer {
    interval: 5 * 60000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

  readonly property bool signedIn: !!(gh && gh.auth === true)

  component Count: Column {
    property string label
    property int n
    property color hot
    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      textFormat: Text.PlainText
      text: String(parent.n)
      color: parent.n > 0 ? parent.hot : Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Text {
      id: titleView
      width: parent.width
      textFormat: Text.PlainText
      text: "github"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.spacing.md
        enabled: !widget.editing
        onClicked: widget.host.openUrl("https://github.com/notifications")
      }
    }

    Text {
      width: parent.width
      visible: !widget.signedIn
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : !widget.gh ? "loading…" : widget.gh.missing ? "needs " + (widget.gh.missing === "gh" ? "github-cli" : widget.gh.missing) : "the GitHub CLI isn't signed in"
      color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Rectangle {
      visible: !!(widget.gh && widget.gh.auth === false)
      width: signIn.implicitWidth + Style.spacing.xl * 2
      height: 44
      radius: Style.cornerRadius
      color: Util.alpha(Commons.Color.accent, 0.15)
      Text {
        id: signIn
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "sign in"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: if (widget.host)
          widget.host.launch(["xdg-terminal-exec", "-e", "gh", "auth", "login"])
      }
    }

    Row {
      id: counts
      visible: widget.signedIn
      width: parent.width
      Count {
        width: counts.width / 3
        label: "unread"
        n: widget.signedIn ? widget.gh.unread : 0
        hot: Commons.Color.accent
      }
      Count {
        width: counts.width / 3
        label: "reviews"
        n: widget.signedIn ? widget.gh.reviews : 0
        hot: Commons.Color.urgent
      }
      Count {
        width: counts.width / 3
        label: "my prs"
        n: widget.signedIn ? widget.gh.mine.length : 0
        hot: widget.fg
      }
    }

    ListView {
      visible: widget.signedIn
      width: parent.width
      height: parent.height - y
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.signedIn ? widget.gh.mine : []

      delegate: Item {
        id: pr
        required property var modelData
        width: ListView.view.width
        height: Math.max(prTitle.implicitHeight, Style.font.body * 1.8)
        Text {
          id: repoName
          width: Math.min(implicitWidth, parent.width * 0.35)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: pr.modelData.repo
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          id: prTitle
          x: repoName.width + Style.spacing.md
          width: parent.width - x
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: pr.modelData.title
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl(pr.modelData.url)
        }
      }
    }
  }
}
