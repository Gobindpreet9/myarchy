#!/usr/bin/env python3
"""Reproduce/verify the native bundle in scratch; never install into the plugin."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / "openui"
OUTPUTS = ["native-worker.cjs", "native-worker.meta.json", "native-metadata.json", "native-schema.json",
           "native-reactive.json", "native-system-prompt.txt", "native-examples.json"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="replace generated assets after successful tests")
    parser.add_argument("--check", action="store_true", help="compare assets only (the default)")
    args = parser.parse_args()
    if args.write and args.check:
        parser.error("choose --write or --check")
    scratch = Path(tempfile.mkdtemp(prefix="openui-rebuild-", dir="/tmp/opencode"))
    build = scratch / "build"
    shutil.copytree(SOURCE, build, ignore=shutil.ignore_patterns("node_modules", "dist"))
    home = scratch / "home"
    home.mkdir(mode=0o700)
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(home),
           "npm_config_cache": str(scratch / "npm-cache"), "OPENUI_TELEMETRY_DISABLED": "1", "DO_NOT_TRACK": "1"}
    for command in (["/usr/bin/npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
                    ["/usr/bin/npm", "run", "build"], ["/usr/bin/npm", "test"]):
        result = subprocess.run(command, cwd=build, env=env, capture_output=True, text=True, timeout=150)
        if result.returncode:
            print(result.stdout, result.stderr)
            print("Build scratch:", scratch)
            return result.returncode
    outputs = OUTPUTS + (["native-worker.cjs.LEGAL.txt"] if (build / "native-worker.cjs.LEGAL.txt").exists() else [])
    stale = []
    for name in outputs:
        destination = SOURCE / name
        if destination.is_symlink():
            raise ValueError("Refusing a symlinked generated asset")
        data = (build / name).read_bytes()
        if args.write:
            destination.write_bytes(data)
        elif not destination.is_file() or destination.read_bytes() != data:
            stale.append(name)
    print("Build/tests passed;", "wrote assets" if args.write else "assets byte-identical" if not stale else "stale: " + ", ".join(stale))
    print("Build scratch:", scratch)
    return bool(stale)


if __name__ == "__main__":
    raise SystemExit(main())
