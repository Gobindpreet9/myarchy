# Exclusions

This repository is not a home-directory, operating-system, or dotfiles backup.

Excluded deliberately:

- `/usr/share/omarchy/` packaged defaults and clean upstream plugin source
- Omarchy `defaults/`, sample files, caches, logs, crash data, and `.bak*` files
- Generated machine-specific state, including `hyprmoncfg-monitors.lua`, OmaSettings JSON state, and copied upstream lock videos
- Terminal, shell, editor, tmux, Git, GitHub CLI, and development configuration
- VPN, vLLM, audio, browser, model, and unrelated application configuration
- User services, package lists, boot/initramfs/PAM/NVIDIA/filesystem/network configuration
- Credentials, API keys, access tokens, passwords, private keys, connection strings, and browser data
- Personal identity data that is not required for desktop restoration

The allowlist is explicit in `manifest.json`; adding a file requires an intentional manifest change and another audit.

Restore preflight checks every source against its recorded SHA-256 and mode
before any write. Source, destination and backup symlinks are rejected; new
directories are private and replacements use no-follow descriptor traversal.
Original files are backed up exclusively and synced before replacement. New
destinations are published exclusively too, preserving concurrently created
files. Apply failures report the completed count and recovery directory; there
is no automatic rollback, and the current file may also have changed.
Run `python3 -m unittest discover -s tests -p 'test_restore.py'` for scratch-only
restore regressions. These safeguards
do not replace reviewing the allowlist and testing in a staging home first.
