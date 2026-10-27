"""Real guardian/Node IPC with synthetic programs; never a provider or store."""
import importlib.util
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("openui_guardian", ROOT / "ai_openui_runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeValidationTests(unittest.TestCase):
    def test_closed_requests_and_states(self):
        job = {"id": 1, "token": "a", "op": "load", "program": 'root = Text("Hi")', "state": {}}
        self.assertEqual(runtime.request(job), job)
        for invalid in ({**job, "id": True}, {**job, "token": ""}, {**job, "extra": 1},
                        {**job, "state": []}, {**job, "state": {"$x": float("inf")}},
                        {**job, "program": "x" * 32769}):
            with self.subTest(invalid=str(invalid)[:80]), self.assertRaises(ValueError):
                runtime.request(invalid)

    def test_duplicate_keys_prototypes_and_invalid_utf8_never_decode(self):
        for source in (b'{"id":1,"id":2}', b'{"constructor":0}', b'NaN', b'"\xff"',
                       (b'[' * 150 + b'0' + b']' * 150)):
            with self.assertRaises((ValueError, UnicodeError)):
                runtime.decode(source)

    def test_spawn_has_no_inherited_credentials_options_or_user_cwd(self):
        with patch.object(runtime.subprocess, "Popen") as popen:
            runtime.spawn()
        args, kwargs = popen.call_args
        self.assertIn("--max-old-space-size=96", args[0])
        self.assertIn("--permission", args[0])
        self.assertEqual(kwargs["cwd"], "/")
        self.assertEqual(kwargs["env"], {"HOME": "/nonexistent", "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        self.assertTrue(kwargs["start_new_session"])

    def test_node_permissions_deny_ungranted_files_and_process_spawning(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as scratch:
            script = Path(scratch) / "probe.cjs"
            script.write_text('''
const results = [];
for (const action of [() => require('node:fs').readFileSync('/etc/hostname'),
                      () => require('node:child_process').spawnSync('/usr/bin/true')]) {
  try { action(); results.push('ALLOWED'); } catch (e) { results.push(e.code); }
}
console.log(JSON.stringify(results));
''')
            child = runtime.spawn(script)
            try:
                output, _ = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0)
                self.assertEqual(json.loads(output), ["ERR_ACCESS_DENIED", "ERR_ACCESS_DENIED"])
            finally:
                runtime.teardown(child)


class RuntimePipeTests(unittest.TestCase):
    def setUp(self):
        self.proc = subprocess.Popen([sys.executable, "-I", "-B", "-u", str(ROOT / "ai_openui_runtime.py"), "--serve"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})
        self.id = 0

    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        self.proc.communicate(timeout=5)

    def call(self, **extra):
        self.id += 1
        self.proc.stdin.write(runtime.compact({"id": self.id, "token": "test-mount", **extra}) + b"\n")
        self.proc.stdin.flush()
        ready, _, _ = select.select([self.proc.stdout], [], [], 5)
        self.assertTrue(ready, "guardian response deadline")
        line = self.proc.stdout.readline(runtime.FRAME_BYTES + 1)
        self.assertTrue(line.endswith(b"\n"), repr(line))
        return json.loads(line)

    def test_real_core_load_edit_blank_and_stale_mount(self):
        result = self.call(op="load", program='$n = 2\nroot = Col([Input($n, "Amount", "number"), Text($n * 3)])', state={})
        self.assertTrue(result["ok"], result)
        target = result["tree"]["children"][0]["id"]
        result = self.call(op="event", target=target, event="change", value=7)
        self.assertEqual(result["state"], {"$n": 7})
        self.assertEqual(result["tree"]["children"][1]["props"]["text"], "21")
        result = self.call(op="event", target=target, event="change", value=None)
        self.assertIsNone(result["state"]["$n"])
        result = self.call(op="load", token="foreign", program='root = Text("Bad")', state={})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "stale_token")

    def test_untrusted_script_is_not_executed(self):
        result = self.call(op="load", program='root = process.exit(23)', state={})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid_program")

    def test_copy_requires_an_explicit_valid_click(self):
        result = self.call(op="load", program='root = Col([Button("Copy", @CopyToClipboard("Plain text"))])', state={})
        self.assertTrue(result["ok"], result)
        self.assertNotIn("copyText", result)
        result = self.call(op="event", target="root/0", event="click")
        self.assertEqual(result["copyText"], "Plain text")

    def test_external_watchdog_kills_an_unresponsive_worker(self):
        self.proc.terminate()
        self.proc.communicate(timeout=5)
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as scratch:
            script = Path(scratch) / "unresponsive.cjs"
            script.write_text("while (true) {}")
            launch = ("import runpy; module=runpy.run_path(" + repr(str(ROOT / "ai_openui_runtime.py")) + "); "
                      "raise SystemExit(module['serve'](worker=" + repr(str(script)) + ", timeout=0.15))")
            self.proc = subprocess.Popen([sys.executable, "-I", "-B", "-u", "-c", launch],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         env={"PATH": "/usr/bin:/bin", "HOME": "/nonexistent"})
            result = self.call(op="load", program='root = Text("Wait")', state={})
            self.assertEqual(result["error"], "runtime_timeout")
            self.proc.wait(timeout=5)
            self.assertEqual(self.proc.returncode, 1)

    def test_closed_pipe_reaps_the_owned_node_process(self):
        result = self.call(op="load", program='root = Text("Done")', state={})
        self.assertTrue(result["ok"])
        children = Path("/proc") / str(self.proc.pid) / "task" / str(self.proc.pid) / "children"
        owned = [int(pid) for pid in children.read_text().split()]
        self.assertEqual(len(owned), 1)
        self.proc.stdin.close()
        self.proc.stdin = None
        self.proc.wait(timeout=5)
        for pid in owned:
            self.assertFalse(Path("/proc", str(pid)).exists(), "Node must be reaped after EOF")


if __name__ == "__main__":
    unittest.main()
