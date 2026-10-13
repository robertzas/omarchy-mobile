// SPDX-License-Identifier: MIT
// The latest commits on omacom/omarchy, branch quattro, from GitHub's public
// API. Ported from simonschubert/omarchy-commits in Simon Schubert's
// omarchy-widgets (MIT, Copyright (c) 2026 Simon Schubert and contributors;
// see
// ../../LICENSE-omarchy-widgets). Tap the card for the full feed, then a commit to open it.
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

  readonly property string repo: String(settings.repo || "omacom/omarchy").trim()
  readonly property string branch: String(settings.branch || "quattro").trim()
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }
  readonly property real now: clock.date.getTime() / 1000

  // { key, commits: [...], at: ms } from the last fetch.
  property var reading: host && host.cached ? host.cached : null
  property string failure: ""
  property bool expanded: false
  readonly property var commits: reading && reading.key === repo + "@" + branch ? reading.commits : []

  function refresh(force) {
    var key = repo + "@" + branch;
    if (!force && reading && reading.key === key && Date.now() - reading.at < 10 * 60000)
      return;
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE)
        return;
      try {
        if (xhr.status !== 200)
          throw new Error("HTTP " + xhr.status);
        let list = JSON.parse(xhr.responseText).map(function (c) {
          var info = c.commit || {};
          return {
            sha: String(c.sha || ""),
            short: String(c.sha || "").slice(0, 7),
            url: String(c.html_url || ""),
            at: Date.parse(info.author ? info.author.date : "") / 1000 || 0,
            subject: String(info.message || "").split("\n")[0],
            author: c.author && c.author.login ? String(c.author.login) : info.author ? String(info.author.name) : "someone"
          };
        });
        widget.failure = "";
        widget.reading = {
          key: key,
          commits: list,
          at: Date.now()
        };
        if (widget.host)
          widget.host.setCached(widget.reading);
      } catch (e) {
        widget.failure = xhr.status === 403 ? "rate limited" : xhr.status === 404 ? "no such repository or branch" : "github offline";
      }
    };
    xhr.open("GET", "https://api.github.com/repos/" + encodeURI(repo) + "/commits?sha=" + encodeURIComponent(branch) + "&per_page=20");
    xhr.setRequestHeader("Accept", "application/vnd.github+json");
    xhr.send();
  }

  function ago(at) {
    var s = now - at;
    if (!at)
      return "…";
    return s < 45 ? "now" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : s < 604800 ? Math.floor(s / 86400) + "d" : Qt.formatDate(new Date(at * 1000), "MMM d");
  }

  Component.onCompleted: refresh(false)
  onRepoChanged: refresh(false)
  onBranchChanged: refresh(false)
  Timer {
    interval: 10 * 60000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

  // A tap anywhere on the card switches between the card and the full feed.
  // In the feed a commit opens on GitHub, and refresh and github ↗ keep
  // their own taps; anywhere else goes back.
  function cycle() {
    widget.expanded = !widget.expanded
    list.positionViewAtBeginning()
  }

  MouseArea {
    anchors.fill: parent
    enabled: !widget.editing
    onClicked: widget.cycle()
  }

  Column {
    anchors.fill: parent
    anchors.margins: Style.spacing.xl
    spacing: Style.spacing.md

    Row {
      id: headerPart
      width: parent.width
      spacing: Style.spacing.md
      Text {
        width: parent.width - branchLabel.width - parent.spacing
        textFormat: Text.PlainText
        text: widget.repo.split("/").pop()
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        id: branchLabel
        textFormat: Text.PlainText
        text: widget.expanded ? "back" : widget.branch
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      width: parent.width
      height: 1
      color: Util.alpha(Commons.Color.muted, 0.25)
    }

    Text {
      width: parent.width
      visible: list.count === 0
      textFormat: Text.PlainText
      text: widget.failure !== "" ? widget.failure : "loading…"
      color: widget.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // The full feed's actions.
    Row {
      id: actionsView
      visible: widget.expanded
      spacing: Style.spacing.lg
      Repeater {
        model: [
          {
            label: "refresh",
            act: "refresh"
          },
          {
            label: "github ↗",
            act: "open"
          }
        ]
        delegate: Text {
          id: actionView
          required property var modelData
          textFormat: Text.PlainText
          text: actionView.modelData.label
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.spacing.lg
            enabled: !widget.editing
            onClicked: actionView.modelData.act === "refresh" ? widget.refresh(true) : Qt.openUrlExternally("https://github.com/" + widget.repo + "/commits/" + widget.branch)
          }
        }
      }
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - y
      clip: true
      interactive: !widget.editing && widget.expanded
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.lg
      model: widget.commits

      // Under the rows, as tall as the list: a Flickable keeps taps from the
      // card behind it, so taps on the card's rows and empty space land here.
      MouseArea {
        y: list.originY
        z: -1
        width: list.width
        height: Math.max(list.contentHeight, list.height)
        enabled: !widget.editing
        onClicked: widget.cycle()
      }

      delegate: Item {
        id: commit
        required property var modelData
        required property int index
        width: ListView.view.width
        height: widget.expanded ? full.height : compact.height

        // The card: the subject and its age, the newest in bold.
        Row {
          id: compact
          visible: !widget.expanded
          width: parent.width
          spacing: Style.spacing.lg
          Text {
            width: parent.width - sideView.width - parent.spacing
            textFormat: Text.PlainText
            text: commit.modelData.subject
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: commit.index === 0
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }
          Column {
            id: sideView
            width: widget.cellsWide >= 4 ? Style.font.caption * 6 : Style.font.caption * 3.5
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: widget.ago(commit.modelData.at)
              color: commit.index === 0 ? Commons.Color.accent : widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }
            Text {
              width: parent.width
              visible: widget.cellsWide >= 4
              textFormat: Text.PlainText
              text: commit.modelData.author
              color: widget.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
            }
          }
        }

        // The full feed: subject, author, age and short sha; a tap opens it.
        Column {
          id: full
          visible: widget.expanded
          width: parent.width
          spacing: Style.spacing.xxs
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: commit.modelData.subject
            color: widget.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: commit.modelData.author + " · " + widget.ago(commit.modelData.at) + " · " + commit.modelData.short
            color: widget.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing && widget.expanded
          onClicked: Qt.openUrlExternally(commit.modelData.url)
        }
      }
    }
  }
}
