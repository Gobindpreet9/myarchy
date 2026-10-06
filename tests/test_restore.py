"""Restore security regressions: all fixtures stay inside a scratch directory."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "myarchy_restore", Path(__file__).resolve().parents[1] / "scripts/restore.py")
restore = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = restore
SPEC.loader.exec_module(restore)


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.root = self.base / "target"
        self.backup = self.base / "backups"
        self.entries = []
        self.repo_patch = patch.object(restore, "REPO", self.repo)
        self.repo_patch.start()
        self.addCleanup(self.repo_patch.stop)

    def entry(self, source="config/first", target=".config/first", data=b"new\n", mode="0644"):
        path = self.repo / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        item = {"path": source, "restore_to": target, "mode": mode,
                "sha256": hashlib.sha256(data).hexdigest()}
        self.entries.append(item)
        return item

    def put(self, relative, data=b"old\n", mode=0o640, *, root=None):
        path = (self.root if root is None else root) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def run_restore(self, *args, root=None, backup=None):
        (self.repo / "manifest.json").write_text(json.dumps({"files": self.entries}))
        argv = ["restore.py", "--root", str(self.root if root is None else root)]
        if backup is not False:
            argv += ["--backup-dir", str(self.backup if backup is None else backup)]
        argv += args
        output = io.StringIO()
        with patch.object(sys, "argv", argv), contextlib.redirect_stdout(output):
            result = restore.main()
        self.assertEqual(result, 0)
        return output.getvalue()

    def refused(self, *args, **kwargs):
        with self.assertRaises(SystemExit) as caught:
            self.run_restore("--apply", *args, **kwargs)
        self.assertRegex(str(caught.exception), "restore (refused|stopped)")

    def test_matching_hash_restores_modes_and_skips_unchanged(self):
        self.entry(mode="0755")
        self.entry("config/same", ".config/same", b"same\n", "0600")
        same = self.put(".config/same", b"same\n", 0o644)
        before = same.stat()
        output = self.run_restore("--apply")
        restored = self.root / ".config/first"
        self.assertEqual(restored.read_bytes(), b"new\n")
        self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o755)
        self.assertEqual(same.stat().st_ino, before.st_ino)
        self.assertEqual(same.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(same.stat().st_mode), 0o644)
        self.assertIn("unchanged", output)
        self.assertFalse(self.backup.exists())

    def test_new_root_and_parent_directories_are_private(self):
        self.entry(target=".config/deep/file", mode="0600")
        self.run_restore("--apply")
        for directory in (self.root, self.root / ".config", self.root / ".config/deep"):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.root / ".config/deep/file").stat().st_mode), 0o600)

    def test_later_stale_hash_aborts_before_any_write(self):
        self.entry()
        bad = self.entry("config/later", ".config/later")
        (self.repo / bad["path"]).write_bytes(b"not the recorded source")
        first = self.put(".config/first")
        before = first.stat()
        self.refused()
        self.assertEqual(first.read_bytes(), b"old\n")
        self.assertEqual(first.stat().st_ino, before.st_ino)
        self.assertFalse((self.root / ".config/later").exists())
        self.assertFalse(self.backup.exists())

    def test_later_invalid_metadata_aborts_before_creating_root(self):
        for key, value in (("mode", "8888"), ("mode", "04755"), ("mode", 644),
                           ("sha256", "bad"), ("restore_to", "../escape"),
                           ("restore_to", "/escape"), ("restore_to", "."),
                           ("restore_to", "a//b"), ("path", "../escape")):
            with self.subTest(key=key, value=value):
                self.entries = []
                self.entry()
                bad = self.entry("config/later", ".config/later")
                bad[key] = value
                self.refused()
                self.assertFalse(self.root.exists())
                self.assertFalse(self.backup.exists())

    def test_destination_file_symlink_refused_and_outside_sentinel_untouched(self):
        self.entry()
        sentinel = self.put("sentinel", b"outside", root=self.base / "outside")
        target = self.root / ".config/first"
        target.parent.mkdir(parents=True)
        target.symlink_to(sentinel)
        self.refused()
        self.assertEqual(sentinel.read_bytes(), b"outside")
        self.assertTrue(target.is_symlink())
        self.assertFalse(self.backup.exists())

    def test_destination_parent_symlink_refused_and_outside_sentinel_untouched(self):
        self.entry()
        outside = self.base / "outside"
        sentinel = self.put("first", b"outside", root=outside)
        self.root.mkdir()
        (self.root / ".config").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(SystemExit) as caught:
            self.run_restore("--apply")
        self.assertIn(str(self.root / ".config"), str(caught.exception))
        self.assertIn("symlinks are not followed", str(caught.exception))
        self.assertEqual(sentinel.read_bytes(), b"outside")
        self.assertFalse(self.backup.exists())

    def test_later_destination_directory_and_fifo_refused_before_early_write(self):
        self.entry()
        self.entry("config/later", ".config/later")
        first = self.put(".config/first")
        later = self.root / ".config/later"
        for kind in ("directory", "fifo"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    later.mkdir()
                else:
                    os.mkfifo(later)
                self.refused()
                self.assertEqual(first.read_bytes(), b"old\n")
                self.assertFalse(self.backup.exists())
                if kind == "directory":
                    later.rmdir()
                else:
                    later.unlink()

    def test_source_symlink_and_source_parent_symlink_refused(self):
        item = self.entry()
        outside = self.base / "outside"
        sentinel = self.put("first", b"new\n", root=outside)
        source = self.repo / item["path"]
        source.unlink()
        source.symlink_to(sentinel)
        self.refused()
        self.assertFalse(self.root.exists())
        source.unlink()
        source.parent.rmdir()
        source.parent.symlink_to(outside, target_is_directory=True)
        self.refused()
        self.assertEqual(sentinel.read_bytes(), b"new\n")
        self.assertFalse(self.root.exists())

    def test_manifest_symlink_refused(self):
        self.entry()
        outside_manifest = self.base / "other-manifest"
        outside_manifest.write_text(json.dumps({"files": self.entries}))
        (self.repo / "manifest.json").symlink_to(outside_manifest)
        self.refused()
        self.assertFalse(self.root.exists())

    def test_root_backup_and_repo_parent_symlinks_refused(self):
        self.entry()
        outside = self.base / "outside"
        outside.mkdir()
        alias = self.base / "alias"
        alias.symlink_to(outside, target_is_directory=True)
        for root, backup in ((alias, self.backup), (alias / "nested", self.backup),
                             (self.root, alias), (self.root, alias / "nested")):
            with self.subTest(root=root, backup=backup):
                self.refused(root=root, backup=backup)
                self.assertFalse(self.root.exists())
                self.assertEqual(list(outside.iterdir()), [])
        alias.unlink()
        alias.symlink_to(self.base, target_is_directory=True)
        with patch.object(restore, "REPO", alias / "repo"):
            self.refused()
        self.assertFalse(self.root.exists())

    def test_backups_preserve_original_contents_modes_and_unrelated_files(self):
        self.entry(mode="0600")
        first = self.put(".config/first", b"original\n", 0o751)
        unrelated = self.put(".config/not-allowlisted", b"keep me", 0o600)
        existing = self.put("keep", b"keep backup", root=self.backup)
        self.run_restore("--apply")
        saved = self.backup / ".config/first"
        self.assertEqual(saved.read_bytes(), b"original\n")
        self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o751)
        self.assertEqual(first.read_bytes(), b"new\n")
        self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
        self.assertEqual(unrelated.read_bytes(), b"keep me")
        self.assertEqual(existing.read_bytes(), b"keep backup")
        self.assertEqual(stat.S_IMODE(saved.parent.stat().st_mode), 0o700)
        before = saved.stat()
        self.run_restore("--apply")  # An unchanged file needs no second backup.
        self.assertEqual(saved.stat().st_ino, before.st_ino)

    def test_later_backup_collision_refused_before_early_write(self):
        self.entry()
        self.entry("config/later", ".config/later")
        first = self.put(".config/first")
        later = self.put(".config/later")
        collision = self.put(".config/later", b"prior backup", root=self.backup)
        self.refused()
        self.assertEqual(first.read_bytes(), b"old\n")
        self.assertEqual(later.read_bytes(), b"old\n")
        self.assertEqual(collision.read_bytes(), b"prior backup")
        self.assertFalse((self.backup / ".config/first").exists())

    def test_default_backups_use_unique_private_directories(self):
        self.entry()
        self.put(".config/first", b"original", 0o610)
        self.run_restore("--apply", backup=False)
        self.put(".config/first", b"second version", 0o640)
        self.run_restore("--apply", backup=False)
        parent = self.root / ".local/state/myarchy-backups"
        backups = list(parent.iterdir())
        self.assertEqual(len(backups), 2)
        self.assertEqual({(backup / ".config/first").read_bytes() for backup in backups},
                         {b"original", b"second version"})
        self.assertEqual({stat.S_IMODE((backup / ".config/first").stat().st_mode)
                          for backup in backups}, {0o610, 0o640})
        for directory in (self.root / ".local", self.root / ".local/state", parent, *backups):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)

    def test_racing_backup_collision_is_not_overwritten(self):
        self.entry()
        target = self.put(".config/first")
        original = os.link

        def insert_collision(source, destination, **kwargs):
            self.assertIsInstance(kwargs["dst_dir_fd"], int)
            self.put(".config/first", b"racing backup", root=self.backup)
            return original(source, destination, **kwargs)

        with patch.object(restore.os, "link", insert_collision):
            self.refused()
        self.assertEqual(target.read_bytes(), b"old\n")
        self.assertEqual((self.backup / ".config/first").read_bytes(), b"racing backup")
        self.assertEqual(list((self.backup / ".config").iterdir()), [self.backup / ".config/first"])

    def test_backup_final_symlink_refused_before_replacing_destination(self):
        self.entry()
        target = self.put(".config/first")
        sentinel = self.put("sentinel", b"outside", root=self.base / "outside")
        saved = self.backup / ".config/first"
        saved.parent.mkdir(parents=True)
        saved.symlink_to(sentinel)
        self.refused()
        self.assertEqual(target.read_bytes(), b"old\n")
        self.assertEqual(sentinel.read_bytes(), b"outside")
        self.assertTrue(saved.is_symlink())

    def test_missing_or_nonregular_later_source_refused_before_early_write(self):
        self.entry()
        later = self.entry("config/later", ".config/later")
        source = self.repo / later["path"]
        source.unlink()
        first = self.put(".config/first")
        for kind in ("missing", "directory", "fifo"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    source.mkdir()
                elif kind == "fifo":
                    os.mkfifo(source)
                self.refused()
                self.assertEqual(first.read_bytes(), b"old\n")
                self.assertFalse(self.backup.exists())
                if kind == "directory":
                    source.rmdir()
                elif kind == "fifo":
                    source.unlink()

    def test_backup_inner_parent_symlink_refused(self):
        self.entry()
        target = self.put(".config/first")
        outside = self.base / "outside"
        sentinel = self.put("first", b"outside", root=outside)
        self.backup.mkdir()
        (self.backup / ".config").symlink_to(outside, target_is_directory=True)
        self.refused()
        self.assertEqual(target.read_bytes(), b"old\n")
        self.assertEqual(sentinel.read_bytes(), b"outside")

    def test_duplicate_and_file_directory_destinations_refused(self):
        self.entry(target="first")
        later = self.entry("config/later", "first")
        for target in ("first", "first/child"):
            with self.subTest(target=target):
                later["restore_to"] = target
                self.refused()
                self.assertFalse(self.root.exists())

    def test_backup_root_cannot_be_under_a_prospective_target_file(self):
        self.entry(target="first")
        self.refused(backup=self.root / "first/backups")
        self.assertFalse(self.root.exists())

    def test_default_and_explicit_dry_run_create_no_directories(self):
        self.entry()
        for args in ((), ("--dry-run",), ("--diff",)):
            with self.subTest(args=args):
                output = self.run_restore(*args)
                self.assertIn("dry-run only", output)
                self.assertFalse(self.root.exists())
                self.assertFalse(self.backup.exists())

    def test_diff_uses_preflight_bytes_and_never_writes(self):
        self.entry()
        target = self.put(".config/first")
        output = self.run_restore("--diff")
        self.assertIn("-old\n", output)
        self.assertIn("+new\n", output)
        self.assertEqual(target.read_bytes(), b"old\n")
        self.assertFalse(self.backup.exists())

    def test_apply_uses_only_hash_validated_source_bytes(self):
        self.entry()
        original = restore.preflight

        def change_source(*args):
            changes = original(*args)
            (self.repo / "config/first").write_bytes(b"changed after preflight")
            return changes

        with patch.object(restore, "preflight", change_source):
            self.run_restore("--apply")
        self.assertEqual((self.root / ".config/first").read_bytes(), b"new\n")

    def test_racing_parent_symlink_is_not_followed(self):
        self.entry()
        target = self.put(".config/first")
        outside = self.base / "outside"
        sentinel = self.put("first", b"outside", root=outside)
        original = restore.preflight

        def swap_parent(*args):
            changes = original(*args)
            target.parent.rename(self.root / "old-config")
            target.parent.symlink_to(outside, target_is_directory=True)
            return changes

        with patch.object(restore, "preflight", swap_parent):
            self.refused()
        self.assertEqual(sentinel.read_bytes(), b"outside")
        self.assertEqual((self.root / "old-config/first").read_bytes(), b"old\n")
        self.assertFalse(self.backup.exists())

    def test_replace_is_descriptor_relative_if_parent_path_is_swapped(self):
        self.entry()
        target = self.put(".config/first")
        outside = self.base / "outside"
        sentinel = self.put("first", b"outside", root=outside)
        original = os.replace

        def swap_parent(source, destination, **kwargs):
            self.assertIsInstance(kwargs["src_dir_fd"], int)
            self.assertIsInstance(kwargs["dst_dir_fd"], int)
            target.parent.rename(self.root / "old-config")
            target.parent.symlink_to(outside, target_is_directory=True)
            return original(source, destination, **kwargs)

        with patch.object(restore.os, "replace", swap_parent):
            self.run_restore("--apply")
        self.assertEqual(sentinel.read_bytes(), b"outside")
        self.assertEqual((self.root / "old-config/first").read_bytes(), b"new\n")
        self.assertEqual((self.backup / ".config/first").read_bytes(), b"old\n")

    def test_new_destination_creation_race_preserves_concurrent_file(self):
        self.entry()
        original = os.link

        def insert_target(source, destination, **kwargs):
            self.put(".config/first", b"concurrent work")
            return original(source, destination, **kwargs)

        with patch.object(restore.os, "link", insert_target):
            self.refused()
        self.assertEqual((self.root / ".config/first").read_bytes(), b"concurrent work")
        self.assertEqual(list((self.root / ".config").iterdir()), [self.root / ".config/first"])

    def test_backup_directory_synced_before_replacement(self):
        self.entry()
        self.put(".config/first")
        events = []
        sync, replace = os.fsync, os.replace

        def record_sync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                events.append(("directory", os.readlink(f"/proc/self/fd/{fd}")))
            return sync(fd)

        def record_replace(*args, **kwargs):
            events.append(("replace", ""))
            return replace(*args, **kwargs)

        with patch.object(restore.os, "fsync", record_sync), patch.object(restore.os, "replace", record_replace):
            self.run_restore("--apply")
        backup_sync = events.index(("directory", str(self.backup / ".config")))
        publication = events.index(("replace", ""))
        destination_sync = events.index(("directory", str(self.root / ".config")))
        self.assertLess(backup_sync, publication)
        self.assertLess(publication, destination_sync)

    def test_cleanup_failure_preserves_primary_error_and_closes_descriptor(self):
        self.root.mkdir()
        stderr = io.StringIO()
        with restore.ExitStack() as stack:
            tree = restore.Tree(self.root)
            stack.callback(tree.close)
            directory = tree.directory
            parents = []

            def record_parent(*args, **kwargs):
                fd = directory(*args, **kwargs)
                parents.append(fd)
                return fd

            with patch.object(tree, "directory", record_parent), \
                    patch.object(restore.os, "fchmod", side_effect=OSError("primary write failure")), \
                    patch.object(restore.os, "unlink", side_effect=OSError("cleanup failure")), \
                    contextlib.redirect_stderr(stderr):
                with self.assertRaisesRegex(OSError, "primary write failure"):
                    tree.write(("file",), b"new", 0o600)
            self.assertIn("cleanup failure", stderr.getvalue())
            with self.assertRaises(OSError):
                os.fstat(parents[-1])

    def test_later_write_failure_reports_partial_apply_and_recovery(self):
        self.entry()
        self.entry("config/later", ".config/later")
        first = self.put(".config/first", b"first original")
        later = self.put(".config/later", b"later original")
        original = restore.Tree.write
        output = io.StringIO()

        def fail_later(tree, parts, *args, **kwargs):
            if tree.path == self.root and parts[-1] == "later":
                raise OSError("disk full")
            return original(tree, parts, *args, **kwargs)

        (self.repo / "manifest.json").write_text(json.dumps({"files": self.entries}))
        argv = ["restore.py", "--root", str(self.root), "--backup-dir", str(self.backup), "--apply"]
        with patch.object(restore.Tree, "write", fail_later), patch.object(sys, "argv", argv), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as caught:
                restore.main()
        self.assertIn(f"backups: {self.backup}", output.getvalue())
        self.assertIn("restore stopped after 1 completed file(s)", str(caught.exception))
        self.assertIn(str(self.backup), str(caught.exception))
        self.assertEqual(first.read_bytes(), b"new\n")
        self.assertEqual(later.read_bytes(), b"later original")
        self.assertEqual((self.backup / ".config/first").read_bytes(), b"first original")
        self.assertEqual((self.backup / ".config/later").read_bytes(), b"later original")


if __name__ == "__main__":
    unittest.main()
