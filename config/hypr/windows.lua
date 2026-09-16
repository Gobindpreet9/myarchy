-- Personal Hyprland window rules.
-- Loaded from ~/.config/hypr/hyprland.lua via require("hypr.windows"),
-- so omarchy package updates never rewrite this file.
--
-- Revert: comment out the require("hypr.windows") line in hyprland.lua and
-- `hyprctl reload` (or delete this file).
--
-- == Forza Horizon 6 under Bottles/Proton, added 2026-09-15 =================
--
-- The game is launched by `bottles-cli run --bottle "Forza Horizon 6"` and its
-- windows arrive with WM class "steam_proton" (xdg tag "proton-game"),
-- xwayland=false, floating, from one process. Two windows are created; measured
-- with `hyprctl clients -j` during a real launch:
--
--   class=steam_proton | initialTitle="Forza Horizon 6" | 2048x1152 @0,0       | fullscreen
--   class=steam_proton | initialTitle=""                | 2560x1440 @-256,-131 | floating
--
-- The untitled second one is the "empty/black screen" that used to grab focus
-- and fullscreen itself over the game, forcing an alt-tab back to the game.

-- 1. The untitled window: never focus it, never let it take focus on creation,
--    and ignore its requests to activate/fullscreen itself over the game.
--    Matched on the *initial* title, so a transient empty title on the game's
--    own window can never make the game unfocusable.
o.window(
  { class = "^(steam_proton|forzahorizon6\\.exe|forzahorizon6)$", initial_title = "^$" },
  {
    no_focus = true,
    no_initial_focus = true,
    suppress_event = "activate fullscreen",
  }
)

-- 2. Any window of the game (both of the above): keep the compositor's idle
--    timer inhibited for as long as the game is up. Gamepad input does not
--    count as activity for Hyprland's idle-notify, so without this omarchy's
--    screensaver (idle.screensaver in ~/.config/omarchy/shell.json, 150s)
--    blanks the screen in the middle of a race. omarchy's Quickshell idle
--    service runs with respectInhibitors, so this rule is enough.
o.window(
  { class = "^(steam_proton|forzahorizon6\\.exe|forzahorizon6)$" },
  { idle_inhibit = "always" }
)
