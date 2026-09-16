#!/bin/bash
# ~/.config/omarchy/scripts/rip.sh

# Check for test mode
if [[ "$1" == "--test" ]]; then
    TEST_MODE=true
else
    TEST_MODE=false
fi

# Prompt for minutes
MINS=$(zenity --entry --text="Minutes until shutdown:" 2>/dev/null)

# Validate input is a number
if ! [[ "$MINS" =~ ^[0-9]+$ ]]; then
    zenity --error --text="Please enter a valid number of minutes."
    exit 1
fi

if [ "$TEST_MODE" = true ]; then
    notify-send "RIP (TEST MODE)" "Shutdown scheduled in $MINS minutes. (No actual shutdown will occur)"
    sleep 2
    notify-send "RIP (TEST MODE)" "Test complete. Shutdown avoided."
else
    notify-send "RIP" "Shutdown scheduled in $MINS minutes."
    # Using shutdown command. We use pkexec to handle elevation gracefully in a GUI context.
    # Note: 'shutdown +N' is the standard way to schedule.
    pkexec shutdown +$MINS
fi
