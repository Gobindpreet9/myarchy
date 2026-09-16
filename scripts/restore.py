#!/usr/bin/env python3
"""Restore the explicit desktop-file allowlist without deleting unrelated files."""
from __future__ import annotations
import argparse, difflib, hashlib, json, os, shutil, sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

def load_manifest():
    with (REPO / "manifest.json").open(encoding="utf-8") as f:
        return json.load(f)

def digest(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""):
            h.update(block)
    return h.hexdigest()

def destination(root: Path, rel: str) -> Path:
    # Manifest paths are repository-controlled relative paths only.
    p=Path(rel)
    if p.is_absolute() or ".." in p.parts:
        raise ValueError(f"unsafe destination in manifest: {rel}")
    return root / p

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path.home(), help="staging home or target home")
    mode=ap.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="list changes; default")
    mode.add_argument("--diff", action="store_true", help="show unified diffs; no writes")
    mode.add_argument("--apply", action="store_true", help="write files after backing up replacements")
    ap.add_argument("--backup-dir", type=Path, help="backup location; defaults under the target root")
    args=ap.parse_args()
    root=args.root.expanduser().resolve()
    data=load_manifest()
    changes=[]
    for item in data["files"]:
        src=REPO/item["path"]
        dst=destination(root,item["restore_to"])
        if not src.is_file(): raise SystemExit(f"manifest source missing: {src}")
        state="create" if not dst.exists() else ("unchanged" if digest(src)==digest(dst) else "update")
        changes.append((item,src,dst,state))
    print(f"target root: {root}")
    print(f"allowlisted files: {len(changes)}")
    for item,src,dst,state in changes:
        print(f"{state:9} {dst}")
        if args.diff and state == "update":
            try: old=dst.read_text(encoding="utf-8").splitlines(keepends=True); new=src.read_text(encoding="utf-8").splitlines(keepends=True)
            except UnicodeDecodeError: continue
            sys.stdout.writelines(difflib.unified_diff(old,new,fromfile=str(dst),tofile=str(src)))
    if not args.apply:
        print("dry-run only; use --apply after reviewing this list/diff")
        return 0
    backup=args.backup_dir.expanduser() if args.backup_dir else root/".local/state/myarchy-backups"/datetime.now().strftime("%Y%m%d-%H%M%S")
    for item,src,dst,state in changes:
        if state == "unchanged": continue
        if state == "update":
            b=backup/Path(item["restore_to"]); b.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(dst,b)
        dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst); os.chmod(dst,int(item["mode"],8))
    print(f"applied; backups: {backup if any(s=='update' for *_,s in changes) else 'none'}")
    return 0

if __name__ == "__main__": raise SystemExit(main())
