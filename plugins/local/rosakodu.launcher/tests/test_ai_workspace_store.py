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


    def reusable_fixture(self):
        """A fully offline saved tool, including shared cached-media paths."""
        self.source_id = "ws-" + "a" * 16
        self.destination_id = "ws-" + "b" * 16
        self.turn_artifact = "af-" + "a" * 16 + "-t42"
        payload = workspace_payload(self.source_id,
            artifacts=[artifact(self.turn_artifact, [
                {"type": "calc", "inputs": [{"id": "weight", "value": 3}]},
                {"type": "image", "source": "media/cached.png", "url": "file:///cached.png"}],
                kind="tool", presentationVersion=2), artifact("loose-artifact", blocks("loose"))],
            interaction={
                "workspaceName": "Original name", "handoffHome": "/isolated/codex-home",
                "csvSource": {"sourceId": "src-" + "c" * 16, "origin": "/fixture/data.csv"},
                "turn:42": {"id": 42, "artifactId": self.turn_artifact, "status": "done",
                    "prompt": "Calculate", "answer": "Result", "explanation": "More detail"},
                "turn:43": {"id": 43, "artifactId": "empty-turn", "status": "error",
                    "error": "No presentation"},
                "turn:44": {"id": 44, "blocks": blocks("legacy")},
                "checklists": {"42": {"0:0": True}},
                "uiStates": {"42": {"calc:0": {"weight": {"v": 7, "u": "kg"}},
                    "table:1": {"sort": 0, "dir": -1, "filter": "literal|filter"}}},
                "checklist:loose-artifact": {"done": [False, True]},
                "references": {"artifactId": "loose-artifact", "text": "loose-artifact"}},
            title="Original name", summary="Saved summary", agent="codex",
            sessionRef="provider-session", draft="Unsent draft", attachment="/fixture/data.csv",
            activeArtifactId=self.turn_artifact, pinned=True)
        self.save(payload)
        # Make a real revision chain; copying it would retain unwanted ancestry.
        self.save(payload)
        self.save(workspace_payload(self.source_id,
            artifacts=[artifact("loose-artifact", blocks("revised"))],
            **{key: value for key, value in payload["workspace"].items() if key != "id"}))
        _, result, _ = self.cli("source_link", {"workspaceId": self.source_id,
            "sourceId": "src-" + "c" * 16, "bytes": 12, "rows": 1})
        self.assertTrue(result["ok"])
        directory = Path(self.root) / "sources" / ("src-" + "c" * 16)
        directory.mkdir(parents=True)
        (directory / "data.csv").write_text("value\n7\n")
        with contextlib.closing(self.db()) as db:
            db.execute("""INSERT INTO jobs VALUES ('job-original', ?, 'media', 'running',
                'token', '', 'old-created', 'old-updated')""", (self.source_id,))
            db.commit()
        return self.cli("load", {"workspaceId": self.source_id})[1]

    def stored_snapshot(self):
        with contextlib.closing(self.db()) as db:
            return {table: db.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall()
                    for table in ("workspaces", "artifacts", "interaction_state", "revisions",
                                  "jobs", "sources")}

    def duplicate(self, **changes):
        return self.cli("duplicate", {"workspaceId": self.source_id,
            "newWorkspaceId": self.destination_id, "title": "  Independent tool  ", **changes})

    def test_rename_changes_only_title_timestamp_and_name_marker(self):
        original = self.reusable_fixture()
        before = self.stored_snapshot()
        with mock.patch.object(store, "_iso", return_value="new-timestamp"):
            code, result, err = self.cli("rename", {"workspaceId": self.source_id, "title": "  Named tool  "})
        self.assertEqual(code, 0, err)
        self.assertEqual(result, {"ok": True, "workspaceId": self.source_id, "title": "Named tool"})
        loaded = self.cli("load", {"workspaceId": self.source_id})[1]
        expected = json.loads(json.dumps(original))
        expected["workspace"].update(title="Named tool", updatedAt="new-timestamp")
        expected["interaction"]["workspaceName"] = "Named tool"
        self.assertEqual(loaded, expected)
        after = self.stored_snapshot()
        for table in ("artifacts", "revisions", "jobs", "sources"):
            self.assertEqual(after[table], before[table], table)
        old_states = {row[1]: row for row in before["interaction_state"]}
        for row in after["interaction_state"]:
            if row[1] != "workspaceName":
                self.assertEqual(row, old_states[row[1]])

    def test_reusable_name_validation_is_static_and_atomic(self):
        self.reusable_fixture()
        before = self.stored_snapshot()
        forbidden = [chr(code) for code in range(32)] + [chr(code) for code in range(127, 160)]
        forbidden += ["\u00ad", "\u061c", "\u180e", "\ufeff", "\ufff9", "\ufffa", "\ufffb"]
        forbidden += [chr(code) for code in range(0x200b, 0x2010)]
        forbidden += [chr(code) for code in range(0x2028, 0x202f)]
        forbidden += [chr(code) for code in range(0x2060, 0x2070)]
        invalid = [None, 0, True, [], {}, "", " \u2003 ", "a" * 97, "😀" * 49,
                   "\ud800", "\udc00", "\ud800x\udc00"] + ["a" + char + "b" for char in forbidden]
        for command in ("rename", "duplicate"):
            for title in invalid:
                with self.subTest(command=command, title=repr(title)):
                    code, result, _ = self.cli(command, {"workspaceId": self.source_id,
                        "newWorkspaceId": self.destination_id, "title": title})
                    self.assertEqual(code, 3)
                    self.assertEqual(result, {"ok": False, "error":
                        "Title must be a non-empty single-line name of at most 96 UTF-16 units"})
        self.assertEqual(self.stored_snapshot(), before)

    def test_reusable_names_use_trimmed_utf16_length_and_accept_valid_pairs(self):
        self.reusable_fixture()
        for title in ("a" * 96, "😀" * 48, "a" * 94 + "😀", "\u0600name"):
            code, result, _ = self.cli("rename", {"workspaceId": self.source_id, "title": "\u2003 " + title + "  "})
            self.assertEqual(code, 0, result)
            self.assertEqual(result["title"], title)
        with contextlib.closing(store.open_store(self.root)) as conn:
            result = store.cmd_rename(conn, {"workspaceId": self.source_id, "title": "\ud83d\ude00"})
        self.assertEqual(result["title"], "😀")
        code, result, _ = self.duplicate(title="😀" * 48)
        self.assertEqual(code, 0, result)
        self.assertEqual(result["title"], "😀" * 48)

    def test_rename_missing_workspace_and_bad_payload_change_nothing(self):
        self.reusable_fixture()
        before = self.stored_snapshot()
        for payload in (None, [], {}, {"workspaceId": "", "title": "Name"},
                        {"workspaceId": "missing", "title": "Name"}):
            self.assertEqual(self.cli("rename", payload)[0], 3)
        self.assertEqual(self.stored_snapshot(), before)

    def test_rename_rolls_back_when_name_marker_write_fails(self):
        self.reusable_fixture()
        before = self.stored_snapshot()
        with mock.patch.object(store, "_upsert_interaction", side_effect=store.StoreError("Write failed")):
            code, result, _ = self.cli("rename", {"workspaceId": self.source_id, "title": "New"})
        self.assertEqual(code, 4)
        self.assertFalse(result["ok"])
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_preserves_content_remaps_identities_and_clears_sessions(self):
        original = self.reusable_fixture()
        before = self.stored_snapshot()
        code, result, err = self.duplicate()
        self.assertEqual(code, 0, (result, err))
        self.assertEqual(result, {"ok": True, "workspaceId": self.destination_id, "title": "Independent tool"})
        copied = self.cli("load", {"workspaceId": self.destination_id})[1]
        workspace = copied["workspace"]
        for field in ("summary", "agent", "draft", "attachment"):
            self.assertEqual(workspace[field], original["workspace"][field])
        self.assertEqual(workspace["sessionRef"], "")
        self.assertFalse(workspace["pinned"])
        self.assertEqual(workspace["createdAt"], workspace["updatedAt"])
        new_turn_id = "af-" + "b" * 16 + "-t42"
        self.assertEqual(workspace["activeArtifactId"], new_turn_id)
        self.assertEqual(copied["artifacts"][0]["id"], new_turn_id)
        new_loose_id = copied["artifacts"][1]["id"]
        self.assertNotEqual(new_loose_id, "loose-artifact")
        for old, new in zip(original["artifacts"], copied["artifacts"]):
            for field in ("kind", "presentationVersion", "blocks"):
                self.assertEqual(new[field], old[field])
            self.assertNotEqual(new["baseRevision"], old["baseRevision"])
        expected_interaction = json.loads(json.dumps(original["interaction"]))
        expected_interaction.pop("handoffHome")
        expected_interaction.pop("csvSource")
        expected_interaction["workspaceName"] = "Independent tool"
        expected_interaction["turn:42"]["artifactId"] = new_turn_id
        expected_interaction["turn:43"]["artifactId"] = "af-" + "b" * 16 + "-t43"
        expected_interaction["checklist:" + new_loose_id] = expected_interaction.pop("checklist:loose-artifact")
        expected_interaction["references"]["artifactId"] = new_loose_id
        self.assertEqual(copied["interaction"], expected_interaction)
        self.assertEqual(self.cli("load", {"workspaceId": self.source_id})[1], original)
        with contextlib.closing(self.db()) as db:
            checkpoints = db.execute("""SELECT r.artifact_id, r.parent_revision, r.checkpoint,
                r.reason, r.prompt FROM revisions r JOIN artifacts a ON a.id = r.artifact_id
                WHERE a.workspace_id = ? ORDER BY r.rowid""", (self.destination_id,)).fetchall()
            self.assertEqual(len(checkpoints), 2)
            for row, entry in zip(checkpoints, copied["artifacts"]):
                self.assertEqual(row, (entry["id"], None, store._canonical(entry["blocks"]), "", ""))
            self.assertEqual(db.execute("SELECT * FROM jobs").fetchall(), before["jobs"])
            self.assertEqual(db.execute("SELECT * FROM sources").fetchall(), before["sources"])

    def test_duplicate_edits_and_delete_are_independent_csv_stays_original(self):
        original = self.reusable_fixture()
        self.assertEqual(self.duplicate()[0], 0)
        copied = self.cli("load", {"workspaceId": self.destination_id})[1]
        copied["artifacts"][0]["blocks"] = blocks("independent edit")
        copied["interaction"]["uiStates"]["42"]["calc:0"]["weight"]["v"] = 99
        copied["interaction"]["checklists"]["42"]["0:0"] = False
        self.save({"workspace": copied["workspace"], "artifacts": copied["artifacts"],
                   "interaction": copied["interaction"]})
        self.assertEqual(self.cli("load", {"workspaceId": self.source_id})[1], original)
        self.assertEqual(self.cli("source_list", {"workspaceId": self.destination_id})[1]["sources"], [])
        self.assertEqual(self.cli("delete", {"workspaceId": self.destination_id})[1], {"ok": True, "deleted": True})
        self.assertEqual(self.cli("load", {"workspaceId": self.source_id})[1], original)
        self.assertEqual((Path(self.root) / "sources" / ("src-" + "c" * 16) / "data.csv").read_text(), "value\n7\n")
        self.assertEqual(len(list((Path(self.root) / "sources").iterdir())), 1)

    def test_duplicate_rejects_collisions_missing_source_and_invalid_ids(self):
        self.reusable_fixture()
        for destination in ("", "ws-1", "ws-" + "A" * 16, "ws-" + "a" * 15,
                            "ws-" + "a" * 17, "../ws-" + "a" * 16, self.destination_id + "\n", None):
            self.assertEqual(self.duplicate(newWorkspaceId=destination)[0], 3)
        self.assertEqual(self.duplicate(workspaceId="missing")[0], 3)
        self.assertEqual(self.duplicate(newWorkspaceId=self.source_id)[0], 3)
        for payload in ([], None, {}, {"workspaceId": 1}):
            self.assertEqual(self.cli("duplicate", payload)[0], 3)
        self.assertEqual(self.duplicate()[0], 0)
        before = self.stored_snapshot()
        self.assertEqual(self.duplicate(title="Overwrite attempt")[0], 3)
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_rejects_global_artifact_collision_without_overwriting(self):
        self.reusable_fixture()
        self.save(workspace_payload("other", artifacts=[artifact("af-" + "b" * 16 + "-t42")]))
        before = self.stored_snapshot()
        code, result, _ = self.duplicate()
        self.assertEqual(code, 3)
        self.assertEqual(result["error"], "Destination artifact already exists")
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_rejects_malformed_turns_without_dropping_rows(self):
        self.reusable_fixture()
        invalid = [None, [], "text", {}, {"id": True}, {"id": 42.0}, {"id": "42"},
                   {"id": 43}, {"id": 42, "artifactId": 1}, {"id": 42, "artifactId": []},
                   {"id": 42, "blocks": {}}, {"id": 42, "blocks": ["invalid"]}]
        for value in invalid:
            with self.subTest(value=value):
                self.save(workspace_payload(self.source_id, interaction={"turn:42": value}))
                before = self.stored_snapshot()
                code, result, _ = self.duplicate()
                self.assertEqual(code, 4)
                self.assertEqual(result["error"], "Stored workspace turns cannot be duplicated")
                self.assertEqual(self.stored_snapshot(), before)
        self.save(workspace_payload(self.source_id, interaction={"turn:42": {"id": 42},
            "turn:bad": {"id": 45}}))
        before = self.stored_snapshot()
        self.assertEqual(self.duplicate()[0], 4)
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_rejects_unreadable_json_and_rolls_back_partial_inserts(self):
        self.reusable_fixture()
        for text in ("not JSON", "NaN", '"\\ud800"', '[{"type":"text"}, 1]', '{}',
                     '[{"type":"text", "type":"calc"}]'):
            with self.subTest(text=text):
                with contextlib.closing(self.db()) as db:
                    db.execute("UPDATE artifacts SET blocks = ? WHERE id = 'loose-artifact'", (text,))
                    db.commit()
                before = self.stored_snapshot()
                self.assertEqual(self.duplicate()[0], 4)
                self.assertEqual(self.stored_snapshot(), before)
        with contextlib.closing(self.db()) as db:
            db.execute("UPDATE artifacts SET blocks = '[]' WHERE id = 'loose-artifact'")
            db.execute("UPDATE interaction_state SET value = 'not JSON' WHERE key = 'uiStates'")
            db.commit()
        before = self.stored_snapshot()
        self.assertEqual(self.duplicate()[0], 4)
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_rolls_back_when_late_interaction_insert_fails(self):
        self.reusable_fixture()
        with contextlib.closing(self.db()) as db:
            db.execute("""CREATE TRIGGER fail_duplicate BEFORE INSERT ON interaction_state
                WHEN NEW.workspace_id = 'ws-bbbbbbbbbbbbbbbb'
                BEGIN SELECT RAISE(ABORT, 'test write failure'); END""")
            db.commit()
        before = self.stored_snapshot()
        self.assertEqual(self.duplicate()[0], 4)
        self.assertEqual(self.stored_snapshot(), before)

    def test_duplicate_empty_workspace_and_empty_active_reference(self):
        self.source_id, self.destination_id = "source", "ws-" + "b" * 16
        self.save(workspace_payload(self.source_id, draft="Draft", activeArtifactId=""))
        self.assertEqual(self.duplicate()[0], 0)
        copied = self.cli("load", {"workspaceId": self.destination_id})[1]
        self.assertEqual(copied["workspace"]["activeArtifactId"], "")
        self.assertEqual(copied["workspace"]["draft"], "Draft")
        self.assertEqual(copied["artifacts"], [])
        self.assertEqual(copied["interaction"], {"workspaceName": "Independent tool"})

    def test_duplicate_artifact_ids_do_not_rewrite_name_or_turn_state_keys(self):
        self.source_id, self.destination_id = "source", "ws-" + "b" * 16
        local_state = {"42": {"calc:0": {"weight": {"v": 7}}}}
        self.save(workspace_payload(self.source_id, artifacts=[artifact("42"), artifact("workspaceName")],
            interaction={"turn:42": {"id": 42, "artifactId": "42"}, "uiStates": local_state,
                         "checklists": {"42": {"0:0": True}}, "workspaceName": "Original"},
            activeArtifactId="workspaceName"))
        self.assertEqual(self.duplicate()[0], 0)
        copied = self.cli("load", {"workspaceId": self.destination_id})[1]
        self.assertEqual(copied["interaction"]["uiStates"], local_state)
        self.assertEqual(copied["interaction"]["checklists"], {"42": {"0:0": True}})
        self.assertEqual(copied["interaction"]["workspaceName"], "Independent tool")
        self.assertEqual(copied["interaction"]["turn:42"]["artifactId"], "af-" + "b" * 16 + "-t42")
        self.assertEqual(copied["workspace"]["activeArtifactId"], copied["artifacts"][1]["id"])

    def test_duplicate_preserves_excess_turns_artifacts_and_workspaces(self):
        self.source_id, self.destination_id = "source", "ws-" + "b" * 16
        with contextlib.closing(store.open_store(self.root)) as conn:
            for index in range(25):
                store.cmd_save(conn, workspace_payload(f"old-{index}"))
                store.cmd_save(conn, workspace_payload(self.source_id,
                    artifacts=[artifact(f"artifact-{index}", blocks(index))],
                    interaction={f"turn:{index}": {"id": index, "artifactId": f"artifact-{index}"},
                        f"note:{index}": index}))
            conn.execute("UPDATE workspaces SET updated_at = '2000-01-01T00:00:00.000Z'")
        before = self.cli("load", {"workspaceId": self.source_id})[1]
        self.assertEqual(self.duplicate()[0], 0)
        copied = self.cli("load", {"workspaceId": self.destination_id})[1]
        self.assertEqual(len(copied["artifacts"]), 25)
        self.assertEqual(len(copied["interaction"]), 51)
        self.assertEqual(self.cli("load", {"workspaceId": self.source_id})[1], before)
        with contextlib.closing(self.db()) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 27)

    def test_worker_dispatches_reusable_commands_and_recovers_after_errors(self):
        self.reusable_fixture()
        read_fd, write_fd = os.pipe()
        out = io.BytesIO()
        requests = [
            {"op": "rename", "payload": {"workspaceId": self.source_id, "title": "  Renamed  "}},
            {"op": "duplicate", "payload": {"workspaceId": self.source_id,
                "newWorkspaceId": self.destination_id, "title": "  Copy  "}},
            {"op": "duplicate", "payload": {"workspaceId": self.source_id,
                "newWorkspaceId": self.destination_id, "title": "Collision"}},
            {"op": "rename", "payload": {"workspaceId": self.source_id, "title": "bad\nname"}},
            {"op": "load", "payload": {"workspaceId": self.destination_id}}]
        try:
            for request in requests:
                os.write(write_fd, json.dumps(request).encode() + b"\n")
            os.close(write_fd)
            self.assertEqual(store.serve(self.root, out, idle=1, fd=read_fd), 0)
        finally:
            os.close(read_fd)
        results = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual(results[0], {"ok": True, "workspaceId": self.source_id, "title": "Renamed"})
        self.assertEqual(results[1], {"ok": True, "workspaceId": self.destination_id, "title": "Copy"})
        self.assertFalse(results[2]["ok"])
        self.assertFalse(results[3]["ok"])
        self.assertEqual(results[4]["workspace"]["title"], "Copy")


SRC_A, SRC_B, SRC_C = "src-" + "a" * 16, "src-" + "b" * 16, "src-" + "c" * 16


class SourceRegistryTests(unittest.TestCase):
    """Ownership registry for copied CSV sources and its safe file cleanup."""

    def setUp(self):
        self.root = temp_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        isolate_environment(self)
        self.sources = Path(self.root) / "sources"

    def cli(self, command, payload):
        out, err = io.BytesIO(), io.BytesIO()
        code = store.main(["--root", self.root, command],
                          stdin=io.BytesIO(json.dumps(payload).encode("utf-8")),
                          stdout=out, stderr=err)
        data = out.getvalue()
        return code, (json.loads(data) if data else None), err.getvalue().decode("utf-8")

    def ok(self, command, payload):
        code, result, err = self.cli(command, payload)
        self.assertEqual(code, 0, (result, err))
        return result

    def db(self):
        return contextlib.closing(sqlite3.connect(str(Path(self.root) / "workspace.db")))

    def workspace(self, workspace_id="ws-1", **fields):
        self.ok("save", workspace_payload(workspace_id, artifacts=[artifact(f"art-{workspace_id}")], **fields))

    def make_source(self, source_id, extra=True):
        directory = self.sources / source_id
        directory.mkdir(parents=True, mode=0o700)
        for name in ("data.csv", "index.bin", "meta.json"):
            (directory / name).write_text("x")
        if extra:
            (directory / "nested").mkdir()
            (directory / "nested" / "part").write_text("y")
        return directory

    def link(self, workspace_id, source_id, size=10, rows=2):
        return self.ok("source_link", {"workspaceId": workspace_id, "sourceId": source_id,
                                       "bytes": size, "rows": rows})

    def make_old_database(self, workspaces=("ws-1", "ws-2")):
        """A v1 database as the previous plugin left it: no sources table."""
        store.open_store(self.root).close()
        for workspace_id in workspaces:
            self.workspace(workspace_id, title=f"T {workspace_id}")
        with self.db() as db:
            db.execute("DROP TABLE sources")
            db.execute("DELETE FROM meta WHERE key = 'sources_backup'")
            db.commit()
        backup = Path(self.root) / store.BACKUP_NAME
        if backup.exists():
            backup.unlink()
        return backup

    def tables(self):
        with self.db() as db:
            return {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}

    def test_table_is_added_to_an_old_database_without_a_schema_bump(self):
        backup = self.make_old_database()
        self.assertNotIn("sources", self.tables())
        self.assertEqual(self.ok("load", {"workspaceId": "ws-2"})["workspace"]["title"], "T ws-2")
        self.assertIn("sources", self.tables())
        with self.db() as db:
            self.assertEqual(db.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()[0], "1")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 2)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM artifacts").fetchone()[0], 2)
        self.assertEqual(store.SCHEMA_VERSION, 1)
        self.assertTrue(backup.is_file())
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        with contextlib.closing(sqlite3.connect(str(backup))) as old:
            self.assertEqual(old.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 2)
            self.assertNotIn("sources", {row[0] for row in old.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'")})
        self.assertFalse(Path(str(backup) + ".tmp").exists())

    def test_backup_is_taken_once_and_only_when_workspaces_exist(self):
        backup = self.make_old_database()
        self.ok("list", {})
        first = backup.read_bytes()
        self.workspace("ws-new", title="Later")
        self.ok("list", {})
        self.assertEqual(backup.read_bytes(), first, "later opens never rewrite the backup")
        backup.unlink()
        self.ok("list", {})
        self.assertFalse(backup.exists(), "the key and table guard stop a second backup")
        # An old database that holds no workspaces has nothing to protect.
        shutil.rmtree(self.root)
        os.mkdir(self.root, 0o700)
        empty_backup = self.make_old_database(workspaces=())
        self.ok("list", {})
        self.assertIn("sources", self.tables())
        self.assertFalse(empty_backup.exists())
        # A brand-new database never makes one either.
        fresh = Path(self.root) / "fresh"
        fresh.mkdir()
        store.open_store(str(fresh)).close()
        self.assertEqual(sorted(path.name for path in fresh.iterdir() if "pre-sources" in path.name), [])

    def test_older_code_style_delete_still_cascades_source_rows(self):
        self.workspace("ws-1")
        self.link("ws-1", SRC_A)
        with self.db() as db:
            db.execute("PRAGMA foreign_keys = ON")
            db.execute("DELETE FROM workspaces WHERE id = 'ws-1'")
            db.commit()
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sources").fetchone()[0], 0)

    def test_link_unlink_and_list(self):
        self.workspace("ws-1")
        self.workspace("ws-2")
        first = self.link("ws-1", SRC_A, size=100, rows=5)
        self.assertEqual(first, {"ok": True, "sourceId": SRC_A})
        self.link("ws-2", SRC_B, size=50, rows=3)
        before = self.ok("source_list", {})["sources"][0]["createdAt"]
        time.sleep(0.005)
        self.link("ws-1", SRC_A, size=120, rows=6)  # idempotent upsert
        listing = self.ok("source_list", {})
        self.assertEqual(listing["count"], 2)
        self.assertEqual(listing["totalBytes"], 170)
        self.assertFalse(listing["truncated"])
        self.assertEqual(listing["sources"][0], {"id": SRC_A, "workspaceId": "ws-1", "bytes": 120,
                                                 "rows": 6, "createdAt": before})
        mine = self.ok("source_list", {"workspaceId": "ws-2"})
        self.assertEqual([entry["id"] for entry in mine["sources"]], [SRC_B])
        self.assertEqual(mine["totalBytes"], 170, "the total always covers the whole registry")
        self.assertEqual(self.ok("source_list", {"workspaceId": "ghost"})["sources"], [])
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A}), {"ok": True, "unlinked": True})
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A}), {"ok": True, "unlinked": False})
        self.assertEqual(self.ok("source_list", {})["totalBytes"], 50)
        with self.db() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces").fetchone()[0], 2)

    def test_link_validation_is_static_and_stores_nothing(self):
        self.workspace("ws-1")
        self.workspace("ws-2")
        self.link("ws-2", SRC_C)
        good = {"workspaceId": "ws-1", "sourceId": SRC_A, "bytes": 1, "rows": 1}
        cases = [({"sourceId": bad}, "sourceId must look like") for bad in
                 ("src-" + "A" * 16, "src-" + "a" * 15, "src-" + "a" * 17, "../src-" + "a" * 16,
                  "src-" + "a" * 16 + "\n", "", None, 7)]
        cases += [({"bytes": bad}, "bytes must be") for bad in (-1, True, "1", 1.5, None, 1 << 41)]
        cases += [({"rows": bad}, "rows must be") for bad in (-1, False, "1", None)]
        cases += [({"workspaceId": "ghost"}, "Workspace does not exist"),
                  ({"workspaceId": ""}, "workspaceId must be"),
                  ({"sourceId": SRC_C}, "belongs to another workspace")]
        for change, message in cases:
            with self.subTest(change=change):
                code, result, _ = self.cli("source_link", {**good, **change})
                self.assertEqual(code, 3)
                self.assertFalse(result["ok"])
                self.assertIn(message, result["error"])
        self.assertEqual(self.ok("source_list", {})["count"], 1)
        for command, body in (("source_link", []), ("source_unlink", {"sourceId": "nope"}),
                              ("source_list", {"workspaceId": 3})):
            self.assertEqual(self.cli(command, body)[0], 3)

    def test_list_is_bounded_but_totals_are_not(self):
        self.workspace("ws-1")
        with self.db() as db:
            db.executemany("INSERT INTO sources VALUES (?, 'ws-1', 10, 1, ?)",
                           [(f"src-{index:016x}", f"2026-01-01T00:00:{index % 60:02d}.000Z")
                            for index in range(store.MAX_SOURCE_LIST + 5)])
            db.commit()
        listing = self.ok("source_list", {})
        self.assertEqual(len(listing["sources"]), store.MAX_SOURCE_LIST)
        self.assertTrue(listing["truncated"])
        self.assertEqual(listing["count"], store.MAX_SOURCE_LIST + 5)
        self.assertEqual(listing["totalBytes"], 10 * (store.MAX_SOURCE_LIST + 5))

    def test_worker_serves_source_operations(self):
        self.workspace("ws-1")
        read_fd, write_fd = os.pipe()
        out = io.BytesIO()
        try:
            for body in ({"op": "source_link", "payload": {"workspaceId": "ws-1", "sourceId": SRC_A,
                                                         "bytes": 7, "rows": 1}},
                         {"op": "source_list", "payload": {}},
                         {"op": "source_link", "payload": {"workspaceId": "ghost", "sourceId": SRC_B,
                                                         "bytes": 7, "rows": 1}},
                         {"op": "source_unlink", "payload": {"sourceId": SRC_A}}):
                os.write(write_fd, json.dumps(body).encode() + b"\n")
            os.close(write_fd)
            self.assertEqual(store.serve(self.root, out, idle=1, fd=read_fd), 0)
        finally:
            os.close(read_fd)
        lines = [json.loads(line) for line in out.getvalue().split(b"\n") if line]
        self.assertEqual(lines[0], {"ok": True, "sourceId": SRC_A})
        self.assertEqual(lines[1]["totalBytes"], 7)
        self.assertEqual(lines[2], {"ok": False, "error": "Workspace does not exist"})
        self.assertEqual(lines[3], {"ok": True, "unlinked": True})

    def test_delete_removes_source_directories_after_the_commit(self):
        self.workspace("ws-1")
        self.workspace("ws-2")
        mine, other = self.make_source(SRC_A), self.make_source(SRC_B)
        self.link("ws-1", SRC_A)
        self.link("ws-2", SRC_B)
        result = self.ok("delete", {"workspaceId": "ws-1"})
        self.assertEqual(result, {"ok": True, "deleted": True, "sourcesRemoved": 1})
        self.assertFalse(mine.exists())
        self.assertTrue(other.is_dir())
        self.assertEqual([entry["id"] for entry in self.ok("source_list", {})["sources"]], [SRC_B])

    def test_unlinked_or_unknown_workspace_delete_removes_no_directories(self):
        self.workspace("ws-1")
        orphan = self.make_source(SRC_A)
        self.assertEqual(self.ok("delete", {"workspaceId": "ws-1"}), {"ok": True, "deleted": True})
        self.assertEqual(self.ok("delete", {"workspaceId": "ghost"}), {"ok": True, "deleted": False})
        self.assertTrue(orphan.is_dir())

    def test_delete_with_a_missing_sources_directory_is_a_no_op(self):
        self.workspace("ws-1")
        self.link("ws-1", SRC_A)
        self.assertFalse(self.sources.exists())
        self.assertEqual(self.ok("delete", {"workspaceId": "ws-1"}),
                         {"ok": True, "deleted": True, "sourcesRemoved": 0})

    def test_failed_directory_removal_never_undoes_the_database_delete(self):
        self.workspace("ws-1")
        self.workspace("ws-2")
        stuck = self.make_source(SRC_A)
        fine = self.make_source(SRC_B)
        self.link("ws-1", SRC_A)
        self.link("ws-1", SRC_B)
        self.link("ws-2", SRC_C)
        stuck.chmod(0o500)  # entries cannot be unlinked
        self.addCleanup(stuck.chmod, 0o700)
        result = self.ok("delete", {"workspaceId": "ws-1"})
        self.assertEqual(result, {"ok": True, "deleted": True, "sourcesRemoved": 1})
        self.assertTrue(stuck.is_dir(), "a failed removal leaves an orphan directory")
        self.assertFalse(fine.exists(), "one failure does not stop the others")
        with self.db() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspaces WHERE id = 'ws-1'").fetchone()[0], 0)
            self.assertEqual([row[0] for row in db.execute("SELECT id FROM sources")], [SRC_C])

    def test_removal_never_follows_links_inside_or_around_a_source(self):
        self.workspace("ws-1")
        outside = Path(self.root) / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        inside = self.make_source(SRC_A, extra=False)
        (inside / "link").symlink_to(outside)
        self.link("ws-1", SRC_A)
        self.link("ws-1", SRC_B)
        (self.sources / SRC_B).symlink_to(outside)
        result = self.ok("delete", {"workspaceId": "ws-1"})
        self.assertEqual(result["sourcesRemoved"], 0)
        self.assertEqual((outside / "keep.txt").read_text(), "keep")
        self.assertTrue((self.sources / SRC_B).is_symlink())
        self.assertTrue((inside / "link").is_symlink(), "a link stops the walk; nothing is followed")

    def test_symlinked_sources_directory_is_refused(self):
        self.workspace("ws-1")
        decoy = Path(self.root) / "decoy"
        (decoy / SRC_A).mkdir(parents=True)
        (decoy / SRC_A / "data.csv").write_text("decoy")
        (decoy / ".tmp-old").mkdir()
        os.utime(decoy / ".tmp-old", (1, 1))
        self.sources.symlink_to(decoy)
        self.link("ws-1", SRC_A)
        self.assertEqual(self.ok("delete", {"workspaceId": "ws-1"})["sourcesRemoved"], 0)
        self.ok("prune", {"preserveWorkspaces": True})
        self.assertEqual((decoy / SRC_A / "data.csv").read_text(), "decoy")
        self.assertTrue((decoy / ".tmp-old").is_dir())
        self.assertTrue(self.sources.is_symlink())

    def test_explicit_prune_removes_directories_of_pruned_workspaces_only(self):
        self.workspace("ws-old")
        self.workspace("ws-pinned", pinned=True)
        self.workspace("ws-new")
        for workspace_id, source_id in (("ws-old", SRC_A), ("ws-pinned", SRC_B), ("ws-new", SRC_C)):
            self.make_source(source_id)
            self.link(workspace_id, source_id)
        stale = store._iso(time.time() - 40 * 86400)
        with self.db() as db:
            db.execute("UPDATE workspaces SET updated_at = ? WHERE id IN ('ws-old', 'ws-pinned')", (stale,))
            db.commit()
        result = self.ok("prune", {})
        self.assertEqual(result, {"ok": True, "prunedWorkspaces": 1, "prunedArtifacts": 0,
                                  "sourcesRemoved": 1})
        self.assertFalse((self.sources / SRC_A).exists())
        self.assertTrue((self.sources / SRC_B).is_dir())
        self.assertTrue((self.sources / SRC_C).is_dir())

    def test_automatic_maintenance_never_removes_source_directories(self):
        self.workspace("ws-1")
        self.link("ws-1", SRC_A)
        linked, orphan = self.make_source(SRC_A), self.make_source(SRC_B)
        with self.db() as db:
            db.execute("UPDATE workspaces SET updated_at = ?", (store._iso(time.time() - 90 * 86400),))
            db.commit()
        old_tmp, fresh_tmp = self.sources / ".tmp-old", self.sources / ".tmp-fresh"
        for directory in (old_tmp, fresh_tmp):
            directory.mkdir()
            (directory / "part").write_text("x")
        os.utime(old_tmp / "part", (1, 1))
        os.utime(old_tmp, (1, 1))
        busy_tmp = self.sources / ".tmp-busy"
        busy_tmp.mkdir()
        (busy_tmp / "part").write_text("x")
        os.utime(busy_tmp, (1, 1))
        lookalike = self.sources / ".tmp-"
        lookalike.mkdir()
        os.utime(lookalike, (1, 1))
        result = self.ok("prune", {"preserveWorkspaces": True})
        self.assertEqual(result, {"ok": True, "prunedWorkspaces": 0, "prunedArtifacts": 0,
                                  "staleTempRemoved": 1})
        self.assertTrue(linked.is_dir())
        self.assertTrue(orphan.is_dir(), "a complete src-* directory with no row is never reaped here")
        self.assertFalse(old_tmp.exists())
        self.assertTrue(fresh_tmp.is_dir())
        self.assertTrue(busy_tmp.is_dir(), "a directory with a fresh file inside is still in use")
        self.assertTrue(lookalike.is_dir())
        self.assertEqual(self.ok("source_list", {})["count"], 1)

    def test_orphan_directories_survive_explicit_prune_too(self):
        self.workspace("ws-1")
        orphan = self.make_source(SRC_A)
        self.assertEqual(self.ok("prune", {}), {"ok": True, "prunedWorkspaces": 0, "prunedArtifacts": 0})
        self.assertTrue(orphan.is_dir())

    def test_authoritative_save_leaves_sources_alone(self):
        self.workspace("ws-1", interaction={"note": 1})
        self.link("ws-1", SRC_A)
        directory = self.make_source(SRC_A)
        self.ok("save", {**workspace_payload("ws-1", interaction={"keep": 2}), "authoritativeContent": True})
        self.assertTrue(directory.is_dir())
        self.assertEqual(self.ok("source_list", {})["count"], 1)

    def test_unlink_defaults_to_the_row_only(self):
        self.workspace("ws-1")
        self.link("ws-1", SRC_A)
        directory = self.make_source(SRC_A)
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A}), {"ok": True, "unlinked": True})
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A, "removeDir": False}),
                         {"ok": True, "unlinked": False})
        self.assertTrue(directory.is_dir(), "without removeDir the copy is never touched")

    def test_unlink_with_remove_dir_removes_only_that_copy_after_the_commit(self):
        self.workspace("ws-1")
        gone, kept = self.make_source(SRC_A), self.make_source(SRC_B)
        self.link("ws-1", SRC_A, size=30)
        self.link("ws-1", SRC_B, size=20)
        result = self.ok("source_unlink", {"sourceId": SRC_A, "removeDir": True})
        self.assertEqual(result, {"ok": True, "unlinked": True, "sourcesRemoved": 1})
        self.assertFalse(gone.exists())
        self.assertTrue(kept.is_dir())
        self.assertEqual([entry["id"] for entry in self.ok("source_list", {})["sources"]], [SRC_B])
        # A repeat (row already gone, directory already gone) is harmless.
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A, "removeDir": True}),
                         {"ok": True, "unlinked": False, "sourcesRemoved": 0})
        # An unlinked-but-present copy (link failed earlier) is still removable.
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_B, "removeDir": True})["sourcesRemoved"], 1)
        self.assertEqual(self.ok("source_list", {})["count"], 0)

    def test_unlink_remove_dir_is_best_effort_and_never_follows_links(self):
        self.workspace("ws-1")
        stuck, linked = self.make_source(SRC_A), self.make_source(SRC_B, extra=False)
        outside = Path(self.root) / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        (linked / "link").symlink_to(outside)
        self.link("ws-1", SRC_A)
        self.link("ws-1", SRC_B)
        stuck.chmod(0o500)
        self.addCleanup(stuck.chmod, 0o700)
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_A, "removeDir": True}),
                         {"ok": True, "unlinked": True, "sourcesRemoved": 0})
        self.assertTrue(stuck.is_dir(), "a failed removal leaves an orphan; the row is already gone")
        self.assertEqual(self.ok("source_unlink", {"sourceId": SRC_B, "removeDir": True})["sourcesRemoved"], 0)
        self.assertEqual((outside / "keep.txt").read_text(), "keep")
        self.assertTrue((linked / "link").is_symlink())

    def test_unlink_remove_dir_refuses_a_symlinked_sources_directory(self):
        self.workspace("ws-1")
        decoy = Path(self.root) / "decoy"
        (decoy / SRC_A).mkdir(parents=True)
        (decoy / SRC_A / "data.csv").write_text("decoy")
        self.sources.symlink_to(decoy)
        self.link("ws-1", SRC_A)
        result = self.ok("source_unlink", {"sourceId": SRC_A, "removeDir": True})
        self.assertEqual(result, {"ok": True, "unlinked": True, "sourcesRemoved": 0})
        self.assertEqual((decoy / SRC_A / "data.csv").read_text(), "decoy")

    def test_unlink_remove_dir_validation_is_static(self):
        self.workspace("ws-1")
        self.link("ws-1", SRC_A)
        directory = self.make_source(SRC_A)
        for bad in ("true", 1, None, [], {}):
            with self.subTest(removeDir=bad):
                code, result, _ = self.cli("source_unlink", {"sourceId": SRC_A, "removeDir": bad})
                self.assertEqual(code, 3)
                self.assertEqual(result, {"ok": False, "error": "removeDir must be a boolean"})
        self.assertTrue(directory.is_dir())
        self.assertEqual(self.ok("source_list", {})["count"], 1, "a rejected request changes nothing")


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
