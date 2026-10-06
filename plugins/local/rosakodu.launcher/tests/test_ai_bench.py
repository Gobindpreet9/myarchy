"""Offline tests for the medium-selection benchmark harness; no IPC or network."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "ai_bench", Path(__file__).resolve().parents[1] / "ai_bench.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class BenchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-bench-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def prompts(self, data):
        path = self.root / "prompts.json"
        path.write_text(json.dumps(data))
        return str(path)

    def test_prompt_file_validation(self):
        valid = bench.load_prompts(self.prompts([
            {"id": "a", "prompt": "One"},
            {"id": "b", "prompt": "Two", "expect": {"blocksAny": ["table"],
                                                    "blocksNone": ["chart"]}}]))
        self.assertEqual([entry["id"] for entry in valid], ["a", "b"])
        for bad in ([], "nope", [{"id": "", "prompt": "x"}], [{"id": "a", "prompt": " "}],
                    [{"id": "a", "prompt": "x"}, {"id": "a", "prompt": "y"}],
                    [{"id": "a", "prompt": "x", "expect": {"blocksAny": "table"}}]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                bench.load_prompts(self.prompts(bad))

    def test_evaluate_structure_expectations(self):
        blocks = [{"type": "diagram"}, {"type": "slider"}, {"type": "text"}]
        state = {"aiState": "done"}
        ok = bench.evaluate({"expect": {"blocksAny": ["diagram"], "blocksNone": ["chart"]}},
                            state, blocks, 10)
        self.assertTrue(ok["passed"])
        self.assertEqual(ok["blockTypes"], ["diagram", "slider", "text"])
        missing = bench.evaluate({"expect": {"blocksAny": ["gallery"]}}, state, blocks, 10)
        self.assertFalse(missing["passed"])
        self.assertIn("expected one of gallery", missing["notes"])
        forbidden = bench.evaluate({"expect": {"blocksNone": ["slider"]}}, state, blocks, 10)
        self.assertFalse(forbidden["passed"])
        failed = bench.evaluate({"expect": {}}, {"aiState": "error"}, blocks, 10)
        self.assertFalse(failed["passed"])
        self.assertIn("state error", failed["notes"])
        slow = bench.evaluate({"expect": {"maxSeconds": 5}}, state, blocks, 30)
        self.assertIn("slow: 30.0s", slow["notes"])
        self.assertTrue(slow["passed"], "slow is a note for review, not an automatic failure")

    def test_evaluate_image_expectation(self):
        state = {"aiState": "done"}
        gallery = [{"type": "gallery", "items": [{"imageUrl": "file:///x.png"}]}]
        self.assertTrue(bench.evaluate({"expect": {"needsImages": True}}, state, gallery, 1)["passed"])
        empty = [{"type": "gallery", "items": [{"imageUrl": ""}]}]
        self.assertFalse(bench.evaluate({"expect": {"needsImages": True}}, state, empty, 1)["passed"])
        image = [{"type": "image", "imageUrl": "file:///y.png"}]
        self.assertTrue(bench.evaluate({"expect": {"needsImages": True}}, state, image, 1)["passed"])

    def test_stored_blocks_read_only_lookup(self):
        db = self.root / "workspace.db"
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE artifacts (id TEXT PRIMARY KEY, blocks TEXT, updated_at TEXT)")
        conn.execute("INSERT INTO artifacts VALUES (?, ?, ?)",
                     ("af-abc-t3", json.dumps([{"type": "table"}]), "2026-01-01T00:00:00.000Z"))
        conn.execute("INSERT INTO artifacts VALUES (?, ?, ?)",
                     ("af-abc-t9", json.dumps([{"type": "check"}]), "2026-01-02T00:00:00.000Z"))
        conn.commit()
        conn.close()
        reader = sqlite3.connect("file:" + str(db) + "?mode=ro", uri=True)
        blocks = bench.stored_blocks(reader, "ws-abc")
        reader.close()
        self.assertEqual(blocks, [{"type": "check"}], "the newest revision wins")
        self.assertEqual(bench.stored_blocks(sqlite3.connect(db), "ws-missing"), [])

    def test_loading_placeholder_detection(self):
        self.assertFalse(bench.loading_placeholder([]))
        self.assertFalse(bench.loading_placeholder([{"type": "text"}]))
        self.assertTrue(bench.loading_placeholder([{"type": "image", "loading": True,
                                                    "error": "Loading visual…"}]))
        self.assertTrue(bench.loading_placeholder([{"type": "gallery", "items": [
            {"error": "Loading visual…"}]}]))
        self.assertFalse(bench.loading_placeholder([{"type": "gallery", "items": [
            {"error": "Media provider rate limited this request; try again later"}]}]),
            "a genuine provider error is a settled state, not a loading placeholder")

    def test_summary_by_kind(self):
        results = [{"passed": True, "kind": "learning"}, {"passed": False, "kind": "learning"},
                   {"passed": True, "kind": "simple"}]
        summary = bench.summarize(results)
        self.assertEqual(summary["prompts"], 3)
        self.assertEqual(summary["passed"], 2)
        self.assertEqual(summary["byKind"]["learning"], {"total": 2, "passed": 1})
        self.assertEqual(summary["byKind"]["simple"], {"total": 1, "passed": 1})


if __name__ == "__main__":
    unittest.main()
