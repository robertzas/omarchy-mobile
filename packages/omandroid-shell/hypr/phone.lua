-- SPDX-License-Identifier: MIT
-- Omandroid's Hyprland rules for a phone, loaded after Omarchy's defaults
-- (from the user's looknfeel.lua). Package updates reach them.

-- Apps fill the screen between the bar and the dock, like Android. Omarchy's
-- floating windows (its terminal, btop, dialogs) are sized for a desktop and
-- would land mostly off a 480 px wide screen.
-- Omarchy floats them through its floating-window tag, so drop the tag.
hl.window_rule({ match = { class = ".*" }, tag = "-floating-window" })
hl.window_rule({ match = { class = ".*" }, maximize = true })
-- ...except the screensaver, which Omarchy shows fullscreen over the bars.
hl.window_rule({ match = { class = "^org.omarchy.screensaver$" }, maximize = false })
hl.window_rule({ match = { class = "^org.omarchy.screensaver$" }, fullscreen = true })

-- Lock after boot, like a phone: the session logs in automatically, then
-- Omarchy's lock comes up with its PIN pad. Only once a PIN is set (the
-- lock-on-start toggle), since a lock with no password can't be opened.
o.launch_on_start(
  "bash -c 'omarchy-toggle-enabled lock-on-start || exit 0; "
    .. "for _ in $(seq 100); do omarchy-shell lock status >/dev/null 2>&1 && break; sleep 0.2; done; "
    .. "omarchy-system-lock'"
)

-- Hardware keys, like Android: a short power press locks and turns the
-- screen off (or wakes a locked phone), holding power opens Omarchy's system
-- menu, and power + volume down takes a screenshot. omandroid-keys works out
-- which gesture it was.
hl.unbind("XF86PowerOff")
o.bind("XF86PowerOff", "Power key", "omandroid-keys power-down", { locked = true })
o.bind("XF86PowerOff", "System menu", "omandroid-keys power-up", { locked = true, release = true })
o.bind("XF86AudioLowerVolume", "Screenshot chord", "omandroid-keys volume-down", { locked = true, non_consuming = true })

-- A fresh phone (no name and email, or no PIN): a notification offers the
-- onboarding that Omarchy's installer does on a computer.
o.launch_on_start("omandroid-onboarding --nudge")

-- The screensaver turns the on-screen keyboard off while it runs and back on
-- when it exits (patches/omarchy/0006). A session restart, a reboot or the
-- lock can end it before it does, which left the keyboard off for good. No
-- screensaver runs at login, so turn it on here.
o.launch_on_start("gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true")
