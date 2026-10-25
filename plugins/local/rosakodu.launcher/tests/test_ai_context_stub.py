"""Offline contract checks for the scratch-only real-broker protocol fixture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

STUB = Path(__file__).with_name("ai_context_stub.py")


class ContextStubTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-context-stub-", dir="/tmp/opencode")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name)
        for name in ("state", "runtime"):
            (self.home / name).mkdir(mode=0o700)
        self.env = {**os.environ, "HOME": str(self.home), "XDG_STATE_HOME": str(self.home / "state"),
                    "XDG_RUNTIME_DIR": str(self.home / "runtime"), "PYTHONDONTWRITEBYTECODE": "1"}

    def run_commands(self, commands, env=None):
        result = subprocess.run([sys.executable, "-B", "-u", str(STUB)],
                                input="".join(json.dumps(command) + "\n" for command in commands),
                                text=True, capture_output=True, timeout=8, env=env or self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_real_command_context_accounting_and_ordered_new_stop_shutdown(self):
        context = {"version": 1, "previous": {"turnId": 3, "prompt": "Stored question", "answer": "Stored answer"},
                   "truncated": False}
        events = self.run_commands([
            {"op": "submit", "agent": "codex", "turnId": 4, "prompt": "Follow up", "workspaceContext": context},
            {"op": "stop", "turnId": 4}, {"op": "new"},
            {"op": "submit", "agent": "codex", "turnId": 7, "prompt": "Fresh"},
            {"op": "shutdown"},
            {"op": "submit", "turnId": 8, "prompt": "Must not run"}])
        self.assertEqual([event["type"] for event in events],
                         ["ready", "started", "done", "stopped", "ready", "started", "done"])
        first, fresh = [json.loads(event["answer"]) for event in events if event["type"] == "done"]
        self.assertEqual(first["context"], context)
        self.assertEqual(first["markerCount"], 1)
        self.assertEqual(first["chargedBytes"], first["promptBytes"])
        self.assertEqual(first["promptBytes"], first["baseBytes"] + first["contextSectionBytes"])
        self.assertTrue(first["chargedOnce"])
        self.assertIsNone(first["session"])
        self.assertIsNone(first["providerHome"])
        self.assertIsNone(fresh["context"])
        self.assertEqual(fresh["markerCount"], 0)
        self.assertEqual(fresh["contextSectionBytes"], 0)
        self.assertLess(len(json.dumps(first)), 2000)

    def test_invalid_context_is_rejected_by_real_broker_before_run(self):
        events = self.run_commands([
            {"op": "submit", "agent": "codex", "turnId": 4, "prompt": "Follow up",
             "workspaceContext": {"version": 999}}, {"op": "shutdown"}])
        self.assertEqual(events, [{"type": "ready"},
                                 {"type": "error", "turnId": 4, "message": "Workspace context is invalid."}])

    def test_attachment_and_source_never_reach_file_read_paths(self):
        for field in ("attachment", "sourceId"):
            with self.subTest(field=field):
                events = self.run_commands([
                    {"op": "submit", "turnId": 4, "prompt": "Must not read", field: "refuse-this"},
                    {"op": "shutdown"}])
                self.assertEqual(events[-1], {"type": "error", "turnId": 4,
                                             "message": "Fixture refuses attachment/source reads"})
                self.assertFalse(any(event["type"] == "started" for event in events))

    def test_non_scratch_home_state_and_runtime_refused_before_ready(self):
        for variable in ("HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            with self.subTest(variable=variable):
                result = subprocess.run([sys.executable, "-B", str(STUB)], input="", text=True,
                                        capture_output=True, timeout=8, env={**self.env, variable: "/"})
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("scratch directory under /tmp/opencode", result.stderr)


if __name__ == "__main__":
    unittest.main()
