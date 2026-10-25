"""Per-turn timing: Timeline marks, the done-event `timing`, and metrics.jsonl.

Offline only: a fake provider process, never an account. The metrics file must
stay content-free (no prompt, answer, path), bounded, private and atomic.
"""
import asyncio
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ai_broker as b

PROMPT = "ZEBRA-PROMPT-7731 literal question"
RAW = json.dumps({"answer": "QUOKKA-ANSWER-4419", "suggestions": [], "blocks": [
    {"type": "table", "title": "Two", "columns": ["Name", "Value"], "rows": [["A", "1"], ["B", "2"]]}]})
ALLOWED_KEYS = {"ts", "received", "spawn", "first_event", "first_text", "first_block", "final", "done",
                "streamed", "textStreamed", "retried", "agent", "nBlocks", "bytesIn", "bytesOut",
                "inputTokens", "cachedInputTokens", "outputTokens", "reasoningTokens", "dedup",
                "outcome", "explain"}


class FakeClock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now

    def advance(self, ms):
        self.now += ms / 1000


class TimelineTests(unittest.TestCase):
    def test_marks_are_whole_millisecond_offsets_and_keep_the_first_value(self):
        clock = FakeClock()
        line = b.Timeline(clock)
        self.assertEqual(line.marks, {"received": 0})
        clock.advance(12.6)
        self.assertEqual(line.mark("spawn"), 13)
        clock.advance(40)
        line.mark("first_event")
        clock.advance(5)
        self.assertEqual(line.mark("spawn"), 13, "a mark keeps its first value")
        self.assertEqual(line.snapshot()["first_event"], 53)
        self.assertTrue(all(type(v) is int for k, v in line.marks.items()))

    def test_single_message_provider_is_not_streamed(self):
        clock = FakeClock()
        line = b.Timeline(clock)
        clock.advance(3)
        line.mark("spawn")
        clock.advance(100)
        line.mark("first_event")
        clock.advance(7000)
        line.finish_single_message()
        clock.advance(2)
        line.mark("done")
        snap = line.snapshot()
        self.assertFalse(snap["streamed"])
        self.assertFalse(snap["textStreamed"])
        self.assertEqual(snap["first_text"], snap["final"])
        self.assertEqual(snap["first_block"], snap["final"])
        values = [snap[name] for name in b.Timeline.ORDER]
        self.assertEqual(values, sorted(values))
        self.assertEqual(snap["done"], snap["final"] + 2)

    def test_progressive_text_precedes_the_final_result(self):
        clock = FakeClock()
        line = b.Timeline(clock)
        clock.advance(10)
        line.mark("spawn")
        line.mark("first_event")
        clock.advance(500)
        line.mark_text(True)
        clock.advance(900)
        line.mark_text(False)  # only the first text mark counts
        line.finish_single_message()
        snap = line.snapshot()
        self.assertTrue(snap["textStreamed"])
        self.assertFalse(snap["streamed"])
        self.assertEqual((snap["first_text"], snap["final"]), (510, 1410))

    def test_clock_going_backwards_never_breaks_monotonic_marks(self):
        clock = FakeClock()
        line = b.Timeline(clock)
        clock.advance(50)
        line.mark("spawn")
        clock.advance(-40)
        self.assertEqual(line.mark("first_event"), 50)

    def test_retry_restarts_the_attempt_but_keeps_received(self):
        clock = FakeClock()
        line = b.Timeline(clock)
        clock.advance(30)
        line.mark("spawn")
        line.restart_attempt()
        self.assertEqual(line.marks, {"received": 0})
        clock.advance(10)
        self.assertEqual(line.mark("spawn"), 40, "totals include the failed attempt")
        self.assertEqual(line.snapshot()["retried"], 1)


class ProviderStreamCompatibilityTests(unittest.TestCase):
    def test_unknown_events_and_fields_are_ignored(self):
        stream = b.ProviderStream("codex")
        for event in ({"type": "future.event", "x": 1}, {"type": "item.updated", "item": {"type": "agent_message"}},
                      {"type": "item.started", "item": {"type": "agent_message", "id": "m", "text": ""}},
                      {"type": "item.completed", "item": {"type": "reasoning", "text": "hidden"}},
                      {"type": "turn.started"}, {"nothing": True}, {"type": None},
                      {"type": "item.updated", "item": {"type": "agent_message", "text": 5}}):
            with self.subTest(event=event):
                stream.consume(event)
        with self.assertRaises(ValueError):  # an untyped item is not a known harmless type
            stream.consume({"type": "item.updated", "item": {}})
        self.assertEqual((stream.raw, stream.partial_updates, stream.final_text), ("", 0, 0))
        self.assertFalse(stream.complete)

    def test_a_tool_item_update_is_still_refused(self):
        stream = b.ProviderStream("codex")
        with self.assertRaises(ValueError):
            stream.consume({"type": "item.updated", "item": {"type": "command_execution", "text": "x"}})

    def test_cumulative_text_sets_raw_and_final_message_replaces_it(self):
        stream = b.ProviderStream("codex")
        stream.consume({"type": "item.updated", "item": {"type": "agent_message", "text": '{"answer":"Hel'}})
        self.assertEqual((stream.partial_updates, stream.preview()), (1, ""))
        stream.consume({"type": "item.updated", "item": {"type": "agent_message", "text": '{"answer":"Hello","bl'}})
        self.assertEqual((stream.partial_updates, stream.preview()), (2, "Hello"))
        stream.consume({"type": "item.completed", "item": {"type": "agent_message", "text": RAW}})
        self.assertEqual((stream.raw, stream.final_text, stream.partial_updates), (RAW, 1, 2))

    def test_usage_keeps_only_known_bounded_integers(self):
        stream = b.ProviderStream("codex")
        stream.consume({"type": "turn.completed", "usage": {
            "input_tokens": 120, "cached_input_tokens": 100, "output_tokens": 7, "reasoning_output_tokens": 0,
            "total_tokens": 127, "evil": 5, "bad": "x"}})
        self.assertEqual(stream.usage, {"inputTokens": 120, "cachedInputTokens": 100, "outputTokens": 7,
                                        "reasoningTokens": 0})
        bad = b.ProviderStream("codex")
        bad.consume({"type": "turn.completed", "usage": {"input_tokens": "9", "output_tokens": True,
                                                         "cached_input_tokens": -1, "reasoning_output_tokens": 2**60}})
        self.assertEqual(bad.usage, {})
        self.assertTrue(bad.complete)
        bad.consume({"type": "turn.completed", "usage": "nope"})
        self.assertEqual(bad.usage, {})


class MetricsFileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.path = self.base / b.METRICS_NAME

    def rows(self):
        return [json.loads(line) for line in self.path.read_text().splitlines()]

    def leftovers(self):
        return sorted(p.name for p in self.base.iterdir() if p.name != b.METRICS_NAME)

    def test_rows_are_capped_at_200_newest_last_private_and_leave_no_staging(self):
        for number in range(230):
            self.assertTrue(b.append_metrics(self.base, {"ts": number, "agent": "codex", "done": number}))
        rows = self.rows()
        self.assertEqual(len(rows), b.METRICS_MAX_LINES)
        self.assertEqual((rows[0]["ts"], rows[-1]["ts"]), (30, 229))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(self.leftovers(), [])

    def test_a_failed_replace_leaves_the_old_file_untouched_and_no_staging(self):
        b.append_metrics(self.base, {"ts": 1})
        before = self.path.read_bytes()
        with patch.object(b.os, "replace", side_effect=OSError("disk full")):
            self.assertFalse(b.append_metrics(self.base, {"ts": 2}))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.leftovers(), [])

    def test_an_unwritable_or_missing_directory_never_raises(self):
        self.assertFalse(b.append_metrics(self.base / "absent", {"ts": 1}))
        blocker = self.base / "file"
        blocker.write_text("x")
        self.assertFalse(b.append_metrics(blocker, {"ts": 1}))
        self.assertFalse(b.append_metrics(self.base, {"ts": float("nan")}))
        self.assertFalse(self.path.exists())

    def test_garbage_and_oversized_history_is_dropped_not_propagated(self):
        self.path.write_text('{"ts": 1}\nnot json\n[1,2]\n\n{"ts": 2}\n')
        self.assertTrue(b.append_metrics(self.base, {"ts": 3}))
        self.assertEqual([r["ts"] for r in self.rows()], [1, 2, 3])
        self.path.write_bytes(b"x" * (b.METRICS_READ_LIMIT + 10))
        self.assertTrue(b.append_metrics(self.base, {"ts": 4}))
        self.assertEqual([r["ts"] for r in self.rows()], [4])

    def test_a_symlinked_metrics_file_is_replaced_not_followed(self):
        target = self.base / "elsewhere.txt"
        target.write_text("keep me")
        self.path.symlink_to(target)
        self.assertTrue(b.append_metrics(self.base, {"ts": 1}))
        self.assertEqual(target.read_text(), "keep me")
        self.assertFalse(self.path.is_symlink())
        self.assertEqual([r["ts"] for r in self.rows()], [1])


class TurnTimingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.fake = self.base / "fake-provider"
        self.events = []
        self.broker = b.Broker(self.events.append, timeout=10)
        self.broker.base = self.base
        self.broker.codex = (self.base, self.base, [], dict(os.environ))
        for target in (patch.object(b, "refresh_codex_auth"), patch.object(b, "discover_codex", self.locate),
                       patch.dict(os.environ, {b.CODEX_DEDUP_ENV: "0"})):
            target.start()
            self.addCleanup(target.stop)
        self.addAsyncCleanup(self.broker.stop)

    async def locate(self):
        return str(self.fake)

    def provider(self, events, pause=0.0, exit_code=0):
        self.fake.write_text("#!" + sys.executable + "\nimport sys,json,time\nsys.stdin.read()\n" +
                             "events=" + repr(events) + "\nfor e in events:\n    time.sleep(" + repr(pause) +
                             ")\n    print(json.dumps(e),flush=True)\nsys.exit(" + repr(exit_code) + ")\n")
        self.fake.chmod(0o700)

    def codex_events(self, raw=RAW, extra=()):
        return [{"type": "thread.started", "thread_id": "timing-1"}, *extra,
                {"type": "item.completed", "item": {"type": "agent_message", "text": raw}},
                {"type": "turn.completed", "usage": {"input_tokens": 1200, "cached_input_tokens": 1000,
                                                     "output_tokens": 70, "reasoning_output_tokens": 5}}]

    async def run_turn(self, turn=1, agent="codex", **extra):
        await self.broker.command({"op": "submit", "agent": agent, "prompt": PROMPT, "turnId": turn, **extra})
        await self.broker.task

    def done(self):
        return next(e for e in self.events if e["type"] == "done")

    def rows(self):
        path = self.base / b.METRICS_NAME
        return [json.loads(line) for line in path.read_text().splitlines()]

    async def test_codex_done_event_carries_monotonic_timing_with_streamed_false(self):
        self.provider(self.codex_events(), pause=0.02)
        await self.run_turn()
        done = self.done()
        timing = done["timing"]
        self.assertEqual(done["answer"], "QUOKKA-ANSWER-4419", "the answer itself is unchanged")
        order = [timing[name] for name in b.Timeline.ORDER]
        self.assertEqual(order, sorted(order))
        self.assertEqual(timing["received"], 0)
        self.assertGreater(timing["first_event"], timing["spawn"])
        self.assertFalse(timing["streamed"])
        self.assertFalse(timing["textStreamed"])
        self.assertEqual(timing["first_block"], timing["final"])
        # The single completed message is the first answer text and the first blocks.
        self.assertGreaterEqual(timing["first_text"], timing["first_event"])
        self.assertLessEqual(timing["first_text"], timing["final"])
        self.assertEqual(timing["agent"], "codex")
        self.assertEqual(timing["nBlocks"], 1)
        self.assertEqual(timing["bytesOut"], len(RAW.encode()))
        self.assertEqual(timing["bytesIn"], self.broker.context_bytes - len(RAW.encode()))
        self.assertEqual((timing["inputTokens"], timing["cachedInputTokens"], timing["outputTokens"],
                          timing["reasoningTokens"]), (1200, 1000, 70, 5))
        self.assertIs(timing["dedup"], False)
        self.assertEqual(timing["retried"], 0)
        self.assertTrue(all(type(v) in (int, bool, str) for v in timing.values()))

    async def test_dedup_flag_and_smaller_bytes_in_are_reported(self):
        self.provider(self.codex_events())
        await self.run_turn()
        full = self.done()["timing"]
        self.events.clear()
        self.broker = b.Broker(self.events.append, timeout=10)
        self.broker.base = self.base
        self.broker.codex = (self.base, self.base, [], dict(os.environ))
        self.addAsyncCleanup(self.broker.stop)
        os.environ[b.CODEX_DEDUP_ENV] = "1"
        await self.run_turn()
        short = self.done()["timing"]
        self.assertIs(short["dedup"], True)
        os.environ.pop(b.CODEX_DEDUP_ENV)  # unset is the default: ON
        self.assertTrue(b.codex_dedup())
        self.assertLess(short["bytesIn"], full["bytesIn"] - len(b.instructions_for("codex").encode()) // 2)

    async def test_streaming_text_marks_a_progressive_first_text(self):
        # Hermes-shaped stream: text deltas before the final result.
        head = '{"answer":"Hello there","blocks":[],"suggestions":[]}'
        self.provider([{"type": "system", "subtype": "init", "session_id": "h1"},
                       {"type": "text", "text": '{"answer":"Hello there",'},
                       {"type": "text", "text": '"blocks":[],"suggestions":[]}'},
                       {"type": "result", "exit_code": 0, "text": head, "session_id": "h1"}], pause=0.05)
        with patch.object(b, "hermes_command", return_value=([str(self.fake)], dict(os.environ))):
            await self.run_turn(agent="hermes")
        timing = self.done()["timing"]
        self.assertTrue(timing["textStreamed"])
        self.assertFalse(timing["streamed"], "blocks still arrive only with the final result")
        self.assertLess(timing["first_text"], timing["final"])
        self.assertEqual(timing["first_block"], timing["final"])
        self.assertNotIn("dedup", timing)
        self.assertEqual(timing["agent"], "hermes")
        self.assertTrue(any(e["type"] == "delta" for e in self.events))

    async def test_metrics_row_is_content_free_private_and_one_per_turn(self):
        self.provider(self.codex_events())
        await self.run_turn(1)
        await self.run_turn(2)
        path = self.base / b.METRICS_NAME
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        data = path.read_text()
        for secret in ("ZEBRA-PROMPT-7731", "QUOKKA-ANSWER-4419", str(self.base), "fake-provider", "timing-1",
                       "Two", "literal question"):
            self.assertNotIn(secret, data)
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        for row in rows:
            self.assertLessEqual(set(row), ALLOWED_KEYS)
            self.assertEqual((row["agent"], row["outcome"], row["explain"]), ("codex", "done", False))
            self.assertIsInstance(row["ts"], int)
            self.assertTrue(all(type(v) in (int, bool, str) for v in row.values()))
            self.assertTrue(all(type(v) is str for k, v in row.items() if k in ("agent", "outcome")))
        # The row is the done event's timing plus ts/outcome/explain, nothing else.
        extras = {"ts", "outcome", "explain"}
        self.assertEqual({k: v for k, v in rows[1].items() if k not in extras}, self.events[-1]["timing"])

    async def test_failed_turn_records_an_error_row_without_the_message(self):
        self.provider([{"type": "thread.started", "thread_id": "x"}], exit_code=3)
        await self.run_turn()
        self.assertEqual(self.events[-1]["type"], "error")
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["outcome"], "error")
        self.assertNotIn("final", rows[0])
        self.assertNotIn(self.events[-1]["message"], (self.base / b.METRICS_NAME).read_text())
        self.assertNotIn("timing", self.events[-1])

    async def test_a_metrics_failure_never_fails_the_turn(self):
        self.provider(self.codex_events())
        for failure in (RuntimeError("boom"), OSError("read-only")):
            self.events.clear()
            with patch.object(b, "append_metrics", side_effect=failure):
                await self.run_turn()
            self.assertEqual([e["type"] for e in self.events].count("done"), 1)
            self.assertNotIn("error", [e["type"] for e in self.events])
        self.events.clear()
        os.chmod(self.base, 0o500)
        try:
            await self.run_turn()
        finally:
            os.chmod(self.base, 0o700)
        self.assertEqual(self.events[-1]["type"], "done")

    async def test_unknown_events_do_not_disturb_the_turn_or_its_timing(self):
        extra = [{"type": "future.event", "payload": {"a": 1}},
                 {"type": "item.started", "item": {"type": "agent_message", "id": "m1"}},
                 {"type": "item.updated", "item": {"type": "agent_message", "id": "m1"}},
                 {"type": "item.completed", "item": {"type": "reasoning", "text": "hidden"}}]
        self.provider(self.codex_events(extra=extra))
        await self.run_turn()
        done = self.done()
        self.assertEqual(done["answer"], "QUOKKA-ANSWER-4419")
        self.assertEqual(done["timing"]["nBlocks"], 1)

    async def test_stale_resume_retry_keeps_one_row_and_counts_the_retry(self):
        self.fake.write_text("#!" + sys.executable + "\nimport sys,json\nsys.stdin.read()\n" +
                             "if 'resume' in sys.argv:\n    sys.exit(2)\n" +
                             "for e in " + repr(self.codex_events()) + ":\n    print(json.dumps(e),flush=True)\n")
        self.fake.chmod(0o700)
        await self.run_turn(resumeSession="stale-session")
        timing = self.done()["timing"]
        self.assertEqual(timing["retried"], 1)
        order = [timing[name] for name in b.Timeline.ORDER]
        self.assertEqual(order, sorted(order))
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["retried"], 1)

    async def test_explain_turn_is_recorded_without_a_done_event(self):
        self.provider(self.codex_events(raw=json.dumps({"answer": "Simpler words.", "blocks": [], "suggestions": []})))
        await self.broker.command({"op": "explain", "agent": "codex", "prompt": "Depth: simpler", "turnId": 4})
        await self.broker.task
        self.assertEqual(self.events[-1]["type"], "explain")
        self.assertNotIn("timing", self.events[-1])
        rows = self.rows()
        self.assertEqual((len(rows), rows[0]["explain"], rows[0]["outcome"]), (1, True, "done"))
        self.assertNotIn("Simpler words.", (self.base / b.METRICS_NAME).read_text())


if __name__ == "__main__":
    unittest.main()
