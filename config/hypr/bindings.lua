-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

o.bind("SUPER + H", "Hermes desktop", "~/.config/hypr/scripts/hermes-desktop.sh")

-- Browser shortcuts: focus the existing default browser, or launch a new one.
-- The Keybind Editor remapped Omarchy's SUPER+SHIFT+B browser bind onto
-- SUPER+code:56 (physical B). Remove that remapped duplicate before binding B.
hl.unbind("SUPER + SHIFT + B")
hl.unbind("SUPER + B")
o.bind("SUPER + B", "Browser", "~/.config/hypr/scripts/browser-focus-or-launch.sh")
hl.unbind("SUPER + CTRL + B")
o.bind("SUPER + CTRL + B", "New browser", "omarchy-launch-browser")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

-- Open the Omarchy menu when Left Super is released by itself.
-- Super+Space remains available, and other Super shortcuts are unchanged.
o.bind("SUPER + SUPER_L", "Omarchy menu", "omarchy-menu toggle", { release = true })

-- RIP: Schedule a shutdown
o.bind("SUPER + R", "RIP", "~/.config/omarchy/scripts/rip.sh")

-- Locally pinned third-party plugins. These bindings keep Omarchy's stock
-- shortcuts intact while exposing the added functionality.
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.pablo-merino.altswitch/altswitch.lua")
o.bind("SUPER + A", "Exposé", hl.dsp.event("expose.window-overview:toggle"))
o.bind("SUPER + SHIFT + K", "Keybind Editor", "omarchy-shell shell toggle astrofoundry.keybind-editor")
o.bind("SUPER + SHIFT + L", "Lock Screen Explorer", "omarchy-shell lock explore")
