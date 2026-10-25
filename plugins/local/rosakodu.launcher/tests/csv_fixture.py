"""Deterministic (seeded) CSV fixtures for the durable-source tests; written to a caller's temp dir, never committed."""
import csv
import datetime
import random

NUMERIC, DATES, TEXT = 14, 2, 3
HEADER = ["n%d" % i for i in range(NUMERIC)] + ["d0", "d1"] + ["t0", "t1", "t2"] + ["multi"]
NAMES = ["Smith, Jane", 'O"Neil, Pat', "Zoë Müller", "日本語 テスト", "café \U0001f600",
         "plain", "", "  padded  ", "Ünï, côdé"]


def main_row(rng, i, multiline_every=50):
    row = [i, rng.randint(-5000, 5000)]
    row += ["%.2f" % rng.uniform(-1e4, 1e4) for _ in range(NUMERIC - 4)]
    row += [rng.choice(["", "%.3f" % rng.random()]), "%de%d" % (rng.randint(1, 9), rng.randint(0, 5))]
    base = datetime.date(2019, 1, 1)
    row += [(base + datetime.timedelta(days=rng.randint(0, 1500))).isoformat() for _ in range(DATES)]
    row += [rng.choice(NAMES), "%s-%d" % (rng.choice(NAMES[:5]), rng.randint(0, 40)),
            'He said "hi", twice %d' % rng.randint(0, 9999)]
    row.append("first line\nsecond, \"quoted\" line %d\r\nthird" % i if i % multiline_every == 0 else "single %d" % i)
    return row


def write_main(path, rows=100_000, seed=20260101, ragged_at=None, newline="\n"):
    """100,000 x 20 by default: 14 numeric, 2 ISO dates, 3 text, 1 with periodic multiline quoted fields."""
    rng = random.Random(seed)
    with open(path, "w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator=newline)
        writer.writerow(HEADER)
        for i in range(rows):
            row = main_row(rng, i)
            if ragged_at is not None and i == ragged_at:
                row = row[:-1]
            writer.writerow(row)
    return path


def write_single_column(path, rows):
    """`rows` data rows of one short column: the cheap way to cross the row cap."""
    with open(path, "wb") as stream:
        stream.write(b"a\n" + b"1\n" * rows)
    return path


def write_oversize(path, size):
    """A valid CSV of at least `size` bytes (for the byte cap)."""
    line = b"x" * 1023 + b"\n"
    with open(path, "wb") as stream:
        stream.write(b"a\n")
        for _ in range(size // len(line) + 1):
            stream.write(line)
    return path


def write_long_line(path, size=(1 << 20) + 1):
    """A header and one `size`-byte record with no newline at all."""
    with open(path, "wb") as stream:
        stream.write(b"a,b\n" + b"x" * size)
    return path
