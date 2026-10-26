#!/bin/bash
# SPDX-License-Identifier: MIT
# omamobile-setup-user against a scratch home and fake commands (omarchy-done,
# gsettings, systemctl, chromium): run twice, as two logins would, and check
# what it leaves in the user's files.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
pkg=$PWD
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

F=$t/fakes; H=$t/home; mkdir -p "$F" "$H/.config/hypr" "$H/.config/omarchy/extensions"
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$F/$1"; chmod +x "$F/$1"; }
# omarchy-done: ensure succeeds once per name, mark records it
fake omarchy-done 'd=$HOME/.local/state/omarchy/done; mkdir -p "$d"
case $1 in
  ensure) [[ -e $d/$2 ]] && exit 1; touch "$d/$2" ;;
  mark) touch "$d/$2" ;;
esac'
fake gsettings 'echo "gsettings $*" >>"$HOME/calls"'
fake systemctl 'echo "systemctl $*" >>"$HOME/calls"'
fake chromium 'echo "Chromium 153.0.0.0"'
for f in monitors looknfeel autostart; do echo "-- $f" >"$H/.config/hypr/$f.lua"; done
echo 'local omarchy_monitor_scale = 2' >"$H/.config/hypr/monitors.lua"
# Omarchy's shipped extension file starts like this
printf '{\n  // Extend the Quickshell Omarchy menu with JSONC.\n  // "personal": {"icon":"","label":"Personal"},\n}\n' \
  >"$H/.config/omarchy/extensions/omarchy-menu.jsonc"

# The system's desktop entries: some of the apps the phone hides, one of them
# marked NoDisplay=false, and one app it keeps
A=$t/applications; mkdir -p "$A"
for id in org.gnome.DiskUtility org.gnome.Evince cups; do
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$id" "$id" >"$A/$id.desktop"
done
printf '[Desktop Entry]\nType=Application\nName=Disks\nNoDisplay=false\nExec=gnome-disks\n' >"$A/org.gnome.DiskUtility.desktop"
printf '[Desktop Entry]\nType=Application\nName=Papers\nExec=papers\n' >"$A/org.gnome.Papers.desktop"

run() {
  env -i HOME="${RUN_HOME:-$H}" PATH="$F:/usr/bin:/bin" XDG_RUNTIME_DIR="$t" OMAMOBILE_SHELL_SHARE="$pkg" OMAMOBILE_SYSTEM_APPLICATIONS="$A" \
    bash bin/omamobile-setup-user >"$t/out" 2>&1 || { cat "$t/out"; fail "omamobile-setup-user runs"; }
}
run
# A user who wants Logout back gives the row their own entry
ext=$H/.config/omarchy/extensions/omarchy-menu.jsonc
sed -i 's|^  "system.logout": {"when": "false"},$|  "system.logout": {"when": "true"},|' "$ext"
run

# The extension file as the menu reads it: JSONC with trailing commas
menu=$(python3 -I - "$ext" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
text = re.sub(r',(\s*[}\]])', r'\1', text)
for key, value in json.loads(text).items():
    print(key, value.get("when", ""))
PY
) || fail "the menu extension file stays valid JSONC"
for id in update.channel update.channel.stable update.channel.rc update.channel.edge update.channel.dev \
          update.config.hyprland update.config.shell setup.direct-boot update.password.drive \
          learn.keybindings learn.tmux-keybindings learn.herdr-keybindings \
          style.bar.position.left style.bar.position.right style.bar.position.bottom \
          trigger.toggle.top-bar trigger.toggle.one-window-ratio trigger.toggle.workspace-layout \
          install.windows install.browser.chrome install.gaming.steam; do
  grep -qx "$id false" <<<"$menu" || fail "Menu row $id is hidden"
  [[ $(grep -c "\"$id\"" "$ext") == 1 ]] || fail "Menu row $id is named once after two logins"
done
grep -qx 'system.logout true' <<<"$menu" || fail "a row the user set is left as they set it"
for id in style.bar.position.top update.omarchy install.gaming.retroarch; do
  grep -q "^$id false" <<<"$menu" && fail "Menu row $id stays"
done
pass "menu rows that break the phone are hidden once, by content, and a user's own entry is kept"

U=$H/.local/share/applications
for id in org.gnome.DiskUtility org.gnome.Evince cups; do
  [[ $(grep -c '^NoDisplay=true$' "$U/$id.desktop") == 1 ]] || fail "$id is hidden from the launcher"
  grep -c '^NoDisplay=false' "$U/$id.desktop" >/dev/null && fail "$id loses its NoDisplay=false"
  grep -qx "Exec=$id" "$U/$id.desktop" || [[ $id == org.gnome.DiskUtility ]] || fail "$id keeps its entry"
done
[[ ! -e $U/org.gnome.Papers.desktop ]] || fail "Papers stays in the launcher"
[[ ! -e $U/foot-server.desktop ]] || fail "an app that isn't installed gets no override"
# The user brings Disks back; an app installed later is hidden at the next login
rm "$U/org.gnome.DiskUtility.desktop"
printf '[Desktop Entry]\nType=Application\nName=Foot Server\nExec=foot --server\n' >"$A/foot-server.desktop"
run
[[ ! -e $U/org.gnome.DiskUtility.desktop ]] || fail "an override the user removed stays removed"
grep -qx 'NoDisplay=true' "$U/foot-server.desktop" || fail "an app installed later is hidden"
pass "desktop and admin apps are hidden once each, when installed, and a user's choice is kept"

# Idle: a new user gets the profile's block and the screensaver toggle
idle() { python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get("idle")))' "$1/.config/omarchy/shell.json"; }
toggle() { [[ -e $1/.local/state/omarchy/toggles/screensaver-off ]]; }
[[ $(idle "$H") == '{"screensaver": 0, "lock": 60}' ]] || fail "a new user's profile has the phone's idle block"
toggle "$H" || fail "a new user's screensaver is off"
# Users set up before this: one without an idle block, one with their own
for who in plain own; do
  h=$t/$who; mkdir -p "$h/.config/hypr" "$h/.config/omarchy" "$h/.local/state/omarchy/done"
  cp "$H"/.config/hypr/*.lua "$h/.config/hypr/"
  touch "$h/.local/state/omarchy/done/omamobile-shell-profile"
  echo '{"version": 1, "plugins": []}' >"$h/.config/omarchy/shell.json"
done
echo '{"version": 1, "plugins": [], "idle": {"screensaver": 300, "lock": 0}}' >"$t/own/.config/omarchy/shell.json"
RUN_HOME=$t/plain run
RUN_HOME=$t/own run
[[ $(idle "$t/plain") == '{"screensaver": 0, "lock": 60}' ]] && toggle "$t/plain" || fail "an earlier user without an idle block gets the phone's"
[[ $(idle "$t/own") == '{"screensaver": 300, "lock": 0}' ]] && ! toggle "$t/own" || fail "a user's own idle block is kept, and their screensaver"
pass "idle: lock after a minute, no screensaver, unless the user set their own"
