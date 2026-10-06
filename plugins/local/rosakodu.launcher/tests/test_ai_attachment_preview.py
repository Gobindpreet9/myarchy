"""Offline preview contract: python -B -m unittest discover -s tests -p test_ai_attachment_preview.py."""
import contextlib
import csv
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN))
import ai_broker as broker
import ai_attachment_preview as worker


class AttachmentPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-preview-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()

    def file(self, content, name="sample.csv"):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return path

    def request(self, path, token=17):
        return {"token": token, "path": str(path)}

    def transport(self, payload):
        source, out = io.BytesIO(payload), io.BytesIO()
        code = worker.main(stdin=source, stdout=out, home=self.home)
        data = out.getvalue()
        self.assertEqual(len(data.splitlines()), 1)
        self.assertTrue(data.endswith(b"\n"))
        self.assertLessEqual(len(data), worker.MAX_RESPONSE_BYTES)
        result = json.loads(data)
        self.assertEqual(code, 0 if result["ok"] else 1)
        return result, data, source

    def compare(self, path, token=17):
        snapshot = broker.attachment_snapshot(str(path), home=self.home)
        response = worker.run(self.request(path, token), home=self.home)
        self.assertEqual(set(response), {"token", "ok", "preview"})
        self.assertTrue(response["ok"])
        self.assertEqual(response["token"], token)
        expected = dict(snapshot, rows=snapshot["rows"][:10], previewRows=min(10, len(snapshot["rows"])))
        self.assertEqual(response["preview"], expected)
        return response["preview"]

    def test_differential_small_bom_multiline_and_literal_strings(self):
        path = self.file('\ufeffcity,value,note\r\n"two\nlines",001,"  spaced  "\r\n'
                         'é,1e3,"$(touch /tmp/no); __import__(\'os\')"\r\n', "small.CsV")
        preview = self.compare(path)
        self.assertEqual(preview["rows"], [["two\nlines", "001", "  spaced  "],
                                          ["é", "1e3", "$(touch /tmp/no); __import__('os')"]])
        self.assertEqual(preview["sampleRows"], 2)
        self.assertEqual(preview["previewRows"], 2)
        self.assertEqual(preview["totalRows"], 2)
        self.assertFalse(preview["truncated"])
        self.assertTrue(all(isinstance(cell, str) for row in preview["rows"] for cell in row))

    def test_display_rows_do_not_redefine_sampling_or_truncation(self):
        path = self.file("x,y\n" + "".join(f"{i},{i * 2}\n" for i in range(35)))
        preview = self.compare(path)
        self.assertEqual(preview["rows"], [[str(i), str(i * 2)] for i in range(10)])
        self.assertEqual(preview["sampleRows"], 35)
        self.assertEqual(preview["previewRows"], 10)
        self.assertEqual(preview["totalRows"], 35)
        self.assertFalse(preview["truncated"], "display clipping is not sampler clipping")
        self.assertIn("first 35 of 35", preview["note"])

    def test_sampler_row_cap_and_exact_totals_preserved(self):
        path = self.file("n\n" + "".join(f"{i}\n" for i in range(300)))
        preview = self.compare(path)
        self.assertEqual(preview["sampleRows"], broker.CSV_SAMPLE_ROWS)
        self.assertEqual(preview["previewRows"], 10)
        self.assertEqual(preview["totalRows"], 300)
        self.assertTrue(preview["truncated"])

    def test_header_only_is_valid_and_empty_cells_are_strings(self):
        preview = self.compare(self.file("a,b\n"))
        self.assertEqual(preview["rows"], [])
        self.assertEqual(preview["sampleRows"], 0)
        self.assertEqual(preview["totalRows"], 0)
        self.assertEqual(self.compare(self.file("a,b\n,\n\n"))["rows"], [["", ""]])

    def test_column_and_cell_clipping_provenance_preserved(self):
        output = io.StringIO(newline="")
        writer = csv.writer(output)
        writer.writerow(["header" * 20] + [f"c{i}" for i in range(20)])
        writer.writerow(["é" * 100, "  spaced  "] + [str(i) for i in range(19)])
        preview = self.compare(self.file(output.getvalue()))
        self.assertEqual(preview["columnCount"], 21)
        self.assertEqual(len(preview["columns"]), 20)
        self.assertEqual(preview["columns"][0], ("header" * 20)[:80])
        self.assertEqual(preview["rows"][0][0], "é" * 80)
        self.assertEqual(preview["rows"][0][1], "  spaced  ")
        self.assertTrue(preview["columnsTruncated"])
        self.assertTrue(preview["cellsTruncated"])
        self.assertTrue(preview["truncated"])
        self.assertIn("shortened", preview["note"])
        self.assertIn("first 20 of 21 columns", preview["note"])
        # The QML validator bounds the note at 300; producer and validator
        # bounds must stay the same bound so disclosures cannot outgrow the
        # peek-card budget.
        self.assertLessEqual(len(preview["note"]), 300)

    def test_clipping_beyond_display_prefix_is_still_disclosed(self):
        path = self.file("a\n" + "ok\n" * 10 + "z" * 100 + "\n")
        preview = self.compare(path)
        self.assertEqual(preview["rows"], [["ok"]] * 10)
        self.assertTrue(preview["cellsTruncated"])
        self.assertEqual(preview["sampleRows"], 11)

    def test_read_window_unknown_totals_and_incomplete_records(self):
        prefix = b"a,b\nfirst,1\n"
        for tail in (b'partial,99', b'"quoted\nunfinished,99', "é,99".encode("utf-8")):
            with self.subTest(tail=tail):
                path = self.file(prefix + tail + b"\nlast,2\n")
                limit = len(prefix) + (1 if tail.startswith(b"\xc3") else 8)
                with patch.object(broker, "CSV_READ_LIMIT", limit):
                    preview = self.compare(path)
                self.assertEqual(preview["rows"], [["first", "1"]])
                self.assertEqual(preview["sampleRows"], 1)
                self.assertIsNone(preview["totalRows"])
                self.assertTrue(preview["truncated"])
                self.assertIn("continues beyond the read window", preview["note"])
                self.assertLessEqual(len(preview["note"]), 300)

    def test_note_bound_holds_when_every_disclosure_combines(self):
        # Worst producer composition: read-window truncation + column clipping
        # + cell clipping together. The QML validator rejects notes above 300,
        # so the producer's own worst case must stay inside that same bound.
        header = ",".join(f"col{i}" for i in range(25))
        row = ",".join(["v" * 100] * 25)
        path = self.file(header + "\n" + row + "\n" + row + "\n")
        # Window: complete header, complete first record, partial second one.
        limit = len(header) + 1 + len(row) + 1 + 20
        with patch.object(broker, "CSV_READ_LIMIT", limit):
            preview = self.compare(path)
        self.assertTrue(preview["columnsTruncated"])
        self.assertTrue(preview["cellsTruncated"])
        self.assertTrue(preview["truncated"])
        self.assertIsNone(preview["totalRows"])
        self.assertIn("continues beyond the read window", preview["note"])
        self.assertLessEqual(len(preview["note"]), 300)

    def test_read_window_header_error_preserved(self):
        path = self.file("longheader,second\n1,2\n")
        with patch.object(broker, "CSV_READ_LIMIT", 5):
            result = worker.run(self.request(path), home=self.home)
        self.assertEqual(result, {"token": 17, "ok": False, "error": "CSV header exceeds the read window."})

    def test_utf8_and_json_escaping_count_serialized_bytes(self):
        for cell in ("é" * 80, "😀" * 80, '"\\\t\n' * 20):
            with self.subTest(cell=cell[:1]):
                output = io.StringIO(newline="")
                writer = csv.writer(output)
                writer.writerow(["text", "index"])
                writer.writerows([[cell, str(i)] for i in range(200)])
                path = self.file(output.getvalue())
                expected = self.compare(path, worker.MAX_TOKEN)
                result, data, _ = self.transport(json.dumps(self.request(path, worker.MAX_TOKEN)).encode() + b"\n")
                self.assertEqual(result["preview"], expected)
                self.assertEqual(result["token"], worker.MAX_TOKEN)
                self.assertEqual(result["preview"]["rows"], [[cell, str(i)] for i in range(10)])
                self.assertLessEqual(len(data), 32 * 1024)
                if cell.startswith("😀"):
                    self.assertIn("😀".encode(), data)
                    self.assertNotIn(b"\\ud83d", data)

    def test_empty_malformed_ragged_binary_and_oversized_fields(self):
        fixtures = (b"", b"\xef\xbb\xbf", b"\n", b"  ,\t\n", b"a,b\n\xff,1\n",
                    b"a,b\nx\0,1\n", b"a,b\nx\x01,1\n", b'a,b\n"unterminated,1',
                    b'a,b\n"x"oops,1\n', b"a,b\nx,1,2\n", b"a,b\nx\n",
                    b'"unterminated', b"a,b\n" + b"z" * (csv.field_size_limit() + 1) + b",1\n",
                    b"a,b\n" + b"ok,1\n" * 205 + b"bad\n")
        for content in fixtures:
            with self.subTest(content=content[:24]):
                path = self.file(content, "untrusted-file-name.csv")
                with self.assertRaises(ValueError) as caught:
                    broker.attachment_snapshot(str(path), home=self.home)
                result = worker.run(self.request(path), home=self.home)
                self.assertFalse(result["ok"])
                self.assertEqual(result["token"], 17)
                self.assertEqual(result["error"], str(caught.exception))
                self.assertNotIn(path.name, result["error"])
                self.assertLessEqual(len(result["error"]), 256)
                self.assertNotIn("preview", result)

    def test_secret_paths_reuse_shared_guard_without_opening(self):
        names = (".ssh/data.csv", ".gnupg/data.csv", ".codex/data.csv", ".hermes/data.csv",
                 ".aws/data.csv", ".azure/data.csv", ".kube/data.csv", "auth/data.csv",
                 "cookies/data.csv", "credentials/data.csv", "secrets/data.csv",
                 "keyrings/data.csv", ".env.csv", ".env.local/data.csv", "auth.csv",
                 "cookie.csv", "passwords.csv", "access-token.csv", "file.pem/data.csv",
                 "file.key/data.csv")
        for name in names:
            with self.subTest(name=name), patch.object(broker.os, "open") as opened:
                result = worker.run(self.request(self.home / name), home=self.home)
                self.assertEqual(result["error"], "Credential and secret files cannot be attached.")
                opened.assert_not_called()

    def test_home_containment_traversal_and_missing_files(self):
        outside = self.root / "outside.csv"
        outside.write_text("a\n1\n", encoding="utf-8")
        for name in (outside, self.home / "../outside.csv", self.home, self.home / "missing.csv"):
            with self.subTest(name=name):
                result = worker.run(self.request(name), home=self.home)
                self.assertFalse(result["ok"])
                self.assertNotIn(str(name), result["error"])
        self.file("a\n1\n", "nested/data.csv")
        self.assertTrue(worker.run(self.request("nested/data.csv"), home=self.home)["ok"])
        with patch.object(Path, "home", return_value=self.home):
            self.assertTrue(worker.run(self.request("nested/data.csv"))["ok"])

    def test_symlinks_directories_and_fifo_fail_without_blocking(self):
        good = self.file("a\n1\n")
        link = self.home / "link.csv"
        link.symlink_to(good)
        directory = self.home / "dir-link"
        directory.symlink_to(self.home, target_is_directory=True)
        regular_directory = self.home / "directory.csv"
        regular_directory.mkdir()
        fifo = self.home / "pipe.csv"
        os.mkfifo(fifo)
        for path in (link, directory / good.name, regular_directory, fifo):
            with self.subTest(path=path):
                result = worker.run(self.request(path), home=self.home)
                self.assertFalse(result["ok"])
                self.assertNotIn(path.name, result["error"])
        with patch.object(broker.os, "open", wraps=broker.os.open) as opened:
            worker.run(self.request(fifo), home=self.home)
        self.assertTrue(opened.call_args_list[-1].args[1] & os.O_NONBLOCK)
        self.assertTrue(opened.call_args_list[-1].args[1] & os.O_NOFOLLOW)

    def test_unknown_extensions_and_invalid_paths_never_read(self):
        for path in ("", None, 1, [], {}, "data.txt", "data.tsv", "data.csv.exe", "data",
                     "a" * 4097 + ".csv", "  "):
            with self.subTest(path=str(path)[:30]), patch.object(worker, "attachment_snapshot") as snapshot:
                result = worker.run({"token": 2, "path": path}, home=self.home)
                self.assertFalse(result["ok"])
                self.assertEqual(result["token"], 2)
                snapshot.assert_not_called()
        for path in ("invalid\0.csv", "invalid\ud800.csv"):
            result = worker.run(self.request(path), home=self.home)
            self.assertEqual(result["error"], "CSV preview is unavailable.")

    def test_nonobjects_missing_fields_and_safe_integer_tokens(self):
        for request in (None, [], "string", 2, True, {}, {"path": "data.csv"}):
            with self.subTest(request=request), patch.object(worker, "attachment_snapshot") as snapshot:
                result = worker.run(request, home=self.home)
                self.assertFalse(result["ok"])
                self.assertIsNone(result["token"])
                snapshot.assert_not_called()
        for token in (-1, worker.MAX_TOKEN + 1, 1.0, True, False, None, "1", [], {}):
            with self.subTest(token=token), patch.object(worker, "attachment_snapshot") as snapshot:
                self.assertIsNone(worker.run({"token": token, "path": "data.csv"}, home=self.home)["token"])
                snapshot.assert_not_called()
        self.assertFalse(worker.run({"token": 0}, home=self.home)["ok"])
        self.assertEqual(worker.run({"token": 0}, home=self.home)["token"], 0)
        path = self.file("a\n1\n")
        for token in (0, 1, worker.MAX_TOKEN, 5, 3):
            self.assertEqual(worker.run(self.request(path, token), home=self.home)["token"], token)

    def test_protocol_rejects_missing_invalid_utf8_and_malformed_json(self):
        for payload in (b"", b"\n", b" \t\r\n", b"\xff\n", b"{\n", b'{"token": 0,}\n',
                        b'{"token":NaN,"path":"a.csv"}\n', b'{"token":Infinity}\n',
                        b'{"token":1,"token":2,"path":"a.csv"}\n', b"[" * 1500 + b"]" * 1500,
                        b'"__import__(\'os\')"\n', b"{} {}\n"):
            with self.subTest(payload=payload[:40]), patch.object(worker, "attachment_snapshot") as snapshot:
                result, _, _ = self.transport(payload)
                self.assertFalse(result["ok"])
                self.assertIsNone(result["token"])
                snapshot.assert_not_called()

    def test_request_byte_boundary_and_one_line_only(self):
        path = self.file("a\n1\n")
        base = json.dumps(self.request(path, 29)).encode()
        exact = base + b" " * (worker.MAX_REQUEST_BYTES - len(base) - 1) + b"\n"
        result, _, _ = self.transport(exact)
        self.assertTrue(result["ok"])
        with patch.object(worker, "attachment_snapshot") as snapshot:
            result, _, source = self.transport(base + b" " * worker.MAX_REQUEST_BYTES + b"\n")
            self.assertEqual(result["error"], "Preview request is too large.")
            self.assertEqual(source.tell(), worker.MAX_REQUEST_BYTES + 1)
            snapshot.assert_not_called()
        result, _, _ = self.transport(base)
        self.assertTrue(result["ok"], "EOF without a trailing newline is accepted")
        result, _, source = self.transport(base + b"\n" + b'{"token":30,"path":"missing.csv"}\n')
        self.assertEqual(result["token"], 29)
        self.assertEqual(source.read(), b'{"token":30,"path":"missing.csv"}\n')
        multibyte = json.dumps(dict(self.request(path), ignored="é" * 4100), ensure_ascii=False).encode()
        self.assertGreater(len(multibyte), worker.MAX_REQUEST_BYTES)
        self.assertEqual(self.transport(multibyte)[0]["error"], "Preview request is too large.")

    def test_response_cap_is_enforced_even_if_sampler_contract_changes(self):
        snapshot = {"kind": "csv", "rows": [["😀" * 9000]], "note": "fixture"}
        with patch.object(worker, "attachment_snapshot", return_value=snapshot):
            result, _, _ = self.transport(b'{"token":31,"path":"sample.csv"}\n')
        self.assertEqual(result, {"token": 31, "ok": False, "error": "CSV preview response is too large."})

    def test_untrusted_exceptions_and_non_csv_results_are_not_exposed(self):
        for exception in (ValueError("/untrusted/path $(code)"), ValueError("x" * 40000),
                          ValueError("CSV line evil has code columns; the header has filename."),
                          OSError("/untrusted/file"), RuntimeError("execute this")):
            with self.subTest(exception=type(exception)), patch.object(worker, "attachment_snapshot", side_effect=exception):
                result = worker.run({"token": 33, "path": "sample.csv"}, home=self.home)
                self.assertEqual(result, {"token": 33, "ok": False, "error": "CSV preview is unavailable."})
        with patch.object(worker, "attachment_snapshot", return_value="not csv"):
            self.assertFalse(worker.run({"token": 33, "path": "sample.csv"}, home=self.home)["ok"])

    def test_import_and_run_never_invoke_provider_network_or_extra_readers(self):
        path = self.file("a\n$(do-not-execute)\n")
        with contextlib.ExitStack() as stack:
            guards = []
            for target in ("subprocess.Popen", "subprocess.run", "os.system", "socket.create_connection",
                           "urllib.request.urlopen", "asyncio.create_subprocess_exec", "ai_broker.main",
                           "ai_broker.Broker", "ai_broker.prepare_codex", "ai_broker.discover_codex",
                           "ai_broker.hermes_command", "ai_broker.enrich_answer", "ai_broker.supervise",
                           "pathlib.Path.read_text", "pathlib.Path.read_bytes", "builtins.open"):
                guards.append(stack.enter_context(patch(target, side_effect=AssertionError(target))))
            spec = importlib.util.spec_from_file_location("preview_import_check", PLUGIN / "ai_attachment_preview.py")
            imported = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(imported)
            with patch.object(imported, "attachment_snapshot", wraps=broker.attachment_snapshot) as snapshot:
                result = imported.run(self.request(path), home=self.home)
            self.assertTrue(result["ok"])
            snapshot.assert_called_once_with(str(path), home=self.home)
            for guard in guards:
                guard.assert_not_called()

    def test_actual_cli_is_one_shot_and_isolated_without_credentials(self):
        path = self.file("\ufeffcity,value\nOslo,001\né, 02 \n")
        env = {"HOME": str(self.home), "XDG_STATE_HOME": str(self.root / "state"),
               "XDG_CONFIG_HOME": str(self.root / "config"), "XDG_CACHE_HOME": str(self.root / "cache"),
               "PATH": str(self.root / "empty-path"), "PYTHONDONTWRITEBYTECODE": "1"}
        before = sorted(p.relative_to(self.root) for p in self.root.rglob("*"))
        for token, name, ok in ((worker.MAX_TOKEN, "~/sample.csv", True), (7, path, True),
                                (3, path, True), (4, self.home / "pipe.csv", False)):
            if str(name).endswith("pipe.csv"):
                os.mkfifo(name)
                before = sorted(p.relative_to(self.root) for p in self.root.rglob("*"))
            result = subprocess.run([sys.executable, "-B", str(PLUGIN / "ai_attachment_preview.py")],
                                    input=json.dumps(self.request(name, token)).encode() + b"\n" + b"ignored\n",
                                    capture_output=True, timeout=5, env=env, cwd=self.home)
            self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
            self.assertEqual(result.stderr, b"")
            self.assertEqual(len(result.stdout.splitlines()), 1)
            response = json.loads(result.stdout)
            self.assertEqual(response["token"], token)
            self.assertEqual(response["ok"], ok)
            self.assertLessEqual(len(result.stdout), worker.MAX_RESPONSE_BYTES)
            if ok:
                self.assertEqual(response["preview"], self.compare(path, token))
            self.assertEqual(sorted(p.relative_to(self.root) for p in self.root.rglob("*")), before)
        for payload in (b"", b"\xff\n", b"{\n", b"[]\n", b'{"token":true,"path":"sample.csv"}\n',
                        b" " * (worker.MAX_REQUEST_BYTES + 1) + b"\n"):
            with self.subTest(payload=payload[:30]):
                result = subprocess.run([sys.executable, "-B", str(PLUGIN / "ai_attachment_preview.py")],
                                        input=payload, capture_output=True, timeout=5, env=env, cwd=self.home)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(len(result.stdout.splitlines()), 1)
                response = json.loads(result.stdout)
                self.assertEqual(set(response), {"token", "ok", "error"})
                self.assertIsNone(response["token"])
                self.assertFalse(response["ok"])
                self.assertLessEqual(len(result.stdout), worker.MAX_RESPONSE_BYTES)
                self.assertEqual(sorted(p.relative_to(self.root) for p in self.root.rglob("*")), before)


if __name__ == "__main__":
    unittest.main()
