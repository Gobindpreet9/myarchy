#!/usr/bin/env python3
"""Qt-only offline checks: never import a launcher service or touch user state."""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="qml-openui-", dir="/tmp/opencode") as scratch:
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("LAUNCHER_", "QML", "QT_", "XDG_"))
           and key not in {"HOME", "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "CODEX_HOME", "HERMES_HOME"}}
    for name, leaf in {"HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_STATE_HOME": "state",
                       "XDG_CACHE_HOME": "cache", "XDG_DATA_HOME": "data", "XDG_RUNTIME_DIR": "runtime"}.items():
        path = Path(scratch, leaf)
        path.mkdir(mode=0o700)
        env[name] = str(path)
    env.update(QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software", QT_QUICK_CONTROLS_STYLE="Basic",
               QML_DISABLE_DISK_CACHE="1")
    result = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(HERE), *os.sys.argv[1:]], env=env, check=False)
    raise SystemExit(result.returncode)
