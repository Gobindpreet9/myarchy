import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


BACKEND = Path(__file__).resolve().parents[1] / "file-search.py"
spec = importlib.util.spec_from_file_location("file_search", BACKEND)
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


@unittest.skipUnless(shutil.which("fd"), "fd is not installed")
class FileSearchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def file(self, name):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
        return str(path)

    def run_search(self, query, home=None):
        result = subprocess.run(
            [sys.executable, str(BACKEND), str(home or self.home), query],
            capture_output=True, text=True, timeout=8,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_empty_and_single_character(self):
        self.file("a")
        self.assertEqual(self.run_search(" \t\n"), [])
        self.assertTrue(self.run_search("a"))

    def test_special_paths_and_row_contract(self):
        for name in ["space name.txt", "a'quote\".txt", "日本語.txt", "line\nbreak.txt"]:
            path = self.file(name)
            rows = self.run_search(name.split()[0])
            row = next(row for row in rows if row["path"] == path)
            self.assertEqual(row, {"kind": "file", "path": path, "title": name,
                                   "parent": str(self.home), "isDirectory": False})

    def test_all_terms_match_full_path_case_insensitively(self):
        target = self.file("Projects/Alpha/REPORT.TXT")
        self.file("Projects/Beta/report.txt")
        self.file("Other/Alpha/memo.txt")
        self.assertEqual([r["path"] for r in self.run_search("report\tALPHA")], [target])

    def test_literal_regex_shell_and_leading_dash(self):
        for name in ["[a-z]+.*.txt", "$(touch PWNED);'quote.txt", "--help.txt"]:
            path = self.file(name)
            self.assertEqual([r["path"] for r in self.run_search(name)], [path])
        self.assertFalse((self.home / "PWNED").exists())

    def test_exclusions_and_hidden_files(self):
        for directory in backend.EXCLUDES[:15]:
            self.file(f"{directory}/needle.txt")
        for name in [".env", ".env.production", "secret.pem", "secret.key"]:
            self.file(f"needle/{name}")
        allowed = self.file(".hidden/needle.txt")
        rows = self.run_search("needle")
        self.assertEqual({r["path"] for r in rows}, {allowed, str(self.home / "needle")})

    def test_directories_and_no_symlink_traversal(self):
        directory = self.home / "needle-directory"
        directory.mkdir()
        with tempfile.TemporaryDirectory() as outside:
            Path(outside, "needle-outside.txt").touch()
            (self.home / "linked").symlink_to(outside, target_is_directory=True)
            (self.home / "needle-link").symlink_to(Path(outside, "needle-outside.txt"))
            rows = self.run_search("needle")
        self.assertEqual(rows, [{"kind": "file", "path": str(directory),
                                 "title": directory.name, "parent": str(self.home),
                                 "isDirectory": True}])

    def test_ranking_and_limit(self):
        exact = self.file("zz/needle")
        prefix = self.file("yy/needle-more")
        for index in range(130):
            self.file(f"aa/x-needle-{index:03d}")
        rows = self.run_search("needle")
        self.assertEqual(len(rows), 100)
        self.assertEqual([r["path"] for r in rows[:2]], [exact, prefix])
        self.assertEqual([r["path"] for r in rows[2:]], sorted(r["path"] for r in rows[2:]))

    def test_invalid_home(self):
        for home in ["relative", str(self.home / "missing")]:
            result = subprocess.run([sys.executable, str(BACKEND), home, "x"],
                                    capture_output=True, text=True, timeout=8)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), [])
            self.assertIn("absolute path", result.stderr)


class ProcessLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.pidfile = self.home / "pid"
        fake_fd = self.home / "fd"
        fake_fd.write_text(
            f"#!{sys.executable}\n"
            "import os, time\n"
            "from pathlib import Path\n"
            "Path(os.environ['PIDFILE']).write_text(str(os.getpid()))\n"
            "os.write(1, os.fsencode(os.environ['RESULT']) + b'\\0')\n"
            "time.sleep(30)\n"
        )
        fake_fd.chmod(0o755)
        self.target = self.home / "needle"
        self.target.touch()
        self.env = dict(os.environ, PATH=str(self.home), PIDFILE=str(self.pidfile),
                        RESULT=str(self.target))

    def assert_reaped(self):
        pid = int(self.pidfile.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_timeout_returns_partial_and_reaps(self):
        started = time.monotonic()
        with mock.patch.dict(os.environ, self.env), mock.patch.object(backend, "TIMEOUT_SECONDS", 0.2):
            rows = backend.search(str(self.home), "needle")
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual([r["path"] for r in rows], [str(self.target)])
        self.assert_reaped()

    def test_sigterm_reaps_child(self):
        process = subprocess.Popen([sys.executable, str(BACKEND), str(self.home), "needle"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not self.pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.pidfile.exists())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIsInstance(json.loads(stdout), list)
            self.assert_reaped()
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    @unittest.skipUnless(sys.platform == "linux", "requires Linux parent-death signals")
    def test_sigkill_stops_child(self):
        process = subprocess.Popen([sys.executable, str(BACKEND), str(self.home), "needle"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        child_pid = None
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if self.pidfile.exists() and self.pidfile.read_text():
                    child_pid = int(self.pidfile.read_text())
                    break
                time.sleep(0.01)
            self.assertIsNotNone(child_pid, "fd child did not start")
            self.assertEqual(os.getpgid(child_pid), child_pid)
            process.kill()
            process.wait(timeout=2)
            self.assertEqual(process.returncode, -signal.SIGKILL)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    # An orphan may remain a zombie until its new parent reaps it.
                    stat = Path(f"/proc/{child_pid}/stat").read_text()
                except FileNotFoundError:
                    break
                if stat.rsplit(")", 1)[1].split()[0] == "Z":
                    break
                time.sleep(0.01)
            else:
                self.fail("fd child is still running after supervisor SIGKILL")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            if child_pid is not None:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.communicate(timeout=2)

    def test_fd_failure_is_stderr_and_nonzero(self):
        (self.home / "fd").write_text(f"#!{sys.executable}\nimport sys\nsys.stderr.write('broken fd')\nsys.exit(2)\n")
        result = subprocess.run([sys.executable, str(BACKEND), str(self.home), "needle"],
                                env=self.env, capture_output=True, text=True, timeout=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), [])
        self.assertIn("broken fd", result.stderr)


if __name__ == "__main__":
    unittest.main()
