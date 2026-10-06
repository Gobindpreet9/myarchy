"""Broker visual isolation without network or model calls."""
import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ai_broker import enrich_answer


def answer():
    return {"answer": "Useful explanation", "blocks": [
        {"type": "image", "title": "Mountain", "query": "Mount Rainier"},
        {"type": "text", "title": "", "text": "Keep this"}], "suggestions": [], "warning": ""}


class VisualRoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_plain_answers_do_not_start_worker(self):
        plain = {"answer": "Hello", "blocks": [], "suggestions": [], "warning": ""}
        command = Mock(side_effect=AssertionError("No network for ordinary text"))
        with patch("ai_broker.media_command", command):
            self.assertIs(await enrich_answer(plain, Path("/unused")), plain)
        command.assert_not_called()

    async def test_visual_requests_are_resolved_before_delivery(self):
        code = "import sys,json; d=json.load(sys.stdin); d['blocks'][0]['error']='No fixture image'; print(json.dumps(d))"
        with patch("ai_broker.media_command", return_value=[sys.executable, "-c", code]):
            result = await enrich_answer(answer(), Path("/unused"))
        self.assertEqual(result["blocks"][0]["error"], "No fixture image")
        self.assertEqual(result["answer"], "Useful explanation")

    async def test_media_failure_does_not_drop_answer_or_other_blocks(self):
        original = answer()
        with patch("ai_broker.media_command", return_value=[sys.executable, "-c", "raise SystemExit(3)"]):
            result = await enrich_answer(original, Path("/unused"))
        self.assertEqual(result["answer"], original["answer"])
        self.assertEqual(result["blocks"][1], original["blocks"][1])
        self.assertIn("unavailable", result["blocks"][0]["error"])
        self.assertNotIn("error", original["blocks"][0])

    async def _verify_worker_terminated(self, cancel):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "pid"
            late_write = Path(directory) / "late-cache-write"
            code = ("import sys,time,os,pathlib; sys.stdin.read(); "
                    f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                    f"time.sleep(30); pathlib.Path({str(late_write)!r}).write_text('must not happen')")
            guarded = [sys.executable, str(Path(__file__).resolve().parents[1] / "ai_broker.py"),
                       "--supervise", str(os.getpid()), sys.executable, "-c", code]
            with patch("ai_broker.media_command", return_value=guarded):
                task = asyncio.create_task(enrich_answer(answer(), Path(directory), timeout=0.4 if not cancel else 25))
                for _ in range(100):
                    if pid_file.exists():
                        break
                    await asyncio.sleep(0.01)
                self.assertTrue(pid_file.exists())
                pid = int(pid_file.read_text())
                if cancel:
                    task.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await task
                else:
                    result = await task
                    self.assertIn("unavailable", result["blocks"][0]["error"])
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                self.assertFalse(late_write.exists())

    async def test_cancellation_kills_worker_and_prevents_later_cache_writes(self):
        await self._verify_worker_terminated(True)

    async def test_hard_deadline_kills_worker_not_just_its_awaiter(self):
        await self._verify_worker_terminated(False)
