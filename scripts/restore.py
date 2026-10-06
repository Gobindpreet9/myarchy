#!/usr/bin/env python3
"""Restore the explicit desktop-file allowlist without deleting unrelated files."""
from __future__ import annotations
import argparse
import difflib
import hashlib
import json
import os
import re
import secrets
import stat
import sys
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from typing import NamedTuple

REPO = Path(__file__).resolve().parents[1]

DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def relative_parts(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not value or "\0" in value:
        raise ValueError(f"unsafe relative path: {value!r}")
    parts = tuple(value.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe relative path: {value!r}")
    return parts


def absolute_path(path: Path) -> Path:
    # Do not resolve symlinks (including symlinks in the root's parents).
    path = path.expanduser()
    if ".." in path.parts or "\0" in str(path):
        raise ValueError(f"unsafe root path: {path}")
    return Path(os.path.abspath(path))


def signature(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


class File(NamedTuple):
    data: bytes
    info: os.stat_result


class Tree:
    """Pin the existing ancestor; traverse only no-follow directory descriptors."""

    def __init__(self, path: Path):
        self.path = absolute_path(path)
        self.fd = os.open("/", DIRECTORY_FLAGS)
        self.pending = ()
        try:
            parts = self.path.parts[1:]
            for index, part in enumerate(parts):
                try:
                    child = os.open(part, DIRECTORY_FLAGS, dir_fd=self.fd)
                except FileNotFoundError:
                    self.pending = tuple(parts[index:])
                    break
                except OSError as error:
                    raise ValueError(f"cannot traverse {Path('/').joinpath(*parts[:index + 1])}: "
                                     "a real directory is required (symlinks are not followed)") from error
                os.close(self.fd)
                self.fd = child
        except BaseException:
            self.close()
            raise

    def close(self):
        os.close(self.fd)

    def directory(self, parts: tuple[str, ...], *, create=False):
        fd = os.dup(self.fd)
        try:
            for part in self.pending + parts:
                try:
                    child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                except FileNotFoundError:
                    if not create:
                        os.close(fd)
                        return None
                    try:
                        os.mkdir(part, mode=0o700, dir_fd=fd)
                        os.fsync(fd)
                    except FileExistsError:
                        pass  # The subsequent no-follow open checks a racing creator.
                    child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
                except OSError as error:
                    logical = self.path.joinpath(*parts)
                    raise ValueError(f"cannot traverse {logical}: a real directory is required "
                                     "(symlinks are not followed)") from error
                os.close(fd)
                fd = child
            return fd
        except OSError as error:
            os.close(fd)
            raise ValueError(f"cannot traverse {self.path.joinpath(*parts)}: "
                             "a real directory is required (symlinks are not followed)") from error
        except BaseException:
            os.close(fd)
            raise

    def read(self, parts: tuple[str, ...]) -> File | None:
        parent = self.directory(parts[:-1])
        if parent is None:
            return None
        try:
            try:
                info = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return None
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"not a regular file: {self.path.joinpath(*parts)}")
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                         os.O_CLOEXEC, dir_fd=parent)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if not stat.S_ISREG(opened.st_mode) or signature(info) != signature(opened):
                    raise ValueError(f"file changed while opening: {self.path.joinpath(*parts)}")
                data = stream.read()
                if signature(opened) != signature(os.fstat(stream.fileno())):
                    raise ValueError(f"file changed while reading: {self.path.joinpath(*parts)}")
            return File(data, opened)
        finally:
            os.close(parent)

    def require_absent(self, parts: tuple[str, ...]):
        parent = self.directory(parts[:-1])
        if parent is None:
            return
        try:
            try:
                os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                return
            raise ValueError(f"backup already exists: {self.path.joinpath(*parts)}")
        finally:
            os.close(parent)

    def write(self, parts: tuple[str, ...], data: bytes, mode: int, *, backup=False,
              expected: File | None = None):
        parent = self.directory(parts[:-1], create=True)
        temporary = ".myarchy-" + secrets.token_hex(16)
        created = False
        try:
            # Never open the final name for writing. Backups publish exclusively;
            # destinations replace a directory entry, never a symlink's referent.
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
            created = True
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fchmod(stream.fileno(), mode)
                os.fsync(stream.fileno())
            if backup or expected is None:
                os.link(temporary, parts[-1], src_dir_fd=parent, dst_dir_fd=parent,
                        follow_symlinks=False)
            else:
                try:
                    current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    current = None
                if ((expected is None and current is not None) or
                        (expected is not None and
                         (current is None or signature(current) != signature(expected.info)))):
                    raise ValueError(f"destination changed since preflight: {self.path.joinpath(*parts)}")
                os.replace(temporary, parts[-1], src_dir_fd=parent, dst_dir_fd=parent)
                created = False
            # Make the backup name durable before the caller replaces an original.
            os.fsync(parent)
        finally:
            primary = sys.exception()
            try:
                if created:
                    try:
                        os.unlink(temporary, dir_fd=parent)
                    except OSError as cleanup_error:
                        if primary is None:
                            raise
                        print(f"temporary cleanup failed at {self.path / temporary}: {cleanup_error}",
                              file=sys.stderr)
            finally:
                os.close(parent)


class Change(NamedTuple):
    source: tuple[str, ...]
    target: tuple[str, ...]
    mode: int
    new: File
    old: File | None
    state: str


def check_path_conflicts(paths: list[Path]):
    names = {str(path) for path in paths}
    if len(names) != len(paths):
        raise ValueError("duplicate destination or overlapping backup path")
    for path in paths:
        if any(str(parent) in names for parent in path.parents):
            raise ValueError(f"file/directory path conflict: {path}")


def preflight(repo: Tree, root: Tree, backup: Tree) -> list[Change]:
    manifest = repo.read(("manifest.json",))
    if manifest is None:
        raise ValueError("manifest source missing: manifest.json")
    entries = json.loads(manifest.data)["files"]
    if not isinstance(entries, list):
        raise ValueError("manifest files must be a list")
    changes = []
    for item in entries:
        source = relative_parts(item["path"])
        target = relative_parts(item["restore_to"])
        mode = item["mode"]
        if not isinstance(mode, str) or not re.fullmatch(r"0?[0-7]{3}", mode):
            raise ValueError(f"invalid file mode: {mode!r}")
        recorded = item["sha256"]
        if not isinstance(recorded, str) or not re.fullmatch(r"[0-9a-f]{64}", recorded):
            raise ValueError(f"invalid SHA256: {recorded!r}")
        new = repo.read(source)
        if new is None:
            raise ValueError(f"manifest source missing: {repo.path.joinpath(*source)}")
        if hashlib.sha256(new.data).hexdigest() != recorded:
            raise ValueError(f"SHA256 mismatch: {repo.path.joinpath(*source)}")
        old = root.read(target)
        state = "create" if old is None else ("unchanged" if old.data == new.data else "update")
        if state == "update":
            backup.require_absent(target)
        changes.append(Change(source, target, int(mode, 8), new, old, state))
    paths = [root.path.joinpath(*change.target) for change in changes]
    paths += [backup.path.joinpath(*change.target) for change in changes if change.state == "update"]
    check_path_conflicts(paths)
    # A root below a prospective file would otherwise fail only after an early write.
    for base in (root.path, backup.path):
        if any(base == path or path in base.parents for path in paths):
            raise ValueError(f"file/directory root conflict: {base}")
    return changes

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path.home(), help="staging home or target home")
    mode=ap.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="list changes; default")
    mode.add_argument("--diff", action="store_true", help="show unified diffs; no writes")
    mode.add_argument("--apply", action="store_true", help="write files after backing up replacements")
    ap.add_argument("--backup-dir", type=Path, help="backup location; defaults under the target root")
    args=ap.parse_args()
    applying = False
    applied = 0
    recovery_path = None
    try:
        with ExitStack() as stack:
            root_path = absolute_path(args.root)
            backup_path = args.backup_dir if args.backup_dir else (
                root_path / ".local/state/myarchy-backups" /
                (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + "-" + secrets.token_hex(8)))
            trees = []
            for path in (REPO, root_path, backup_path):
                tree = Tree(path)
                stack.callback(tree.close)
                trees.append(tree)
            repo, root, backup = trees
            changes = preflight(repo, root, backup)
            print(f"target root: {root.path}")
            print(f"allowlisted files: {len(changes)}")
            for change in changes:
                dst = root.path.joinpath(*change.target)
                src = repo.path.joinpath(*change.source)
                print(f"{change.state:9} {dst}")
                if args.diff and change.state == "update":
                    try:
                        old = change.old.data.decode("utf-8").splitlines(keepends=True)
                        new = change.new.data.decode("utf-8").splitlines(keepends=True)
                    except UnicodeDecodeError:
                        continue
                    sys.stdout.writelines(difflib.unified_diff(old, new, fromfile=str(dst), tofile=str(src)))
            if not args.apply:
                print("dry-run only; use --apply after reviewing this list/diff")
                return 0
            recovery_path = backup.path
            print(f"backups: {backup.path}")
            applying = True
            for change in changes:
                if change.state == "unchanged":
                    continue
                current = root.read(change.target)
                if ((current is None) != (change.old is None) or
                        (current is not None and (current.data != change.old.data or
                         signature(current.info) != signature(change.old.info)))):
                    raise ValueError(f"destination changed since preflight: {root.path.joinpath(*change.target)}")
                if change.state == "update":
                    backup.write(change.target, change.old.data, stat.S_IMODE(change.old.info.st_mode), backup=True)
                root.write(change.target, change.new.data, change.mode, expected=change.old)
                applied += 1
            print(f"applied; backups: {backup.path if any(c.state == 'update' for c in changes) else 'none'}")
            return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        if applying:
            raise SystemExit(f"restore stopped after {applied} completed file(s): {error}; "
                             f"originals backed up at {recovery_path}. "
                             "The current file may also have changed; no automatic rollback was attempted.") from error
        raise SystemExit(f"restore refused: {error}") from error

if __name__ == "__main__": raise SystemExit(main())
