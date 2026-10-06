"""Establish answer-only Hermes policy before importing the installed CLI."""
import os
from collections.abc import MutableMapping
import runpy
import sys

SAFETY_ENV = {key: "1" for key in ("HERMES_SAFE_MODE", "HERMES_IGNORE_USER_CONFIG", "HERMES_IGNORE_RULES")}


class SafetyEnvironment(MutableMapping):
    """Allow credential dotenv loading, but never let it undo the safety flags."""
    def __init__(self, underlying):
        self.underlying = underlying
        self.underlying.update(SAFETY_ENV)

    def __getitem__(self, key):
        return self.underlying[key]

    def __setitem__(self, key, value):
        self.underlying[key] = SAFETY_ENV.get(key, value)

    def __delitem__(self, key):
        if key not in SAFETY_ENV:
            del self.underlying[key]

    def __iter__(self):
        return iter(self.underlying)

    def __len__(self):
        return len(self.underlying)

    def copy(self):
        return dict(self)


def deny_tools(*args, **kwargs):
    raise RuntimeError("Launcher answer-only policy denied a tool call")


def install_guards():
    for key in ("HERMES_SAFE_MODE", "HERMES_IGNORE_USER_CONFIG", "HERMES_IGNORE_RULES"):
        os.environ[key] = "1"
    import model_tools
    import toolsets
    toolsets.create_custom_toolset("launcher_answer_only", "No tools", tools=[])
    model_tools.get_tool_definitions = lambda *args, **kwargs: []
    model_tools.handle_function_call = deny_tools
    from run_agent import AIAgent
    original_init = AIAgent.__init__

    def answer_only_init(self, *args, **kwargs):
        kwargs.update(enabled_toolsets=["launcher_answer_only"], skip_memory=True,
                      skip_background_review=True, skip_context_files=True,
                      load_soul_identity=False, save_trajectories=False,
                      checkpoints_enabled=False, max_tokens=8192)
        original_init(self, *args, **kwargs)
        if self.tools:
            raise RuntimeError("Launcher answer-only policy requires an empty tool list")

    AIAgent.__init__ = answer_only_init
    for name in ("_execute_tool_calls", "_execute_tool_calls_sequential", "_execute_tool_calls_concurrent"):
        setattr(AIAgent, name, deny_tools)


def main():
    root = sys.argv.pop(1)
    sys.path.insert(0, root)
    os.environ = SafetyEnvironment(os.environ)
    # Activate the already-installed dependencies without bootstrap's installer,
    # recovery or re-exec paths, which could otherwise bypass these guards.
    for key in ("HERMES_SAFE_MODE", "HERMES_IGNORE_USER_CONFIG", "HERMES_IGNORE_RULES"):
        os.environ[key] = "1"
    from pathlib import Path
    from pm import environments
    # Dependencies belong to this installed checkout, not the session/auth home.
    environments.dependency_home_root = lambda: Path(root).parent
    environments.activate_dependencies(Path(root))
    from hermes_cli import venv_sync, _early_recovery
    venv_sync.prepare_launch = lambda *args, **kwargs: None
    _early_recovery.recover_if_needed = lambda *args, **kwargs: None
    import hermes_bootstrap  # cannot install/recover/re-exec after the overrides
    install_guards()
    sys.argv[0] = "hermes"
    runpy.run_module("hermes_cli.main", run_name="__main__")


if __name__ == "__main__":
    main()
