#!/bin/sh

if omarchy-hyprland-focus-app zen; then
    exit 0
fi

exec omarchy-launch-browser
