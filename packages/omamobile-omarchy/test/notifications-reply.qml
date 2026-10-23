// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "notifications" as Notifications

// Omarchy's notification service with patch 0015, on a private session bus
// (test/notifications-reply). The script sends a notification that asks for
// an inline reply and a plain one; this opens the reply field on the first,
// types and sends, and prints what it saw as "T ..." lines. Then it quits.
ShellRoot {
  id: shell
  Notifications.Service { id: svc }

  function say(s) { console.log("T " + s) }

  function find(item, name, pred) {
    if (!item) return null
    if (item.objectName === name && (!pred || pred(item))) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var r = find(kids[i], name, pred)
      if (r) return r
    }
    return null
  }

  function cardOf(item) {
    while (item && item.replyRequested === undefined) item = item.parent
    return item
  }

  // The toast window (a stand-in, see the script): Variants' first instance.
  function toastWindow() {
    for (var i = 0; i < svc.data.length; i++) {
      var v = svc.data[i]
      if (v.instances && v.instances.length) return v.instances[0]
    }
    return null
  }

  property bool done: false
  Timer {
    interval: 200; repeat: true; running: !shell.done
    onTriggered: {
      if (svc.popupModel.count !== 2) return
      shell.done = true
      // Newest first: the plain one is index 0, the one asking is index 1.
      shell.say("placeholder plain=" + JSON.stringify(svc.replyPlaceholderAt(0)) + " asking=" + JSON.stringify(svc.replyPlaceholderAt(1)))
      var win = shell.toastWindow()
      var button = shell.find(win.contentItem, "notificationReplyButton", function(b) {
        var c = shell.cardOf(b)
        return c && c.replyPlaceholder.length > 0
      })
      var buttons = 0
      shell.find(win.contentItem, "notificationReplyButton", function(b) { if (b.visible) buttons++; return false })
      shell.say("closed buttons=" + buttons + " focus=" + win.kbFocus)
      var card = shell.cardOf(button)
      card.replyRequested()
      Qt.callLater(function() {
        var field = shell.find(card, "notificationReplyField")
        shell.say("open replies=" + svc.openReplies + " focus=" + win.kbFocus + " field=" + field.visible + " ticking=" + card.parent.ticking)
        field.text = "   "
        card.sendReply()
        shell.say("blank replies=" + svc.openReplies + " count=" + svc.popupModel.count)
        field.text = "On my way"
        card.sendReply()
        Qt.callLater(function() {
          shell.say("sent replies=" + svc.openReplies + " count=" + svc.popupModel.count + " focus=" + win.kbFocus)
          Qt.quit()
        })
      })
    }
  }
}
