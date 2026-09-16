# Plugin provenance

`manifest.json` records each plugin's public upstream URL and exact local base commit. `patches/` contains only tracked local modifications. `untracked/` contains only local plugin files that do not exist in the upstream checkout.

The repository intentionally does not vendor clean plugin source or nested `.git` directories. To reconstruct a plugin, clone its recorded public URL, check out its recorded commit, review the patch, apply it, then copy the listed untracked files. Do not apply patches over an existing checkout without first reviewing its current status.

Files named `README-security.md` found as local untracked files in the source plugin worktrees were intentionally excluded because they are audit notes rather than desktop customizations.
