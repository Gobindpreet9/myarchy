#!/usr/bin/env python3
"""In-memory store/broker protocol fixture; never access files or providers."""
import json
import sys


def emit(value):
    print(json.dumps(value), flush=True)


FORM_PROMPT = "Answers to the form on the previous answer."
FORM_KINDS = ("number", "choice", "text", "toggle")


def form_problem(command):
    """Why a form-answer submit is malformed (None when it matches the client contract).

    Mirrors the closed shape the launcher sends in workspaceContext.form; the real
    broker validates it again. Nothing here evaluates or stores anything.
    """
    if command.get("prompt") != FORM_PROMPT or "attachment" in command:
        return "the prompt must be the fixed sentence without an attachment"
    form = (command.get("workspaceContext") or {}).get("form")
    if type(form) is not dict or set(form) != {"turnId", "blockIndex", "title", "answers"}:
        return "form keys"
    if type(form["turnId"]) is not int or type(form["blockIndex"]) is not int or not 0 <= form["blockIndex"] <= 5:
        return "form identity"
    if type(form["title"]) is not str or len(form["title"]) > 160:
        return "form title"
    answers = form["answers"]
    if type(answers) is not list or not 1 <= len(answers) <= 6:
        return "answers"
    for answer in answers:
        if type(answer) is not dict or not {"id", "label", "kind", "value"} <= set(answer) <= {"id", "label", "kind", "value", "valueText", "unit"}:
            return "answer keys"
        if answer["kind"] not in FORM_KINDS or type(answer["label"]) is not str or not 0 < len(answer["label"]) <= 80:
            return "answer kind or label"
        if type(answer["id"]) is not str or not 0 < len(answer["id"]) <= 24:
            return "answer id"
        if ("valueText" in answer) != (answer["kind"] == "choice"):
            return "valueText belongs to choices only"
        if "unit" in answer and (answer["kind"] != "number" or type(answer["unit"]) is not str
                                 or not 0 < len(answer["unit"]) <= 24):
            return "unit belongs to numeric answers only"
        if answer["kind"] == "text" and (type(answer["value"]) is not str or len(answer["value"]) > 200):
            return "text value"
        if answer["kind"] != "text" and (type(answer["value"]) not in (int, float) or type(answer["value"]) is bool):
            return "numeric value"
    return None


CHOICE_PROMPT = "Choice made on the previous answer."
CHOICE_KINDS = ("actions", "compare")
FOCUS_KINDS = ("table", "gallery", "diagram", "steps", "chart", "calc", "compare", "timeline", "actions", "text")
CONTEXT_KEYS = ("form", "choice", "focus")


def ranged(value, low, high):
    return type(value) is int and low <= value <= high


def choice_problem(command):
    """Why a picked-option submit is malformed (None when it matches the client contract).

    A fixture of the closed shape the launcher sends in workspaceContext.choice;
    the real broker's validator (ai_broker.validate_workspace_context) is the authority.
    """
    if command.get("prompt") != CHOICE_PROMPT or "attachment" in command:
        return "the prompt must be the fixed sentence without an attachment"
    choice = command["workspaceContext"]["choice"]
    if type(choice) is not dict or set(choice) != {"turnId", "blockIndex", "kind", "index", "title", "label"}:
        return "choice keys"
    if not ranged(choice["turnId"], 0, 2**53 - 1) or not ranged(choice["blockIndex"], 0, 5) or not ranged(choice["index"], 0, 15):
        return "choice identity"
    if choice["kind"] not in CHOICE_KINDS:
        return "choice kind"
    if type(choice["title"]) is not str or len(choice["title"]) > 160:
        return "choice title"
    if type(choice["label"]) is not str or not 0 < len(choice["label"]) <= 40:
        return "choice label"
    return None


def focus_problem(command):
    """Why a focused typed question is malformed (None when it matches the client contract)."""
    focus = command["workspaceContext"]["focus"]
    if type(focus) is not dict or set(focus) != {"turnId", "blockIndex", "kind", "index", "label", "detail"}:
        return "focus keys"
    if not ranged(focus["turnId"], 0, 2**53 - 1) or not ranged(focus["blockIndex"], 0, 5) or not ranged(focus["index"], -1, 63):
        return "focus identity"
    if focus["kind"] not in FOCUS_KINDS:
        return "focus kind"
    if type(focus["label"]) is not str or not 0 < len(focus["label"]) <= 80:
        return "focus label"
    if type(focus["detail"]) is not str or len(focus["detail"]) > 240:
        return "focus detail"
    return None


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
            # An ordinary submit intentionally has no provider or asynchronous
            # side effects; only a form answer, a picked option or a focused
            # question is acknowledged (or refused).
            context = command.get("workspaceContext") or {}
            present = [key for key in CONTEXT_KEYS if key in context]
            if op == "submit" and present:
                problem = "form, choice and focus are mutually exclusive" if len(present) > 1 else None
                if problem is None:
                    problem = {"form": form_problem, "choice": choice_problem, "focus": focus_problem}[present[0]](command)
                name = present[0].capitalize()
                if problem:
                    emit({"type": "error", "turnId": command.get("turnId"), "message": name + " rejected: " + problem})
                else:
                    emit({"type": "done", "turnId": command.get("turnId"), "answer": name + " accepted",
                          "blocks": [], "suggestions": []})
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
