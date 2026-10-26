#!/bin/bash
# SPDX-License-Identifier: MIT
# omamobile-osk-guard against fake gsettings and pgrep: it turns the keyboard
# back on only when no screensaver runs, waits out one that does, and leaves
# an enabled keyboard alone.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
F=$t/fakes; mkdir -p "$F"
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$F/$1"; chmod +x "$F/$1"; }
fake gsettings 'case $1 in
  get) cat "$T/osk" ;;
  set) echo "$4" >"$T/osk"; echo set >>"$T/log" ;;
  monitor) echo false >"$T/osk"; printf "screen-keyboard-enabled: false\n" ;;
esac'
# A screensaver "runs" for as many pgrep calls as $T/screensaver says
fake pgrep 'n=$(cat "$T/screensaver" 2>/dev/null || echo 0); ((n > 0)) || exit 1; echo $((n - 1)) >"$T/screensaver"'
fake sleep ':'
guard() { env T="$t" OMAMOBILE_OSK_GUARD_GRACE=0 PATH="$F:/usr/bin:/bin" bash bin/omamobile-osk-guard "$@" >/dev/null; }
state() { : >"$t/log"; echo "$1" >"$t/osk"; echo "$2" >"$t/screensaver"; }

state false 0; guard --once
[[ $(cat "$t/osk") == true ]] || fail "off with no screensaver: turned back on"
state true 0; guard --once
[[ ! -s $t/log ]] || fail "on: left alone"
state false 3; guard --once
[[ $(cat "$t/osk") == true && $(cat "$t/screensaver") == 0 ]] || fail "a running screensaver is waited out"
pass "the keyboard comes back on only once no screensaver runs"

# Watching: the fake monitor turns the keyboard off and reports it; the
# guard turns it back on, and exits non-zero when the monitor ends, so
# systemd restarts it
state true 0
guard && fail "the guard exits non-zero when its monitor ends"
[[ $(cat "$t/osk") == true && $(grep -c set "$t/log") == 1 ]] || fail "a change the monitor reports is checked"
pass "the watch loop restores the keyboard and exits for a restart when the monitor ends"
