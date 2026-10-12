# SPDX-License-Identifier: MIT
# Adds the lock-keypad hooks to an Omarchy lock plugin directory (LockView.qml
# and Service.qml), next to its Keypad.qml. Used to build the upstream patch
# and to apply the same change to the phone's installed Omarchy until it ships.
# Usage: python3 -I omarchy-lock-keypad-hooks.py <shell/plugins/lock>
import sys
from pathlib import Path

lock = Path(sys.argv[1])


def edit(name, replacements):
    path = lock / name
    text = path.read_text()
    for old, new, count in replacements:
        found = text.count(old)
        if found != count:
            sys.exit(f"{name}: expected {count} of {old!r}, found {found}")
        text = text.replace(old, new)
    path.write_text(text)


edit("LockView.qml", [
    ("  property bool syncingPasswordText: false\n",
     "  property bool syncingPasswordText: false\n"
     "  // Touch-only devices: a number pad under the field (the lock-keypad toggle).\n"
     "  property bool keypad: false\n", 1),
    ('  readonly property string placeholderText: "Enter Password"\n',
     '  readonly property string placeholderText: keypad ? "Enter PIN" : "Enter Password"\n', 1),
    ("      id: inputField\n      width: root.fieldWidth\n      height: root.fieldHeight\n      anchors.centerIn: parent\n",
     "      id: inputField\n      width: root.fieldWidth\n      height: root.fieldHeight\n"
     "      anchors.horizontalCenter: parent.horizontalCenter\n"
     "      anchors.verticalCenter: root.keypad ? undefined : parent.verticalCenter\n"
     "      anchors.bottom: root.keypad ? numberPad.top : undefined\n"
     "      anchors.bottomMargin: root.keypad ? Style.space(40) : 0\n", 1),
    ("    BorderSurface {\n      id: inputField\n",
     "    Keypad {\n"
     "      id: numberPad\n"
     "      visible: root.keypad\n"
     "      enabled: root.inputEnabled && !root.authenticatingPassword\n"
     "      anchors.horizontalCenter: parent.horizontalCenter\n"
     "      anchors.bottom: parent.bottom\n"
     "      anchors.bottomMargin: Math.round(parent.height * 0.08)\n"
     "      onDigit: function(value) {\n"
     "        root.wakeRequested()\n"
     "        if (root.failureMessage.length > 0) root.clearFailureRequested()\n"
     "        root.passwordTextEdited(root.passwordText + value)\n"
     "      }\n"
     "      onBackspace: {\n"
     "        root.wakeRequested()\n"
     "        root.passwordTextEdited(root.passwordText.slice(0, -1))\n"
     "      }\n"
     "      onEnter: {\n"
     "        var submitted = root.passwordText\n"
     "        root.passwordTextEdited(\"\")\n"
     "        if (submitted.length > 0) root.submitPassword(submitted)\n"
     "      }\n"
     "    }\n\n"
     "    BorderSurface {\n      id: inputField\n", 1),
])

# With the number pad, the field itself never takes focus: a focused text field
# asks for an input method, which brings up the on-screen keyboard behind the
# lock and leaves it open after unlocking. A plain item takes the hardware keys.
edit("LockView.qml", [
    ("  function forcePasswordFocus() {\n    passwordInput.forceActiveFocus()\n  }\n",
     "  function forcePasswordFocus() {\n"
     "    if (keypad) keypadKeys.forceActiveFocus()\n"
     "    else passwordInput.forceActiveFocus()\n"
     "  }\n", 1),
    ("        activeFocusOnPress: true\n",
     "        activeFocusOnPress: !root.keypad\n", 1),
    ("    Keypad {\n      id: numberPad\n",
     "    Item {\n"
     "      id: keypadKeys\n"
     "      Keys.onPressed: function(event) {\n"
     "        if (!numberPad.enabled) return\n"
     "        if (event.text.length === 1 && event.text >= \"0\" && event.text <= \"9\") numberPad.digit(event.text)\n"
     "        else if (event.key === Qt.Key_Backspace) numberPad.backspace()\n"
     "        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) numberPad.enter()\n"
     "        else if (event.key === Qt.Key_Escape) root.passwordTextEdited(\"\")\n"
     "        else return\n"
     "        event.accepted = true\n"
     "      }\n"
     "    }\n\n"
     "    Keypad {\n      id: numberPad\n", 1),
])

# Touch-only devices: no hover. The lock surface appearing under a still,
# hidden pointer counted as movement and woke the display just after a power
# button press had turned it off. Taps still wake it.
edit("LockView.qml", [
    ("      hoverEnabled: true\n      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }\n",
     "      hoverEnabled: !root.keypad\n      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }\n", 1),
])

edit("Service.qml", [
    ("  property bool fingerprintConfigured: false\n",
     "  property bool fingerprintConfigured: false\n"
     "  property bool keypad: false\n", 1),
    ("    id: idleBlankTimer\n    interval: 5000\n",
     "    id: idleBlankTimer\n"
     "    // Touch-only devices (the number pad) get longer to find and use it.\n"
     "    interval: root.keypad ? 10000 : 5000\n", 1),
    ("  function beginLock() {\n",
     "  function beginLock() {\n"
     "    keypadToggle.reload()\n", 1),
])

# Every LockView (the lock surface and the preview) gets the keypad setting.
service = lock / "Service.qml"
text = service.read_text()
lines = text.split("\n")
out = []
views = 0
for line in lines:
    out.append(line)
    if line.strip() == "LockView {":
        indent = line[: len(line) - len(line.lstrip())] + "  "
        out.append(indent + "keypad: root.keypad")
        views += 1
if views < 1:
    sys.exit("Service.qml: no LockView found")
text = "\n".join(out)

toggle = (
    "  // Touch-only devices opt into the number pad: omarchy-toggle lock-keypad.\n"
    "  FileView {\n"
    "    id: keypadToggle\n"
    '    path: root.stateHome + "/omarchy/toggles/lock-keypad"\n'
    "    watchChanges: true\n"
    "    printErrors: false\n"
    "    onLoaded: root.keypad = true\n"
    "    onLoadFailed: root.keypad = false\n"
    "    onFileChanged: reload()\n"
    "  }\n\n"
)
anchor = "  FileView {\n"
if text.count(anchor) < 1:
    sys.exit("Service.qml: no FileView anchor")
text = text.replace(anchor, toggle + anchor, 1)
service.write_text(text)
print(f"hooked {lock} ({views} LockView instances)")
