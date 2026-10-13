// SPDX-License-Identifier: MIT
// Pure helpers for the phone status bar. The glyph sets match Omarchy's own
// network (panels/network/Model.js) and power (panels/power/Model.js) panels,
// so the phone reads the same as the desktop bar.

function findDevice(devices, type) {
  var list = devices || []
  var fallback = null
  for (var i = 0; i < list.length; i++) {
    var device = list[i]
    if (!device || device.type !== type) continue
    if (device.connected) return device
    if (!fallback) fallback = device
  }
  return fallback
}

function connectedNetwork(networks) {
  var list = networks || []
  for (var i = 0; i < list.length; i++)
    if (list[i] && list[i].connected) return list[i]
  return null
}

function wifiIcon(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return icons[index]
}

// kind: "wifi" | "ethernet" | "off" | "disconnected"
function networkIcon(kind, strength) {
  if (kind === "wifi") return wifiIcon(strength)
  if (kind === "ethernet") return "󰈀"
  if (kind === "off") return "󰤭"
  return "󰤮"
}

function cellularIcon(strength) {
  if (strength < 0) return "󰞃"
  var icons = ["󰢿", "󰢼", "󰢽", "󰢾"]
  return icons[Math.max(0, Math.min(3, Math.floor(strength / 25.01)))]
}

function batteryIcon(percent, charging, full) {
  if (percent < 0) return ""
  if (full) return "󰂅"
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(percent / 10)))
  return charging ? chargingIcons[index] : defaultIcons[index]
}
