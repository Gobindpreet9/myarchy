"""Opt-in measurements for the durable CSV source worker (never part of the default suite).

LAUNCHER_STRESS=1 python3 tests/stress_csv_source.py. Fixtures and state live in
a scratch dir under /tmp/opencode and are removed afterwards. Prints the real
numbers; page timings are client round trips (an upper bound for worker time)
plus the in-process handler time.
"""
import json
import os
from pathlib import Path
import select
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
sys.path[:0] = [str(PLUGIN), str(HERE)]
import ai_csv_source as src
import ai_resource_probe
import csv_fixture as fixture

MIB = 1 << 20


class Client:
    def __init__(self, root, home, idle=None):
        env = {"HOME": str(home), "PATH": os.environ["PATH"], "LC_CTYPE": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
        if idle is not None:
            env["LAUNCHER_CSV_IDLE"] = str(idle)
        self.proc = subprocess.Popen([sys.executable, str(PLUGIN / "ai_csv_source.py"), "--root", str(root), "--serve"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.n = 0

    def send(self, op, **fields):
        self.n += 1
        self.proc.stdin.write(json.dumps({"id": self.n, "op": op, **fields}).encode() + b"\n")
        self.proc.stdin.flush()
        return self.n

    def recv(self, timeout=120):
        assert select.select([self.proc.stdout], [], [], timeout)[0], "no reply"
        return json.loads(self.proc.stdout.readline())

    def rpc(self, op, **fields):
        started = time.perf_counter()
        self.send(op, **fields)
        events = 0
        while True:
            reply = self.recv()
            if "event" in reply:
                events += 1
                continue
            return reply, time.perf_counter() - started, events

    def memory(self):
        sample = ai_resource_probe.snapshot(Path("/proc"), self.proc.pid)["processes"][0]
        peak = next(int(line.split()[1]) for line in open("/proc/%d/status" % self.proc.pid) if line.startswith("VmHWM"))
        return sample["rss_bytes"] / MIB, sample["pss_bytes"] / MIB, peak / 1024


def p95(values):
    return sorted(values)[max(0, int(len(values) * 0.95 + 0.999) - 1)]


def tree_bytes(root):
    return sum(os.lstat(os.path.join(b, n)).st_size for b, d, f in os.walk(root) for n in f)


def snapshot(root):
    return {os.path.join(b, n): (os.lstat(os.path.join(b, n)).st_size, os.lstat(os.path.join(b, n)).st_mtime_ns)
            for b, d, f in os.walk(root) for n in d + f}


def main():
    if os.environ.get("LAUNCHER_STRESS") != "1":
        print("set LAUNCHER_STRESS=1 to run")
        return 0
    os.makedirs("/tmp/opencode", exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix="csv-stress-", dir="/tmp/opencode")).resolve()
    home, state = base / "home", base / "state"
    home.mkdir()
    state.mkdir(0o700)
    out = {}
    try:
        t = time.perf_counter()
        fixture.write_main(home / "main.csv")
        out["fixtureSeconds"] = round(time.perf_counter() - t, 2)
        out["fixtureBytes"] = (home / "main.csv").stat().st_size
        client = Client(state, home)
        client.rpc("verify", sourceId="src-0000000000000000")  # worker is up and idle
        base_rss, base_pss, _ = client.memory()
        reply, seconds, events = client.rpc("register", path="main.csv")
        assert reply["ok"] and reply["rows"] == 100_000, reply
        sid = reply["sourceId"]
        out["register"] = {"seconds": round(seconds, 2), "progressEvents": events, "rows": reply["rows"]}
        after_rss, after_pss, peak = client.memory()
        out["written"] = {"bytesOnDisk": tree_bytes(state / "sources"), "copyBytes": reply["bytes"]}
        before = snapshot(state)

        views = {}
        for label, fields in (("numericDesc", {"sort": 2, "dir": -1, "filter": ""}), ("textAsc", {"sort": 17, "dir": 1, "filter": ""}),
                              ("dateDesc", {"sort": 14, "dir": -1, "filter": ""}), ("filterO", {"sort": -1, "dir": 1, "filter": "o"}),
                              ("filterSort", {"sort": 3, "dir": 1, "filter": "ZoË"})):
            reply, seconds, _ = client.rpc("view", sourceId=sid, gen=len(views) + 1, **fields)
            assert reply["ok"], reply
            views[label] = (round(seconds, 3), reply["viewRows"])
        out["viewBuild"] = views

        gen = 100
        client.rpc("view", sourceId=sid, sort=-1, dir=1, filter="", gen=gen)
        client.rpc("page", sourceId=sid, page=0, gen=gen)
        rng = __import__("random").Random(5)
        identity = [client.rpc("page", sourceId=sid, page=p, gen=gen)[1] for p in list(range(10)) + [rng.randrange(4000) for _ in range(40)]]
        client.rpc("view", sourceId=sid, sort=2, dir=-1, filter="", gen=gen + 1)
        sorted_pages = [client.rpc("page", sourceId=sid, page=rng.randrange(4000), gen=gen + 1)[1] for _ in range(40)]
        out["pageRoundTripMs"] = {"identityP95": round(p95(identity) * 1000, 2), "identityMedian": round(statistics.median(identity) * 1000, 2),
                                  "sortedP95": round(p95(sorted_pages) * 1000, 2), "count": len(identity) + len(sorted_pages)}

        # supersede latency: a long text sort, then any newer request
        client.send("view", sourceId=sid, sort=17, dir=-1, filter="", gen=gen + 2)
        time.sleep(0.04)
        sent = time.perf_counter()
        client.send("verify", sourceId=sid)
        first = client.recv()
        out["supersede"] = {"abortMs": round((time.perf_counter() - sent) * 1000, 1), "reply": first.get("error", "completed before the newer request")}
        client.recv()
        client.rpc("view", sourceId=sid, sort=-1, dir=1, filter="", gen=gen + 3)
        final_rss, final_pss, peak = client.memory()
        out["workerMiB"] = {"baselineRss": round(base_rss, 1), "afterRegisterRss": round(after_rss, 1), "finalRss": round(final_rss, 1),
                            "peakRss": round(peak, 1), "rssDeltaPeak": round(peak - base_rss, 1),
                            "baselinePss": round(base_pss, 1), "finalPss": round(final_pss, 1), "pssDelta": round(final_pss - base_pss, 1)}
        out["readsWroteNothing"] = snapshot(state) == before

        worker = src.Worker(state, home)
        worker.handle({"op": "view", "sourceId": sid, "sort": 2, "dir": -1, "filter": "", "gen": 7}, lambda e: None)
        timings = []
        for page in [rng.randrange(4000) for _ in range(60)]:
            t = time.perf_counter()
            worker.handle({"op": "page", "sourceId": sid, "page": page, "gen": 7}, lambda e: None)
            timings.append(time.perf_counter() - t)
        out["pageInProcessMs"] = {"p95": round(p95(timings) * 1000, 2), "max": round(max(timings) * 1000, 2)}
        worker._drop(sid)

        # refusals at the real caps
        refusals = {}
        fixture.write_main(home / "ragged.csv", ragged_at=90_000)
        fixture.write_single_column(home / "rows.csv", src.MAX_ROWS + 1)
        fixture.write_long_line(home / "long.csv")
        fixture.write_oversize(home / "bytes.csv", src.MAX_BYTES + 1)
        for name in ("ragged.csv", "rows.csv", "long.csv", "bytes.csv"):
            reply, seconds, _ = client.rpc("register", path=name)
            refusals[name] = {"seconds": round(seconds, 2), "error": reply.get("error")}
        refusals["leftovers"] = sorted(n for n in os.listdir(state / "sources") if n != sid)
        out["refusals"] = refusals

        # a file at the cap: ~64 MiB, 335,000 rows
        fixture.write_main(home / "cap.csv", rows=335_000)
        size = (home / "cap.csv").stat().st_size
        reply, seconds, _ = client.rpc("register", path="cap.csv")
        out["atCap"] = {"bytes": size, "ok": reply["ok"], "seconds": round(seconds, 2), "error": reply.get("error"),
                        "rssPeakMiB": round(client.memory()[2], 1)}
        if reply["ok"]:
            reply, seconds, _ = client.rpc("view", sourceId=reply["sourceId"], sort=2, dir=1, filter="", gen=1)
            out["atCap"]["sortOver250k"] = reply.get("error")

        last = time.perf_counter()
        client.proc.wait(60)
        out["idleExit"] = {"secondsAfterLastRequest": round(time.perf_counter() - last, 1), "code": client.proc.returncode}
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
