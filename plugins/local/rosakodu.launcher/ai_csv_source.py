"""Durable CSV source worker: copy once on explicit registration, then page it.

`python3 ai_csv_source.py --root <stateRoot> --serve` answers one JSON object
per line, strictly in order (request <= 8 KiB, response <= 256 KiB, every
request carries an integer `id`). Errors are static strings; stderr is silent
and file contents are never logged or echoed. Registering is the ONLY write
this worker does: a verbatim private copy (data.csv), an index of every 64th
record (index.bin) and meta.json under <stateRoot>/sources/src-<16 hex>/.
Paging, sorting, filtering and idling write nothing. A source is complete
(within the caps below) or does not exist. The caller supplies a clean
environment; the worker spawns nothing and imports no provider code.

Behaviour the caller must know. (1) A `view` build is aborted with
`{"ok":false,"error":"Superseded.","gen":n}` when ANY newer request is already
waiting (page, verify, close, another view...), checked every 4,096 rows: send
the next request only after the view reply unless you mean to supersede it.
(2) `page` must carry the `gen` of the latest successful view (0 before any
view, which is the identity view); otherwise it answers "Stale view." with that
gen. `open` keeps a live view. (3) Per-column stats: min/max/sum/mean are null
unless every non-empty cell is a plain number (dates: unambiguous ISO without
a zone); distinct/distinctExact/minLength/maxLength are null unless the
column's inferredType is "text"; distinct stops at 1,000 (distinctExact
false). meta.json `columns` equals the stats names (sanitized, <= 40 chars).
`--reap-sources` lists sources and stale temp dirs (dry run); `--apply
--expect-count N` removes ONLY stale `.tmp-*` dirs, never a complete source.
(4) Blank physical lines are not data and are dropped (they do not count as
rows). A SINGLE-column file therefore cannot hold an empty value: an empty cell
is a blank line and disappears; use a quoted "" to keep one. Blank lines still
count as lines for the register progress timer and for the view supersede
cadence, so a flood of them (8 MiB of newlines costs about 1.8 s) still reports
progress and still yields to a newer request. (5) The view filter has its
control characters (below U+0020 and U+007F) removed before matching, because
cells are joined with \\x01 and a filter must never match across a boundary;
a filter that becomes empty is no filter.
"""
import array
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import stat
import sys
import time

MAX_BYTES = 64 << 20
MAX_ROWS = 500_000
MAX_LINE = 1 << 20
SORT_MAX_ROWS = 250_000
PAGE_SIZE = 25
CHECKPOINT = 64
SHOWN = 20
CELL_CHARS = 80
STAT_NAME_CHARS = 40
DISTINCT_CAP = 1000
CHUNK_ROWS = 4096
PROGRESS_SECONDS = 0.25
MAX_REQUEST = 8192
MAX_RESPONSE = 256 * 1024
META_LIMIT = 32 * 1024
IDLE_SECONDS = 30.0
TMP_STALE = 3600
CACHE_SOURCES = 8
MAX_ORIGIN = 1024

SOURCE_ID = re.compile(r"src-[0-9a-f]{16}")
TMP_NAME = re.compile(r"\.tmp-[0-9a-f]{16}")
FILES = ("data.csv", "index.bin", "meta.json")
BINARY = re.compile(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]")
NOATIME = getattr(os, "O_NOATIME", 0)

# Messages that may cross the boundary: the sampler's readable CSV errors and
# the guarded opener's, plus this module's own. Nothing else is ever echoed.
GUARD_ERRORS = frozenset({
    "Choose a text file inside your home directory.",
    "Attachment must be inside your home directory.",
    "Invalid attachment path.",
    "Credential and secret files cannot be attached.",
    "Attachment is unavailable or is a symbolic link.",
})
E_CSV_ONLY = "Only explicit .csv files can be copied."
E_REGULAR = "Only regular files can be copied."
E_CHANGED = "File changed while reading; try again."
E_BYTES = "CSV is larger than 64 MiB."
E_ROWS = "CSV has more than 500,000 rows."
E_LINE = "CSV has a line longer than 1 MiB."
E_BINARY = "Attachment is binary."
E_UTF8 = "Attachment must be UTF-8 text."
E_EMPTY = "CSV attachment is empty."
E_HEADER = "CSV header could not be parsed."
E_NO_HEADER = "CSV attachment has no header row."
E_PATH = "Choose a CSV file with a shorter path."
E_STORE = "Could not store the CSV copy."
E_ID = "Invalid source id."
E_MISSING = "Source copy is missing."
E_DAMAGED = "Source copy is damaged."
E_UNSAFE = "Source storage is unsafe."
E_STALE = "Stale view."
E_SUPERSEDED = "Superseded."
E_SORT_CAP = "Too many rows to sort; filter first."
E_TOO_LARGE = "Response is too large."
E_GENERIC = "CSV source is unavailable."


class Refuse(Exception):
    """A static, user-readable refusal; `extra` carries optional response fields."""

    def __init__(self, message, **extra):
        super().__init__(message)
        self.extra = extra


def _parse_error(line):
    return "CSV could not be parsed near line %d (invalid quotes or oversized field)." % line


# ---------------------------------------------------------------- classifier
# Python mirror of CsvTypes.classifyCell/inferCells. Same conservative rules:
# only a plain decimal point is a number; separators, currency, spaces and
# brackets are "ambNumber"; leading zeros and >15-digit integers are codes;
# day/month order is read only from evidence. tests/csv_type_golden.json is
# the shared table that keeps the two implementations in step.
_WS = "\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a" \
      "\u2028\u2029\u202f\u205f\u3000\ufeff"  # JavaScript trim() set, not str.isspace()
_WSC = r"[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]"
_CUR = "[$€£¥₹₩₽¢₪₺฿₫₴₦]"
_PLAIN = re.compile(r"[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?", re.A)
_PERCENT = re.compile(r"[+-]?(?:\d+(?:\.\d+)?|\.\d+)%", re.A)
_AMB = re.compile(r"\(?[+-]?(?:(?:" + _CUR + r"|[A-Z]{3})" + _WSC + r"?)?\d[\d.,  '’ ]*"
                  r"(?:" + _WSC + r"?(?:" + _CUR + r"|[A-Z]{3}))?%?\)?", re.A)
_ISO = re.compile(r"(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?"
                  r"(Z|[+-]\d{2}:?\d{2})?)?", re.A)
_YEAR_FIRST = re.compile(r"(\d{4})([/.])(\d{1,2})\2(\d{1,2})", re.A)
_PARTS = re.compile(r"(\d{1,2})([/.\-])(\d{1,2})\2(\d{2}|\d{4})", re.A)
_START = frozenset("0123456789+-.(" + _CUR[1:-1])
# Fast path for a whole column chunk: possessive, linear, a strict subset of
# the plain numbers (15 digits, no leading zero) so the slow path decides the rest.
_SHAPE = r"[+-]?+(?:(?:0|[1-9]\d{0,14}+)(?:\.\d++)?+|\.\d++)(?:[eE][+-]?+\d++)?+"
_ALL_NUMBERS = re.compile(r"(?:(?:" + _SHAPE + r")?+\n)*+(?:" + _SHAPE + r")?+", re.A)
KINDS = ("empty", "number", "percent", "code", "ambNumber", "iso", "dmy", "mdy", "amb", "either", "text")
_ISO_ZERO_FRACTION = "000000000"


def _leap(year):
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0


def _valid_day(day, month, year):
    if not 1 <= month <= 12 or day < 1:
        return False
    if month == 2:
        return day <= (29 if year is None or _leap(year) else 28)
    return day <= (30 if month in (4, 6, 9, 11) else 31)


def _classify_date(s):
    """-> (kind, payload) or ("", None) when the cell is not date-shaped."""
    m = _ISO.fullmatch(s)
    if m:
        y, mo, d = int(m[1]), int(m[2]), int(m[3])
        if y < 1 or not _valid_day(d, mo, y):
            return "text", None
        if m[4] is not None and (int(m[4]) > 23 or int(m[5]) > 59 or (m[6] is not None and int(m[6]) > 59)):
            return "text", None
        key = (y, mo, d, int(m[4] or 0), int(m[5] or 0), int(m[6] or 0), (m[7] or ".")[1:].ljust(9, "0"))
        return "iso", (key, s, m[8] is not None)
    m = _YEAR_FIRST.fullmatch(s)
    if m:
        y, mo, d = int(m[1]), int(m[3]), int(m[4])
        return ("iso", ((y, mo, d, 0, 0, 0, _ISO_ZERO_FRACTION), s, False)) if _valid_day(d, mo, y) else ("text", None)
    m = _PARTS.fullmatch(s)
    if not m:
        return "", None
    a, b = int(m[1]), int(m[3])
    year = int(m[4]) if len(m[4]) == 4 else None
    if a == 0 or b == 0 or a > 31 or b > 31:
        return "text", None
    if a == b and a <= 12:
        return "either", None
    if a > 12 and b <= 12:
        return ("dmy" if _valid_day(a, b, year) else "text"), None
    if b > 12 and a <= 12:
        return ("mdy" if _valid_day(b, a, year) else "text"), None
    return ("amb" if a <= 12 and b <= 12 else "text"), None


_TEXT, _EMPTY = ("text", None), ("empty", None)
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def clean_cell(cell):
    """The ONE cleaning step shared by classification, stats and numeric sort keys."""
    return cell.strip(_WS)


def numeric_key(cell):
    """Sort key of a cell the stats counted as a number (classify's own float), else None."""
    kind, value = classify(cell)
    return value if kind == "number" else None


def classify(cell):
    """One cell -> (kind, payload); payload is a float for numbers, an ISO key for iso."""
    n = len(cell)
    # JavaScript counts UTF-16 units; code points can only undercount.
    if n > 160 or (n > 80 and len(cell.encode("utf-16-le")) > 320):
        return _TEXT
    s = clean_cell(cell)
    if not s:
        return _EMPTY
    c = s[0]
    if c not in _START and not ("A" <= c <= "Z" and s[:3].isalpha() and s[:3].isupper() and s[:3].isascii()):
        return _TEXT  # no rule below can match this start
    if _PLAIN.fullmatch(s):
        digits = s[1:] if s[0] in "+-" else s
        if digits[0] == "0" and len(digits) > 1 and digits[1].isdigit():
            return "code", None
        if digits.isdigit() and len(digits) > 15:
            return "code", None
        value = float(s)
        return ("number", value) if math.isfinite(value) else _TEXT
    if _PERCENT.fullmatch(s):
        return "percent", None
    kind, payload = _classify_date(s)
    if kind:
        return kind, payload
    if _AMB.fullmatch(s):
        return "ambNumber", None
    return _TEXT


def infer_type(counts):
    """Whole-column outcome from per-kind counts (CsvTypes.inferCells, type only)."""
    g = counts.get
    if sum(counts.values()) - g("empty", 0) == 0:
        return "empty"
    dates = g("iso", 0) + g("dmy", 0) + g("mdy", 0) + g("amb", 0) + g("either", 0)
    numeric = g("number", 0) + g("percent", 0) + g("ambNumber", 0)
    if g("text", 0) or g("code", 0):
        return "text"
    if numeric and dates:
        return "text"
    if numeric:
        return "unsure" if g("ambNumber", 0) or (g("percent", 0) and g("number", 0)) else "number"
    if g("dmy", 0) and g("mdy", 0):
        return "unsure"
    if g("dmy", 0) or g("mdy", 0):
        return "date"
    return "unsure" if g("amb", 0) else "date"


def _neumaier(s, c, values):
    for x in values:
        t = s + x
        c += ((s - t) + x) if abs(s) >= abs(x) else ((x - t) + s)
        s = t
    return s, c


def _number(x):
    if x is None or not math.isfinite(x) or abs(x) > 1e300:  # the broker rejects larger values
        return None
    return int(x) if x.is_integer() and abs(x) < 2 ** 53 else x


def _stat_name(name):
    from ai_broker import _column_name  # same sanitizer as the model prompt
    text = _column_name(name)
    return text if len(text) <= STAT_NAME_CHARS else text[:STAT_NAME_CHARS - 1] + "…"


class ColumnStats:
    """Streaming exact statistics for one displayed column, fed in row chunks."""

    def __init__(self):
        self.k = dict.fromkeys(KINDS, 0)
        self.fast = True      # only plain numbers and empties seen so far
        self.lo = self.hi = None
        self.s = self.c = 0.0
        self.dlo = self.dhi = None
        self.tz = False
        self.seen, self.capped = set(), False
        self.minlen = self.maxlen = None
        self.cache = {}

    def feed(self, cells):
        if self.fast:
            joined = "\n".join(cells)
            if _ALL_NUMBERS.fullmatch(joined) and joined.count("\n") == len(cells) - 1:
                kept = list(filter(None, cells))
                values = list(map(float, kept))
                if not values or (min(values) > -math.inf and max(values) < math.inf):
                    self.k["number"] += len(kept)
                    self.k["empty"] += len(cells) - len(kept)
                    self._numbers(values)
                    self._track(kept)
                    return
        kept, numbers, k, cache = [], [], self.k, self.cache
        for cell in cells:
            hit = cache.get(cell)
            if hit is None:
                hit = classify(cell)
                if len(cell) <= 64:
                    if len(cache) >= 4096:
                        cache.clear()
                    cache[cell] = hit
            kind, payload = hit
            k[kind] += 1
            if kind == "empty":
                continue
            kept.append(cell)
            if kind == "number":
                numbers.append(payload)
            else:
                self.fast = False
                if kind == "iso":
                    key, text, tz = payload
                    self.tz |= tz
                    if self.dlo is None or key < self.dlo[0]:
                        self.dlo = (key, text)
                    if self.dhi is None or key > self.dhi[0]:
                        self.dhi = (key, text)
        self._numbers(numbers)
        self._track(kept)

    def _numbers(self, values):
        if values:
            lo, hi = min(values), max(values)
            self.lo = lo if self.lo is None else min(self.lo, lo)
            self.hi = hi if self.hi is None else max(self.hi, hi)
            self.s, self.c = _neumaier(self.s, self.c, values)

    def _track(self, kept):
        if not kept:
            return
        lengths = list(map(len, kept))
        lo, hi = min(lengths), max(lengths)
        self.minlen = lo if self.minlen is None else min(self.minlen, lo)
        self.maxlen = hi if self.maxlen is None else max(self.maxlen, hi)
        if not self.capped:
            self.seen.update(kept)
            if len(self.seen) > DISTINCT_CAP:
                self.capped, self.seen = True, set()

    def result(self, name):
        k = self.k
        nonempty = sum(k.values()) - k["empty"]
        inferred = infer_type(k)
        out = {"name": name, "nonEmpty": nonempty, "empty": k["empty"],
               "typeCounts": {"number": k["number"],
                              "date": k["iso"] + k["dmy"] + k["mdy"] + k["either"],
                              "text": k["text"] + k["code"],
                              "unsure": k["amb"] + k["percent"] + k["ambNumber"]},
               "inferredType": inferred, "min": None, "max": None, "sum": None, "mean": None,
               "distinct": None, "distinctExact": None, "minLength": None, "maxLength": None}
        if nonempty and k["number"] == nonempty:
            total = self.s + self.c
            out.update(min=_number(self.lo), max=_number(self.hi), sum=_number(total),
                       mean=_number(total / nonempty))
        elif nonempty and k["iso"] == nonempty and not self.tz:
            out.update(min=self.dlo[1], max=self.dhi[1])
        if inferred == "text":
            out.update(distinct=DISTINCT_CAP if self.capped else len(self.seen),
                       distinctExact=not self.capped, minLength=self.minlen, maxLength=self.maxlen)
        return out


# ------------------------------------------------------------- record source
class Lines:
    """Binary line source for csv.reader that tracks the byte offset.

    Lines end at \\n, \\r or \\r\\n (what io.StringIO(newline="") gives the
    broker's sampler). csv.reader pulls exactly the lines of the record it is
    returning, so `pos` after next(reader) is the record boundary
    (tests pin this). Strict UTF-8 and the no-control-bytes rule apply per line.
    """

    def __init__(self, stream, pos=0):
        self.stream, self.pos, self.bom = stream, pos, pos == 0

    def __iter__(self):
        stream = self.stream
        while True:
            raw = stream.readline(MAX_LINE + 1)
            if not raw:
                return
            parts = raw.splitlines(True)
            if len(raw) > MAX_LINE and len(parts) > 1:
                stream.seek(-len(parts[-1]), os.SEEK_CUR)  # incomplete tail: read it again
                parts.pop()
            for part in parts:
                if len(part) > MAX_LINE:
                    raise Refuse(E_LINE)
                if BINARY.search(part):
                    raise Refuse(E_BINARY)
                try:
                    text = part.decode("utf-8")
                except UnicodeError:
                    raise Refuse(E_UTF8) from None
                if self.bom:
                    self.bom, text = False, text.removeprefix("\ufeff")
                self.pos += len(part)
                yield text


def _private_open(dir_fd, name, flags, mode=0o600):
    try:
        return os.open(name, flags | NOATIME, mode, dir_fd=dir_fd)
    except PermissionError:
        return os.open(name, flags, mode, dir_fd=dir_fd)  # O_NOATIME needs ownership


def _open_dir(parent_fd, name):
    fd = _private_open(parent_fd, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise Refuse(E_UNSAFE)
    return fd


def _open_root(root, create=False):
    root = str(root)
    if not os.path.isabs(root):
        raise Refuse(E_UNSAFE)
    if create:
        os.makedirs(root, 0o700, exist_ok=True)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(fd)
        raise Refuse(E_UNSAFE)
    return fd


def _open_sources(root, create=False):
    """fd of <root>/sources: no symlinks, ours, private; created only when asked."""
    root_fd = _open_root(root, create)
    try:
        if create:
            try:
                os.mkdir("sources", 0o700, dir_fd=root_fd)
            except FileExistsError:
                pass
        return _open_dir(root_fd, "sources")
    finally:
        os.close(root_fd)


def _write_file(dir_fd, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    finally:
        os.close(fd)


def _unlink_tmp(sources_fd, name):
    """Remove one temp dir holding only the known source files; never recursive."""
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=sources_fd)
    try:
        entries = os.listdir(fd)
        if any(entry not in FILES for entry in entries):
            raise Refuse(E_UNSAFE)
        for entry in entries:
            os.unlink(entry, dir_fd=fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=sources_fd)


# ------------------------------------------------------------------ register
def _scan(stream, progress):
    """One record-by-record pass over the copy: validate, index, and gather stats."""
    lines = Lines(stream)
    reader = csv.reader(lines, strict=True)
    try:
        header = next(reader)
    except StopIteration:
        raise Refuse(E_EMPTY) from None
    except csv.Error:
        raise Refuse(E_HEADER) from None
    if not any(cell[:CELL_CHARS].strip() for cell in header[:SHOWN]):
        raise Refuse(E_NO_HEADER)
    width, shown = len(header), min(SHOWN, len(header))
    columns = [ColumnStats() for _ in range(shown)]
    offsets, chunk, rows, start = array.array("Q"), [], 0, lines.pos
    last, seen = time.monotonic(), 0

    def tick():
        nonlocal last
        now = time.monotonic()
        if progress and now - last >= PROGRESS_SECONDS:
            progress(rows)
            last = now

    def flush():
        for column, cells in zip(columns, zip(*chunk)):
            column.feed(cells)
        chunk.clear()

    while True:
        try:
            row = next(reader)
        except StopIteration:
            break
        except csv.Error:
            raise Refuse(_parse_error(reader.line_num)) from None
        seen += 1
        if not row:  # blank physical lines are not data, but they still count as lines
            start = lines.pos
            if seen % CHUNK_ROWS == 0:
                tick()
            continue
        if len(row) != width:
            raise Refuse("CSV line %d has %d columns; the header has %d." % (reader.line_num, len(row), width))
        if rows % CHECKPOINT == 0:
            offsets.append(start)
        rows += 1
        if rows > MAX_ROWS:
            raise Refuse(E_ROWS)
        start = lines.pos
        chunk.append(row[:shown])
        if len(chunk) >= CHUNK_ROWS:
            flush()
            tick()
        elif seen % CHUNK_ROWS == 0:
            tick()
    if chunk:
        flush()
    stats = [column.result(_stat_name(header[i])) for i, column in enumerate(columns)]
    # The broker requires columns[i] == stats[i].name, so both carry the sanitized name.
    return {"rows": rows, "columnCount": width, "columns": [item["name"] for item in stats], "stats": stats}, offsets


def _origin_path(name, home):
    home = Path(home or Path.home()).resolve()
    path = Path(os.path.expanduser(name))
    return "/".join((path if path.is_absolute() else home / path).relative_to(home).parts)


def register(root, name, home=None, progress=None):
    """Copy one explicit .csv into a new private source; returns its meta dict."""
    from ai_broker import open_guarded
    if not isinstance(name, str) or not name.lower().endswith(".csv"):
        raise Refuse(E_CSV_ONLY)
    try:
        stream, before, _ = open_guarded(name, home)
        origin = _origin_path(name, home)
    except ValueError as exc:  # the opener's "text file smaller than 64 KiB" means a directory here
        raise Refuse(str(exc) if str(exc) in GUARD_ERRORS else E_REGULAR) from None
    except OSError:
        raise Refuse(E_REGULAR) from None
    if len(origin) > MAX_ORIGIN:
        stream.close()
        raise Refuse(E_PATH)
    sources_fd = tmp_name = tmp_fd = None
    try:
        with stream:
            if not stat.S_ISREG(before.st_mode):
                raise Refuse(E_REGULAR)
            if before.st_size > MAX_BYTES:
                raise Refuse(E_BYTES)
            sources_fd = _open_sources(root, create=True)
            sid = tmp_fd = None
            for _ in range(8):
                sid = os.urandom(8).hex()
                tmp_name = ".tmp-" + sid
                try:
                    os.mkdir(tmp_name, 0o700, dir_fd=sources_fd)
                    break
                except FileExistsError:
                    tmp_name = None
            if tmp_name is None:
                raise Refuse(E_STORE)
            tmp_fd = os.open(tmp_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=sources_fd)
            os.fchmod(tmp_fd, 0o700)
            digest, size = hashlib.sha256(), 0
            out = os.open("data.csv", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=tmp_fd)
            try:
                while True:
                    block = stream.read(1 << 20)
                    if not block:
                        break
                    size += len(block)
                    if size > MAX_BYTES:
                        raise Refuse(E_BYTES)
                    digest.update(block)
                    view = memoryview(block)
                    while view:
                        view = view[os.write(out, view):]
                os.fsync(out)
            finally:
                os.close(out)
            after = os.fstat(stream.fileno())
            if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns) or size != before.st_size:
                raise Refuse(E_CHANGED)
        fd = os.open("data.csv", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=tmp_fd)
        with os.fdopen(fd, "rb", buffering=1 << 16) as copy:
            body, offsets = _scan(copy, progress)
        if sys.byteorder == "big":
            offsets.byteswap()
        meta = {"version": 1, "sourceId": "src-" + sid, "bytes": size, "sha256": digest.hexdigest(), **body,
                "origin": {"path": origin, "size": before.st_size, "mtimeNs": before.st_mtime_ns},
                "state": "ready"}
        blob = json.dumps(meta, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if len(blob) > META_LIMIT:
            raise Refuse(E_STORE)
        _write_file(tmp_fd, "index.bin", offsets.tobytes())
        _write_file(tmp_fd, "meta.json", blob)
        os.fsync(tmp_fd)
        os.rename(tmp_name, "src-" + sid, src_dir_fd=sources_fd, dst_dir_fd=sources_fd)
        tmp_name = None
        os.fsync(sources_fd)
        return meta
    except OSError:
        raise Refuse(E_STORE) from None
    finally:
        if tmp_fd is not None:
            os.close(tmp_fd)
        if tmp_name is not None and sources_fd is not None:
            try:
                _unlink_tmp(sources_fd, tmp_name)
            except (OSError, Refuse):
                pass
        if sources_fd is not None:
            os.close(sources_fd)


# --------------------------------------------------------------- read helpers
def _text(value, limit):
    return isinstance(value, str) and len(value) <= limit


def _int(value, low=0, high=2 ** 53):
    return type(value) is int and low <= value <= high


def _scalar(value):
    return value is None or isinstance(value, str) or (
        type(value) in (int, float) and math.isfinite(value))


def validate_meta(meta, sid):
    """Strict structure check of meta.json; a malformed file is "damaged"."""
    stat_keys = {"name", "nonEmpty", "empty", "typeCounts", "inferredType", "min", "max", "sum", "mean",
                 "distinct", "distinctExact", "minLength", "maxLength"}
    try:
        ok = (isinstance(meta, dict) and set(meta) == {"version", "sourceId", "bytes", "sha256", "rows",
              "columnCount", "columns", "origin", "stats", "state"} and meta["version"] == 1
              and meta["sourceId"] == sid and meta["state"] == "ready" and _int(meta["bytes"])
              and re.fullmatch(r"[0-9a-f]{64}", meta["sha256"]) and _int(meta["rows"], 0, 2 ** 31)
              and _int(meta["columnCount"], 1, 2 ** 31))
        shown = min(SHOWN, meta["columnCount"]) if ok else 0
        ok = ok and isinstance(meta["columns"], list) and len(meta["columns"]) == shown \
            and all(_text(c, CELL_CHARS) for c in meta["columns"]) \
            and isinstance(meta["stats"], list) and len(meta["stats"]) == shown \
            and all(isinstance(i, dict) and i.get("name") == c for i, c in zip(meta["stats"], meta["columns"])) \
            and all(isinstance(i, dict) and i.get("nonEmpty", -1) + i.get("empty", -1) == meta["rows"]
                    for i in meta["stats"])
        origin = meta["origin"]
        ok = ok and isinstance(origin, dict) and set(origin) == {"path", "size", "mtimeNs"} \
            and _text(origin["path"], MAX_ORIGIN) and origin["path"] and not origin["path"].startswith("/") \
            and ".." not in origin["path"].split("/") and _int(origin["size"]) \
            and _int(origin["mtimeNs"], 0, 2 ** 64)
        for item in meta["stats"] if ok else ():
            counts = item["typeCounts"]
            ok = ok and isinstance(item, dict) and set(item) == stat_keys and _text(item["name"], STAT_NAME_CHARS) \
                and _int(item["nonEmpty"]) and _int(item["empty"]) and isinstance(counts, dict) \
                and set(counts) == {"number", "date", "text", "unsure"} and all(_int(v) for v in counts.values()) \
                and item["inferredType"] in ("number", "date", "text", "unsure", "empty") \
                and all(_scalar(item[key]) for key in ("min", "max", "sum", "mean")) \
                and (item["distinct"] is None or _int(item["distinct"], 0, DISTINCT_CAP)) \
                and (item["distinctExact"] is None or type(item["distinctExact"]) is bool) \
                and all(item[key] is None or _int(item[key]) for key in ("minLength", "maxLength"))
    except (KeyError, TypeError):
        ok = False
    if not ok:
        raise Refuse(E_DAMAGED)
    return meta


class View:
    """Row ids of the current sort/filter; ids is None for the identity view."""

    def __init__(self, gen, ids, count):
        self.gen, self.ids, self.count = gen, ids, count


class Source:
    """One opened source: validated meta, checkpoint index and a data handle."""

    def __init__(self, sid, meta, offsets, stream):
        self.sid, self.meta, self.offsets, self.stream = sid, meta, offsets, stream
        self.rows = meta["rows"]
        self.shown = min(SHOWN, meta["columnCount"])
        self.view = View(0, None, self.rows)

    def numeric(self, column):
        item = self.meta["stats"][column]
        return item["nonEmpty"] > 0 and item["typeCounts"]["number"] == item["nonEmpty"]


def _read_file(dir_fd, name, limit):
    fd = _private_open(dir_fd, name, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
            raise Refuse(E_DAMAGED)
        return stream.read(limit + 1)


def open_source(root, sid):
    """Walk root -> sources -> src-<id> with no-follow dir fds and load the source."""
    if not isinstance(sid, str) or not SOURCE_ID.fullmatch(sid):
        raise Refuse(E_ID)
    try:
        sources_fd = _open_sources(root)
        try:
            dir_fd = _open_dir(sources_fd, sid)
        finally:
            os.close(sources_fd)
    except OSError as exc:  # missing is a state; a symlink or odd entry is not
        raise Refuse(E_MISSING if isinstance(exc, FileNotFoundError) else E_UNSAFE) from None
    try:
        try:
            raw = _read_file(dir_fd, "meta.json", META_LIMIT)
            if len(raw) > META_LIMIT:
                raise Refuse(E_DAMAGED)
            meta = validate_meta(json.loads(raw.decode("utf-8")), sid)
            index = _read_file(dir_fd, "index.bin", 8 * (MAX_ROWS // CHECKPOINT + 2))
            fd = _private_open(dir_fd, "data.csv", os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            raise Refuse(E_MISSING) from None
        except (OSError, ValueError, RecursionError):
            raise Refuse(E_DAMAGED) from None
    finally:
        os.close(dir_fd)
    stream = os.fdopen(fd, "rb", buffering=1 << 16)
    try:
        info = os.fstat(fd)
        offsets = array.array("Q")
        if len(index) % 8 or len(index) // 8 != -(-meta["rows"] // CHECKPOINT):
            raise Refuse(E_DAMAGED)
        offsets.frombytes(index)
        if sys.byteorder == "big":
            offsets.byteswap()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size != meta["bytes"] \
                or any(a >= b for a, b in zip(offsets, offsets[1:])) or (offsets and offsets[-1] >= info.st_size):
            raise Refuse(E_DAMAGED)
    except BaseException:
        stream.close()
        raise
    return Source(sid, meta, offsets, stream)


def _rows(source, wanted):
    """Parse the given row ids: seek to each block's checkpoint, read <= 63 records ahead."""
    found, ids = {}, sorted(set(wanted))
    index = 0
    while index < len(ids):
        block = ids[index] // CHECKPOINT
        end = index
        while end < len(ids) and ids[end] // CHECKPOINT == block:
            end += 1
        need, last = set(ids[index:end]), ids[end - 1]
        source.stream.seek(source.offsets[block])
        reader = csv.reader(Lines(source.stream, 1), strict=True)
        row_id = block * CHECKPOINT
        try:
            for row in reader:
                if not row:
                    continue
                if row_id in need:
                    found[row_id] = row
                if row_id == last:
                    break
                row_id += 1
            else:
                raise Refuse(E_DAMAGED)
        except csv.Error:
            raise Refuse(E_DAMAGED) from None
        index = end
    return found


def build_view(source, gen, sort, direction, needle, waiting):
    """One forward scan of data.csv into a row-id view; `waiting()` aborts it.

    The filter is a literal case-insensitive substring over the row's displayed
    cells joined with \\x01 (never a regular expression); control characters in
    the filter are removed first so it cannot match across a cell boundary, and
    a filter that becomes empty is no filter. Text sort is by
    character code on the casefolded cell: this intentionally differs from the
    answer table's locale compare. Empties sort last in both directions and
    ties keep row order.
    """
    needle = _CONTROL.sub("", needle).casefold()
    if sort < 0 and not needle:
        return View(gen, None, source.rows)
    numeric = sort >= 0 and source.numeric(sort)
    ids, keys, empties = array.array("I"), [], array.array("I")
    if source.rows:
        source.stream.seek(source.offsets[0])
        reader = csv.reader(Lines(source.stream, 1), strict=True)
        row_id = lines = 0
        try:
            for row in reader:
                # Cadence counts EVERY line (blank ones too): a blank-line flood
                # must not run unchecked while a newer request waits.
                lines += 1
                if (lines - 1) % CHUNK_ROWS == 0 and waiting():
                    raise Refuse(E_SUPERSEDED, gen=gen)
                if not row:
                    continue
                current, row_id = row_id, row_id + 1
                if needle and needle not in "\x01".join(row[:source.shown]).casefold():
                    continue
                if sort < 0:
                    ids.append(current)
                    continue
                cell = row[sort] if sort < len(row) else ""
                if not clean_cell(cell):
                    empties.append(current)
                    continue
                if numeric:
                    key = numeric_key(cell)  # exactly what the stats counted
                    if key is None:
                        empties.append(current)
                        continue
                    keys.append(key)
                else:
                    keys.append(cell.casefold())
                ids.append(current)
                if len(ids) + len(empties) > SORT_MAX_ROWS:
                    raise Refuse(E_SORT_CAP, gen=gen)
        except csv.Error:
            raise Refuse(E_DAMAGED) from None
    if sort >= 0:
        order = sorted(range(len(ids)), key=keys.__getitem__, reverse=direction == -1)  # stable
        ids = array.array("I", (ids[i] for i in order))
        ids.extend(empties)
    return View(gen, ids, len(ids))


def _page(source, page, gen):
    view = source.view
    if gen != view.gen:
        raise Refuse(E_STALE, gen=gen)
    count = view.count
    pages = -(-count // PAGE_SIZE)
    page = min(page, max(pages - 1, 0))
    first = page * PAGE_SIZE
    wanted = list(range(first, min(count, first + PAGE_SIZE)))
    if view.ids is not None:
        wanted = [view.ids[i] for i in wanted]
    found = _rows(source, wanted)
    clipped, rows = False, []
    for row_id in wanted:
        cells = found[row_id][:source.shown]
        cells += [""] * (source.shown - len(cells))
        for i, cell in enumerate(cells):
            if len(cell) > CELL_CHARS:
                cells[i], clipped = cell[:CELL_CHARS], True
        rows.append(cells)
    return {"gen": gen, "page": page, "pageSize": PAGE_SIZE, "pageCount": pages, "viewRows": count,
            "firstRow": wanted[0] + 1 if wanted else 0, "rows": rows, "cellsTruncated": clipped}


# -------------------------------------------------------------------- worker
def _summary(meta):
    return {"sourceId": meta["sourceId"], "rows": meta["rows"], "columnCount": meta["columnCount"],
            "columns": meta["columns"], "bytes": meta["bytes"], "stats": meta["stats"]}


class Worker:
    """Request handlers; `waiting()` says whether a newer request is queued."""

    def __init__(self, root, home=None, waiting=lambda: False):
        self.root, self.home, self.waiting, self.sources = root, home, waiting, {}

    def _source(self, request):
        sid = request.get("sourceId")
        if not isinstance(sid, str) or not SOURCE_ID.fullmatch(sid):
            raise Refuse(E_ID)
        if sid not in self.sources:
            self.sources[sid] = open_source(self.root, sid)
            while len(self.sources) > CACHE_SOURCES:
                self._drop(next(iter(self.sources)))
        return self.sources[sid]

    def _drop(self, sid):
        source = self.sources.pop(sid, None)
        if source:
            source.stream.close()

    def register(self, request, emit):
        path = request.get("path")
        if not isinstance(path, str) or not path or len(path) > 4096:
            raise Refuse("Choose a CSV file inside your home directory.")
        meta = register(self.root, path, self.home,
                        lambda rows: emit({"event": "progress", "rows": rows}))
        return _summary(meta)

    def open(self, request, emit):
        old = self.sources.get(request.get("sourceId")) if isinstance(request.get("sourceId"), str) else None
        view = old.view if old else None
        if old:
            self._drop(old.sid)
        source = self._source(request)
        source.view = view or source.view  # reloading meta keeps the live view
        return _summary(source.meta)

    def verify(self, request, emit):
        sid = request.get("sourceId")
        if not isinstance(sid, str) or not SOURCE_ID.fullmatch(sid):
            raise Refuse(E_ID)
        try:
            source = open_source(self.root, sid)
        except Refuse as exc:
            if str(exc) == E_MISSING:
                return {"state": "copyMissing"}
            raise
        source.stream.close()
        origin = source.meta["origin"]
        try:
            info = os.lstat(Path(self.home or Path.home()).resolve() / origin["path"])
        except OSError:
            return {"state": "originMissing"}
        same = stat.S_ISREG(info.st_mode) and info.st_size == origin["size"] and info.st_mtime_ns == origin["mtimeNs"]
        return {"state": "ready" if same else "originChanged"}

    def view(self, request, emit):
        source = self._source(request)
        sort, direction, text, gen = (request.get(k) for k in ("sort", "dir", "filter", "gen"))
        if not _int(gen):
            raise Refuse("Invalid view request.")
        if not _int(sort, -1, source.shown - 1):
            raise Refuse("Invalid sort column.")
        if type(direction) is not int or direction not in (1, -1):
            raise Refuse("Invalid sort direction.")
        if not isinstance(text, str) or len(text) > 200:
            raise Refuse("Invalid filter.")
        source.view = build_view(source, gen, sort, direction, text, self.waiting)
        return {"gen": gen, "viewRows": source.view.count}

    def page(self, request, emit):
        source = self._source(request)
        page, gen = request.get("page"), request.get("gen")
        if not _int(page, 0, 2 ** 31) or not _int(gen):
            raise Refuse("Invalid page request.")
        return _page(source, page, gen)

    def close(self, request, emit):
        sid = request.get("sourceId")
        if not isinstance(sid, str) or not SOURCE_ID.fullmatch(sid):
            raise Refuse(E_ID)
        self._drop(sid)
        return {}

    def handle(self, request, emit):
        """One request -> response fields (without id/ok); raises Refuse."""
        op = request.get("op")
        method = {"register": self.register, "open": self.open, "verify": self.verify, "view": self.view,
                  "page": self.page, "close": self.close}.get(op) if isinstance(op, str) else None
        if method is None:
            raise Refuse("Unknown operation.")
        return method(request, emit)


class _Input:
    """Buffered, non-blocking stdin so queued requests stay visible to `waiting`."""

    def __init__(self, fd):
        self.fd, self.buf, self.skipping = fd, b"", False
        os.set_blocking(fd, False)

    def waiting(self):
        if self.buf:
            return True
        try:
            return bool(select.select([self.fd], [], [], 0)[0])
        except (OSError, ValueError):
            return True

    def line(self, timeout):
        while True:
            end = self.buf.find(b"\n")
            if self.skipping:  # discarding the rest of an oversized request
                if end >= 0:
                    self.buf, self.skipping = self.buf[end + 1:], False
                    continue
                self.buf = b""
            elif end >= 0:
                line, self.buf = self.buf[:end], self.buf[end + 1:]
                return ("oversize", b"") if len(line) > MAX_REQUEST else ("line", line)
            elif len(self.buf) > MAX_REQUEST:
                self.buf, self.skipping = b"", True
                return "oversize", b""
            try:
                ready = select.select([self.fd], [], [], timeout)[0]
            except (OSError, ValueError):
                return "eof", b""
            if not ready:
                return "idle", b""
            try:
                chunk = os.read(self.fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                return "eof", b""
            if not chunk:
                return "eof", b""
            self.buf += chunk


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError("invalid constant")


def serve(root, out, idle=None, fd=0, home=None):
    """Request loop; exits 0 on stdin EOF or after `idle` seconds without a request."""
    if idle is None:
        try:
            idle = float(os.environ.get("LAUNCHER_CSV_IDLE") or IDLE_SECONDS)
        except ValueError:
            idle = IDLE_SECONDS
    source = _Input(fd)
    worker = Worker(root, home, source.waiting)

    def send(payload):
        data = json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        if len(data) + 1 > MAX_RESPONSE:
            data = json.dumps({"id": payload.get("id"), "ok": False, "error": E_TOO_LARGE}).encode("utf-8")
        out.write(data + b"\n")
        out.flush()

    try:
        while True:
            status, line = source.line(max(0.05, idle))
            if status in ("eof", "idle"):
                return 0
            request_id = None
            try:
                if status == "oversize":
                    raise Refuse("Request is too large.")
                request = json.loads(line.decode("utf-8"), object_pairs_hook=_unique,
                                     parse_constant=_reject_constant)
                request_id = request.get("id") if isinstance(request, dict) else None
                if not _int(request_id):
                    request_id = None
                    raise Refuse("Request needs an integer id.")
                body = worker.handle(request, lambda event: send({"id": request_id, **event}))
                send({"id": request_id, "ok": True, **body})
            except Refuse as exc:
                send({"id": request_id, "ok": False, "error": str(exc), **exc.extra})
            except (ValueError, UnicodeError, RecursionError):
                send({"id": request_id, "ok": False, "error": "Request must be one JSON object."})
            except (BrokenPipeError, KeyboardInterrupt):
                raise
            except Exception:
                send({"id": request_id, "ok": False, "error": E_GENERIC})
    except (BrokenPipeError, OSError, KeyboardInterrupt):
        return 0
    finally:
        for sid in list(worker.sources):
            worker._drop(sid)


# --------------------------------------------------------------------- reaper
def plan_reap(root, now=None, stale=TMP_STALE):
    """List sources and temp dirs. Pure read; only stale temp dirs are removable."""
    now = time.time() if now is None else now
    try:
        sources_fd = _open_sources(root)
    except FileNotFoundError:
        return []
    plan = []
    try:
        for name in sorted(os.listdir(sources_fd)):
            kind = "source" if SOURCE_ID.fullmatch(name) else "temp" if TMP_NAME.fullmatch(name) else None
            if kind is None:
                continue
            item = {"name": name, "kind": kind, "bytes": 0, "ageHours": None, "action": "keep",
                    "reason": "complete source (listed only; orphan status needs the database)"
                              if kind == "source" else ""}
            try:
                fd = _open_dir(sources_fd, name)
            except (OSError, Refuse):
                item["reason"] = "not a private directory"
                plan.append(item)
                continue
            try:
                newest = os.fstat(fd).st_mtime
                for entry in os.listdir(fd):
                    info = os.stat(entry, dir_fd=fd, follow_symlinks=False)
                    item["bytes"] += info.st_size
                    newest = max(newest, info.st_mtime)
            finally:
                os.close(fd)
            item["ageHours"] = round(max(0.0, now - newest) / 3600, 1)
            if kind == "temp":
                if now - newest >= stale:
                    item["action"], item["reason"] = "remove", "stale temporary registration"
                else:
                    item["reason"] = "younger than %g h (a registration may be running)" % (stale / 3600)
            plan.append(item)
    finally:
        os.close(sources_fd)
    return plan


def reap_sources(root, apply=False, expect=None, now=None, stale=TMP_STALE):
    plan = plan_reap(root, now, stale)
    doomed = [item["name"] for item in plan if item["action"] == "remove"]
    result = {"applied": False, "plan": plan, "candidates": len(doomed), "removed": [], "failed": []}
    if not apply:
        return result
    if expect is not None and expect != len(doomed):
        raise Refuse("Approved %d temp dirs but %d qualify now; re-run the dry run." % (expect, len(doomed)))
    fresh = {item["name"] for item in plan_reap(root, now, stale) if item["action"] == "remove"}
    result["applied"] = True
    sources_fd = _open_sources(root) if doomed else None
    try:
        for name in doomed:
            try:
                if name not in fresh:
                    raise Refuse("no longer qualifies")
                _unlink_tmp(sources_fd, name)
                result["removed"].append(name)
            except (OSError, Refuse) as exc:
                result["failed"].append({"name": name, "error": str(exc)[:200]})
    finally:
        if sources_fd is not None:
            os.close(sources_fd)
    return result


def reap_main(root, apply, expect):
    try:
        result = reap_sources(root, apply, expect)
    except (Refuse, OSError) as exc:
        print("refused: %s" % exc, file=sys.stderr)
        return 2
    for item in result["plan"]:
        age = "?" if item["ageHours"] is None else "%.1fh" % item["ageHours"]
        print("%-6s %-26s %8.1f MiB %7s  %s" % (item["action"], item["name"], item["bytes"] / 1048576, age,
                                                item["reason"]))
    if result["applied"]:
        print("removed %d temp dirs; %d skipped or failed" % (len(result["removed"]), len(result["failed"])))
    else:
        print("dry run: %d stale temp dirs qualify. Nothing was deleted; re-run with --apply --expect-count %d "
              "to remove them." % (result["candidates"], result["candidates"]))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) >= 3 and argv[0] == "--root":
        root, mode, tail = argv[1], argv[2], argv[3:]
        if mode == "--serve" and not tail:
            os.dup2(os.open(os.devnull, os.O_WRONLY), 2)  # stderr must never carry data
            return serve(root, sys.stdout.buffer)
        if mode == "--reap-sources" and not tail:
            return reap_main(root, False, None)
        if mode == "--reap-sources" and tail == ["--apply"]:
            return reap_main(root, True, None)
        if mode == "--reap-sources" and len(tail) == 3 and tail[:2] == ["--apply", "--expect-count"] \
                and tail[2].isdigit():
            return reap_main(root, True, int(tail[2]))
    sys.stderr.write("usage: ai_csv_source.py --root <stateRoot> --serve\n"
                     "       ai_csv_source.py --root <stateRoot> --reap-sources [--apply [--expect-count N]]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
