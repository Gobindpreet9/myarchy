# myarchy

A plain-Git backup of the personal Omarchy desktop layer. This repository is intentionally narrow: it preserves desktop appearance, Hyprland behavior, Omarchy shell customizations, lock-screen/branding assets, desktop hooks, and local changes to installed Omarchy plugins.

## Scope

- `config/hypr/`: personal Hyprland overrides and desktop helper scripts.
- `config/omarchy/`: shell, dock, menu, branding, lock design, theme hook, and desktop scripts.
- `plugins/manifest.json`: public upstream plugin URLs and pinned commits.
- `plugins/patches/`: local modifications relative to those pinned upstream commits.
- `plugins/untracked/`: local plugin files that are not part of upstream.
- `scripts/`: auditable restore and secret-scan tooling.

Upstream Omarchy files under `/usr/share/omarchy/` are not copied. Clean plugin source is not duplicated either; the manifest identifies the public source and exact commit needed to reconstruct it.

## Restore

Always inspect first:

```sh
python scripts/restore.py --root /path/to/staging-home --dry-run
python scripts/restore.py --root /path/to/staging-home --diff
```

Apply only after reviewing the diff:

```sh
python scripts/restore.py --root /path/to/staging-home --apply
```

The restore tool uses only the allowlist in `manifest.json`, creates a timestamped backup before replacing an existing destination, never deletes unrelated files, and never restarts services or installs packages. It is designed to be tested in a staging home before touching a live desktop.

Plugin provenance and local patch application are documented in `plugins/manifest.json`; plugin source is intentionally not vendored.

## Safety

Run the audit before committing or pushing:

```sh
python scripts/audit.py
```

No credentials, tokens, passwords, private keys, connection strings, generated runtime state, machine-specific monitor identifiers, terminal/shell/editor/development configuration, or service configuration belongs here. See [`EXCLUSIONS.md`](EXCLUSIONS.md).
