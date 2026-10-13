// SPDX-License-Identifier: MIT
// The latest release of each GitHub repository you list; new ones stand out.
// Ported from simonschubert/releases in Simon Schubert's omarchy-widgets
// (MIT, Copyright (c) 2026 Simon Schubert and contributors; see
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

  readonly property var repos: String(settings.repos || "").split(/[\s,]+/).filter(function (r) {
    return /^[\w.-]+\/[\w.-]+$/.test(r);
  })
  readonly property color fg: host ? host.foreground : Commons.Color.menu.text
  readonly property color dim: host ? host.dimForeground : Commons.Color.menu.text

  SystemClock {
    id: clock
    precision: SystemClock.Hours
  }
  readonly property real now: clock.date.getTime() / 1000

  // { key, releases: [{ repo, tag, url, at }], at: ms }. GitHub allows 60
  // requests an hour without a token: one per repository, once an hour.
  property var reading: host && host.cached ? host.cached : null
  readonly property var releases: reading && reading.key === repos.join(" ") ? reading.releases : []
  property bool fetching: false
  property string failure: ""

  function refresh(force) {
    var key = repos.join(" ");
    if (fetching)
      return;
    if (!force && reading && reading.key === key && Date.now() - reading.at < 3600000)
      return;
    var got = [];
    var left = repos.length;
    var errors = 0;
    var finish = function () {
      got.sort(function (a, b) {
        return b.at - a.at;
      });
      widget.fetching = false;
      widget.failure = got.length === 0 && errors > 0 ? "couldn't reach GitHub" : "";
      if (got.length === 0 && errors > 0)
        return;
      widget.reading = {
        key: key,
        releases: got,
        at: Date.now()
      };
      if (widget.host)
        widget.host.setCached(widget.reading);
    };
    if (left === 0) {
      finish();
      return;
    }
    fetching = true;
    repos.forEach(function (repo) {
      var xhr = new XMLHttpRequest();
      xhr.onreadystatechange = function () {
        if (xhr.readyState !== XMLHttpRequest.DONE)
          return;
        try {
          if (xhr.status !== 200)
            throw new Error("HTTP " + xhr.status);
          let r = JSON.parse(xhr.responseText);
          got.push({
            repo: repo,
            tag: String(r.tag_name || ""),
            url: String(r.html_url || ""),
            at: Date.parse(r.published_at) / 1000 || 0
          });
        } catch (e) {
          errors++;
        }
        if (--left === 0)
          finish();
      };
      xhr.open("GET", "https://api.github.com/repos/" + repo + "/releases/latest");
      xhr.setRequestHeader("Accept", "application/vnd.github+json");
      xhr.send();
    });
  }

  Component.onCompleted: refresh(false)
  onReposChanged: refresh(false)
  Timer {
    interval: 3600000
    repeat: true
    running: true
    onTriggered: widget.refresh(true)
  }

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
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: widget.failure !== "" ? "releases · " + widget.failure : "releases"
        color: widget.failure !== "" ? Commons.Color.urgent : widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "edit"
        color: widget.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        anchors.fill: parent
        enabled: !widget.editing
        onClicked: if (widget.host)
          widget.host.openSettings()
      }
    }

    ListView {
      width: parent.width
      height: parent.height - headerPart.height - parent.spacing
      clip: true
      interactive: !widget.editing
      boundsBehavior: Flickable.StopAtBounds
      spacing: Style.spacing.sm
      model: widget.releases

      delegate: Item {
        id: release
        required property var modelData
        readonly property int days: Math.floor((widget.now - release.modelData.at) / 86400)
        readonly property bool fresh: release.days < 7
        width: ListView.view.width
        height: Math.max(nameView.implicitHeight, Style.font.body * 1.8)

        Rectangle {
          id: dot
          width: 6
          height: 6
          radius: 3
          anchors.verticalCenter: parent.verticalCenter
          visible: release.fresh
          color: Commons.Color.accent
        }
        Text {
          id: nameView
          x: dot.width + Style.spacing.md
          width: parent.width - x - tagView.width - age.width - Style.spacing.md * 2
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: release.modelData.repo.split("/")[1]
          color: widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          id: tagView
          anchors.right: age.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, release.width * 0.4)
          textFormat: Text.PlainText
          text: release.modelData.tag
          color: release.fresh ? Commons.Color.accent : widget.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          id: age
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: release.days < 1 ? "today" : release.days + "d"
          color: widget.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          enabled: !widget.editing
          onClicked: widget.host.openUrl(release.modelData.url)
        }
      }
    }
  }
}
