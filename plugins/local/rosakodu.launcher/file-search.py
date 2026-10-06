#!/usr/bin/env python3
"""Bounded, literal local path search for the launcher (HOME QUERY)."""

import bisect
import ctypes
import json
import os
import selectors
import signal
import subprocess
import sys
import time


TIMEOUT_SECONDS = 5.0
MAX_RESULTS = 100
EXCLUDES = (
    ".git", "node_modules", ".cache", ".venv", "venv",
    ".local/share/Trash", ".local/share/Steam", ".npm", ".cargo",
    ".rustup", ".ssh", ".gnupg", ".hermes", ".aws",
    ".env", ".env.*", "*.pem", "*.key",
)
_cancelled = False


def cancel_search(_signum, _frame):
    # Do not raise inside Popen: cancellation there could orphan the child.
    global _cancelled
    _cancelled = True


def search(home, query):
    if not os.path.isabs(home) or not os.path.isdir(home):
        raise ValueError("HOME must be an absolute path to an existing directory")
    home = os.path.abspath(home)
    terms = query.split()
    if not terms or _cancelled:
        return []
    folded_terms = [term.casefold() for term in terms]
    folded_query = " ".join(terms).casefold()
    argv = [
        "fd", "--fixed-strings", "--ignore-case", "--full-path", "--hidden",
        "--absolute-path", "--print0", "--type", "f", "--type", "d",
    ]
    for exclude in EXCLUDES:
        argv.extend(["--exclude", exclude])
    argv.extend(["--", max(terms, key=len), home])
    deadline = time.monotonic() + TIMEOUT_SECONDS
    best = []
    pending = b""
    errors = bytearray()
    timed_out = False
    if sys.platform != "linux":
        raise RuntimeError("file search requires Linux parent-death signals")
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int] + [ctypes.c_ulong] * 4
    libc.prctl.restype = ctypes.c_int
    parent_pid = os.getpid()

    def kill_with_parent():
        # This supervisor is single-threaded, so preexec_fn is safe here.
        # Quickshell may SIGKILL us, bypassing the normal finally cleanup.
        if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        # Cover parent death between fork and installing the death signal.
        if os.getppid() != parent_pid:
            os._exit(1)

    process = subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True, preexec_fn=kill_with_parent,
    )
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map() and not _cancelled:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if key.data == "stderr":
                        errors.extend(chunk[:max(0, 8192 - len(errors))])
                        continue
                    records = (pending + chunk).split(b"\0")
                    pending = records.pop()
                    for record in records:
                        if _cancelled or time.monotonic() >= deadline:
                            timed_out = not _cancelled
                            break
                        path = os.path.normpath(os.fsdecode(record))
                        folded_path = path.casefold()
                        if not all(term in folded_path for term in folded_terms):
                            continue
                        title = os.path.basename(path)
                        folded_title = title.casefold()
                        rank = (0 if folded_title == folded_query else
                                1 if folded_title.startswith(folded_query) else 2)
                        entry = ((rank, folded_path, path), path)
                        bisect.insort(best, entry)
                        if len(best) > MAX_RESULTS:
                            best.pop()
                if timed_out:
                    break
        if not timed_out and not _cancelled:
            # Pipes can close before the process exits; the same deadline applies.
            while process.poll() is None and not _cancelled:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    process.wait(timeout=min(remaining, 0.1))
                except subprocess.TimeoutExpired:
                    pass
        if not timed_out and not _cancelled and process.returncode:
            detail = errors.decode("utf-8", errors="replace").strip()
            raise RuntimeError(detail or f"fd exited with status {process.returncode}")
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()
        process.stdout.close()
        process.stderr.close()
    return [
        {"kind": "file", "path": path, "title": os.path.basename(path),
         "parent": os.path.dirname(path), "isDirectory": os.path.isdir(path)}
        for _, path in best
    ]


def main():
    signal.signal(signal.SIGTERM, cancel_search)
    signal.signal(signal.SIGINT, cancel_search)
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: python3 file-search.py HOME QUERY")
        rows = search(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"file-search: {error}", file=sys.stderr)
        print("[]")
        return 1
    print(json.dumps(rows, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
