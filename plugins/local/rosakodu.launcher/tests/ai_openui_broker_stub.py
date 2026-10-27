"""Synthetic OpenUI broker fixture; no files, credentials or provider imports."""
import json
import sys


def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)


emit({"type": "ready"})
for line in sys.stdin:
    request = json.loads(line)
    op = request.get("op")
    if op == "new":
        emit({"type": "ready"})
    elif op == "submit":
        if request.get("responseMode") != "openui":
            emit({"type": "error", "turnId": request["turnId"], "message": "Fixture needs the OpenUI profile."})
            continue
        value = 2
        if request["prompt"] in ("Revise", "Revise selected"):
            context = request.get("openuiContext", {})
            value = context.get("state", {}).get("$n")
            selected = request["prompt"] == "Revise selected"
            if value != (9 if selected else 7) or not context.get("code") or (selected and "$n = 2" not in context["code"]):
                emit({"type": "error", "turnId": request["turnId"], "message": "Fixture needs the acknowledged local state."})
                continue
        program = f'$n = {value}\nroot = Col([Input($n, "Amount", "number"), Text($n * 3), Button("Reset", @Reset($n))])'
        emit({"type": "done", "turnId": request["turnId"], "answer": "Adjust the amount locally.",
              "blocks": [{"type": "text", "text": "Synthetic offline fixture."},
                         {"type": "openui", "title": "A linked local tool", "code": program}],
              "suggestions": []})
    elif op == "stop":
        emit({"type": "stopped", "turnId": request.get("turnId")})
    elif op == "shutdown":
        break
