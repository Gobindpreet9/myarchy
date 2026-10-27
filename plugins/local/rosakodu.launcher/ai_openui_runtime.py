#!/usr/bin/python3
"""Credential-free JSONL guardian for the bundled, non-JavaScript OpenUI runtime.

No provider/store imports, user paths, environment-based configuration, shell,
or model-selected executable. The guardian owns a separate Node process group;
EOF, termination, bad IPC and a wall-clock deadline all tear that group down.
Node's permission model is an additional boundary, not a replacement for the
worker's language/AST allowlist. Run with /usr/bin/python3 -I -B -u.
"""
from collections import deque
import ctypes
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

FRAME_BYTES = 512 * 1024
PROGRAM_BYTES = 32 * 1024
STATE_BYTES = 64 * 1024
QUEUE_LIMIT = 16
REQUEST_TIMEOUT = 3.0
SAFE_INTEGER = 9007199254740991
WORKER = Path(__file__).resolve().parent / "openui" / "native-worker.cjs"
FORBIDDEN = {"__proto__", "constructor", "prototype"}
KINDS = frozenset("Col Row Grid Card Box Divider Spacer Title Text Caption Label Badge Button IconButton Pressable Input TextArea Slider Checkbox Select SegmentedControl RadioGroup Icon Svg Circle Ellipse Rect Line Path Polyline Polygon G SvgText".split())
WORKER_ERRORS = frozenset("invalid_request invalid_program limit_exceeded stale_token not_loaded invalid_event unsupported_action runtime_error".split())
ERRORS = WORKER_ERRORS | {"runtime_unavailable", "runtime_timeout", "invalid_response", "runtime_stopped"}
WARNING = "Some values could not be calculated."


class Invalid(ValueError):
    pass


def compact(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")


def text(value, limit, nonempty=False):
    if not isinstance(value, str) or (nonempty and not value) or len(value.encode("utf-8")) > limit:
        raise Invalid()
    return value


def json_value(value, string_limit=STATE_BYTES):
    count = 0

    def visit(v, depth):
        nonlocal count
        count += 1
        if count > 32768 or depth > 64:
            raise Invalid()
        if v is None or type(v) is bool:
            return
        if type(v) in (int, float):
            if not math.isfinite(v):
                raise Invalid()
        elif isinstance(v, str):
            text(v, string_limit)
        elif type(v) is list:
            for item in v:
                visit(item, depth + 1)
        elif type(v) is dict:
            for key, item in v.items():
                text(key, 4096)
                if key in FORBIDDEN:
                    raise Invalid()
                visit(item, depth + 1)
        else:
            raise Invalid()

    visit(value, 0)


def state(value):
    if type(value) is not dict or len(value) > 40:
        raise Invalid()
    json_value(value)
    if len(compact(value)) > STATE_BYTES:
        raise Invalid()
    return value


def integer(value):
    return type(value) is int and 0 < value <= SAFE_INTEGER


def request(value):
    if type(value) is not dict or not integer(value.get("id")):
        raise Invalid()
    text(value.get("token"), 128, True)
    if value.get("op") == "load":
        if set(value) != {"id", "token", "op", "program", "state"}:
            raise Invalid()
        text(value["program"], PROGRAM_BYTES, True)
        if not value["program"].strip():
            raise Invalid()
        state(value["state"])
    elif value.get("op") == "event":
        if not {"id", "token", "op", "target", "event"} <= set(value) or set(value) - {"id", "token", "op", "target", "event", "value", "handle"}:
            raise Invalid()
        text(value["target"], 512, True)
        if "handle" in value:
            text(value["handle"], 64, True)
        if value["event"] == "change":
            if "value" not in value:
                raise Invalid()
            v = value["value"]
            if v is not None and type(v) not in (str, bool, int, float):
                raise Invalid()
            json_value(v, PROGRAM_BYTES)
        elif value["event"] != "click" or value.get("value") is not None:
            raise Invalid()
    else:
        raise Invalid()
    if len(compact(value)) + 1 > FRAME_BYTES:
        raise Invalid()
    return value


def tree(value):
    nodes = 0

    def visit(node, expected, depth):
        nonlocal nodes
        nodes += 1
        if nodes > 512 or depth > 64 or type(node) is not dict or set(node) != {"id", "kind", "props", "children"}:
            raise Invalid()
        if node["id"] != expected or node["kind"] not in KINDS or type(node["props"]) is not dict or type(node["children"]) is not list:
            raise Invalid()
        text(node["id"], 512, True)
        # TextArea's bound value is deliberately larger than other props.
        for key, item in node["props"].items():
            if key in FORBIDDEN:
                raise Invalid()
            text(key, 4096)
            json_value(item, PROGRAM_BYTES if node["kind"] == "TextArea" and key == "value" else 4096)
        if len(node["children"]) > 512:
            raise Invalid()
        for i, child in enumerate(node["children"]):
            visit(child, f"{expected}/{i}", depth + 1)

    visit(value, "root", 0)
    return value


def response(value, job):
    if type(value) is not dict or not integer(value.get("id")) or value["id"] != job["id"] or value.get("token") != job["token"]:
        raise Invalid()
    if value.get("ok") is False:
        if set(value) != {"id", "token", "ok", "error"} or value["error"] not in WORKER_ERRORS:
            raise Invalid()
    elif value.get("ok") is True:
        if not {"id", "token", "ok", "tree", "state"} <= set(value) or set(value) - {"id", "token", "ok", "tree", "state", "warning", "copyText"}:
            raise Invalid()
        state(value["state"])
        tree(value["tree"])
        if "warning" in value and value["warning"] != WARNING:
            raise Invalid()
        if "copyText" in value:
            text(value["copyText"], PROGRAM_BYTES)
            if job["op"] != "event" or job["event"] != "click":
                raise Invalid()
    else:
        raise Invalid()
    if len(compact(value)) + 1 > FRAME_BYTES:
        raise Invalid()
    return value


def decode(line):
    # Reject duplicate keys, NaN/Infinity, invalid UTF-8 and excessively nested
    # input before allowing it near the worker or QML's JSON decoder.
    if len(line) + 1 > FRAME_BYTES:
        raise Invalid()
    source = line.decode("utf-8", errors="strict")
    depth, quoted, escaped = 0, False, False
    for ch in source:
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
        elif ch in "[{":
            depth += 1
            if depth > 140:
                raise Invalid()
        elif ch in "]}":
            depth -= 1

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result or key in FORBIDDEN:
                raise Invalid()
            result[key] = value
        return result

    def constant(_):
        raise Invalid()

    return json.loads(source, object_pairs_hook=pairs, parse_constant=constant)


def failure(job, code):
    return {"id": job["id"] if job else None, "token": job["token"] if job else "", "ok": False, "error": code}


def child_setup():
    # Linux parent-death protection also covers a guardian killed with SIGKILL.
    # The trusted worker cannot spawn children (Node permissions deny it).
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != parent:
        os._exit(127)
    os.umask(0o077)


def spawn(worker=WORKER):
    bundle = str(Path(worker).resolve(strict=True))
    return subprocess.Popen([
        "/usr/bin/node", "--max-old-space-size=96", "--max-semi-space-size=4",
        "--stack-size=512", "--no-addons", "--no-deprecation", "--disable-proto=throw",
        "--permission", "--allow-fs-read=" + bundle, bundle,
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd="/", env={"HOME": "/nonexistent", "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
        close_fds=True, start_new_session=True, preexec_fn=child_setup, bufsize=0)


def teardown(proc):
    if proc is None:
        return
    # Always signal the group, even when its leader exited before its children.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()
    for stream in (proc.stdin, proc.stdout):
        if stream:
            stream.close()


def serve(input_fd=0, output_fd=1, *, worker=WORKER, timeout=REQUEST_TIMEOUT):
    """Internal worker/timeout overrides are for isolated tests, never CLI/env."""
    selector = selectors.DefaultSelector()
    wake_r, wake_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    old_signals = {}
    old_blocking = {}
    proc = None
    incoming, child_input, outgoing, child_output = bytearray(), bytearray(), bytearray(), bytearray()
    jobs = deque()
    job, token, deadline = None, None, None
    ending, exit_code, terminated = False, 0, False

    def terminate(_sig, _frame):
        nonlocal terminated
        terminated = True
        try:
            os.write(wake_w, b"x")
        except OSError:
            pass

    def watch(fd, events, label):
        try:
            selector.get_key(fd)
        except KeyError:
            selector.register(fd, events, label)
        else:
            selector.modify(fd, events, label)

    def unwatch(fd):
        try:
            selector.unregister(fd)
        except (KeyError, ValueError):
            pass

    def emit(value):
        frame = compact(value) + b"\n"
        if len(outgoing) + len(frame) > FRAME_BYTES:
            raise Invalid()
        outgoing.extend(frame)
        watch(output_fd, selectors.EVENT_WRITE, "output")

    def fatal(code, current=None):
        nonlocal ending, exit_code, proc, deadline
        teardown(proc)
        if proc is not None:
            unwatch(proc.stdout)
            unwatch(proc.stdin)
        proc = None
        deadline = None
        ending, exit_code = True, 1
        unwatch(input_fd)
        emit(failure(current, code))

    try:
        for fd in (input_fd, output_fd):
            old_blocking[fd] = os.get_blocking(fd)
            os.set_blocking(fd, False)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            old_signals[sig] = signal.signal(sig, terminate)
        watch(input_fd, selectors.EVENT_READ, "input")
        watch(wake_r, selectors.EVENT_READ, "wake")
        while not terminated:
            if ending and not outgoing:
                break
            if not ending and job is None and jobs:
                job = jobs.popleft()
                if token is not None and job["token"] != token:
                    fatal("stale_token", job)
                    continue
                token = job["token"]
                if proc is None:
                    if job["op"] != "load":
                        fatal("not_loaded", job)
                        continue
                    try:
                        proc = spawn(worker)
                    except (OSError, ValueError, subprocess.SubprocessError):
                        fatal("runtime_unavailable", job)
                        continue
                    os.set_blocking(proc.stdin.fileno(), False)
                    os.set_blocking(proc.stdout.fileno(), False)
                    watch(proc.stdout, selectors.EVENT_READ, "child")
                child_input = bytearray(compact(job) + b"\n")
                watch(proc.stdin, selectors.EVENT_WRITE, "send")
                deadline = time.monotonic() + timeout
            wait = max(0, deadline - time.monotonic()) if deadline is not None else None
            events = selector.select(wait)
            if terminated:
                break
            if deadline is not None and time.monotonic() >= deadline:
                fatal("runtime_timeout", job)
                continue
            for key, _ in events:
                label = key.data
                if label == "wake":
                    continue
                if label == "output":
                    try:
                        written = os.write(output_fd, outgoing)
                    except BlockingIOError:
                        continue
                    del outgoing[:written]
                    if not outgoing:
                        unwatch(output_fd)
                elif ending:
                    continue
                elif label == "input":
                    chunk = os.read(input_fd, 65536)
                    if not chunk:  # EOF is cancellation, not permission to keep evaluating.
                        terminated = True
                        break
                    incoming.extend(chunk)
                    if len(incoming) > FRAME_BYTES:
                        fatal("limit_exceeded", job)
                        continue
                    while b"\n" in incoming:
                        line, _, rest = incoming.partition(b"\n")
                        incoming = bytearray(rest)
                        try:
                            candidate = request(decode(line))
                            if len(jobs) >= QUEUE_LIMIT or sum(len(compact(j)) + 1 for j in jobs) + len(line) + 1 > FRAME_BYTES:
                                raise Invalid()
                        except (ValueError, TypeError, UnicodeError, RecursionError, OverflowError):
                            fatal("invalid_request", job)
                            break
                        jobs.append(candidate)
                elif label == "send":
                    try:
                        written = os.write(proc.stdin.fileno(), child_input)
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        fatal("runtime_stopped", job)
                        continue
                    del child_input[:written]
                    if not child_input:
                        unwatch(proc.stdin)
                elif label == "child":
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    if not chunk:
                        fatal("runtime_stopped", job)
                        continue
                    child_output.extend(chunk)
                    if len(child_output) > FRAME_BYTES or job is None:
                        fatal("invalid_response", job)
                        continue
                    if b"\n" in child_output:
                        line, _, rest = child_output.partition(b"\n")
                        try:
                            if rest or child_input:
                                raise Invalid()
                            result = response(decode(line), job)
                        except (ValueError, TypeError, UnicodeError, RecursionError, OverflowError):
                            fatal("invalid_response", job)
                            continue
                        child_output.clear()
                        emit(result)
                        job, deadline = None, None
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError, OverflowError):
        # Never leak filesystem paths, Node errors, stderr or an input value.
        exit_code = 1
    finally:
        teardown(proc)
        selector.close()
        os.close(wake_r)
        os.close(wake_w)
        for sig, handler in old_signals.items():
            signal.signal(sig, handler)
        for fd, blocking in old_blocking.items():
            os.set_blocking(fd, blocking)
    return exit_code


def main():
    if sys.argv[1:] not in ([], ["--serve"]):
        return 1
    os.chdir("/")
    os.umask(0o077)
    return serve()


if __name__ == "__main__":
    raise SystemExit(main())
