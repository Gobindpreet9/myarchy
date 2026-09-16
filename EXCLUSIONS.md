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
