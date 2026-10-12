// SPDX-License-Identifier: MIT
import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Pull-down quick settings for the phone. The sheet drops from the top edge
// over the status bar: a clock header, eight toggle tiles, then brightness and
// volume. Tap outside it, swipe it up, or press Escape to put it away. The
// Wi-Fi and Bluetooth tiles' chevrons (or a long-press) open the panels in
// WifiPanel.qml and BluetoothPanel.qml.
//
// Backends are the same ones Omarchy's desktop panels drive: Quickshell's
// NetworkManager and BlueZ services, omarchy-bluetooth-power, PipeWire, the
// notification service's do-not-disturb, and brightnessctl for the panel
// backlight. Tiles with no backend on this device render dimmed and do
// nothing; see the STUB notes below.
Item {
  id: root

  // Injected by the host.
  property var shell: null
  property var manifest: null

  property bool opened: false
  readonly property string pluginId: (manifest && manifest.id) || "omandroid.quicksettings"

  // ---------------------------------------------------------------- lifecycle

  // A payload of {"page": "wifi"} or {"page": "bluetooth"} opens that panel
  // instead of the sheet.
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (error) {}
    if (payload.page === "wifi" || payload.page === "bluetooth") {
      openPage(payload.page)
      // Let the host finish delivering this open before it hears a hide.
      Qt.callLater(root.dismiss)
      return
    }
    wifiPicker.close()
    bluetoothPanelItem.close()
    opened = true
    refreshDnd()
    brightness.refresh()
    torch.refresh()
    rotationLock.refresh()
    location.refresh()
    nfc.refresh()
    clockFormatRead.running = true
  }

  // Host-initiated close (`shell hide`).
  function close() {
    opened = false
  }

  // User-initiated close routes through the host so its open state stays in step.
  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // `shell call omandroid.quicksettings state` for scripts and tests.
  function state() {
    return JSON.stringify({
      opened: opened,
      wifi: wifi.enabled,
      bluetooth: bluetooth.enabled,
      doNotDisturb: dnd.enabled,
      torch: torch.available ? torch.enabled : null,
      brightness: brightness.available ? brightness.percent : null,
      volume: audio.available ? Math.round(audio.volume * 100) : null,
      wifiPanel: wifiPicker.opened,
      bluetoothPanel: bluetoothPanelItem.opened
    })
  }

  // `shell call omandroid.quicksettings openBluetooth ''`: the same as the
  // Bluetooth tile's chevron. `bluetoothPanel ''` returns its state as JSON.
  function openBluetooth() {
    if (!bluetooth.available) return "unavailable"
    openBluetoothPanel()
    return bluetoothPanelItem.snapshot()
  }

  function bluetoothPanel() {
    return bluetoothPanelItem.snapshot()
  }

  // `shell call omandroid.quicksettings openWifi ''`: the same as the tile's
  // chevron. `wifiPanel ''` returns the picker's state as JSON.
  function openWifi() {
    if (!wifi.available) return "unavailable"
    openWifiPanel()
    return wifiPicker.snapshot()
  }

  function wifiPanel() {
    return wifiPicker.snapshot()
  }

  // `shell call omandroid.quicksettings toggleTile <name>`: the same
  // action as tapping a tile. Returns the new state() or "unknown".
  function toggleTile(name) {
    var tilesByName = {
      "wifi": wifi, "bluetooth": bluetooth, "mobile-data": mobileData,
      "rotation-lock": rotationLock, "torch": torch, "dnd": dnd, "location": location,
      "nfc": nfc
    }
    var target = tilesByName[String(name || "")]
    if (!target) return "unknown"
    if (!target.available) return "unavailable"
    target.toggle()
    return state()
  }

  // ---------------------------------------------------------------- clock

  // The header follows the bar clock's 12/24-hour choice (Omarchy's clock
  // 12-hour formats all carry "AP"), read from shell.json on open.
  property bool twelveHour: false

  Process {
    id: clockFormatRead
    command: ["sh", "-c", "grep -o '\"clockFormat\": *\"[^\"]*\"' \"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json\" | head -1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var format = String(text || "").replace(/^"clockFormat": *"/, "").replace(/"\s*$/, "")
        root.twelveHour = /AP/i.test(format)
      }
    }
  }


  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: !!battery && battery.isPresent === true

  // ---------------------------------------------------------------- Wi-Fi

  QtObject {
    id: wifi

    readonly property bool backendAvailable: Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var device: {
      for (var i = 0; i < devices.length; i++)
        if (devices[i] && devices[i].type === DeviceType.Wifi) return devices[i]
      return null
    }
    readonly property var network: {
      var networks = device && device.networks ? device.networks.values : []
      for (var i = 0; i < networks.length; i++)
        if (networks[i] && networks[i].connected) return networks[i]
      return null
    }
    readonly property bool available: backendAvailable && !!device && Networking.wifiHardwareEnabled !== false
    readonly property bool enabled: available && Networking.wifiEnabled
    readonly property string status: {
      if (!backendAvailable) return "NetworkManager not running"
      if (!device) return "No Wi-Fi radio"
      if (!Networking.wifiEnabled) return "Off"
      return network ? network.name : "Not connected"
    }

    function toggle() {
      if (available) Networking.wifiEnabled = !Networking.wifiEnabled
    }
  }

  // The picker behind the tile's chevron or a long-press. It is its own
  // window, so the sheet goes away and the picker stays up on its own; its
  // back glyph brings the sheet back.
  function openWifiPanel() {
    openPage("wifi")
    root.dismiss()
  }

  function openBluetoothPanel() {
    openPage("bluetooth")
    root.dismiss()
  }

  // One page at a time.
  function openPage(page) {
    if (page === "wifi") {
      bluetoothPanelItem.close()
      wifiPicker.open()
    } else {
      wifiPicker.close()
      bluetoothPanelItem.open()
    }
  }

  // A page's back glyph: close it and bring the sheet back.
  function backToSheet(page) {
    page.close()
    var summoned = root.shell && typeof root.shell.summon === "function" && root.shell.summon(root.pluginId, "{}")
    if (!summoned) root.open("{}")
  }

  WifiPanel {
    id: wifiPicker
    device: wifi.device
    onBackRequested: root.backToSheet(wifiPicker)
  }

  // ---------------------------------------------------------------- Bluetooth

  QtObject {
    id: bluetooth

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool available: !!adapter
    readonly property bool enabled: available && adapter.enabled
    property bool pending: false
    readonly property var connected: {
      var devices = Bluetooth.devices ? Bluetooth.devices.values : []
      for (var i = 0; i < devices.length; i++)
        if (devices[i] && devices[i].connected) return devices[i]
      return null
    }
    readonly property string status: {
      if (!available) return "No adapter"
      if (pending) return enabled ? "Turning off…" : "Turning on…"
      if (!enabled) return "Off"
      return connected ? (connected.name || "Connected") : "On"
    }

    onEnabledChanged: pending = false

    // Same path as Omarchy's Bluetooth panel: the rfkill block persists across
    // reboots, BlueZ's Powered does not. Ask for a direction, not a toggle, so
    // a second tap while BlueZ catches up cannot undo the first.
    function toggle() {
      if (!available || pending) return
      pending = true
      bluetoothPendingTimeout.restart()
      Quickshell.execDetached(["omarchy-bluetooth-power", enabled ? "off" : "on"])
    }
  }

  // The panel behind the Bluetooth tile's chevron or a long-press; its own
  // window, like the Wi-Fi picker.
  BluetoothPanel {
    id: bluetoothPanelItem
    adapter: bluetooth.adapter
    powerPending: bluetooth.pending
    onBackRequested: root.backToSheet(bluetoothPanelItem)
    onPowerToggleRequested: bluetooth.toggle()
  }

  Timer {
    id: bluetoothPendingTimeout
    interval: 6000
    onTriggered: bluetooth.pending = false
  }

  // ---------------------------------------------------------------- do not disturb

  // A panel plugin gets no handle on omarchy.notifications (the host only
  // proxies it to full bars), so read and set DND through the notification
  // service's own IPC target on this shell instance. Quickshell.shellDir and
  // the inherited WAYLAND_DISPLAY pin the call to this shell, never the desktop's.
  QtObject {
    id: dnd

    property bool enabled: false
    readonly property bool available: true

    function toggle() {
      enabled = !enabled
      dndProc.command = ["qs", "ipc", "-p", Quickshell.shellDir, "call", "notifications", "setDnd", enabled ? "on" : "off"]
      dndProc.running = true
    }
  }

  function refreshDnd() {
    if (dndProc.running) return
    dndProc.command = ["qs", "ipc", "-p", Quickshell.shellDir, "call", "notifications", "dndState"]
    dndProc.running = true
  }

  Process {
    id: dndProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        if (value === "on" || value === "off") dnd.enabled = value === "on"
      }
    }
  }

  // ---------------------------------------------------------------- stubs

  // STUB: mobile data. Quickshell.Networking has no modem backend and the
  // Pixel 7 Pro's modem has no mainline driver, so there is nothing to switch.
  // Wire this to ModemManager (mmcli / its D-Bus API) when a modem exists.
  QtObject {
    id: mobileData
    readonly property bool available: false
    readonly property bool enabled: false
    readonly property string status: "No modem"
    function toggle() {}
  }

  // Rotation lock over omandroid-autorotate (omandroid-sensors): it rotates
  // the screen while the sensor proxy has an accelerometer, unless
  // ~/.local/state/omandroid/rotation-lock exists. Turning the lock off also
  // enables the service, so auto-rotate stays on after a reboot.
  QtObject {
    id: rotationLock

    property bool available: false
    property bool enabled: false
    readonly property string status: !available ? "No sensor" : enabled ? "Locked" : "Auto-rotate"

    function refresh() {
      if (!rotationRead.running) rotationRead.running = true
    }

    function toggle() {
      if (!available || rotationWrite.running) return
      rotationWrite.command = enabled
        ? ["sh", "-c", "rm -f \"$HOME/.local/state/omandroid/rotation-lock\"; systemctl --user enable --now omandroid-autorotate.service"]
        : ["sh", "-c", "mkdir -p \"$HOME/.local/state/omandroid\" && touch \"$HOME/.local/state/omandroid/rotation-lock\""]
      rotationWrite.running = true
    }
  }

  Process {
    id: rotationRead
    // none: no accelerometer; locked: the lock file, or the service is off
    command: ["sh", "-c",
      "busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer 2>/dev/null | grep -q true || { echo none; exit 0; }; "
      + "[ -e \"$HOME/.local/state/omandroid/rotation-lock\" ] && { echo locked; exit 0; }; "
      + "systemctl --user is-active --quiet omandroid-autorotate.service && echo auto || echo locked"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        rotationLock.available = value === "auto" || value === "locked"
        rotationLock.enabled = value === "locked"
      }
    }
  }

  Process {
    id: rotationWrite
    onExited: rotationLock.refresh()
  }

  // Location over omandroid-gnss (package omandroid-gnss): on lets apps ask
  // GeoClue for positions and runs the receiver only while one does; off
  // stops it and lets nothing start it. As the user, on/off go through
  // polkit. "No GNSS" when the command or the vendor files are missing.
  QtObject {
    id: location

    property bool available: false
    property bool enabled: false
    property bool running: false
    readonly property string status: !available ? "No GNSS" : !enabled ? "Off" : running ? "In use" : "On"

    function refresh() {
      if (!locationRead.running) locationRead.running = true
    }

    function toggle() {
      if (!available || locationWrite.running) return
      locationWrite.command = ["omandroid-gnss", enabled ? "off" : "on"]
      enabled = !enabled
      locationWrite.running = true
    }
  }

  Process {
    id: locationRead
    command: ["omandroid-gnss", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = null
        try { info = JSON.parse(String(text || "").trim()) } catch (error) {}
        location.available = !!info && info.installed === true
        location.enabled = !!info && info.location === "on"
        location.running = !!info && info.running === "yes"
      }
    }
    onExited: function(exitCode) { if (exitCode !== 0) location.available = false }
  }

  Process {
    id: locationWrite
    onExited: location.refresh()
  }

  // NFC through its rfkill switch, which the kernel's NFC core registers for
  // each controller (type "nfc"); the session may write /dev/rfkill. "No NFC"
  // until a controller has probed.
  QtObject {
    id: nfc

    property bool available: false
    property bool enabled: false
    readonly property string status: !available ? "No NFC" : enabled ? "On" : "Off"

    function refresh() {
      if (!nfcRead.running) nfcRead.running = true
    }

    function toggle() {
      if (!available || nfcWrite.running) return
      nfcWrite.command = ["rfkill", enabled ? "block" : "unblock", "nfc"]
      enabled = !enabled
      nfcWrite.running = true
    }
  }

  Process {
    id: nfcRead
    command: ["rfkill", "-rn", "-o", "TYPE,SOFT"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n").filter(function(line) { return /^nfc\s/.test(line) })
        nfc.available = lines.length > 0
        nfc.enabled = lines.length > 0 && lines.every(function(line) { return /\sunblocked$/.test(line) })
      }
    }
    onExited: function(exitCode) { if (exitCode !== 0) nfc.available = false }
  }

  Process {
    id: nfcWrite
    onExited: nfc.refresh()
  }

  // The rear flash LED in torch mode (leds-lm3644, white:torch). "100%" is
  // the device tree's torch cap, not the chip's maximum. brightnessctl goes
  // through logind's SetBrightness when it can't write sysfs itself, which
  // the active session may do for leds devices.
  QtObject {
    id: torch

    property bool available: false
    property bool enabled: false
    readonly property string status: !available ? "No flash LED" : enabled ? "On" : "Off"

    function refresh() {
      if (!torchRead.running) torchRead.running = true
    }

    function toggle() {
      if (!available || torchWrite.running) return
      torchWrite.command = ["brightnessctl", "--device=white:torch", "--quiet", "set", enabled ? "0" : "100%"]
      torchWrite.running = true
    }
  }

  Process {
    id: torchRead
    command: ["brightnessctl", "--device=white:torch", "--machine-readable", "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // device,class,current,percent%,max
        var parts = String(text || "").trim().split(",")
        var current = parts.length >= 3 ? parseInt(parts[2], 10) : NaN
        torch.available = isFinite(current)
        torch.enabled = isFinite(current) && current > 0
      }
    }
    onExited: function(exitCode) { if (exitCode !== 0) torch.available = false }
  }

  Process {
    id: torchWrite
    onExited: torch.refresh()
  }

  // ---------------------------------------------------------------- brightness

  // The panel backlight through brightnessctl's backlight class, the device
  // a phone actually has. No backlight (a desktop with only external
  // monitors) leaves the row dimmed.
  QtObject {
    id: brightness

    property bool available: false
    property int percent: 0
    property int pendingPercent: -1

    function refresh() {
      if (!brightnessRead.running) brightnessRead.running = true
    }

    function set(fraction) {
      percent = Math.max(1, Math.round(fraction * 100))
      pendingPercent = percent
      if (!brightnessWrite.running) flush()
    }

    function flush() {
      if (pendingPercent < 0) return
      brightnessWrite.command = ["brightnessctl", "--class=backlight", "--quiet", "set", pendingPercent + "%"]
      pendingPercent = -1
      brightnessWrite.running = true
    }
  }

  Process {
    id: brightnessRead
    command: ["brightnessctl", "--class=backlight", "--machine-readable", "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // device,class,current,percent%,max
        var parts = String(text || "").trim().split(",")
        var value = parts.length >= 4 ? parseInt(parts[3], 10) : NaN
        brightness.available = isFinite(value)
        if (isFinite(value)) brightness.percent = value
      }
    }
    onExited: function(exitCode) { if (exitCode !== 0) brightness.available = false }
  }

  Process {
    id: brightnessWrite
    onExited: brightness.flush()
  }

  // ---------------------------------------------------------------- volume

  QtObject {
    id: audio

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool available: !!sink && !!sink.audio
    readonly property real volume: available ? Math.min(1, sink.audio.volume) : 0
    readonly property bool muted: available ? sink.audio.muted : false
    readonly property string icon: {
      if (!available) return "󰖁"
      if (muted) return "󰖁"
      if (volume >= 0.67) return "󰕾"
      if (volume >= 0.34) return "󰖀"
      return "󰕿"
    }

    function setVolume(value) {
      if (!available) return
      sink.audio.volume = Math.max(0, Math.min(1, value))
      if (sink.audio.muted && value > 0) sink.audio.muted = false
    }

    function toggleMute() {
      if (available) sink.audio.muted = !sink.audio.muted
    }
  }

  PwObjectTracker { objects: audio.sink ? [audio.sink] : [] }

  // ---------------------------------------------------------------- surface

  // 0 = tucked above the screen, 1 = fully down. Driving the window's
  // visibility from this lets the sheet finish sliding up before it unmaps.
  property real reveal: opened ? 1 : 0
  Behavior on reveal { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

  readonly property color foreground: Commons.Color.popups.text
  readonly property int pad: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.lg

  PanelWindow {
    id: window

    visible: root.opened || root.reveal > 0
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omandroid-quicksettings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
      opacity: root.reveal
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: sheet

      x: Style.gapsOut
      width: parent.width - Style.gapsOut * 2
      height: content.implicitHeight + sheet.contentTopInset + sheet.contentBottomInset
      y: Style.gapsOut - (height + Style.gapsOut * 2) * (1 - root.reveal) + drag.offset
      color: Commons.Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: root.pad

      focus: root.opened
      Keys.onEscapePressed: root.dismiss()

      // Swallow taps inside the sheet so they don't reach the scrim, and turn
      // an upward swipe anywhere on it into a dismiss.
      MouseArea {
        id: drag
        anchors.fill: parent
        property real startY: 0
        property real offset: 0
        onPressed: function(mouse) { startY = mouse.y; offset = 0 }
        onPositionChanged: function(mouse) { offset = Math.min(0, mouse.y - startY) }
        onReleased: {
          if (offset < -Style.space(60)) root.dismiss()
          offset = 0
        }
        onCanceled: offset = 0
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: sheet.contentTopInset
        anchors.rightMargin: sheet.contentRightInset
        anchors.bottomMargin: sheet.contentBottomInset
        anchors.leftMargin: sheet.contentLeftInset
        spacing: root.pad

        // ---------- Header: time and date, battery on the right
        Item {
          width: parent.width
          implicitHeight: Math.max(headerClock.implicitHeight, headerBattery.implicitHeight)

          Column {
            id: headerClock
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              text: Qt.formatDateTime(clock.date, root.twelveHour ? "h:mm AP" : "HH:mm")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: Qt.formatDateTime(clock.date, "dddd, d MMMM")
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Text {
            id: headerBattery
            visible: root.hasBattery
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.hasBattery
              ? (UPower.onBattery ? "󰁹 " : "󰂄 ") + Math.round(root.battery.percentage * 100) + "%"
              : ""
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Toggle tiles
        Grid {
          id: tiles
          width: parent.width
          columns: 2
          columnSpacing: root.gap
          rowSpacing: root.gap

          readonly property real tileWidth: (width - columnSpacing) / 2

          Tile {
            width: tiles.tileWidth
            icon: wifi.enabled ? "󰤨" : "󰤭"
            label: "Wi-Fi"
            status: wifi.status
            active: wifi.enabled
            available: wifi.available
            details: true
            onClicked: wifi.toggle()
            onDetailsRequested: root.openWifiPanel()
          }

          Tile {
            width: tiles.tileWidth
            icon: bluetooth.enabled ? (bluetooth.connected ? "󰂱" : "󰂯") : "󰂲"
            label: "Bluetooth"
            status: bluetooth.status
            active: bluetooth.enabled
            available: bluetooth.available
            busy: bluetooth.pending
            details: true
            onClicked: bluetooth.toggle()
            onDetailsRequested: root.openBluetoothPanel()
          }

          Tile {
            width: tiles.tileWidth
            icon: "󰞃"
            label: "Mobile data"
            status: mobileData.status
            active: mobileData.enabled
            available: mobileData.available
            onClicked: mobileData.toggle()
          }

          Tile {
            width: tiles.tileWidth
            icon: "󰑵"
            label: "Rotation lock"
            status: rotationLock.status
            active: rotationLock.enabled
            available: rotationLock.available
            onClicked: rotationLock.toggle()
          }

          Tile {
            width: tiles.tileWidth
            icon: location.enabled ? "󰍎" : "󰍐"
            label: "Location"
            status: location.status
            active: location.enabled
            available: location.available
            onClicked: location.toggle()
          }

          Tile {
            width: tiles.tileWidth
            icon: "󰎖"
            label: "NFC"
            status: nfc.status
            active: nfc.enabled
            available: nfc.available
            onClicked: nfc.toggle()
          }

          Tile {
            width: tiles.tileWidth
            icon: "󰉄"
            label: "Torch"
            status: torch.status
            active: torch.enabled
            available: torch.available
            onClicked: torch.toggle()
          }

          Tile {
            width: tiles.tileWidth
            icon: dnd.enabled ? "󰂛" : "󰂚"
            label: "Do not disturb"
            status: dnd.enabled ? "On" : "Off"
            active: dnd.enabled
            available: dnd.available
            onClicked: dnd.toggle()
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Sliders
        Column {
          width: parent.width
          spacing: Style.spacing.sm

          SliderRow {
            width: parent.width
            icon: "󰃠"
            value: brightness.percent / 100
            available: brightness.available
            unavailableText: "No backlight"
            onMoved: function(value) { brightness.set(value) }
          }

          SliderRow {
            width: parent.width
            icon: audio.icon
            value: audio.volume
            available: audio.available
            unavailableText: "No audio output"
            onMoved: function(value) { audio.setVolume(value) }
            onIconClicked: audio.toggleMute()
          }
        }

        // ---------- Handle: a visible cue that the sheet swipes back up
        Item {
          width: parent.width
          height: Math.max(24, Style.space(24))

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(48)
            height: Math.max(4, Style.space(4))
            radius: height / 2
            color: Util.alpha(root.foreground, 0.35)
          }
        }
      }
    }
  }
}
