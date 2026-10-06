#!/usr/bin/env python3
"""Versioned medium-selection benchmark for the launcher AI workspace.

Drives the RUNNING shell through the launcher's IPC (newchat / submit / status),
waits for each answer, then checks the persisted presentation for the expected
interface signals. It measures structure, not taste: whether the right *kind*
of interface appeared for the subject, how long it took, and whether anything
failed. Qualitative review stays a human/agent checklist on top of the JSON.

Usage:
    python3 ai_bench.py --prompts bench-prompts.json --limit 6 \
        --out /tmp/opencode/bench-results.json

Requires: the omarchy shell running with this plugin, a signed-in provider, and
sqlite3 available in Python. Read-only against the workspace DB.
"""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

IPC = ["omarchy-shell", "rosakodu.launcher"]
LEARNING = ("steps", "check", "predict", "diagram", "slider")
VISUAL = ("image", "gallery", "market", "chart")


def ipc(*args, timeout=30):
    result = subprocess.run(IPC + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    return result.stdout.strip()


def status():
    raw = ipc("status")
    try:
        return json.loads(raw)
    except ValueError:
        return {}


def db_path():
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(root) / "omarchy" / "launcher-ai" / "workspace.db"


def load_prompts(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, list) or not data:
        raise ValueError("prompt file must be a non-empty JSON list")
    seen = set()
    for entry in data:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not entry["id"].strip() \
                or not isinstance(entry.get("prompt"), str) or not entry["prompt"].strip():
            raise ValueError("each prompt needs a non-empty id and prompt")
        if entry["id"] in seen:
            raise ValueError("duplicate prompt id: " + entry["id"])
        seen.add(entry["id"])
        expect = entry.get("expect") or {}
        for key in ("blocksAny", "blocksNone"):
            values = expect.get(key, [])
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                raise ValueError(f"expect.{key} must be a list of block types")
    return data


def stored_blocks(conn, workspace_id):
    row = conn.execute(
        "SELECT blocks FROM artifacts WHERE id LIKE ? ORDER BY updated_at DESC LIMIT 1",
        ("af-" + workspace_id[3:] + "-t%",)).fetchone()
    if not row:
        return []
    try:
        blocks = json.loads(row[0])
    except ValueError:
        return []
    return blocks if isinstance(blocks, list) else []


def evaluate(entry, state, blocks, elapsed):
    types = [str(block.get("type", "")) for block in blocks if isinstance(block, dict)]
    expect = entry.get("expect") or {}
    notes, passed = [], True
    any_of = expect.get("blocksAny", [])
    if any_of and not any(t in types for t in any_of):
        passed = False
        notes.append("expected one of " + "/".join(any_of) + " but saw " + (",".join(types) or "none"))
    for forbidden in expect.get("blocksNone", []):
        if forbidden in types:
            passed = False
            notes.append("unexpected " + forbidden)
    if expect.get("needsImages"):
        has_image = any(t in types for t in ("image", "gallery")) and any(
            (b.get("imageUrl") or any((i.get("imageUrl") for i in (b.get("items") or []))))
            for b in blocks if isinstance(b, dict))
        if not has_image:
            passed = False
            reasons = []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("error"):
                    reasons.append(str(b["error"])[:80])
                for item in b.get("items") or []:
                    if isinstance(item, dict) and item.get("error"):
                        reasons.append(str(item["error"])[:80])
            notes.append("no resolved image" + ((" (" + reasons[0] + ")") if reasons else ""))
    answer = str(state.get("aiState") or "")
    if answer != "done":
        passed = False
        notes.append("state " + (answer or "unknown"))
    if expect.get("maxSeconds") and elapsed > float(expect["maxSeconds"]):
        notes.append("slow: %.1fs" % elapsed)
    return {"passed": passed, "blockTypes": types, "notes": "; ".join(notes)}


def loading_placeholder(blocks):
    """True while a media block still carries the pre-enrichment snapshot."""
    for block in blocks:
        if not isinstance(block, dict):
            continue
        if block.get("loading") or str(block.get("error", "")).startswith("Loading visual"):
            return True
        if any(isinstance(item, dict) and str(item.get("error", "")).startswith("Loading visual")
               for item in block.get("items") or []):
            return True
    return False


def run(entries, timeout=180, poll=3.0):
    results = []
    conn = sqlite3.connect("file:" + str(db_path()) + "?mode=ro", uri=True) if db_path().exists() else None
    for entry in entries:
        ipc("newchat")
        started = time.monotonic()
        ipc("submit", entry["prompt"])
        state = {}
        while time.monotonic() - started < timeout:
            time.sleep(poll)
            state = status()
            if state and not state.get("aiBusy", True):
                break
        elapsed = time.monotonic() - started
        # The answer is done, but the settled save lands slightly later (the
        # autosave debounce plus the store worker), and an autosave can capture
        # the pre-enrichment "Loading visual…" snapshot. Read with a bounded
        # retry until the stored blocks are settled.
        blocks = []
        if conn:
            workspace_id = str(state.get("workspaceId") or "")
            deadline = time.monotonic() + 12
            while True:
                blocks = stored_blocks(conn, workspace_id)
                settled = blocks and not loading_placeholder(blocks)
                if settled or time.monotonic() > deadline:
                    break
                time.sleep(0.5)
        verdict = evaluate(entry, state, blocks, elapsed)
        verdict.update({"id": entry["id"], "kind": entry.get("kind", "mixed"),
                        "prompt": entry["prompt"], "seconds": round(elapsed, 1),
                        "workspaceId": state.get("workspaceId")})
        results.append(verdict)
        print(("%-24s %-4s %5.1fs  %s" % (entry["id"], "pass" if verdict["passed"] else "FAIL",
              elapsed, ", ".join(verdict["blockTypes"]) or "no blocks") +
              (("  -- " + verdict["notes"]) if verdict["notes"] else "")), flush=True)
    if conn:
        conn.close()
    return results


def summarize(results):
    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    kinds = {}
    for r in results:
        bucket = kinds.setdefault(r["kind"], [0, 0])
        bucket[0] += 1
        bucket[1] += 1 if r["passed"] else 0
    return {"prompts": total, "passed": passed,
            "byKind": {k: {"total": v[0], "passed": v[1]} for k, v in sorted(kinds.items())}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompts", default=str(Path(__file__).with_name("bench-prompts.json")))
    parser.add_argument("--limit", type=int, default=0, help="run only the first N prompts")
    parser.add_argument("--only", default="", help="comma-separated prompt ids")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--out", default="")
    args = parser.parse_args(argv)

    entries = load_prompts(args.prompts)
    if args.only:
        wanted = {part.strip() for part in args.only.split(",") if part.strip()}
        entries = [e for e in entries if e["id"] in wanted]
    if args.limit:
        entries = entries[:args.limit]
    if not entries:
        print("no prompts selected", file=sys.stderr)
        return 2
    results = run(entries, timeout=args.timeout)
    report = {"version": 1, "summary": summarize(results), "results": results}
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text)
    print("\n" + json.dumps(report["summary"]))
    return 0 if report["summary"]["passed"] == report["summary"]["prompts"] else 1


if __name__ == "__main__":
    sys.exit(main())
