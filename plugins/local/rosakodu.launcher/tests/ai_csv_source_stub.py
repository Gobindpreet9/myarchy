#!/usr/bin/env python3
"""Offline stand-in for `ai_csv_source.py --root <root> --serve`.

Follows the frozen line protocol (one JSON object per line, ids echoed, strict
order, static errors, <= 8 KiB requests, worker exits 0 on EOF and after
LAUNCHER_CSV_IDLE seconds, default 30) over an in-memory fake source. It never
opens a file, a provider or a subprocess: behaviour comes only from the
register path's BASENAME, and the source id encodes it so a restarted stub
can re-open any id it handed out.

  rows<N>   row count (default 60)         wide      25 columns (20 shown)
  progress  3 progress events first        slow      register sleeps 0.3 s
  hang      register never answers         crash     register exits 3
  quit      register exits 0 unanswered
  error     register fails (allowlisted)   evil      register fails (hostile text)
  badmeta   register replies ok with a valid sourceId but an invalid meta (the client must reject it)
  pagehang  page 0 never answers           pagecrash page 7 exits 3
  badwidth  page rows are one cell short   badcell   page holds a lone surrogate
  changed / gone / nocopy                  verify reports originChanged / originMissing / copyMissing
Like the real worker, a filtered or sorted view answers Superseded when ANY
request is already queued behind it. View filters: "slow" delays that view 0.3 s
before it checks;
"wronggen" answers the wrong generation. Helper modes --check-alive/--check-gone
inspect one known PID only (never PID 0 or a name scan).
"""
import json
import os
import re
import select
import sys
import time

PAGE = 25
FLAGS = {"pagehang": 1, "pagecrash": 2, "badwidth": 4, "badcell": 8, "wide": 16,
         "changed": 32, "gone": 64, "nocopy": 128}
STATES = {32: "originChanged", 64: "originMissing", 128: "copyMissing"}
BASE = ["id", "city", "amount", "day"]
EVIL = "SECRET /scratch/private/.ssh/id_rsa <script>"


def emit(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def hang():
    """Never answer; end when the parent goes away (stdin EOF) so no orphan stays."""
    while os.read(0, 65536):
        pass
    os._exit(0)


def columns(flags):
    return BASE + ["extra%d" % k for k in range(21)] if flags & 16 else list(BASE)


def cell(row, col, flags):
    if col == 0:
        return str(row)
    if col == 1:
        return "City%d" % (row % 7)
    if col == 2:
        return str(row * 10 % 997)
    if col == 3:
        return "2024-%02d-%02d" % (row % 12 + 1, row % 28 + 1)
    return "x%d" % row


def stats(rows, flags):
    out = []
    for col, name in enumerate(columns(flags)[:20]):
        kind = {0: "number", 2: "number", 3: "date"}.get(col, "text")
        values = [cell(r, col, flags) for r in range(1, min(rows, 500) + 1)]
        nums = [float(v) for v in values] if kind == "number" else []
        out.append({
            "name": name, "nonEmpty": rows, "empty": 0,
            "typeCounts": {"number": rows if kind == "number" else 0, "date": rows if kind == "date" else 0,
                           "text": rows if kind == "text" else 0, "unsure": 0},
            "inferredType": kind if rows else "empty",
            "min": min(nums) if nums else None, "max": max(nums) if nums else None,
            "sum": sum(nums) if nums else None, "mean": sum(nums) / len(nums) if nums else None,
            "distinct": len(set(values)), "distinctExact": rows <= 500,
            "minLength": min(map(len, values)) if values else None,
            "maxLength": max(map(len, values)) if values else None})
    return out


def source_id(rows, flags):
    return "src-%08x%08x" % (rows, flags)


def decode(sid):
    if not isinstance(sid, str) or not re.fullmatch(r"src-[0-9a-f]{16}", sid):
        return None
    rows, flags = int(sid[4:12], 16), int(sid[12:], 16)
    return (rows, flags) if rows <= 1000000 and flags < 256 else None


def meta(rid, rows, flags):
    cols = columns(flags)
    return {"id": rid, "ok": True, "sourceId": source_id(rows, flags), "rows": rows,
            "columnCount": len(cols), "columns": cols[:20], "bytes": rows * 24 + 16, "stats": stats(rows, flags)}


def well_formed(op, request, width):
    def integer(key, low):
        return type(request.get(key)) is int and request[key] >= low
    if op == "page":
        return integer("page", 0) and integer("gen", 0)
    return (integer("gen", 0) and integer("sort", -1) and request["sort"] < width
            and request.get("dir") in (1, -1) and isinstance(request.get("filter"), str)
            and len(request["filter"]) <= 200)


class Stub:
    def __init__(self):
        self.opened = {}   # sourceId -> {"gen": int, "view": [source rows]}
        self.buffer = b""
        self.eof = False
        self.idle = float(os.environ.get("LAUNCHER_CSV_IDLE") or 30)

    def fill(self, timeout):
        """Read whatever is available; True when the pipe delivered bytes."""
        if self.eof:
            return False
        ready, _, _ = select.select([0], [], [], timeout)
        if not ready:
            return False
        chunk = os.read(0, 65536)
        if not chunk:
            self.eof = True
            return False
        self.buffer += chunk
        return True

    def pending(self):
        """Complete requests already waiting behind the current one."""
        while self.fill(0):
            pass
        found = []
        for raw in self.buffer.split(b"\n")[:-1]:
            try:
                found.append(json.loads(raw))
            except ValueError:
                pass
        return found

    def next_line(self):
        deadline = time.monotonic() + self.idle
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if self.eof or remaining <= 0:
                return None
            self.fill(remaining)
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def register(self, request):
        rid = request["id"]
        path = request.get("path")
        if not isinstance(path, str) or not path.startswith("/"):
            return emit({"id": rid, "ok": False, "error": "Choose a CSV file inside your home directory."})
        name = os.path.basename(path).lower()
        if "hang" in name and "page" not in name:
            hang()
        if "crash" in name and "page" not in name:
            os._exit(3)
        if "quit" in name:
            os._exit(0)
        if "evil" in name:
            return emit({"id": rid, "ok": False, "error": EVIL})
        if "error" in name:
            return emit({"id": rid, "ok": False, "error": "Attachment is unavailable or is a symbolic link."})
        found = re.search(r"rows(\d+)", name)
        rows = min(int(found.group(1)), 1000000) if found else 60
        flags = sum(bit for key, bit in FLAGS.items() if key in name)
        if "progress" in name:
            for step in (1, 2, 3):
                emit({"id": rid, "event": "progress", "rows": rows * step // 3})
                time.sleep(0.05)
        if "slow" in name:
            time.sleep(0.3)
        self.opened[source_id(rows, flags)] = {"gen": 0, "total": rows, "view": list(range(1, rows + 1))}
        reply = meta(rid, rows, flags)
        if "badmeta" in name:
            reply["columnCount"] = 0
        emit(reply)

    def open(self, request):
        decoded = decode(request.get("sourceId"))
        if decoded is None:
            return emit({"id": request["id"], "ok": False, "error": "Invalid source id."})
        self.opened[request["sourceId"]] = {"gen": 0, "total": decoded[0], "view": list(range(1, decoded[0] + 1))}
        emit(meta(request["id"], *decoded) | {"sourceId": request["sourceId"]})

    def view(self, request, state, flags):
        rid, gen = request["id"], request["gen"]
        filt = request["filter"].lower()
        if "slow" in filt:
            time.sleep(0.3)
        if (filt or request["sort"] >= 0) and self.pending():
            return emit({"id": rid, "ok": False, "error": "Superseded.", "gen": gen})
        rows = [r for r in range(1, state["total"] + 1)
                if not filt or any(filt in cell(r, c, flags).lower() for c in range(len(columns(flags)[:20])))]
        sort = request["sort"]
        if sort >= 0:
            numeric = sort in (0, 2)
            rows.sort(key=lambda r: (int(cell(r, sort, flags)) if numeric else cell(r, sort, flags), r),
                      reverse=request["dir"] < 0)
        state["gen"], state["view"], state["filter"] = gen, rows, filt
        emit({"id": rid, "ok": True, "gen": gen + 5 if "wronggen" in filt else gen, "viewRows": len(rows)})

    def page(self, request, state, flags):
        rid, gen, page = request["id"], request["gen"], request["page"]
        if gen != state["gen"]:
            return emit({"id": rid, "ok": False, "error": "Stale view.", "gen": gen})
        if (flags & 1) and page == 0:
            hang()
        if (flags & 2) and page == 7:
            os._exit(3)
        view = state["view"]
        chunk = view[page * PAGE:(page + 1) * PAGE]
        width = len(columns(flags)[:20])
        rows = [[cell(r, c, flags) for c in range(width)] for r in chunk]
        if flags & 4 and rows:
            rows[0] = rows[0][:-1]
        if flags & 8 and rows:
            rows[0][1] = "bad\ud800"
        emit({"id": rid, "ok": True, "gen": gen, "page": page, "pageSize": PAGE,
              "pageCount": -(-len(view) // PAGE), "viewRows": len(view),
              "firstRow": chunk[0] if chunk else 0, "rows": rows, "cellsTruncated": False})

    def handle(self, raw):
        if len(raw) > 8192:
            return emit({"id": -1, "ok": False, "error": "Request is too large."})
        try:
            request = json.loads(raw)
        except ValueError:
            return emit({"id": -1, "ok": False, "error": "Request needs an integer id."})
        rid = request.get("id") if isinstance(request, dict) else None
        if not isinstance(rid, int):
            return emit({"id": -1, "ok": False, "error": "Request needs an integer id."})
        op = request.get("op")
        if op == "register":
            return self.register(request)
        if op == "open":
            return self.open(request)
        decoded = decode(request.get("sourceId"))
        if op == "verify":
            if decoded is None:
                return emit({"id": rid, "ok": False, "error": "Invalid source id."})
            return emit({"id": rid, "ok": True, "state": STATES.get(decoded[1] & 224, "ready")})
        state = self.opened.get(request.get("sourceId")) if decoded else None
        if op == "close":
            self.opened.pop(request.get("sourceId"), None)
            return emit({"id": rid, "ok": True})
        if op not in ("view", "page"):
            return emit({"id": rid, "ok": False, "error": "Unknown operation."})
        if state is None:
            return emit({"id": rid, "ok": False, "error": "Invalid source id."})
        if not well_formed(op, request, len(columns(decoded[1])[:20])):
            return emit({"id": rid, "ok": False, "error": "Invalid %s request." % op})
        (self.view if op == "view" else self.page)(request, state, decoded[1])

    def serve(self):
        while True:
            raw = self.next_line()
            if raw is None:
                return
            self.handle(raw)


def check_helper(mode, value):
    """Bounded check of one known PID, never a process-name scan."""
    if not value.isdecimal() or not 0 < int(value) <= 2 ** 31 - 1:
        raise SystemExit("A positive captured helper PID is required")
    pid = int(value)
    if mode == "--check-alive":
        command = open("/proc/%d/cmdline" % pid, "rb").read().rstrip(b"\0").split(b"\0")
        if os.path.abspath(__file__).encode() not in command:
            raise SystemExit("Captured PID is not the known stub worker")
        print("known worker alive", flush=True)
        return
    deadline = time.monotonic() + 2
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            print("known worker gone", flush=True)
            return
        if time.monotonic() >= deadline:
            raise SystemExit("Destroyed source left its worker process alive")
        time.sleep(0.02)


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] in ("--check-alive", "--check-gone"):
        return check_helper(*args)
    if "--serve" not in args:
        raise SystemExit("usage: ai_csv_source_stub.py --root <root> --serve")
    Stub().serve()


if __name__ == "__main__":
    main()
