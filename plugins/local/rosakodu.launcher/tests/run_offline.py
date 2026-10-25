#!/usr/bin/env python3
"""Run launcher checks with private scratch state and no provider credentials."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = ["AiServiceCheck", "AiWorkspaceStoreCheck", "AiWorkspaceContextCheck",
          "AiSeamsServiceCheck", "AiCsvSourceCheck", "AiAttachmentPreviewCheck",
          "AiPreviewServiceCheck", "AiDetachedWindowCheck"]
SUITES = ["main", "AiBlocksCheck", "AiVisualCheck", "AiAnswerCheck", "AiTaskVisualCheck"]


def run(name, logs):
    home = Path(tempfile.mkdtemp(prefix="ai-preview-check-", dir="/tmp/opencode"))
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("LAUNCHER_", "QML", "QT_", "XDG_", "CODEX_", "HERMES_", "OPENAI_", "ANTHROPIC_", "NODE_"))
           and k not in {"HOME", "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"}}
    env["HOME"] = str(home)
    for key, leaf in {"XDG_STATE_HOME": "s", "XDG_CONFIG_HOME": "c", "XDG_CACHE_HOME": "cache",
                      "XDG_RUNTIME_DIR": "r", "XDG_DATA_HOME": "d"}.items():
        path = home / leaf
        path.mkdir(mode=0o700)
        env[key] = str(path)
    defaults = home / ".config/omarchy/defaults"
    defaults.mkdir(parents=True)
    (defaults / "agent").write_text("codex\n")
    env.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QML_DISABLE_DISK_CACHE="1",
               PYTHONDONTWRITEBYTECODE="1")
    if name == "python":
        command = ["python3", "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"]
    elif name in CHECKS:
        command = ["quickshell", "-p", name + ".qml"]
    else:
        target = "tests" if name == "main" else "tests/" + name + ("" if name.endswith(".qml") else ".qml")
        command = ["/usr/lib/qt6/bin/qmltestrunner", "-input", target]
    path = logs / (name.replace("/", "-") + ".log")
    with path.open("w") as out:
        try:
            code = subprocess.run(command, cwd=ROOT, env=env, stdout=out,
                                  stderr=subprocess.STDOUT, timeout=200).returncode
        except subprocess.TimeoutExpired:
            code = 124
    text = path.read_text(errors="replace")
    summary = [line for line in text.splitlines()
               if any(word in line for word in ("Totals:", "FAIL!", "ERROR", "passed", "Ran ", "OK", "FAILED"))]
    print(name, "exit", code, "\n" + "\n".join(summary[-25:]), flush=True)
    if code:
        print(text[-2500:], flush=True)
    return code


if __name__ == "__main__":
    logs = Path(tempfile.mkdtemp(prefix="launcher-check-", dir="/tmp/opencode"))
    names = sys.argv[1:] or ["python", *SUITES, *CHECKS]
    with ThreadPoolExecutor(max_workers=2) as pool:
        codes = list(pool.map(lambda name: run(name, logs), names))
    print("Logs:", logs)
    sys.exit(any(codes))
