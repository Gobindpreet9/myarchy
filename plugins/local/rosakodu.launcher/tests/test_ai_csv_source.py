"""Durable CSV source worker: python -B -m unittest discover -s tests -p test_ai_csv_source.py.

In-process tests drive the handlers; the transport, idle/EOF exits, supersede
and zero-write tests drive the real `--serve` subprocess.
"""
import csv
import io
import json
import math
import os
from pathlib import Path
import random
import re
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
sys.path[:0] = [str(PLUGIN), str(HERE)]
import ai_csv_source as src
import csv_fixture as fixture

TMP_BASE = "/tmp/opencode"
MODULE = PLUGIN / "ai_csv_source.py"
SID = "src-0123456789abcdef"


def brute(data, header=True):
    """Independent reference parse: universal-newline csv over the decoded text."""
    text = data.decode("utf-8").removeprefix("\ufeff")
    rows = list(csv.reader(io.StringIO(text, newline=""), strict=True))
    return rows[0], [row for row in rows[1:] if row]


def to_bytes(rows, newline="\n"):
    out = io.StringIO(newline="")
    csv.writer(out, lineterminator=newline).writerows(rows)
    return out.getvalue().encode("utf-8")


class Base(unittest.TestCase):
    def setUp(self):
        os.makedirs(TMP_BASE, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="csv-source-", dir=TMP_BASE)).resolve()
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.home, self.state = self.temp / "home", self.temp / "state"
        self.home.mkdir()
        self.state.mkdir(0o700)
        self.worker = src.Worker(self.state, self.home)
        self.addCleanup(lambda: [self.worker._drop(sid) for sid in list(self.worker.sources)])

    def file(self, name, content):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode("utf-8"))
        return path

    def register(self, name="data.csv", content=None, **patches):
        if content is not None:
            self.file(name, content)
        return src.register(self.state, name, self.home)

    def broker_message(self, data):
        """The sampler's own readable error for the same bytes: the messages must match."""
        import ai_broker
        with self.assertRaises(ValueError) as caught:
            ai_broker._csv_snapshot(data.decode("utf-8"))
        return str(caught.exception)

    def refused(self, name="data.csv", content=None):
        before = self.leftovers()
        with self.assertRaises(src.Refuse) as caught:
            self.register(name, content)
        self.assertEqual(self.leftovers(), before)
        return str(caught.exception)

    def leftovers(self):
        sources = self.state / "sources"
        return sorted(os.listdir(sources)) if sources.is_dir() else []

    def source(self, meta):
        source = src.open_source(self.state, meta["sourceId"])
        self.addCleanup(source.stream.close)
        return source

    def call(self, op, **fields):
        return self.worker.handle({"op": op, **fields}, lambda event: None)

    def tree(self):
        seen = {}
        for base, dirs, files in os.walk(self.state):
            for name in dirs + files:
                info = os.lstat(os.path.join(base, name))
                seen[os.path.join(base, name)] = (info.st_mode, info.st_size, info.st_mtime_ns)
        info = os.lstat(self.state)
        seen[str(self.state)] = (info.st_mode, info.st_size, info.st_mtime_ns)
        return seen


class Session:
    """The real `--serve` subprocess with the clean environment the launcher gives it."""

    def __init__(self, test, idle=None, home=None):
        env = {"HOME": str(home or test.home), "PATH": os.environ["PATH"], "LC_CTYPE": "C.UTF-8",
               "PYTHONDONTWRITEBYTECODE": "1"}
        if idle is not None:
            env["LAUNCHER_CSV_IDLE"] = str(idle)
        self.proc = subprocess.Popen([sys.executable, str(MODULE), "--root", str(test.state), "--serve"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        test.addCleanup(self.close)
        self.count = 0

    def send(self, *requests):
        self.proc.stdin.write(b"".join(json.dumps(r).encode("utf-8") + b"\n" for r in requests))
        self.proc.stdin.flush()

    def recv(self, timeout=30):
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        assert ready, "worker did not answer"
        return json.loads(self.proc.stdout.readline())

    def rpc(self, op, **fields):
        self.count += 1
        self.send({"id": self.count, "op": op, **fields})
        while True:
            reply = self.recv()
            if "event" not in reply:
                assert reply["id"] == self.count
                return reply

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        for stream in (self.proc.stdout, self.proc.stderr):
            stream.close()


class RoundTripTests(Base):
    def test_multiline_quoted_bom_unicode_blank_lines_round_trip(self):
        rows = [["id", "name", "note"]]
        for i in range(150):
            rows.append([str(i), "café 日本 \U0001f600 %d" % i,
                         'multi\nline "q", %d\r\nend' % i if i % 7 == 0 else ("" if i % 5 == 0 else "x,y")])
        data = b"\xef\xbb\xbf" + to_bytes(rows, "\r\n").replace(b"\r\n149", b"\r\n\r\n149")
        meta = self.register("t.csv", data)
        self.assertEqual((meta["rows"], meta["columnCount"], meta["columns"]), (150, 3, ["id", "name", "note"]))
        self.assertEqual((self.state / "sources" / meta["sourceId"] / "data.csv").read_bytes(), data)
        source = self.source(meta)
        _, reference = brute(data)
        self.assertEqual(reference[0][0], "0")
        collected = []
        for page in range(6):
            reply = src._page(source, page, 0)
            self.assertEqual((reply["pageSize"], reply["pageCount"], reply["viewRows"]), (25, 6, 150))
            self.assertEqual(reply["firstRow"], page * 25 + 1)
            collected += reply["rows"]
        self.assertEqual(collected, reference)

    def test_register_and_open_agree_and_header_only_source_is_empty(self):
        meta = self.register("a.csv", "x,y\n1,2\n")
        self.assertEqual(self.call("open", sourceId=meta["sourceId"]), src._summary(meta))
        empty = self.register("h.csv", "x,y\n")
        page = self.call("page", sourceId=empty["sourceId"], page=0, gen=0)
        self.assertEqual((page["rows"], page["pageCount"], page["viewRows"], page["firstRow"]), ([], 0, 0, 0))
        self.assertEqual(self.call("view", sourceId=empty["sourceId"], sort=-1, dir=1, filter="q", gen=2)["viewRows"], 0)

    def test_lone_cr_and_blank_line_files(self):
        meta = self.register("cr.csv", b"a,b\r1,2\r3,\"q\rr\"\r\r4,5\r")
        self.assertEqual(meta["rows"], 3)
        self.assertEqual(src._page(self.source(meta), 0, 0)["rows"], [["1", "2"], ["3", "q\rr"], ["4", "5"]])

    def test_layout_permissions_and_meta_schema(self):
        import hashlib
        data = b"a,b\n1,2\n3,4\n"
        meta = self.register("x/y.csv", data)
        directory = self.state / "sources" / meta["sourceId"]
        self.assertRegex(meta["sourceId"], r"src-[0-9a-f]{16}")
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.state / "sources").stat().st_mode), 0o700)
        self.assertEqual(sorted(os.listdir(directory)), ["data.csv", "index.bin", "meta.json"])
        for name in os.listdir(directory):
            self.assertEqual(stat.S_IMODE((directory / name).stat().st_mode), 0o600)
        self.assertEqual((directory / "index.bin").read_bytes(), (len(b"a,b\n")).to_bytes(8, "little"))
        stored = json.loads((directory / "meta.json").read_text())
        self.assertEqual(stored, meta)
        self.assertEqual(set(stored), {"version", "sourceId", "bytes", "sha256", "rows", "columnCount", "columns",
                                       "origin", "stats", "state"})
        self.assertEqual((stored["version"], stored["state"], stored["bytes"]), (1, "ready", len(data)))
        self.assertEqual(stored["sha256"], hashlib.sha256(data).hexdigest())
        origin = (self.home / "x/y.csv").stat()
        self.assertEqual(stored["origin"], {"path": "x/y.csv", "size": origin.st_size, "mtimeNs": origin.st_mtime_ns})
        self.assertEqual(set(stored["stats"][0]), {"name", "nonEmpty", "empty", "typeCounts", "inferredType", "min",
                                                   "max", "sum", "mean", "distinct", "distinctExact", "minLength",
                                                   "maxLength"})
        self.assertEqual(stored["stats"][0]["typeCounts"], {"number": 2, "date": 0, "text": 0, "unsure": 0})
        self.assertLessEqual(len((directory / "meta.json").read_bytes()), src.META_LIMIT)

    def test_columns_clamp_and_pages_show_only_twenty_clipped_cells(self):
        header = ["h%d" % i + "é" * 100 for i in range(25)]
        row = ["c%d" % i + "z" * 100 for i in range(25)]
        meta = self.register("w.csv", to_bytes([header, row, ["short"] * 25]))
        self.assertEqual((meta["columnCount"], len(meta["columns"]), len(meta["stats"])), (25, 20, 20))
        self.assertTrue(all(len(c) == 40 for c in meta["columns"]))
        self.assertEqual(meta["columns"], [s["name"] for s in meta["stats"]])
        page = src._page(self.source(meta), 0, 0)
        self.assertTrue(page["cellsTruncated"])
        self.assertEqual(len(page["rows"][0]), 20)
        self.assertTrue(all(len(cell) <= 80 for row in page["rows"] for cell in row))
        self.assertFalse(src._page(self.source(self.register("n.csv", "a\n1\n")), 0, 0)["cellsTruncated"])

    def test_page_clamps_and_requires_the_current_gen(self):
        meta = self.register("p.csv", "a\n" + "".join("%d\n" % i for i in range(60)))
        sid = meta["sourceId"]
        self.assertEqual(self.call("page", sourceId=sid, page=99, gen=0)["page"], 2)
        self.assertEqual(self.call("page", sourceId=sid, page=2, gen=0)["rows"][-1], ["59"])
        with self.assertRaises(src.Refuse) as caught:
            self.call("page", sourceId=sid, page=0, gen=4)
        self.assertEqual((str(caught.exception), caught.exception.extra), ("Stale view.", {"gen": 4}))
        self.call("view", sourceId=sid, sort=-1, dir=1, filter="", gen=4)
        self.assertEqual(self.call("page", sourceId=sid, page=0, gen=4)["gen"], 4)
        for bad in ({"page": -1, "gen": 4}, {"page": True, "gen": 4}, {"page": 0, "gen": "4"}, {"page": 1.5, "gen": 4}):
            with self.assertRaises(src.Refuse):
                self.call("page", sourceId=sid, **bad)


class RefusalTests(Base):
    def test_ragged_malformed_oversized_binary_and_encoding_are_refused_cleanly(self):
        for data in (b"a,b\n1,2\n3,4,5\n", b'a,b\n1,"2\n', b'a,b\n1,"x"y\n',
                     b'a\n"' + b"x" * (csv.field_size_limit() + 1) + b'"\n'):
            self.assertEqual(self.refused("r.csv", data), self.broker_message(data))
        self.assertEqual(self.refused("r.csv", "a,b\n1,2\n3,4,5\n"), "CSV line 3 has 3 columns; the header has 2.")
        self.assertEqual(self.refused("r.csv", b"a,b\n1,\x002\n"), "Attachment is binary.")
        self.assertEqual(self.refused("r.csv", b"a,b\n1,\x1b2\n"), "Attachment is binary.")
        self.assertEqual(self.refused("r.csv", b"a,b\n\xff,1\n"), "Attachment must be UTF-8 text.")
        self.assertEqual(self.refused("r.csv", b"a,b\n\xed\xa0\x80,1\n"), "Attachment must be UTF-8 text.")
        self.assertEqual(self.refused("r.csv", ""), "CSV attachment is empty.")
        self.assertEqual(self.refused("r.csv", "\n1,2\n"), "CSV attachment has no header row.")
        self.assertEqual(self.refused("r.csv", ",\n1,2\n"), "CSV attachment has no header row.")
        self.assertEqual(self.refused("r.txt", "a\n1\n"), src.E_CSV_ONLY)

    def test_ragged_row_far_into_a_large_file_fails_the_whole_registration(self):
        fixture.write_main(self.home / "big.csv", rows=3000, ragged_at=2900)
        message = self.refused("big.csv")
        self.assertRegex(message, r"CSV line \d+ has 19 columns; the header has 20\.")
        self.assertEqual(message, self.broker_message((self.home / "big.csv").read_bytes()))

    def test_path_policy_comes_from_the_guarded_opener(self):
        self.file("secrets.csv", "a\n1\n")
        self.assertEqual(self.refused("secrets.csv"), "Credential and secret files cannot be attached.")
        self.assertEqual(self.refused(".env.csv"), "Credential and secret files cannot be attached.")
        outside = self.temp / "outside.csv"
        outside.write_text("a\n1\n")
        self.assertEqual(self.refused(str(outside)), "Attachment must be inside your home directory.")
        self.assertEqual(self.refused("../outside.csv"), "Invalid attachment path.")
        self.assertEqual(self.refused("missing.csv"), "Attachment is unavailable or is a symbolic link.")
        self.file("real.csv", "a\n1\n")
        (self.home / "link.csv").symlink_to(self.home / "real.csv")
        self.assertEqual(self.refused("link.csv"), "Attachment is unavailable or is a symbolic link.")
        (self.home / "dirlink").symlink_to(self.temp)
        self.assertEqual(self.refused("dirlink/outside.csv"), "Attachment is unavailable or is a symbolic link.")

    def test_fifo_and_directory_never_block_or_register(self):
        os.mkfifo(self.home / "pipe.csv")
        self.assertEqual(self.refused("pipe.csv"), src.E_REGULAR)
        (self.home / "dir.csv").mkdir()
        self.assertEqual(self.refused("dir.csv"), src.E_REGULAR)

    def test_caps_are_complete_or_nothing(self):
        data = b"a\n" + b"1\n" * 10
        with mock.patch.object(src, "MAX_ROWS", 9):
            self.assertEqual(self.refused("c.csv", data), src.E_ROWS)
        with mock.patch.object(src, "MAX_ROWS", 10):
            self.assertEqual(self.register("c.csv")["rows"], 10)
        with mock.patch.object(src, "MAX_BYTES", len(data) - 1):
            self.assertEqual(self.refused("c.csv"), src.E_BYTES)
        with mock.patch.object(src, "MAX_LINE", 64):
            self.assertEqual(self.refused("c.csv", b"a,b\n" + b"x" * 65 + b",1\n"), src.E_LINE)
            self.assertEqual(self.refused("c.csv", b"a,b\n" + b"x" * 65), src.E_LINE)
            self.assertEqual(self.refused("c.csv", b"a,b\r" + b"x" * 65 + b",1\r"), src.E_LINE)

    def test_a_file_that_changes_while_it_is_copied_is_refused(self):
        origin = self.file("g.csv", b"a\n" + b"1\n" * 10)
        real = src.hashlib.sha256

        def changing(mutate):
            class Digest:
                done = False

                def __init__(self):
                    self.inner = real()

                def update(self, block):
                    self.inner.update(block)
                    if not Digest.done:
                        Digest.done = True
                        mutate()

                def hexdigest(self):
                    return self.inner.hexdigest()
            return Digest

        def append():
            with open(origin, "ab") as stream:
                stream.write(b"2\n")

        def touch():
            os.utime(origin, ns=(1, origin.stat().st_mtime_ns + 10 ** 9))

        for mutate in (append, touch):
            with mock.patch.object(src.hashlib, "sha256", changing(mutate)):
                self.assertEqual(self.refused("g.csv"), src.E_CHANGED)
        self.assertEqual(self.register("g.csv")["rows"], 11)

    def test_one_mebibyte_line_without_newline_is_refused_by_default_caps(self):
        fixture.write_long_line(self.home / "long.csv")
        self.assertEqual(self.refused("long.csv"), src.E_LINE)

    def test_row_cap_with_default_limits_and_failure_keeps_other_temp_dirs(self):
        (self.state / "sources").mkdir(mode=0o700)
        other = self.state / "sources" / (".tmp-" + "f" * 16)
        other.mkdir(mode=0o700)
        (other / "data.csv").write_text("x")
        fixture.write_single_column(self.home / "many.csv", src.MAX_ROWS + 1)
        with self.assertRaises(src.Refuse) as caught:
            self.register("many.csv")
        self.assertEqual(str(caught.exception), src.E_ROWS)
        self.assertEqual(self.leftovers(), [other.name])
        self.assertEqual((other / "data.csv").read_text(), "x")

    def test_symlinked_state_or_sources_directories_are_refused_and_nothing_is_written_through_them(self):
        os.rename(self.state, self.temp / "real-state")
        self.state.symlink_to(self.temp / "real-state")
        with self.assertRaises(src.Refuse):
            self.register("s.csv", "a\n1\n")
        self.state.unlink()
        os.rename(self.temp / "real-state", self.state)
        (self.state / "sources").symlink_to(self.temp)
        before = sorted(os.listdir(self.temp))
        with self.assertRaises(src.Refuse):
            self.register("s.csv", "a\n1\n")
        self.assertEqual(sorted(os.listdir(self.temp)), before)
        with self.assertRaises(src.Refuse) as caught:
            src.open_source(self.state, SID)
        self.assertEqual(str(caught.exception), src.E_UNSAFE)


class BrokerContractTests(Base):
    def test_meta_json_passes_the_brokers_strict_loader(self):
        import ai_broker
        fixture.write_main(self.home / "f.csv", rows=1500)
        self.file("t.csv", "a,b\n1,x\n,y\n 2 ,\n")
        self.file("h.csv", "a\n")
        self.file("w.csv", to_bytes([["h%d\u00e9\n" % i + "z" * 90 for i in range(25)], ["1"] * 25]))
        self.file("mix.csv", "n,d,t,u,p\n1,2024-01-02,a,\"1,5\",12%\n2,2024-01-03,b,\"2,5\",7%\n")
        for name in ("f.csv", "t.csv", "h.csv", "w.csv", "mix.csv"):
            meta = self.register(name)
            raw = (self.state / "sources" / meta["sourceId"] / "meta.json").read_bytes()
            self.assertLessEqual(len(raw), 32 * 1024)
            loaded = ai_broker.load_source(meta["sourceId"], str(self.state))
            self.assertEqual((loaded["rows"], loaded["columnCount"], loaded["bytes"]),
                             (meta["rows"], meta["columnCount"], meta["bytes"]), name)
            self.assertEqual(len(loaded["columns"]), min(20, meta["columnCount"]))


class OffsetTests(Base):
    def test_offset_after_next_is_the_record_boundary(self):
        cases = {
            "lf multiline": [b"a,b\n", b'1,"x\ny"\n', b'2,"p\n\nq"\n', b"3,z\n"],
            "crlf multiline": [b"a,b\r\n", b'1,"x\r\ny"\r\n', b"2,w\r\n"],
            "lone cr": [b"a,b\r", b"1,2\r", b'3,"q\rr"\r', b"4,5\r"],
            "mixed endings": [b"a,b\n", b"1,2\r\n", b"3,4\r", b'5,"a\r\nb"\n', b"6,7\n"],
            "blank lines": [b"a\n", b"\n", b"1\n", b"\r\n", b"2\n"],
            "no trailing newline": [b"a,b\n", b"1,2"],
            "bom": [b"\xef\xbb\xbfa,b\n", b"1,2\n"],
            "unicode": ["a,b\n".encode(), "é,\"日\n\U0001f600\"\n".encode()],
        }
        for name, records in cases.items():
            with self.subTest(name):
                lines = src.Lines(io.BytesIO(b"".join(records)))
                reader = csv.reader(lines, strict=True)
                boundary = 0
                for record in records:
                    next(reader)
                    boundary += len(record)
                    self.assertEqual(lines.pos, boundary)
                with self.assertRaises(StopIteration):
                    next(reader)

    def test_checkpoint_seek_equals_brute_force_at_every_page_boundary(self):
        rng = random.Random(7)
        for newline in ("\n", "\r\n", "\r"):
            with self.subTest(newline=newline):
                rows = [["id", "text", "tail"]]
                for i in range(731):
                    note = "|".join("l%d" % j for j in range(rng.randint(1, 3))).replace("|", newline)
                    rows.append([str(i), 'q"%s,%d' % (note, i) if i % 3 == 0 else "plain %d" % i, "z" * (i % 5)])
                    if i in (63, 64, 127, 128):
                        rows.append([])  # a blank record around a checkpoint
                data = to_bytes(rows, newline)
                meta = self.register("m.csv", data)
                source = self.source(meta)
                _, reference = brute(data)
                self.assertEqual(meta["rows"], len(reference))
                self.assertEqual(len(source.offsets), -(-len(reference) // 64))
                for page in range(-(-len(reference) // 25)):
                    self.assertEqual(src._page(source, page, 0)["rows"], reference[page * 25:page * 25 + 25], page)
                every = src._rows(source, range(len(reference)))
                self.assertEqual([every[i] for i in range(len(reference))], reference)
                for block, offset in enumerate(source.offsets):
                    first = next(r for r in csv.reader(io.StringIO(data[offset:].decode(), newline=""), strict=True) if r)
                    self.assertEqual(first, reference[block * 64])
                shuffled = list(range(len(reference)))
                rng.shuffle(shuffled)
                found = src._rows(source, shuffled[:200])
                self.assertTrue(all(found[i] == reference[i] for i in found))


class StatsTests(Base):
    @staticmethod
    def neumaier(values):
        total = comp = 0.0
        for x in values:
            t = total + x
            comp += ((total - t) + x) if abs(total) >= abs(x) else ((x - t) + total)
            total = t
        return total + comp

    def stats(self, cells, chunk=None):
        column = src.ColumnStats()
        for start in range(0, len(cells), chunk or len(cells) or 1):
            column.feed(tuple(cells[start:start + (chunk or len(cells))]))
        return column.result("c")

    def test_numeric_stats_match_a_plain_recompute_and_neumaier_beats_naive_sum(self):
        rng = random.Random(3)
        cells = ["%.3f" % rng.uniform(-1e6, 1e6) if i % 9 else "" for i in range(5000)]
        cells[4] = " 7 "
        cells[5] = "   "
        values = [float(c) for c in cells if c.strip()]
        result = self.stats(cells, chunk=777)
        self.assertEqual((result["nonEmpty"], result["empty"]), (len(values), len(cells) - len(values)))
        self.assertEqual((result["min"], result["max"]), (min(values), max(values)))
        self.assertEqual(result["sum"], self.neumaier(values))
        self.assertAlmostEqual(result["sum"], math.fsum(values), delta=1e-6)
        self.assertEqual(result["mean"], self.neumaier(values) / len(values))
        self.assertEqual(result["inferredType"], "number")
        self.assertEqual(result["typeCounts"]["number"], len(values))
        hard = self.stats(["1e100", "1", "-1e100", "1", "1e100", "-1e100"])
        self.assertEqual(hard["sum"], 2)
        self.assertNotEqual(1e100 + 1 + -1e100 + 1 + 1e100 + -1e100, 2)

    def test_fast_path_and_per_cell_path_agree(self):
        rng = random.Random(11)
        columns = [["%d" % rng.randint(-99, 99), "%.2f" % rng.random(), "", ".5", "-0", "1e3", "1e999", "007",
                    " 3 ", "1,5", "2024-01-02", "N/A", "12%", "01/02/03", "abc", "1234567890123456"][:n]
                   for n in (5, 9, 16)]
        columns.append(["%.2f" % rng.uniform(-9, 9) for _ in range(3000)])
        for cells in columns:
            fast = self.stats(cells * 3, chunk=50)
            with mock.patch.object(src, "_ALL_NUMBERS", re.compile(r"(?!)")):
                slow = self.stats(cells * 3, chunk=50)
            self.assertEqual(fast, slow)

    def test_dates_text_percent_and_mixed_columns(self):
        iso = self.stats(["2024-03-01", "", "2023-12-31 10:00", "2024-02-29T01:02:03.5", "2024/01/01"])
        self.assertEqual((iso["inferredType"], iso["min"], iso["max"], iso["sum"]), ("date", "2023-12-31 10:00", "2024-03-01", None))
        self.assertEqual(iso["typeCounts"], {"number": 0, "date": 4, "text": 0, "unsure": 0})
        zoned = self.stats(["2024-03-01T01:00Z", "2024-03-02"])
        self.assertEqual((zoned["inferredType"], zoned["min"], zoned["max"]), ("date", None, None))
        ambiguous = self.stats(["2024-03-01", "01/02/2024"])
        self.assertEqual((ambiguous["inferredType"], ambiguous["min"], ambiguous["typeCounts"]["unsure"]), ("unsure", None, 1))
        percent = self.stats(["12%", "7.5%"])
        self.assertEqual((percent["inferredType"], percent["min"], percent["typeCounts"]["unsure"]), ("number", None, 2))
        mixed = self.stats(["1", "2", "abc"])
        self.assertEqual((mixed["inferredType"], mixed["min"], mixed["sum"]), ("text", None, None))
        self.assertEqual(mixed["typeCounts"], {"number": 2, "date": 0, "text": 1, "unsure": 0})
        null = self.stats(["N/A", " ", "", "n/a"])
        self.assertEqual((null["nonEmpty"], null["empty"], null["inferredType"]), (2, 2, "text"))
        self.assertEqual(self.stats(["", " "])["inferredType"], "empty")
        codes = self.stats(["01234", "02134"])
        self.assertEqual((codes["inferredType"], codes["typeCounts"]["text"], codes["min"]), ("text", 2, None))

    def test_text_distinct_cap_and_length_flags(self):
        for count, exact, shown in ((999, True, 999), (1000, True, 1000), (1001, False, 1000), (5000, False, 1000)):
            cells = ["v%d" % i for i in range(count)] + ["v0", "v1", ""]
            result = self.stats(cells, chunk=300)
            self.assertEqual((result["distinct"], result["distinctExact"]), (shown, exact), count)
            self.assertEqual((result["nonEmpty"], result["empty"]), (count + 2, 1))
        lengths = self.stats(["ab", "\U0001f600é日xyz", " pad ", "", "a"])
        self.assertEqual((lengths["minLength"], lengths["maxLength"], lengths["distinct"]), (1, 6, 4))
        self.assertIsNone(self.stats(["1", "2"])["distinct"])
        self.assertIsNone(self.stats(["2024-01-01"])["minLength"])

    def test_registered_stats_match_the_fixture_columns(self):
        fixture.write_main(self.home / "f.csv", rows=4000)
        meta = self.register("f.csv")
        header, rows = brute((self.home / "f.csv").read_bytes())
        self.assertEqual((meta["rows"], meta["columnCount"]), (4000, 20))
        for index in (0, 2, 12):
            values = [float(row[index]) for row in rows if row[index].strip()]
            stats = meta["stats"][index]
            self.assertEqual((stats["nonEmpty"], stats["min"], stats["max"]), (len(values), min(values), max(values)))
            self.assertEqual(stats["sum"], src._number(self.neumaier(values)))
        self.assertEqual([s["inferredType"] for s in meta["stats"]],
                         ["number"] * 14 + ["date"] * 2 + ["text"] * 4)
        self.assertEqual(meta["stats"][14]["min"], min(row[14] for row in rows))
        self.assertEqual(meta["stats"][17]["distinct"], len({row[17] for row in rows if row[17].strip()}))

    def test_python_mirror_matches_the_shared_golden_table(self):
        cases = json.loads((HERE / "csv_type_golden.json").read_text(encoding="utf-8"))["cases"]
        self.assertGreater(len(cases), 60)
        for case in cases:
            counts = dict.fromkeys(src.KINDS, 0)
            for cell in case["cells"]:
                counts[src.classify(cell)[0]] += 1
            self.assertEqual(src.infer_type(counts), case["type"], case["tag"])
            if case["cells"]:
                self.assertEqual(self.stats(case["cells"])["inferredType"], case["type"], case["tag"])


class ViewTests(Base):
    CONTENT = ("id,qty,name,when\n"
               "0,10,Alpha beta,2024-01-02\n1,,alpha Gamma,2024-01-01\n2,3,Beta,2024-01-03\n3,10,Éclair,\n"
               "4,-2.5,éclair b,2024-01-02\n5,3,delta|x,2024-01-01\n6,,,2024-01-05\n7,1e1,Zed,2024-01-04\n"
               "8,  ,ZED,2024-01-04\n")

    def setUp(self):
        super().setUp()
        self.sid = self.register("v.csv", self.CONTENT)["sourceId"]
        self.gen = 0

    def view(self, sort=-1, dirn=1, text=""):
        self.gen += 1
        reply = self.call("view", sourceId=self.sid, sort=sort, dir=dirn, filter=text, gen=self.gen)
        self.assertEqual(reply, {"gen": self.gen, "viewRows": reply["viewRows"]})
        rows = []
        for page in range(-(-reply["viewRows"] // 25)):
            rows += self.call("page", sourceId=self.sid, page=page, gen=self.gen)["rows"]
        return [row[0] for row in rows]

    def test_numeric_sort_puts_empties_last_in_both_directions_with_stable_ties(self):
        self.assertEqual(self.view(), [str(i) for i in range(9)])
        self.assertEqual(self.view(1, 1), ["4", "2", "5", "0", "3", "7", "1", "6", "8"])
        self.assertEqual(self.view(1, -1), ["0", "3", "7", "2", "5", "4", "1", "6", "8"])

    def test_text_sort_is_by_character_code_on_the_casefolded_cell(self):
        # code order: every ASCII name precedes the accented ones; blank names stay last in both directions
        self.assertEqual(self.view(2, 1), ["0", "1", "2", "5", "7", "8", "3", "4", "6"])
        self.assertEqual(self.view(2, -1), ["4", "3", "7", "8", "5", "2", "1", "0", "6"])

    def test_filter_is_a_literal_case_insensitive_substring_never_a_regex(self):
        self.assertEqual(self.view(text="a|b"), [])
        self.assertEqual(self.view(text="delta|x"), ["5"])
        self.assertEqual(self.view(text="ALPHA"), ["0", "1"])
        self.assertEqual(self.view(text="\u00c9CLAIR"), ["3", "4"])
        self.assertEqual(self.view(text=".*"), [])
        self.assertEqual(self.view(text="2024-01-05"), ["6"])
        self.assertEqual(self.view(text="ZED"), ["7", "8"])
        self.assertEqual(self.view(text="6,"), [])  # cells are joined with \x01, not commas
        # control characters are stripped from the filter, so \x01 can never bridge two cells
        self.assertEqual(self.view(text="beta\x012024-01-02"), [])
        self.assertEqual(self.view(0, -1, "beta"), ["2", "0"])
        self.assertEqual(self.view(1, 1, "a"), ["4", "2", "5", "0", "3", "1"])

    def test_filter_control_characters_cannot_match_across_cells_and_empty_means_no_filter(self):
        everything = [str(i) for i in range(9)]
        # "Alpha beta" and "2024-01-02" are different cells of row 0, joined by \x01 inside the worker
        self.assertEqual(self.view(text="beta\x012024-01-02"), [])
        self.assertEqual(self.view(text="Alpha beta\x01"), ["0"], "the separator is removed, the text still matches")
        self.assertEqual(self.view(text="al\x1fpha\x7f"), ["0", "1"])
        for needle in ("\x01", "\t\x00\x7f"):
            self.assertEqual(self.view(text=needle), everything, "only control characters means no filter")
        self.assertEqual(self.view(1, 1, "\x01"), ["4", "2", "5", "0", "3", "7", "1", "6", "8"], "an emptied filter keeps the sort")

    def test_numeric_sort_uses_the_same_cleaning_as_the_stats(self):
        bom, nbsp = "\ufeff", "\u00a0"
        content = ("n\n10\n" + bom + "5\n2\n" + nbsp + "7" + nbsp + "\n" + bom + "\n3\n")
        meta = self.register("bom.csv", content)
        stat = meta["stats"][0]
        self.assertEqual((stat["inferredType"], stat["typeCounts"]["number"], stat["empty"]), ("number", 5, 1))
        self.assertEqual((stat["sum"], stat["min"], stat["max"]), (27, 2, 10), "the BOM-prefixed 5 counts in the stats")
        self.sid, self.gen = meta["sourceId"], 0
        clean = lambda cells: [cell.strip(bom + nbsp) for cell in cells]
        self.assertEqual(clean(self.view(0, 1)), ["2", "3", "5", "7", "10", ""], "ascending, the blank cell last")
        self.assertEqual(clean(self.view(0, -1)), ["10", "7", "5", "3", "2", ""], "descending, the blank cell still last")

    def test_invalid_view_requests_are_static_refusals(self):
        for fields in ({"sort": 4}, {"sort": -2}, {"sort": True}, {"sort": "1"}, {"dir": 0}, {"dir": "1"},
                       {"filter": "x" * 201}, {"filter": None}, {"gen": -1}, {"gen": "1"}):
            request = {"sourceId": self.sid, "sort": 0, "dir": 1, "filter": "", "gen": 1, **fields}
            with self.assertRaises(src.Refuse, msg=fields):
                self.call("view", **request)

    def test_sort_cap_counts_matching_rows_and_filtering_first_succeeds(self):
        with mock.patch.object(src, "SORT_MAX_ROWS", 8):
            with self.assertRaises(src.Refuse) as caught:
                self.call("view", sourceId=self.sid, sort=0, dir=1, filter="", gen=5)
            self.assertEqual((str(caught.exception), caught.exception.extra), (src.E_SORT_CAP, {"gen": 5}))
            self.assertEqual(self.view(0, -1, "lpha")[:2], ["1", "0"])
            self.assertEqual(self.call("view", sourceId=self.sid, sort=-1, dir=1, filter="", gen=6)["viewRows"], 9)

    def test_superseded_view_aborts_and_keeps_the_previous_view(self):
        self.view(0, -1)
        first = self.gen
        checks = []
        source = self.worker.sources[self.sid]
        with mock.patch.object(src, "CHUNK_ROWS", 3):
            self.worker.waiting = lambda: checks.append(1) or len(checks) >= 2
            with self.assertRaises(src.Refuse) as caught:
                self.call("view", sourceId=self.sid, sort=1, dir=1, filter="", gen=first + 1)
        self.assertEqual((str(caught.exception), caught.exception.extra), ("Superseded.", {"gen": first + 1}))
        self.assertEqual(len(checks), 2)
        self.assertEqual(source.view.gen, first)

    def test_close_drops_views_and_open_keeps_a_live_one(self):
        self.view(0, -1)
        self.call("open", sourceId=self.sid)
        self.assertEqual(self.worker.sources[self.sid].view.gen, self.gen)
        self.assertEqual(self.call("close", sourceId=self.sid), {})
        self.assertNotIn(self.sid, self.worker.sources)
        self.assertEqual(self.call("page", sourceId=self.sid, page=0, gen=0)["rows"][0][0], "0")


class IdentityAndVerifyTests(Base):
    def test_source_ids_must_match_the_exact_pattern_for_every_operation(self):
        bad = ["../x", "src-ABCDEF0123456789", "src-0123456789abcde", "src-0123456789abcdef0", SID + "/..",
               "/etc/passwd", "", " " + SID, SID + "\n", "src-0123456789abcdeg", None, 7, ["src"], {"a": 1}]
        for sid in bad:
            for op, extra in (("open", {}), ("verify", {}), ("close", {}), ("view", {"sort": -1, "dir": 1, "filter": "",
                              "gen": 1}), ("page", {"page": 0, "gen": 0})):
                with self.subTest(sid=sid, op=op), self.assertRaises(src.Refuse) as caught:
                    self.call(op, sourceId=sid, **extra)
                self.assertEqual(str(caught.exception), src.E_ID)
        with self.assertRaises(src.Refuse) as caught:
            self.call("page", page=0, gen=0)
        self.assertEqual(str(caught.exception), src.E_ID)
        with self.assertRaises(src.Refuse) as caught:
            self.call("page", sourceId=SID, page=0, gen=0)
        self.assertEqual(str(caught.exception), src.E_MISSING)

    def test_verify_states(self):
        origin = self.file("o.csv", "a,b\n1,2\n")
        meta = self.register("o.csv")
        sid = meta["sourceId"]
        state = lambda: self.call("verify", sourceId=sid)["state"]
        self.assertEqual(state(), "ready")
        os.utime(origin, ns=(1, origin.stat().st_mtime_ns + 5))
        self.assertEqual(state(), "originChanged")
        meta = self.register("o.csv")
        sid = meta["sourceId"]
        self.assertEqual(state(), "ready")
        origin.write_text("a,b\n1,2\n3,4\n")
        self.assertEqual(state(), "originChanged")
        origin.unlink()
        self.assertEqual(state(), "originMissing")
        origin.symlink_to(self.temp)
        self.assertEqual(state(), "originChanged")
        directory = self.state / "sources" / sid
        (directory / "data.csv").unlink()
        self.assertEqual(state(), "copyMissing")
        shutil.rmtree(directory)
        self.assertEqual(state(), "copyMissing")

    def test_damaged_or_unsafe_sources_are_refused(self):
        sid = self.register("d.csv", "a,b\n" + "1,2\n" * 200)["sourceId"]
        directory = self.state / "sources" / sid
        good = (directory / "meta.json").read_text()
        meta = json.loads(good)

        def damaged(text=None, **change):
            tampered = dict(meta, **change)
            (directory / "meta.json").write_text(text if text is not None else json.dumps(tampered))
            with self.assertRaises(src.Refuse) as caught:
                src.open_source(self.state, sid)
            self.assertEqual(str(caught.exception), src.E_DAMAGED, change)

        damaged("[]")
        damaged("not json")
        damaged(sourceId="src-ffffffffffffffff")
        damaged(version=2)
        damaged(rows="200")
        damaged(columns=["a"] * 21)
        damaged(extra=1)
        damaged(columns=["x", "b"])
        damaged(rows=199)
        damaged(origin={"path": "../x.csv", "size": 1, "mtimeNs": 1})
        damaged(origin={"path": "/abs.csv", "size": 1, "mtimeNs": 1})
        damaged(stats=[dict(meta["stats"][0], name="x" * 41), meta["stats"][1]])
        damaged(stats=[dict(meta["stats"][0], inferredType="bogus"), meta["stats"][1]])
        damaged(" " * (src.META_LIMIT + 1))
        (directory / "meta.json").write_text(good)
        self.assertEqual(self.source({"sourceId": sid}).rows, 200)
        (directory / "index.bin").write_bytes(b"\x00" * 8)
        with self.assertRaises(src.Refuse):
            src.open_source(self.state, sid)
        (directory / "index.bin").write_bytes((4).to_bytes(8, "little") * 4)
        with self.assertRaises(src.Refuse):
            src.open_source(self.state, sid)
        (directory / "index.bin").unlink()
        with self.assertRaises(src.Refuse) as caught:
            src.open_source(self.state, sid)
        self.assertEqual(str(caught.exception), src.E_MISSING)
        directory.chmod(0o755)
        with self.assertRaises(src.Refuse) as caught:
            src.open_source(self.state, sid)
        self.assertEqual(str(caught.exception), src.E_UNSAFE)

    def test_a_symlinked_meta_or_data_file_is_never_followed(self):
        sid = self.register("l.csv", "a\n1\n")["sourceId"]
        directory = self.state / "sources" / sid
        outside_meta = self.temp / "secret.json"
        outside_meta.write_text((directory / "meta.json").read_text())
        (directory / "meta.json").unlink()
        (directory / "meta.json").symlink_to(outside_meta)
        with self.assertRaises((src.Refuse, OSError)):
            src.open_source(self.state, sid)


class RegisterEventTests(Base):
    def test_progress_events_precede_the_result_with_increasing_rows(self):
        fixture.write_main(self.home / "p.csv", rows=9000)
        events = []
        with mock.patch.object(src, "PROGRESS_SECONDS", 0):
            reply = self.worker.register({"path": "p.csv"}, events.append)
        self.assertEqual([e["rows"] for e in events], [4096, 8192])
        self.assertTrue(all(e["event"] == "progress" for e in events))
        self.assertEqual(reply["rows"], 9000)


class BlankLineFloodTests(Base):
    FLOOD = 20000

    def flood(self, name="flood.csv"):
        # the index skips LEADING blanks, so the flood sits between two data rows
        return self.register(name, "a,b\n1,2\n" + "\n" * self.FLOOD + "3,4\n")

    def test_register_reports_progress_while_scanning_only_blank_lines(self):
        self.file("flood.csv", "a,b\n" + "\n" * self.FLOOD + "1,2\n")
        events = []
        with mock.patch.object(src, "PROGRESS_SECONDS", 0):
            reply = self.worker.register({"path": "flood.csv"}, events.append)
        self.assertEqual(reply["rows"], 1, "blank lines are still dropped")
        self.assertGreaterEqual(len(events), self.FLOOD // src.CHUNK_ROWS - 1)
        self.assertTrue(all(e["event"] == "progress" and e["rows"] == 0 for e in events))

    def test_a_queued_request_supersedes_a_view_over_a_blank_flood(self):
        meta = self.flood()
        self.assertEqual((meta["rows"], meta["stats"][0]["nonEmpty"]), (2, 2))
        source = self.source(meta)
        self.worker.sources[meta["sourceId"]] = source
        checks = []
        self.worker.waiting = lambda: checks.append(1) or len(checks) >= 2
        with self.assertRaises(src.Refuse) as caught:
            self.call("view", sourceId=meta["sourceId"], sort=0, dir=1, filter="", gen=1)
        self.assertEqual((str(caught.exception), caught.exception.extra), ("Superseded.", {"gen": 1}))
        self.assertEqual(len(checks), 2, "the second check fell inside the blank run, before the last data row")
        self.worker.waiting = lambda: False
        self.assertEqual(self.call("view", sourceId=meta["sourceId"], sort=0, dir=1, filter="", gen=2)["viewRows"], 2)

    def test_default_cadence_still_checks_once_per_4096_lines(self):
        meta = self.flood()
        self.worker.sources[meta["sourceId"]] = self.source(meta)
        checks = []
        self.worker.waiting = lambda: checks.append(1) and False
        self.call("view", sourceId=meta["sourceId"], sort=0, dir=1, filter="", gen=1)
        lines = self.FLOOD + 2  # 1 + the flood + 1 physical lines
        self.assertEqual(len(checks), -(-lines // src.CHUNK_ROWS))


class LimitGuardTests(Base):
    """Boundaries the rest of the suite never reached; each assertion pins one guard."""

    def test_source_cache_evicts_the_oldest_beyond_the_cap_and_closes_its_stream(self):
        self.assertEqual(src.CACHE_SOURCES, 8)
        ids = [self.register("c%d.csv" % i, "a\n%d\n" % i)["sourceId"] for i in range(src.CACHE_SOURCES + 2)]
        streams = {}
        for sid in ids:
            self.call("open", sourceId=sid)
            streams[sid] = self.worker.sources[sid].stream
        self.assertEqual(len(self.worker.sources), src.CACHE_SOURCES)
        self.assertEqual(list(self.worker.sources), ids[2:])
        self.assertTrue(streams[ids[0]].closed and streams[ids[1]].closed, "an evicted source must release its descriptor")
        self.assertFalse(any(streams[sid].closed for sid in ids[2:]))
        self.assertEqual(self.call("page", sourceId=ids[0], page=0, gen=0)["rows"], [["0"]], "an evicted source reopens on demand")

    def test_origin_path_length_is_capped_at_exactly_max_origin(self):
        name = "/".join(["d" * 200] * 4) + "/x.csv"
        self.file(name, "a\n1\n")
        origin = src._origin_path(name, self.home)
        self.assertEqual(self.register(name)["origin"]["path"], origin)  # under the real cap
        deep = "/".join(["e" * 200] * 6) + "/y.csv"
        self.file(deep, "a\n1\n")
        self.assertGreater(len(src._origin_path(deep, self.home)), src.MAX_ORIGIN)
        self.assertEqual(self.refused(deep), src.E_PATH)
        with mock.patch.object(src, "MAX_ORIGIN", len(origin)):
            self.assertEqual(self.register(name)["origin"]["path"], origin, "a path of exactly MAX_ORIGIN is allowed")
        with mock.patch.object(src, "MAX_ORIGIN", len(origin) - 1):
            self.assertEqual(self.refused(name), src.E_PATH)

    def test_meta_json_is_capped_when_written_and_when_read(self):
        meta = self.register("m.csv", "a\n1\n")
        size = len((self.state / "sources" / meta["sourceId"] / "meta.json").read_bytes())
        with mock.patch.object(src, "META_LIMIT", size):
            self.assertEqual(self.register("m.csv")["rows"], 1, "exactly META_LIMIT bytes is allowed")
        before = self.leftovers()
        with mock.patch.object(src, "META_LIMIT", size - 1):
            self.assertEqual(self.refused("m.csv"), src.E_STORE)
        self.assertEqual(self.leftovers(), before)
        # Read side: a file that grows between fstat and read is still refused by length.
        real = src._read_file

        def grown(dir_fd, name, limit):
            data = real(dir_fd, name, limit)
            return data + b" " * (limit + 1 - len(data)) if name == "meta.json" else data

        with mock.patch.object(src, "_read_file", grown), self.assertRaises(src.Refuse) as caught:
            src.open_source(self.state, meta["sourceId"])
        self.assertEqual(str(caught.exception), src.E_DAMAGED)
        src.open_source(self.state, meta["sourceId"]).stream.close()

    def test_an_oversize_reply_is_replaced_by_a_static_error_with_the_same_id(self):
        sid = self.register("r.csv", "a,b\n" + "".join("%d,%s\n" % (i, "x" * 60) for i in range(100)))["sourceId"]

        def serve(limit):
            reader, writer = os.pipe()
            os.write(writer, json.dumps({"id": 7, "op": "page", "sourceId": sid, "page": 0, "gen": 0}).encode() + b"\n")
            os.close(writer)
            out = io.BytesIO()
            with mock.patch.object(src, "MAX_RESPONSE", limit):
                self.assertEqual(src.serve(self.state, out, idle=2, fd=reader, home=self.home), 0)
            os.close(reader)
            return out.getvalue()

        full = serve(src.MAX_RESPONSE)
        reply = json.loads(full)
        self.assertEqual((reply["id"], reply["ok"], len(reply["rows"])), (7, True, 25))
        self.assertEqual(serve(len(full)), full, "a reply of exactly MAX_RESPONSE bytes (newline included) is sent")
        small = json.loads(serve(len(full) - 1))
        self.assertEqual(small, {"id": 7, "ok": False, "error": src.E_TOO_LARGE})

    def test_state_root_must_be_absolute_and_not_group_or_world_writable(self):
        root = self.temp / "root"
        root.mkdir()
        for mode, allowed in ((0o700, True), (0o755, True), (0o775, False), (0o757, False), (0o777, False), (0o722, False)):
            root.chmod(mode)
            with self.subTest(mode=oct(mode)):
                if allowed:
                    os.close(src._open_root(root))
                else:
                    with self.assertRaises(src.Refuse) as caught:
                        src._open_root(root)
                    self.assertEqual(str(caught.exception), src.E_UNSAFE)
        with self.assertRaises(src.Refuse):
            src._open_root("relative/root")
        root.chmod(0o777)
        self.file("u.csv", "a\n1\n")
        with self.assertRaises(src.Refuse) as caught:
            src.register(root, "u.csv", self.home)
        self.assertEqual(str(caught.exception), src.E_UNSAFE)


class StaleTempAndReaperTests(Base):
    def temp_dir(self, name, age, entries=("data.csv",)):
        (self.state / "sources").mkdir(mode=0o700, exist_ok=True)
        directory = self.state / "sources" / name
        directory.mkdir(mode=0o700, exist_ok=True)
        for entry in entries:
            (directory / entry).write_text("partial")
            os.utime(directory / entry, (time.time() - age,) * 2)
        os.utime(directory, (time.time() - age,) * 2)
        return directory

    def cli(self, *extra):
        return subprocess.run([sys.executable, str(MODULE), "--root", str(self.state), "--reap-sources", *extra],
                              capture_output=True, text=True, env={"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1"})

    def test_dry_run_lists_and_removes_nothing_and_apply_removes_only_stale_temp_dirs(self):
        meta = self.register("a.csv", "a\n1\n")
        old = self.temp_dir(".tmp-" + "a" * 16, 7200, ("data.csv", "index.bin"))
        young = self.temp_dir(".tmp-" + "b" * 16, 60)
        odd = self.temp_dir(".tmp-" + "c" * 16, 7200, ("data.csv", "surprise.txt"))
        stranger = self.temp_dir("keep-me", 7200)
        keep_source = self.state / "sources" / meta["sourceId"]
        os.utime(keep_source, (1, 1))
        before = self.tree()
        dry = self.cli()
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(self.tree(), before)
        self.assertIn(meta["sourceId"], dry.stdout)
        self.assertIn(old.name, dry.stdout)
        self.assertIn("dry run: 2 stale temp dirs qualify", dry.stdout)
        self.assertIn("--apply --expect-count 2", dry.stdout)
        self.assertRegex(dry.stdout, r"keep +%s +\d" % meta["sourceId"])
        wrong = self.cli("--apply", "--expect-count", "1")
        self.assertEqual((wrong.returncode, self.tree()), (2, before))
        done = self.cli("--apply", "--expect-count", "2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("removed 1 temp dirs; 1 skipped or failed", done.stdout)
        self.assertEqual(sorted(os.listdir(self.state / "sources")),
                         sorted([keep_source.name, young.name, odd.name, stranger.name]))
        self.assertTrue((odd / "surprise.txt").exists() and (odd / "data.csv").exists())
        self.assertTrue((keep_source / "data.csv").exists())

    def test_reap_never_follows_a_symlinked_sources_directory_and_handles_no_sources(self):
        self.assertEqual(src.plan_reap(self.state), [])
        self.assertIn("dry run: 0 stale", self.cli().stdout)
        (self.state / "sources").symlink_to(self.temp)
        before = sorted(os.listdir(self.temp))
        self.assertEqual(self.cli("--apply").returncode, 2)
        self.assertEqual(sorted(os.listdir(self.temp)), before)

    def test_apply_rechecks_the_plan_and_spares_a_dir_touched_after_the_dry_run(self):
        old = self.temp_dir(".tmp-" + "e" * 16, 7200)
        real, calls = src.plan_reap, []

        def touched_between_plans(*args, **kwargs):
            calls.append(1)
            plan = real(*args, **kwargs)
            if len(calls) == 1:  # a registration wakes up right after the first look
                for path in (old, *old.iterdir()):
                    os.utime(path, None)
            return plan

        with mock.patch.object(src, "plan_reap", touched_between_plans):
            result = src.reap_sources(self.state, apply=True, expect=1)
        self.assertEqual(len(calls), 2, "the plan is read a second time before anything is deleted")
        self.assertEqual(result["removed"], [])
        self.assertEqual([item["name"] for item in result["failed"]], [old.name])
        self.assertTrue((old / "data.csv").exists(), "the now-fresh temp dir must survive")

    def test_a_failed_registration_removes_only_its_own_temp_dir(self):
        foreign = self.temp_dir(".tmp-" + "d" * 16, 7200)
        self.register("ok.csv", "a\n1\n")
        self.assertEqual(self.refused_leftovers("bad.csv", "a,b\n1\n"), [foreign.name, self.leftovers()[1]])
        self.assertTrue((foreign / "data.csv").exists())

    def refused_leftovers(self, name, content):
        with self.assertRaises(src.Refuse):
            self.register(name, content)
        return self.leftovers()

    def test_usage_errors_exit_two(self):
        for argv in ([], ["--root"], ["--root", "x"], ["--root", str(self.state), "--bogus"],
                     ["--root", str(self.state), "--reap-sources", "--expect-count", "1"],
                     ["--root", str(self.state), "--serve", "extra"]):
            result = subprocess.run([sys.executable, str(MODULE), *argv], capture_output=True, text=True,
                                    stdin=subprocess.DEVNULL, env={"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1"})
            self.assertEqual(result.returncode, 2, argv)


class TransportTests(Base):
    def test_pipelined_requests_answer_in_order_and_eof_exits_cleanly(self):
        meta = self.register("t.csv", "a,b\n" + "".join("%d,x\n" % i for i in range(100)))
        sid = meta["sourceId"]
        session = Session(self)
        session.send({"id": 1, "op": "open", "sourceId": sid}, {"id": 2, "op": "verify", "sourceId": sid},
                     {"id": 3, "op": "page", "sourceId": sid, "page": 3, "gen": 0}, {"id": 4, "op": "close", "sourceId": sid})
        replies = [session.recv() for _ in range(4)]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4])
        self.assertTrue(all(r["ok"] for r in replies))
        self.assertEqual((replies[1]["state"], replies[2]["rows"][0]), ("ready", ["75", "x"]))
        self.assertEqual(session.rpc("view", sourceId=sid, sort=0, dir=-1, filter="", gen=1)["viewRows"], 100)
        self.assertEqual(session.rpc("page", sourceId=sid, page=0, gen=1)["rows"][0], ["99", "x"])
        session.proc.stdin.close()
        self.assertEqual(session.proc.wait(10), 0)
        self.assertEqual(session.proc.stderr.read(), b"")

    def test_register_over_the_wire_emits_progress_then_result(self):
        fixture.write_main(self.home / "w.csv", rows=30000)
        session = Session(self)
        session.send({"id": 9, "op": "register", "path": "w.csv"})
        seen = []
        while True:
            reply = session.recv()
            seen.append(reply)
            if "event" not in reply:
                break
        self.assertTrue(all(r["id"] == 9 for r in seen))
        self.assertTrue(all(r["event"] == "progress" and r["rows"] > 0 for r in seen[:-1]))
        self.assertEqual((seen[-1]["ok"], seen[-1]["rows"], seen[-1]["columnCount"]), (True, 30000, 20))
        self.assertEqual(session.rpc("open", sourceId=seen[-1]["sourceId"])["stats"], seen[-1]["stats"])

    def test_bad_requests_get_static_errors_and_the_worker_keeps_serving(self):
        session = Session(self)
        for payload, error in ((b"not json\n", "Request must be one JSON object."),
                               (b'{"op":"open"}\n', "Request needs an integer id."),
                               (b'{"id":"1","op":"open"}\n', "Request needs an integer id."),
                               (b'{"id":true,"op":"open"}\n', "Request needs an integer id."),
                               (b"[1]\n", "Request needs an integer id."),
                               (b'{"id":1,"id":2,"op":"x"}\n', "Request must be one JSON object."),
                               (b'{"id":1,"op":"x","v":NaN}\n', "Request must be one JSON object."),
                               (b'{"id":7,"op":"nope"}\n', "Unknown operation."),
                               (b'{"id":8,"op":"open","sourceId":"../x"}\n', src.E_ID)):
            session.proc.stdin.write(payload)
            session.proc.stdin.flush()
            reply = session.recv()
            self.assertEqual((reply["ok"], reply["error"]), (False, error), payload)
        session.proc.stdin.write(b'{"id":3,"op":"open","pad":"' + b"x" * 9000 + b'"}\n{"id":4,"op":"nope"}\n')
        session.proc.stdin.flush()
        first, second = session.recv(), session.recv()
        self.assertEqual((first["id"], first["error"]), (None, "Request is too large."))
        self.assertEqual((second["id"], second["error"]), (4, "Unknown operation."))
        session.proc.stdin.write(b"y" * 20000)  # no newline yet: one error, then the rest is discarded
        session.proc.stdin.flush()
        self.assertEqual(session.recv()["error"], "Request is too large.")
        session.proc.stdin.write(b"y" * 50 + b'\n{"id":5,"op":"nope"}\n')
        session.proc.stdin.flush()
        self.assertEqual((session.recv()["id"]), 5)
        self.assertEqual(session.rpc("register", path="/etc/passwd.csv")["error"],
                         "Attachment must be inside your home directory.")
        self.assertEqual(session.rpc("register", path=7)["error"], "Choose a CSV file inside your home directory.")
        self.assertIsNone(session.proc.poll())

    def test_worst_case_page_stays_inside_the_response_limit(self):
        cell = "\U0001f600" * 90
        meta = self.register("big.csv", to_bytes([["c%d" % i for i in range(30)]] + [[cell] * 30] * 40))
        session = Session(self)
        reply = session.rpc("page", sourceId=meta["sourceId"], page=0, gen=0)
        self.assertTrue(reply["ok"] and reply["cellsTruncated"])
        self.assertLessEqual(len(json.dumps(reply, ensure_ascii=False).encode("utf-8")), src.MAX_RESPONSE)
        self.assertEqual(len(reply["rows"]), 25)

    def test_superseded_view_answers_with_gen_and_the_newer_request_runs(self):
        fixture.write_main(self.home / "s.csv", rows=9000)
        sid = self.register("s.csv")["sourceId"]
        session = Session(self)
        session.send({"id": 1, "op": "view", "sourceId": sid, "sort": 2, "dir": 1, "filter": "", "gen": 1},
                     {"id": 2, "op": "view", "sourceId": sid, "sort": 3, "dir": -1, "filter": "", "gen": 2})
        first, second = session.recv(), session.recv()
        self.assertEqual(first, {"id": 1, "ok": False, "error": "Superseded.", "gen": 1})
        self.assertEqual((second["id"], second["ok"], second["gen"], second["viewRows"]), (2, True, 2, 9000))
        self.assertEqual(session.rpc("page", sourceId=sid, page=0, gen=1)["error"], "Stale view.")

    def test_idle_exit_and_eof_exit(self):
        idle = Session(self, idle=0.4)
        started = time.monotonic()
        self.assertEqual(idle.proc.wait(10), 0)
        self.assertLess(time.monotonic() - started, 5)
        busy = Session(self, idle=0.6)
        meta = self.register("i.csv", "a\n1\n")
        self.assertTrue(busy.rpc("open", sourceId=meta["sourceId"])["ok"])
        asked = time.monotonic()
        self.assertEqual(busy.proc.wait(10), 0)
        self.assertGreaterEqual(time.monotonic() - asked, 0.3)
        eof = Session(self, idle=60)
        eof.proc.stdin.close()
        self.assertEqual(eof.proc.wait(10), 0)

    def test_reads_write_zero_bytes(self):
        fixture.write_main(self.home / "z.csv", rows=3000)
        sid = self.register("z.csv")["sourceId"]
        before = self.tree()
        session = Session(self)
        self.assertTrue(session.rpc("open", sourceId=sid)["ok"])
        self.assertEqual(session.rpc("verify", sourceId=sid)["state"], "ready")
        for gen, (sort, text) in enumerate(((2, ""), (16, "o"), (-1, "x"), (14, ""), (-1, ""))):
            self.assertTrue(session.rpc("view", sourceId=sid, sort=sort, dir=-1, filter=text, gen=gen + 1)["ok"])
            for page in (0, 5, 30):
                self.assertTrue(session.rpc("page", sourceId=sid, page=page, gen=gen + 1)["ok"])
        self.assertTrue(session.rpc("close", sourceId=sid)["ok"])
        self.assertEqual(self.tree(), before)
        session.close()
        self.assertEqual(self.tree(), before)


if __name__ == "__main__":
    unittest.main()
