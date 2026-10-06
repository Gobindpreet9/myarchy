#!/usr/bin/env python3
"""Read-only, sampled shared-shell/process-tree observations, not AI attribution."""

import argparse
import json
import math
import os
from pathlib import Path
import platform
import sys
import time

CATEGORIES = ("shell", "provider", "external-provider", "broker", "media", "store", "other")


def parse_stat(text):
    # comm may contain whitespace and parentheses; the final ')' ends field 2.
    head, _, tail = text.rpartition(")")
    pid, comm = head.split("(", 1)
    fields = tail.split()
    return dict(pid=int(pid), name=comm, ppid=int(fields[1]),
                cpu_ticks=int(fields[11]) + int(fields[12]),
                start_ticks=int(fields[19]))


def category(args, inherited="other"):
    # Only the executable/script prefix: never classify user prompt text.
    names = set()
    for arg in args:
        if arg.startswith("-"):
            continue
        name = Path(arg).name
        names.add(name)
        if name not in ("python", "python3", "node", "env") and not name.startswith("python3."):
            break
    for label, markers in (("broker", {"ai_broker.py"}),
                           ("media", {"ai_media.py"}),
                           ("store", {"ai_workspace_store.py"}),
                           ("provider", {"codex", "hermes", "hermes.py", "ai_hermes.py"})):
        if names & markers:
            if label == "provider" and inherited not in ("broker", "provider"):
                return "external-provider"
            return label
    return inherited


def memory(text):
    result = {"pss_bytes": None, "rss_bytes": None}
    for line in text.splitlines():
        fields = line.split()
        if fields and fields[0] in ("Pss:", "Rss:"):
            if len(fields) != 3 or fields[2] != "kB":
                raise ValueError("unexpected smaps unit")
            result["pss_bytes" if fields[0] == "Pss:" else "rss_bytes"] = int(fields[1]) * 1024
    return result


def snapshot(proc, pid, expected_start=None):
    errors, stats = [], {}
    try:
        root = parse_stat((proc / str(pid) / "stat").read_text())
        if expected_start is not None and root["start_ticks"] != expected_start:
            raise ValueError("target PID reused; replacement excluded")
    except (OSError, ValueError, IndexError) as exc:
        return {"processes": [], "errors": [f"target {pid}: {exc}"], "target_present": False}
    scan_failures = 0
    for entry in proc.iterdir():
        if entry.name.isdigit():
            try:
                stats[int(entry.name)] = parse_stat((entry / "stat").read_text())
            except (OSError, ValueError, IndexError):
                scan_failures += 1
    stats[pid] = root
    selected, frontier = {pid: "shell"}, [pid]
    children = {}
    for child, stat in stats.items():
        children.setdefault(stat["ppid"], []).append(child)
    processes = []
    while frontier:
        current = frontier.pop()
        stat = stats[current].copy()
        directory = proc / str(current)
        label = selected[current]
        try:
            args = directory.joinpath("cmdline").read_bytes().decode(errors="replace").split("\0")
            label = "shell" if current == pid else category(args, label)
        except OSError as exc:
            errors.append(f"{current}/cmdline: {exc}; category inherited")
        stat.update(category=label, pss_bytes=None, rss_bytes=None)
        try:
            stat.update(memory(directory.joinpath("smaps_rollup").read_text()))
            if stat["pss_bytes"] is None or stat["rss_bytes"] is None:
                errors.append(f"{current}/smaps_rollup: missing Pss or Rss")
        except (OSError, ValueError) as exc:
            errors.append(f"{current}/smaps_rollup: {exc}")
        try:
            after = parse_stat(directory.joinpath("stat").read_text())
            if after["start_ticks"] != stat["start_ticks"]:
                raise ValueError("PID reused during sample")
            processes.append(stat)
        except (OSError, ValueError, IndexError) as exc:
            errors.append(f"{current}/stat: {exc}; process excluded")
        for child in children.get(current, []):
            if child not in selected:
                selected[child] = "other" if label == "shell" else label
                frontier.append(child)
    return dict(processes=processes, errors=errors, target_present=any(
        p["pid"] == pid for p in processes), scan_stat_failures=scan_failures)


def aggregate(sample, previous, elapsed, hz):
    old = {(p["pid"], p["start_ticks"]): p for p in previous or []}
    groups = {}
    for label in ("total",) + CATEGORIES:
        items = [p for p in sample["processes"] if label == "total" or p["category"] == label]
        prior = [p for p in previous or [] if label == "total" or p["category"] == label]
        group = {"process_count": len(items), "cpu_ticks": sum(p["cpu_ticks"] for p in items)
                 if sample["target_present"] else None}
        for metric in ("pss_bytes", "rss_bytes"):
            missing = sum(p[metric] is None for p in items)
            group[metric + "_missing"] = missing
            group[metric + "_readable"] = sum(p[metric] or 0 for p in items)
            group[metric] = None if missing or not sample["target_present"] else group[metric + "_readable"]
        matched = [p for p in items if (p["pid"], p["start_ticks"]) in old
                   and p["cpu_ticks"] >= old[p["pid"], p["start_ticks"]]["cpu_ticks"]
                   and (label == "total" or old[p["pid"], p["start_ticks"]]["category"] == label)]
        ticks = sum(p["cpu_ticks"] - old[p["pid"], p["start_ticks"]]["cpu_ticks"] for p in matched)
        identities = {(p["pid"], p["start_ticks"]) for p in items}
        group.update(cpu_delta_ticks_known=ticks if previous is not None and sample["target_present"] else None,
                     cpu_delta_complete=previous is not None and sample["target_present"]
                     and len(matched) == len(items) and all(
                         (p["pid"], p["start_ticks"]) in identities for p in prior),
                     cpu_percent_one_core_known=100 * ticks / hz / elapsed
                     if previous is not None and sample["target_present"] and elapsed > 0 else None)
        groups[label] = group
    return groups


def hardware(proc, sysroot=Path("/sys"), os_release=Path("/etc/os-release")):
    def read(path):
        try:
            return path.read_text().strip()
        except OSError:
            return None
    cpu = read(proc / "cpuinfo")
    ram = read(proc / "meminfo")
    return dict(kernel=platform.release(), architecture=platform.machine(),
                python=platform.python_version(), os_release=read(os_release),
                logical_cpus=os.cpu_count(), cpu_model=next((line.split(":", 1)[1].strip()
                    for line in (cpu or "").splitlines() if line.startswith("model name")), None),
                ram_total_bytes=next((int(line.split()[1]) * 1024 for line in (ram or "").splitlines()
                    if line.startswith("MemTotal:")), None),
                gpu_pci_ids=[dict(card=card.name, vendor=read(card / "device/vendor"),
                                  device=read(card / "device/device"))
                             for card in sorted((sysroot / "class/drm").glob("card[0-9]*"))
                             if "-" not in card.name])


def run(pid, seconds=60, interval=1, scenario="unspecified", context="", proc=Path("/proc")):
    hz = os.sysconf("SC_CLK_TCK")
    report = dict(schema_version=1, pid=pid, scenario=scenario, context=context,
                  started_unix=time.time(), requested_seconds=seconds, interval_seconds=interval,
                  clock_ticks_per_second=hz, hardware=hardware(proc), samples=[], limitations=[
                      "Shared shell and all observed descendants, including unrelated plugins; not feature-attributable CPU/PSS.",
                      "No A/B baseline or enabled/disabled comparison; scenario/context are caller supplied.",
                      "Non-atomic /proc polling misses short-lived children, exit-tail CPU, reparented processes and between-sample peaks.",
                      "CPU deltas match PID plus start time; unmatched/new/exited processes make intervals incomplete; known CPU is a lower bound.",
                       "Categories are executable/script-name heuristics, not ownership proof; provider means a broker descendant, external-provider means other provider launches. CPU percent is of one core, may exceed 100%.",
                      "PSS/RSS null means unavailable/incomplete; readable sums are partial, RSS double-counts shared pages.",
                      "Peaks are peak observed samples, not true peaks. No GPU memory/CPU, frames, wakeups, latency or write tracing.",
                      "GPU PCI IDs only; runtime versions, display scaling/refresh, theme, fixture and cold/warm state require caller context."])
    start = time.monotonic()
    previous, last, identity = None, start, None
    while True:
        sample = snapshot(proc, pid, identity)
        now = time.monotonic()
        sample["elapsed_seconds"] = now - start
        sample["groups"] = aggregate(sample, previous, now - last, hz)
        report["samples"].append(sample)
        previous, last = sample["processes"], now
        if identity is None:
            identity = next((p["start_ticks"] for p in previous if p["pid"] == pid), None)
        if not sample["target_present"] or now - start >= seconds:
            break
        time.sleep(min(interval, seconds - (now - start)))
    report["observed_seconds"] = last - start
    report["peak_observed"] = {}
    report["summary"] = {}
    for label in ("total",) + CATEGORIES:
        groups = [s["groups"][label] for s in report["samples"]]
        peaks = {key: max((g[key] for g in groups if g[key] is not None), default=None)
                 for key in ("pss_bytes", "rss_bytes", "pss_bytes_readable", "rss_bytes_readable",
                             "process_count", "cpu_percent_one_core_known")}
        deltas = [g["cpu_delta_ticks_known"] for g in groups[1:] if g["cpu_delta_ticks_known"] is not None]
        window = last - start - report["samples"][0]["elapsed_seconds"]
        report["summary"][label] = dict(cpu_seconds_known=sum(deltas) / hz if deltas else None,
                     average_cpu_percent_one_core_known=100 * sum(deltas) / hz / window
                     if deltas and window > 0 else None,
                     cpu_intervals_complete=len(groups) > 1 and all(g["cpu_delta_complete"] for g in groups[1:]))
        report["peak_observed"][label] = peaks
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="explicit shared Quickshell PID (not launched or signalled)")
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--scenario", default="unspecified")
    parser.add_argument("--context", default="", help="fixture/version, cold/warm, theme, scaling/refresh and runtime notes")
    parser.add_argument("--output", type=Path, help="optional JSON report file; stdout always receives JSON")
    args = parser.parse_args(argv)
    if (args.pid <= 0 or not math.isfinite(args.seconds) or not math.isfinite(args.interval)
            or not 0.1 <= args.seconds <= 1800 or not 0.1 <= args.interval <= 60
            or args.interval > args.seconds or args.seconds / args.interval > 3600):
        parser.error("positive PID; seconds 0.1–1800; interval 0.1–60 <= seconds; at most 3600 intervals")
    text = json.dumps(run(args.pid, args.seconds, args.interval, args.scenario, args.context), indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
