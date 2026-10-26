#!/bin/bash
# SPDX-License-Identifier: MIT
# omamobile-keys' volume keys: a photo while the Camera app (omacam) is in
# front of an unlocked phone, once per press; the volume otherwise. Stand-ins
# for hyprctl, omacam, omarchy-shell and omarchy-audio-output-volume record
# what was called.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/run"
log=$t/calls
cat >"$t/bin/hyprctl" <<STUB
#!/bin/bash
printf '{"class": "%s"}\n' "\$(cat "$t/class")"
STUB
cat >"$t/bin/omacam" <<STUB
#!/bin/bash
echo "omacam \$*" >>"$log"
STUB
cat >"$t/bin/omarchy-audio-output-volume" <<STUB
#!/bin/bash
echo "volume \$*" >>"$log"
STUB
cat >"$t/bin/omarchy-shell" <<STUB
#!/bin/bash
cat "$t/locked"
STUB
chmod +x "$t"/bin/*
export PATH="$t/bin:$PATH" XDG_RUNTIME_DIR="$t/run"
keys() { bash "$here/bin/omamobile-keys" "$@"; }
fail() { printf 'not ok - %s\n' "$1" >&2; cat "$log" >&2 2>/dev/null; exit 1; }
reset() { : >"$log"; rm -rf "$t/run/omamobile-keys"; }

echo foot >"$t/class"; echo false >"$t/locked"
reset; keys volume-up; [[ $(cat "$log") == "volume raise" ]] || fail "volume up raises the volume"
reset; keys volume-down; sleep 0.4; [[ $(cat "$log") == "volume lower" ]] || fail "volume down lowers the volume"

echo omacam >"$t/class"
reset; keys volume-up; [[ $(cat "$log") == "omacam --remote shutter" ]] || fail "volume up takes a photo in the camera"
reset; keys volume-down; sleep 0.4; [[ $(cat "$log") == "omacam --remote shutter" ]] || fail "volume down takes a photo in the camera"
reset; keys volume-up; keys volume-up; keys volume-up
[[ $(grep -c shutter "$log") == 1 ]] || fail "a held key takes one photo"

echo true >"$t/locked"
reset; keys volume-up; [[ $(cat "$log") == "volume raise" ]] || fail "a locked phone changes the volume, never takes a photo"
echo "ok - volume keys: camera shutter in front, volume otherwise"

# The power key's short press, by lock state and screen state. hyprctl answers
# both the window class and the monitors' dpmsStatus; the backlight tools are
# stubs, and bl_power is not consulted (no backlight device on this machine).
cat >"$t/bin/hyprctl" <<STUB
#!/bin/bash
if [[ \$1 == monitors ]]; then printf '[{"dpmsStatus": %s}]\n' "\$(cat "$t/dpms")"; exit 0; fi
printf '{"class": "%s"}\n' "\$(cat "$t/class")"
STUB
cat >"$t/bin/omarchy-hw-display" <<STUB
#!/bin/bash
echo ""
STUB
# No screensaver on this machine, whatever Omarchy runs here.
cat >"$t/bin/pgrep" <<STUB
#!/bin/bash
exit 1
STUB
for tool in omarchy-brightness-display omarchy-system-lock omarchy-shell brightnessctl; do
  cat >"$t/bin/$tool" <<STUB
#!/bin/bash
[[ "$tool \$*" == "omarchy-shell lock isLocked" ]] && { cat "$t/locked"; exit 0; }
echo "$tool \$*" >>"$log"
STUB
done
chmod +x "$t"/bin/*
echo foot >"$t/class"
press() { reset; keys power-down; keys power-up; sleep 0.5; }

echo false >"$t/locked"; echo true >"$t/dpms"
press; grep -q "omarchy-system-lock" "$log" || fail "unlocked and lit: a press locks"
echo false >"$t/locked"; echo false >"$t/dpms"
press; grep -q "omarchy-brightness-display on" "$log" || fail "unlocked and dark: a press lights the screen"
grep -q "omarchy-system-lock" "$log" && fail "unlocked and dark: a press does not lock"
echo true >"$t/locked"; echo true >"$t/dpms"
press; grep -q "omarchy-brightness-display off" "$log" || fail "locked and lit: a press turns the screen off"
grep -q "omarchy-system-lock" "$log" && fail "locked and lit: a press does not lock again"
echo true >"$t/locked"; echo false >"$t/dpms"
press; grep -q "omarchy-shell lock wake" "$log" || fail "locked and dark: a press wakes the lock screen"
grep -q "omarchy-brightness-display on" "$log" || fail "locked and dark: a press lights the screen"
grep -q "omarchy-system-lock" "$log" && fail "locked and dark: a press does not lock again"
# hyprctl failing must read as "screen on": the press locks, never wakes blind.
cat >"$t/bin/hyprctl" <<STUB
#!/bin/bash
exit 1
STUB
echo false >"$t/locked"
press; grep -q "omarchy-system-lock" "$log" || fail "an unanswered screen state reads as lit: the press locks"
echo "ok - power key: lock, screen off, and wake by lock and screen state"
