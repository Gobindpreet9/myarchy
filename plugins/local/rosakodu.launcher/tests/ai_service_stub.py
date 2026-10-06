#!/usr/bin/env python3
"""In-memory store/broker protocol fixture; never access files or providers."""
import json
import sys


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    store = "--serve" in sys.argv[1:]
    if not store:
        emit({"type": "ready"})
    for line in sys.stdin:
        command = json.loads(line)
        op = command.get("op")
        if not store:
            if op == "new":
                emit({"type": "ready"})
            elif op == "stop":
                emit({"type": "stopped"})
            # Submit intentionally has no provider or asynchronous side effects.
            continue
        if op == "load":
            emit({"ok": True, "workspace": {"id": "ws-lazy-1", "agent": "codex",
                                           "draft": "Stored draft", "attachment": ""},
                  "artifacts": [], "interaction": {"turn:1": {
                      "id": 1, "prompt": "Fixture", "answer": "Stored answer", "blocks": [],
                      "status": "done", "suggestions": [], "warning": "", "error": ""}}})
        elif op == "list":
            emit({"ok": True, "workspaces": []})
        else:
            emit({"ok": True})


if __name__ == "__main__":
    main()
