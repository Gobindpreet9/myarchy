"""Offline persistence tests for the AI workspace store; stdlib only, no fixtures."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ai_workspace_store as store

MODULE = Path(store.__file__).resolve()
TMP_BASE = "/tmp/opencode"


def temp_root():
    return tempfile.mkdtemp(prefix="ai-workspace-", dir=TMP_BASE)


def isolate_environment(test):
    home, state = Path(test.root) / "home", Path(test.root) / "state"
    home.mkdir()
    state.mkdir()
    patcher = mock.patch.dict(os.environ, HOME=str(home), XDG_STATE_HOME=str(state))
    patcher.start()
    test.addCleanup(patcher.stop)


def workspace_payload(workspace_id="ws-1", artifacts=(), interaction=None, **fields):
    return {"workspace": {"id": workspace_id, **fields},
            "artifacts": list(artifacts), "interaction": interaction or {}}


def artifact(artifact_id="art-1", blocks=(), **fields):
    return {"id": artifact_id, "blocks": list(blocks), **fields}


def blocks(marker):
    return [{"type": "text", "title": "Part", "text": f"answer {marker}"},
            {"type": "checklist", "title": "Steps", "items": ["a", "b"]}]


class WorkspaceStoreTests(unittest.TestCase):
    """Command behavior, driven through the real CLI entry in-process."""

    def setUp(self):
        self.root = temp_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        isolate_environment(self)

    def cli(self, command, payload, root=None):
        out, err = io.BytesIO(), io.BytesIO()
        source = io.BytesIO(json.dumps(payload).encode("utf-8"))
        code = store.main(["--root", root if root is not None else self.root, command],
                          stdin=source, stdout=out, stderr=err)
        data = out.getvalue()
        return code, (json.loads(data) if data else None), err.getvalue().decode("utf-8")

    def process(self, command, payload_text, root=None):
        return subprocess.run(
            [sys.executable, str(MODULE), "--root", root if root is not None else self.root, command],
            input=payload_text, capture_output=True, text=True, timeout=20)

    def db(self):
        return sqlite3.connect(str(Path(self.root) / "workspace.db"))

    def save(self, payload, **kwargs):
        code, result, err = self.cli("save", payload, **kwargs)
        self.assertEqual(code, 0, err)
        self.assertTrue(result["ok"], err)
        return result

    def test_save_load_round_trip_preserves_every_field_and_block_order(self):
        payload = workspace_payload(
            artifacts=[artifact("art-1", blocks("one")),
                       artifact("art-2", [{"type": "table", "columns": ["A"], "rows": [["1"]]}],
                                kind="comparison", presentationVersion=2,
                                reason="extend", prompt="more")],
            interaction={"checklist:art-1": {"done": [True, False], "note": "café ☕"}},
            title="Seasons", summary="Why seasons happen", agent="codex",
            sessionRef="sess-1", draft="draft text", attachment="attachment text",
            activeArtifactId="art-1", pinned=False)
        result = self.save(payload)
        self.assertEqual(result["workspaceId"], "ws-1")
        self.assertEqual(result["savedArtifacts"], 2)
        self.assertEqual(result["savedRevisions"], 2)
        stamp = result["updatedAt"]
        self.assertRegex(stamp, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
        code, loaded, err = self.cli("load", {"workspaceId": "ws-1"})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded["workspace"], {
            "id": "ws-1", "title": "Seasons", "summary": "Why seasons happen", "agent": "codex",
            "sessionRef": "sess-1", "draft": "draft text", "attachment": "attachment text",
            "activeArtifactId": "art-1", "createdAt": stamp, "updatedAt": stamp, "pinned": False})
        self.assertEqual(loaded["artifacts"][0], {
            "id": "art-1", "kind": "answer", "presentationVersion": 1,
            "blocks": blocks("one"), "baseRevision": mock.ANY, "updatedAt": stamp})
        self.assertRegex(loaded["artifacts"][0]["baseRevision"], r"^rv-[0-9a-f]{32}$")
        self.assertEqual(loaded["artifacts"][1]["blocks"],
                         [{"type": "table", "columns": ["A"], "rows": [["1"]]}])
        self.assertEqual(loaded["artifacts"][1]["kind"], "comparison")
        self.assertEqual(loaded["artifacts"][1]["presentationVersion"], 2)
        self.assertEqual(loaded["interaction"], {"checklist:art-1": {"done": [True, False], "note": "café ☕"}})
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM revisions").fetchone()[0], 2)
            reason, prompt = db.execute(
                "SELECT reason, prompt FROM revisions WHERE artifact_id = 'art-2'").fetchone()
        self.assertEqual((reason, prompt), ("extend", "more"))

    def test_latest_load_returns_most_recently_updated_workspace(self):
        self.save(workspace_payload("ws-a", title="A"))
        time.sleep(0.005)
        self.save(workspace_payload("ws-b", title="B"))
        code, loaded, err = self.cli("load", {"latest": True})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded["workspace"]["id"], "ws-b")
        time.sleep(0.005)
        self.save(workspace_payload("ws-a", title="A2"))
        code, loaded, err = self.cli("load", {"latest": True})
        self.assertEqual(loaded["workspace"]["id"], "ws-a")

    def test_twenty_presented_turns_round_trip(self):
        artifacts = [artifact(f"af-t{index}", blocks(index)) for index in range(1, 21)]
        interaction = {f"turn:{index}": {"id": index, "artifactId": f"af-t{index}",
                       "prompt": f"Question {index}", "status": "done"}
                       for index in range(1, 21)}
        result = self.save(workspace_payload("ws-twenty", artifacts=artifacts,
                                             interaction=interaction))
        self.assertEqual(result["savedArtifacts"], 20)
        code, loaded, err = self.cli("load", {"workspaceId": "ws-twenty"})
        self.assertEqual(code, 0, err)
        self.assertEqual([(entry["id"], entry["blocks"]) for entry in loaded["artifacts"]],
                         [(entry["id"], entry["blocks"]) for entry in artifacts])
        self.assertEqual(loaded["interaction"], interaction)

    def test_authoritative_snapshot_removes_only_obsolete_content(self):
        def snapshot(start):
            turns = range(start, start + 20)
            payload = workspace_payload("ws-window",
                artifacts=[artifact(f"af-t{i}", blocks(i)) for i in turns],
                interaction={f"turn:{i}": {"id": i, "artifactId": f"af-t{i}"} for i in turns})
            payload["authoritativeContent"] = True
            return payload
        self.save(snapshot(1))
        self.save(snapshot(2))
        code, loaded, err = self.cli("load", {"workspaceId": "ws-window"})
        self.assertEqual(code, 0, err)
        self.assertEqual({entry["id"] for entry in loaded["artifacts"]},
                         {f"af-t{i}" for i in range(2, 22)})
        self.assertEqual(set(loaded["interaction"]), {f"turn:{i}" for i in range(2, 22)})
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM revisions").fetchone()[0], 20)
        self.save(workspace_payload("ws-window", draft="Thin edit"))
        _, thin_loaded, _ = self.cli("load", {"workspaceId": "ws-window"})
        self.assertEqual(thin_loaded["artifacts"], loaded["artifacts"])
        self.assertEqual(thin_loaded["interaction"], loaded["interaction"])
        empty = workspace_payload("ws-window")
        empty["authoritativeContent"] = True
        self.save(empty)
        _, cleared, _ = self.cli("load", {"workspaceId": "ws-window"})
        self.assertEqual((cleared["artifacts"], cleared["interaction"]), ([], {}))

    def test_load_missing_workspace_returns_null(self):
        self.save(workspace_payload("ws-1", title="Present"))
        code, loaded, err = self.cli("load", {"workspaceId": "absent"})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded, {"ok": True, "workspace": None})
        code, loaded, err = self.cli("load", {"workspaceId": "ws-1"})
        self.assertEqual(loaded["workspace"]["title"], "Present")

    def test_load_latest_on_empty_store_returns_null(self):
        code, loaded, err = self.cli("load", {"latest": True})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded, {"ok": True, "workspace": None})

    def test_load_rejects_ambiguous_or_empty_selectors(self):
        for payload in ({"workspaceId": ""}, {"workspaceId": 7}, {},
                        {"latest": "yes"}, {"workspaceId": "ws-1", "latest": True}):
            with self.subTest(payload=str(payload)):
                code, result, err = self.cli("load", payload)
                self.assertEqual(code, 3, err)
                self.assertFalse(result["ok"])

    def test_update_preserves_created_at_and_bumps_updated_at(self):
        first = self.save(workspace_payload("ws-1", title="First"))
        time.sleep(0.005)
        second = self.save(workspace_payload("ws-1", title="Second"))
        self.assertNotEqual(second["updatedAt"], first["updatedAt"])
        with contextlib.closing(self.db()) as db:
            created, updated = db.execute(
                "SELECT created_at, updated_at FROM workspaces WHERE id = 'ws-1'").fetchone()
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 1)
        self.assertEqual(created, first["updatedAt"])
        self.assertEqual(updated, second["updatedAt"])

    def test_revisions_are_recorded_only_when_blocks_change(self):
        self.save(workspace_payload(artifacts=[artifact(blocks=blocks("one"))]))
        self.save(workspace_payload(artifacts=[artifact(blocks=blocks("one"))]))
        self.save(workspace_payload(artifacts=[artifact(blocks=blocks("two"),
                                                        reason="extend", prompt="revise this")]))
        self.save(workspace_payload(artifacts=[artifact(blocks=blocks("two"))]))
        self.save(workspace_payload(artifacts=[artifact(blocks=blocks("three"))]))
        with contextlib.closing(self.db()) as db:
            rows = db.execute("""SELECT id, parent_revision, checkpoint, reason, prompt
                FROM revisions WHERE artifact_id = 'art-1' ORDER BY rowid""").fetchall()
            base = db.execute("SELECT base_revision FROM artifacts WHERE id = 'art-1'").fetchone()[0]
        self.assertEqual(len(rows), 3)
        self.assertIsNone(rows[0][1])
        self.assertEqual(rows[1][1], rows[0][0])
        self.assertEqual(rows[2][1], rows[1][0])
        self.assertEqual(base, rows[2][0])
        self.assertEqual([json.loads(row[2]) for row in rows],
                         [blocks("one"), blocks("two"), blocks("three")])
        self.assertEqual((rows[1][3], rows[1][4]), ("extend", "revise this"))
        self.assertEqual((rows[2][3], rows[2][4]), ("", ""))
        self.assertTrue(all(row[0].startswith("rv-") for row in rows))

    def test_revision_cap_keeps_256_newest_snapshots(self):
        conn = store.open_store(self.root)
        try:
            for index in range(300):
                payload = workspace_payload("ws-cap", artifacts=[artifact(
                    blocks=[{"type": "text", "text": f"revision {index}"}])])
                result = store.cmd_save(conn, payload)
                self.assertEqual((result["ok"], result["savedRevisions"]), (True, 1))
        finally:
            conn.close()
        with contextlib.closing(self.db()) as db:
            count = db.execute("SELECT COUNT(*) FROM revisions WHERE artifact_id = 'art-1'").fetchone()[0]
            newest = db.execute("""SELECT checkpoint FROM revisions WHERE artifact_id = 'art-1'
                ORDER BY rowid DESC LIMIT 1""").fetchone()[0]
            oldest = db.execute("""SELECT checkpoint FROM revisions WHERE artifact_id = 'art-1'
                ORDER BY rowid ASC LIMIT 1""").fetchone()[0]
            base = db.execute("SELECT base_revision FROM artifacts WHERE id = 'art-1'").fetchone()[0]
        self.assertEqual(count, 256)
        self.assertEqual(json.loads(newest), [{"type": "text", "text": "revision 299"}])
        self.assertEqual(json.loads(oldest), [{"type": "text", "text": "revision 44"}])
        self.assertFalse("revision 43" in newest or "revision 43" in oldest)

    def test_interaction_upsert_preserves_unmentioned_keys(self):
        self.save(workspace_payload("ws-int", interaction={"check:a": {"done": False}, "keep": 1}))
        self.save(workspace_payload("ws-int", interaction={"check:a": {"done": True}}))
        code, loaded, err = self.cli("load", {"workspaceId": "ws-int"})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded["interaction"], {"check:a": {"done": True}, "keep": 1})

    def test_delete_cascades_artifacts_revisions_jobs_and_state(self):
        self.save(workspace_payload("ws-del", artifacts=[artifact(blocks=blocks("one"))],
                                    interaction={"note": "kept state"}))
        now = store._iso()
        with contextlib.closing(self.db()) as db:
            db.execute("""INSERT INTO jobs (id, workspace_id, target, status, token, error, created_at, updated_at)
                VALUES ('job-1', 'ws-del', 'image', 'running', '', '', ?, ?)""", (now, now))
            db.commit()
            self.assertEqual(db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 1)
        code, result, err = self.cli("delete", {"workspaceId": "ws-del"})
        self.assertEqual(code, 0, err)
        self.assertEqual(result, {"ok": True, "deleted": True})
        with contextlib.closing(self.db()) as db:
            for table, expected in (("workspaces", 0), ("artifacts", 0), ("revisions", 0),
                                    ("jobs", 0), ("interaction_state", 0)):
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0],
                                 expected, table)

    def test_delete_unknown_workspace_reports_false(self):
        self.save(workspace_payload("ws-keep", title="Keep"))
        code, result, err = self.cli("delete", {"workspaceId": "nope"})
        self.assertEqual(code, 0, err)
        self.assertEqual(result, {"ok": True, "deleted": False})
        code, loaded, err = self.cli("load", {"workspaceId": "ws-keep"})
        self.assertEqual(loaded["workspace"]["title"], "Keep")

    def test_prune_respects_pinned_and_thirty_day_window(self):
        self.save(workspace_payload("ws-recent", title="Recent"))
        self.save(workspace_payload("ws-old", title="Old", interaction={"note": 1}))
        self.save(workspace_payload("ws-pinned", title="Pinned", pinned=True))
        stale = store._iso(time.time() - 40 * 86400)
        with contextlib.closing(self.db()) as db:
            db.execute("UPDATE workspaces SET updated_at = ? WHERE id IN ('ws-old', 'ws-pinned')", (stale,))
            # FKs keep orphans out of normal saves; simulate one created while
            # foreign_keys was off, which prune must reclaim.
            db.execute("PRAGMA foreign_keys = OFF")
            db.execute("""INSERT INTO artifacts (id, workspace_id, blocks, updated_at)
                VALUES ('orphan', 'vanished-workspace', '[]', ?)""", (store._iso(),))
            db.commit()
        code, result, err = self.cli("prune", {})
        self.assertEqual(code, 0, err)
        self.assertEqual(result, {"ok": True, "prunedWorkspaces": 1, "prunedArtifacts": 1})
        for workspace_id, present in (("ws-recent", True), ("ws-old", False), ("ws-pinned", True)):
            code, loaded, err = self.cli("load", {"workspaceId": workspace_id})
            self.assertEqual(loaded["workspace"] is not None, present, workspace_id)
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM interaction_state").fetchone()[0], 0)

    def test_prune_keeps_at_most_twenty_most_recent_unpinned(self):
        conn = store.open_store(self.root)
        try:
            for index in range(25):
                store.cmd_save(conn, workspace_payload(f"ws-{index:02d}", title=f"T{index}"))
        finally:
            conn.close()
        # All are recent, so the 30-day rule cannot prune them; the unpinned
        # cap alone must trim the 5 oldest down to the 20 most recent.
        code, result, err = self.cli("prune", {})
        self.assertEqual(result["prunedWorkspaces"], 5)
        with contextlib.closing(self.db()) as db:
            remaining = {row[0] for row in db.execute("SELECT id FROM workspaces")}
        self.assertEqual(remaining, {f"ws-{index:02d}" for index in range(5, 25)})

    def test_automatic_maintenance_preserves_old_and_excess_workspaces(self):
        conn = store.open_store(self.root)
        try:
            for index in range(25):
                store.cmd_save(conn, workspace_payload(f"ws-{index:02d}",
                    interaction={"note": index}))
            conn.execute("UPDATE workspaces SET updated_at = ?", (store._iso(time.time() - 40 * 86400),))
            conn.commit()
        finally:
            conn.close()
        code, result, err = self.cli("prune", {"preserveWorkspaces": True})
        self.assertEqual(code, 0, err)
        self.assertEqual(result["prunedWorkspaces"], 0)
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 25)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM interaction_state").fetchone()[0], 25)
        code, _, _ = self.cli("prune", {"preserveWorkspaces": "true"})
        self.assertNotEqual(code, 0)

    def test_prune_deletes_every_unpinned_workspace_older_than_the_window(self):
        conn = store.open_store(self.root)
        try:
            for index in range(25):
                store.cmd_save(conn, workspace_payload(f"ws-{index:02d}", title=f"T{index}"))
        finally:
            conn.close()
        base = time.time() - 40 * 86400
        with contextlib.closing(self.db()) as db:
            for index in range(25):
                db.execute("UPDATE workspaces SET updated_at = ? WHERE id = ?",
                           (store._iso(base + index), f"ws-{index:02d}"))
            db.commit()
        code, result, err = self.cli("prune", {})
        self.assertEqual(result["prunedWorkspaces"], 25)
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 0)

    def test_list_limit_bounds_and_ordering(self):
        self.save(workspace_payload("ws-1", title="One"))
        time.sleep(0.005)
        self.save(workspace_payload("ws-2", title="Two"))
        time.sleep(0.005)
        self.save(workspace_payload("ws-3", title="Three", pinned=True))
        code, result, err = self.cli("list", {})
        self.assertEqual(code, 0, err)
        self.assertEqual([row["id"] for row in result["workspaces"]], ["ws-3", "ws-2", "ws-1"])
        self.assertEqual(result["workspaces"][0],
                         {"id": "ws-3", "title": "Three", "summary": "", "updatedAt": mock.ANY,
                          "pinned": True, "artifactCount": 0})
        code, result, err = self.cli("list", {"limit": 2})
        self.assertEqual([row["id"] for row in result["workspaces"]], ["ws-3", "ws-2"])
        for limit in (0, 51, "20", 1.5, True):
            with self.subTest(limit=limit):
                code, result, err = self.cli("list", {"limit": limit})
                self.assertEqual(code, 3, err)
                self.assertFalse(result["ok"])

    def test_worker_serve_mode_burst_in_order_and_idle_exit(self):
        """The demand-started worker keeps one connection across a burst,
        answers each request in order (including in-band errors), and exits
        cleanly when stdin closes or the idle window passes."""
        env = dict(os.environ, LAUNCHER_STORE_IDLE="1")
        process = subprocess.Popen(
            [sys.executable, str(MODULE), "--root", self.root, "--serve"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env)

        def exchange(body):
            # The service sends {op, payload} over the channel in worker mode
            # (the one-shot CLI reads the op from argv and the body from
            # stdin); both transports carry exactly one JSON line.
            process.stdin.write(json.dumps(body) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            self.assertTrue(line, "worker must answer every request in order")
            return json.loads(line)

        try:
            result = exchange({"op": "save", "payload": workspace_payload("ws-worker", draft="first")})
            self.assertTrue(result["ok"])
            result = exchange({"op": "load", "payload": {"latest": True}})
            self.assertEqual(result["workspace"]["id"], "ws-worker")
            self.assertEqual(result["workspace"]["draft"], "first")
            result = exchange({"op": "list", "payload": {"limit": 10}})
            self.assertEqual([entry["id"] for entry in result["workspaces"]], ["ws-worker"])
            result = exchange("not json at all")
            self.assertFalse(result["ok"], "malformed input answers as an error, not a crash")
            result = exchange({"op": "delete", "payload": {"workspaceId": "missing"}})
            self.assertEqual(result["deleted"], False)
            # EOF is the parent closing the channel; the worker exits 0.
            process.stdin.close()
            self.assertEqual(process.wait(timeout=10), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_worker_error_contract_and_empty_store(self):
        """Worker errors mirror the CLI's static strings; an empty store loads
        as a well-formed empty workspace, never a crash."""
        read_fd, write_fd = os.pipe()
        out = io.BytesIO()
        try:
            os.write(write_fd, json.dumps({"op": "delete", "payload": {"workspaceId": ""}}).encode() + b"\n")
            os.write(write_fd, json.dumps({"op": "load", "payload": {"latest": True}}).encode() + b"\n")
            os.close(write_fd)
            code = store.serve(self.root, out, idle=1, fd=read_fd)
        finally:
            try:
                os.close(read_fd)
            except OSError:
                pass
        self.assertEqual(code, 0)
        lines = [json.loads(line) for line in out.getvalue().split(b"\n") if line]
        self.assertFalse(lines[0]["ok"])
        self.assertIn("non-empty", lines[0]["error"])
        self.assertIsNone(lines[1]["workspace"], "an empty store loads as a null workspace")

    def test_partial_save_preserves_stored_content(self):
        """Coalesced dirty-field saves omit content, never clear it: a save
        carrying only the workspace row must leave artifacts and interaction
        rows intact (the launcher sends the full, small workspace field set
        plus empty content lists for draft/attachment-only edits)."""
        self.save(workspace_payload("ws-partial", artifacts=[artifact("art-p", blocks("one"))],
                                    interaction={"checklists": {"1": {"0:0": True}}},
                                    draft="first", title="Original"))
        code, result, err = self.cli("save", {
            "workspace": {"id": "ws-partial", "title": "Original", "summary": "", "agent": "",
                          "sessionRef": "", "draft": "second", "attachment": ""},
            "artifacts": [], "interaction": {}})
        self.assertEqual(code, 0, err)
        self.assertEqual(result["savedArtifacts"], 0)
        code, loaded, err = self.cli("load", {"workspaceId": "ws-partial"})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded["workspace"]["draft"], "second")
        self.assertEqual(loaded["workspace"]["title"], "Original")
        self.assertEqual(loaded["artifacts"][0]["blocks"], blocks("one"), "artifacts survive a draft-only save")
        self.assertEqual(loaded["interaction"]["checklists"], {"1": {"0:0": True}},
                         "interaction rows survive a draft-only save")
        # A later full save still rewrites everything consistently.
        code, _, err = self.cli("save", workspace_payload("ws-partial",
                                artifacts=[artifact("art-p", blocks("two"))], draft="third"))
        self.assertEqual(code, 0, err)
        code, loaded, err = self.cli("load", {"workspaceId": "ws-partial"})
        self.assertEqual(loaded["artifacts"][0]["blocks"], blocks("two"))

    def test_minimal_save_creates_default_row(self):
        result = self.save({"workspace": {"id": "ws-min"}})
        self.assertEqual((result["savedArtifacts"], result["savedRevisions"]), (0, 0))
        code, loaded, err = self.cli("load", {"workspaceId": "ws-min"})
        self.assertEqual(loaded["workspace"]["title"], "")
        self.assertEqual(loaded["workspace"]["pinned"], False)
        self.assertEqual(loaded["workspace"]["activeArtifactId"], None)
        self.assertEqual(loaded["artifacts"], [])
        self.assertEqual(loaded["interaction"], {})

    def test_save_rejects_malformed_workspace_fields(self):
        cases = (
            {}, {"workspace": None}, {"workspace": {"id": 7}}, {"workspace": {"id": "", "title": "x"}},
            {"workspace": {"id": "ws-1", "pinned": "yes"}}, {"workspace": {"id": "ws-1", "draft": 5}},
            {"workspace": {"id": "ws-1"}, "artifacts": {}},
            {"workspace": {"id": "ws-1"}, "interaction": []},
            {"workspace": {"id": "ws-1"}, "interaction": {"big": "x" * (store.MAX_INTERACTION_VALUE + 1)}},
            {"workspace": {"id": "ws-1"}, "artifacts": [artifact() for _ in range(store.MAX_ARTIFACTS + 1)]},
            {"workspace": {"id": "ws-1"}, "artifacts": ["not a dict"]},
            {"workspace": {"id": "ws-1"}, "artifacts": [{"blocks": []}]},
            {"workspace": {"id": "ws-1"}, "artifacts": [artifact(kind="", blocks=[])]},
            {"workspace": {"id": "ws-1"}, "artifacts": [artifact(presentationVersion=0)]},
            {"workspace": {"id": "ws-1"}, "authoritativeContent": "yes"},
        )
        for payload in cases:
            with self.subTest(payload=str(payload)[:60]):
                code, result, err = self.cli("save", payload)
                self.assertEqual(code, 3, err)
                self.assertFalse(result["ok"])

    def test_invalid_blocks_fail_closed(self):
        good = {"type": "text", "text": "ok"}
        cases = ("not a list", [good, "not a dict"], [good, {"text": "no type"}],
                 [{"type": 7, "text": "bad type"}], [{"type": ""}], [good] * 65)
        for index, bad in enumerate(cases):
            with self.subTest(index=index):
                code, result, err = self.cli("save", workspace_payload(artifacts=[artifact(blocks=bad)]))
                self.assertEqual(code, 3, err)
                self.assertFalse(result["ok"])

    def test_artifact_cannot_move_between_workspaces(self):
        self.save(workspace_payload("ws-a", artifacts=[artifact("art-1", blocks=blocks("one"))]))
        code, result, err = self.cli("save", workspace_payload("ws-b", artifacts=[artifact("art-1",
                                                                                          blocks=blocks("one"))]))
        self.assertEqual(code, 3, err)
        self.assertFalse(result["ok"])
        # The rejected save rolled back entirely: ws-b was never created.
        code, loaded, err = self.cli("load", {"workspaceId": "ws-b"})
        self.assertEqual(loaded, {"ok": True, "workspace": None})


class RobustnessTests(unittest.TestCase):
    """Transaction atomicity, path safety, and WAL concurrency smoke."""

    def setUp(self):
        self.root = temp_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        isolate_environment(self)

    def cli(self, command, payload):
        out, err = io.BytesIO(), io.BytesIO()
        code = store.main(["--root", self.root, command],
                          stdin=io.BytesIO(json.dumps(payload).encode("utf-8")),
                          stdout=out, stderr=err)
        data = out.getvalue()
        return code, (json.loads(data) if data else None), err.getvalue().decode("utf-8")

    def test_failed_save_leaves_prior_state_intact(self):
        conn = store.open_store(self.root)
        try:
            self.assertTrue(store.cmd_save(conn, workspace_payload(
                "ws-1", artifacts=[artifact(blocks=blocks("one"))], title="Original"))["ok"])
        finally:
            conn.close()
        conn = store.open_store(self.root)
        try:
            breaking = workspace_payload("ws-1", artifacts=[artifact(blocks=blocks("two"))],
                                         interaction={"boom": True}, title="Broken")
            with mock.patch.object(store, "_upsert_interaction",
                                   side_effect=store.StoreError("Simulated storage failure")):
                with self.assertRaises(store.StoreError):
                    store.cmd_save(conn, breaking)
        finally:
            conn.close()
        code, loaded, err = self.cli("load", {"workspaceId": "ws-1"})
        self.assertEqual(code, 0, err)
        self.assertEqual(loaded["workspace"]["title"], "Original")
        self.assertEqual(loaded["artifacts"][0]["blocks"], blocks("one"))
        self.assertEqual(loaded["interaction"], {})
        with contextlib.closing(sqlite3.connect(str(Path(self.root) / "workspace.db"))) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM revisions").fetchone()[0], 1)

    def test_wal_mode_and_save_during_held_read(self):
        conn = store.open_store(self.root)
        try:
            self.assertTrue(store.cmd_save(conn, workspace_payload("ws-1", title="First"))["ok"])
            self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        finally:
            conn.close()
        # A second handle holds a read transaction; WAL readers never block the
        # writer, so the save must still return ok (single-writer, no races).
        held = sqlite3.connect(str(Path(self.root) / "workspace.db"), timeout=3, isolation_level=None)
        try:
            held.execute("BEGIN")
            held.execute("SELECT COUNT(*) FROM workspaces").fetchone()
            code, result, err = self.cli("save", workspace_payload("ws-1", title="Updated"))
            self.assertEqual(code, 0, err)
            self.assertTrue(result["ok"])
            code, loaded, err = self.cli("load", {"workspaceId": "ws-1"})
            self.assertEqual(loaded["workspace"]["title"], "Updated")
        finally:
            held.execute("ROLLBACK")
            held.close()

    def test_store_enforces_private_modes_under_umask_022(self):
        root = Path(self.root) / "private" / "store"
        mask = os.umask(0o022)
        try:
            with contextlib.closing(store.open_store(str(root))) as conn:
                store.cmd_save(conn, workspace_payload("ws-private", draft="Secret"))
                for directory in (root.parent, root):
                    self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                for name in ("workspace.db", "workspace.db-wal", "workspace.db-shm"):
                    path = root / name
                    self.assertTrue(path.exists(), name)
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600, name)
                    path.chmod(0o644)
                root.chmod(0o755)
                with contextlib.closing(store.open_store(str(root))):
                    self.assertEqual(root.stat().st_mode & 0o777, 0o700)
                    for name in ("workspace.db", "workspace.db-wal", "workspace.db-shm"):
                        self.assertEqual((root / name).stat().st_mode & 0o777, 0o600, name)
        finally:
            os.umask(mask)

    def test_root_symlink_components_never_touch_outside_sentinel(self):
        outside = Path(self.root) / "outside"
        outside.mkdir(mode=0o755)
        outside.chmod(0o755)
        sentinel = outside / "workspace.db"
        sentinel.write_text("untouched sentinel")
        sentinel.chmod(0o644)
        link = Path(self.root) / "link"
        link.symlink_to(outside, target_is_directory=True)
        for root in (link, link / "nested"):
            with self.subTest(root=root), self.assertRaises(store.InputError):
                store.open_store(str(root))
        self.assertEqual(sentinel.read_text(), "untouched sentinel")
        self.assertEqual(sentinel.stat().st_mode & 0o777, 0o644)
        self.assertEqual(outside.stat().st_mode & 0o777, 0o755)
        self.assertFalse((outside / "nested").exists())

    def test_database_and_sidecar_links_never_touch_sentinel(self):
        sentinel = Path(self.root) / "sentinel"
        sentinel.write_text("untouched sentinel")
        sentinel.chmod(0o644)
        for name in ("workspace.db", "workspace.db-wal", "workspace.db-shm", "workspace.db-journal"):
            root = Path(self.root) / name
            root.mkdir()
            (root / name).symlink_to(sentinel)
            with self.subTest(name=name), self.assertRaises(store.InputError):
                store.open_store(str(root))
            self.assertEqual(sentinel.read_text(), "untouched sentinel")
            self.assertEqual(sentinel.stat().st_mode & 0o777, 0o644)
        root = Path(self.root) / "hardlink"
        root.mkdir()
        os.link(sentinel, root / "workspace.db")
        with self.assertRaises(store.InputError):
            store.open_store(str(root))
        self.assertEqual(sentinel.read_text(), "untouched sentinel")
        self.assertEqual(sentinel.stat().st_mode & 0o777, 0o644)

    def test_shared_writable_parent_is_rejected_before_storage(self):
        shared = Path(self.root) / "shared"
        shared.mkdir()
        shared.chmod(0o777)
        root = shared / "store"
        root.mkdir()
        sentinel = root / "workspace.db"
        sentinel.write_text("untouched sentinel")
        sentinel.chmod(0o644)
        with self.assertRaises(store.InputError):
            store.open_store(str(root))
        self.assertEqual(sentinel.read_text(), "untouched sentinel")
        self.assertEqual(sentinel.stat().st_mode & 0o777, 0o644)


class CliContractTests(unittest.TestCase):
    """Process-level exit codes and stdio framing via subprocess."""

    def setUp(self):
        self.root = temp_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        isolate_environment(self)

    def process(self, command, payload_text, root=None):
        argv = [sys.executable, str(MODULE)]
        if root is not None or command is not None:
            argv += ["--root", root if root is not None else self.root]
            if command is not None:
                argv.append(command)
        return subprocess.run(argv, input=payload_text, capture_output=True, text=True, timeout=20)

    def test_usage_errors_report_exit_2(self):
        cases = ([], ["--root", self.root], ["--root", self.root, "unknown"],
                 [str(self.root), "save"], ["--root", self.root, "save", "extra"])
        for argv in cases:
            with self.subTest(argv=argv):
                result = subprocess.run([sys.executable, str(MODULE)] + argv,
                                        input="", capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_oversize_payload_is_rejected_before_storage(self):
        raw = b'{"pad":"' + b"a" * (store.MAX_PAYLOAD + 1) + b'"}'
        result = self.process("save", raw.decode("utf-8"))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(result.stderr, "")
        self.assertFalse(Path(self.root, "workspace.db").exists())

    def test_invalid_json_payload_is_rejected(self):
        result = self.process("save", "{not json")
        self.assertEqual(result.returncode, 3)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(result.stderr, "")

    def test_newer_schema_version_fails_closed(self):
        result = self.process("save", json.dumps({"workspace": {"id": "ws-1", "title": "Seed"}}))
        self.assertEqual(result.returncode, 0, result.stderr)
        with contextlib.closing(sqlite3.connect(str(Path(self.root) / "workspace.db"))) as db:
            db.execute("UPDATE meta SET value = '2' WHERE key = 'schema_version'")
            db.commit()
        result = self.process("load", '{"latest": true}')
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         {"ok": False, "error": "Workspace schema is newer than this app (v2)"})
        self.assertEqual(result.stderr, "")

    def test_root_path_safety_refusals(self):
        for name, root in (("relative", "not/absolute"), ("dotdot", str(Path(self.root) / ".." / "escape")),
                           ("empty", "")):
            with self.subTest(name=name):
                result = self.process("list", "{}", root=root)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertFalse(json.loads(result.stdout)["ok"])
                self.assertEqual(result.stderr, "")
        (Path(self.root) / "elsewhere.db").write_text("")
        (Path(self.root) / "workspace.db").symlink_to("elsewhere.db")
        result = self.process("list", "{}")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual((Path(self.root) / "elsewhere.db").stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()
