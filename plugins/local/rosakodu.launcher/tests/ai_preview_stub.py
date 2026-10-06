"""Offline preview lifecycle stub; never imports a broker or runs a provider.

Normal (including timeout) mode uses only stdin and synthetic responses, never
opens the requested path. Explicit --fixtures/--replace modes write synthetic
CSV fixtures only into an isolated /tmp/opencode scratch HOME. Explicit helper
checks inspect only a captured positive PID; they never signal PID 0.
"""
import json
import os
from pathlib import Path
import sys
import time


def fixtures(replace=False):
    home = Path(os.environ["HOME"])
    if not str(home).startswith("/tmp/opencode/ai-preview-check-"):
        raise SystemExit("A dedicated scratch HOME is required")
    home.mkdir(parents=True, exist_ok=True)
    rows = [("Oslo", "1200"), ("Porto", "600"), ("Lisbon", "900"),
            ("Paris", "1400"), ("Riga", "700"), ("Rome", "1100"),
            ("Tallinn", "800"), ("Vienna", "1000")]
    if replace:
        rows[0] = ("Changed", "42")
    (home / "rents.csv").write_text("City,Rent\n" + "".join(f"{a},{b}\n" for a, b in rows), encoding="utf-8")
    (home / "malformed.csv").write_text("City,Rent\nParis,1400,extra\n", encoding="utf-8")
    print("fixtures ready", flush=True)


def main():
    if len(sys.argv) > 1:
        mode = sys.argv[1]
        if mode in ("--fixtures", "--replace"):
            fixtures(mode == "--replace")
        elif mode in ("--check-alive", "--check-gone"):
            check_helper(mode, sys.argv[2])
        else:
            raise SystemExit("Unknown test mode")
        return
    request = json.loads(sys.stdin.readline(8193))
    token = request["token"]
    name = request["path"].rsplit("/", 1)[-1]
    if name == "timeout.csv":
        # No requested-file access, marker writes, provider import or subprocess.
        time.sleep(60)
        return
    if name == "delayed.csv":
        time.sleep(0.6)
    if name == "malformed-json.csv":
        print("{not JSON", flush=True)
        return
    if name == "oversized.csv":
        print("x" * 32769, flush=True)
        return
    if name == "unterminated.csv":
        sys.stdout.write("x" * 32769)
        sys.stdout.flush()
        time.sleep(60)
        return
    preview = {"kind": "csv", "columns": ["token"], "rows": [[str(token)]],
               "previewRows": 1, "sampleRows": 1, "columnCount": 1,
               "totalRows": 1, "columnsTruncated": False, "cellsTruncated": False,
               "truncated": False, "note": "Synthetic local preview."}
    allowed = {"HOME", "PATH", "PYTHONDONTWRITEBYTECODE", "XDG_STATE_HOME", "LC_CTYPE"}
    if set(os.environ) - allowed or os.environ.get("PATH") != "/usr/bin:/bin":
        print(json.dumps({"token": token, "ok": False, "error": "Environment was not isolated"}), flush=True)
        return
    if name == "invalid-cell.csv":
        preview["rows"] = [[42]]
    if name == "invalid-meta.csv":
        preview["sampleRows"] = 201
    if name == "invalid-shape.csv":
        preview["rows"] = [["one", "two"]]
    if name == "invalid-limit.csv":
        preview["rows"] = [["value"]] * 11
        preview["previewRows"] = 11
    if name == "invalid-unknown-total.csv":
        preview["totalRows"] = None
    if name == "invalid-cell-truncation.csv":
        preview["cellsTruncated"] = True
    if name == "invalid-row-truncation.csv":
        preview["totalRows"] = 2
    if name == "invalid-spurious-truncation.csv":
        preview["truncated"] = True
    if name == "invalid-preview-prefix.csv":
        preview.update(sampleRows=200, totalRows=200)
    if name == "invalid-column-prefix.csv":
        preview["columnCount"] = 2
    if name == "invalid-column-flag.csv":
        preview.update(columnCount=21, columns=["token"] * 20,
                       rows=[[str(token)] * 20], truncated=True)
    if name == "invalid-spurious-column-flag.csv":
        preview.update(columnsTruncated=True, truncated=True)
    if name == "invalid-column-truncation.csv":
        preview.update(columnCount=21, columns=["token"] * 20,
                       rows=[[str(token)] * 20], columnsTruncated=True)
    if name == "invalid-high-surrogate.csv":
        preview["rows"] = [["\ud800"]]
    if name == "invalid-low-surrogate.csv":
        preview["rows"] = [["\udc00"]]
    if name == "invalid-header-surrogate.csv":
        preview["columns"] = ["\ud800x"]
    if name == "invalid-emoji-limit.csv":
        preview["rows"] = [["💡" * 81]]
    if name == "invalid-note.csv":
        preview["note"] = "n" * 301
    if name == "emoji-limit.csv":
        preview.update(columns=["💡" * 80], rows=[["💡" * 80]])
    if name == "sample-prefix.csv":
        preview.update(rows=[[str(token)]] * 10, previewRows=10,
                       sampleRows=200, totalRows=200)
    if name == "valid-truncation.csv":
        preview.update(columns=["token"] * 20, rows=[[str(token)] * 20],
                       columnCount=21, columnsTruncated=True, cellsTruncated=True,
                       totalRows=None, truncated=True)
    if name == "stale.csv":
        print(json.dumps({"token": token - 1, "ok": False, "error": "stale token"}), flush=True)
        print(json.dumps({"token": token, "path": "/wrong.csv", "ok": False, "error": "stale path"}), flush=True)
    if name == "unicode-chunk.csv":
        preview["rows"] = [["ü💡"]]
        line = (json.dumps({"token": token, "ok": True, "preview": preview}, ensure_ascii=False) + "\n").encode("utf-8")
        boundary = line.index("💡".encode("utf-8")) + 1
        sys.stdout.buffer.write(line[:boundary])
        sys.stdout.buffer.flush()
        time.sleep(0.03)
        sys.stdout.buffer.write(line[boundary:])
        sys.stdout.buffer.flush()
        return
    print(json.dumps({"token": token, "ok": True, "preview": preview}), flush=True)
    if name == "double.csv":
        print(json.dumps({"token": token, "ok": False, "error": "CSV preview is unavailable."}), flush=True)
        raise SystemExit(1)


def check_helper(mode, value):
    """Bounded check of one known PID, not a process-name or provider scan."""
    if not value.isdecimal() or not 0 < int(value) <= 2 ** 31 - 1:
        raise SystemExit("A positive captured helper PID is required")
    pid = int(value)
    if mode == "--check-alive":
        command = Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0").split(b"\0")
        expected = [b"/usr/bin/python3", b"-B", b"-u", str(Path(__file__).resolve()).encode()]
        if command != expected:
            raise SystemExit("Captured PID is not the known preview helper")
        print("known helper alive", flush=True)
        return
    deadline = time.monotonic() + 2
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            print("known helper gone", flush=True)
            return
        if time.monotonic() >= deadline:
            raise SystemExit("Destroyed reader left its helper process alive")
        time.sleep(0.02)


if __name__ == "__main__":
    main()
