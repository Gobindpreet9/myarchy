"""Offline /proc fixtures: python -m unittest discover -s tests -p test_ai_resource_probe.py."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ai_resource_probe", Path(__file__).resolve().parents[1] / "ai_resource_probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def stat(pid, ppid=1, ticks=30, start=100, name="process (with) spaces)"):
    fields = ["S"] + ["0"] * 21
    fields[1], fields[11], fields[12], fields[19] = str(ppid), str(ticks - 10), "10", str(start)
    return f"{pid} ({name}) " + " ".join(fields)


class ResourceProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-probe-", dir="/tmp/opencode")
        self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)

    def process(self, pid, ppid=1, args=("quickshell",), ticks=30, start=100, pss=12, rss=40):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        (directory / "stat").write_text(stat(pid, ppid, ticks, start))
        (directory / "cmdline").write_bytes("\0".join(args).encode() + b"\0")
        (directory / "smaps_rollup").write_text(f"Rss: {rss} kB\nPss: {pss} kB\nSwapPss: 900 kB\n")
        return directory

    def test_stat_comm_spaces_and_nested_parentheses(self):
        parsed = probe.parse_stat(stat(42, 7, 123, 987))
        self.assertEqual(parsed, dict(pid=42, ppid=7, name="process (with) spaces)", cpu_ticks=123, start_ticks=987))

    def test_tree_and_inherited_categories(self):
        self.process(10)
        self.process(20, 10, ("python3", "/plugin/ai_broker.py"))
        self.process(21, 20, ("/bin/codex", "exec"))
        self.process(22, 21, ("node",))
        self.process(30, 10, ("python3", "ai_media.py"))
        self.process(40, 10, ("python3", "ai_workspace_store.py"))
        self.process(50, 10, ("unrelated",))
        self.process(60, 1, ("codex",))
        self.process(70, 10, ("omarchy-agent-update",))
        self.process(71, 70, ("codex",))
        self.process(72, 71, ("git",))
        sample = probe.snapshot(self.proc, 10)
        self.assertEqual({p["pid"]: p["category"] for p in sample["processes"]},
                          {10: "shell", 20: "broker", 21: "provider", 22: "provider", 30: "media", 40: "store", 50: "other",
                           70: "other", 71: "external-provider", 72: "external-provider"})
        total = probe.aggregate(sample, None, 0, 100)["total"]
        self.assertEqual(total["pss_bytes"], 10 * 12 * 1024)
        self.assertEqual(total["rss_bytes"], 10 * 40 * 1024)
        self.assertIsNone(total["cpu_delta_ticks_known"])

    def test_categories_ignore_prompt_arguments(self):
        self.assertEqual(probe.category(["unrelated", "ai_broker.py"]), "other")
        self.assertEqual(probe.category(["codex", "exec", "ai_workspace_store.py"], "broker"), "provider")
        self.assertEqual(probe.category(["python3", "-I", "/plugin/ai_hermes.py", "root"], "broker"), "provider")
        self.assertEqual(probe.category(["node", "/bin/codex", "exec"], "broker"), "provider")
        self.assertEqual(probe.category(["codex", "exec"]), "external-provider")

    def test_unreadable_missing_memory_and_target_are_not_zero(self):
        root = self.process(10)
        child = self.process(20, 10)
        (child / "smaps_rollup").unlink()
        sample = probe.snapshot(self.proc, 10)
        total = probe.aggregate(sample, None, 0, 100)["total"]
        self.assertIsNone(total["pss_bytes"])
        self.assertEqual(total["pss_bytes_readable"], 12 * 1024)
        self.assertEqual(total["pss_bytes_missing"], 1)
        self.assertTrue(sample["errors"])
        (root / "smaps_rollup").write_text("Rss: 40 kB\n")
        self.assertIsNone(probe.snapshot(self.proc, 10)["processes"][0]["pss_bytes"])
        missing = probe.snapshot(self.proc, 999)
        self.assertFalse(missing["target_present"])
        self.assertIsNone(probe.aggregate(missing, None, 0, 100)["total"]["pss_bytes"])
        self.assertIsNone(probe.aggregate(missing, sample["processes"], 2, 100)["total"]["cpu_delta_ticks_known"])

    def test_permission_denied_smaps_is_explicit(self):
        directory = self.process(10)
        original = Path.read_text
        def read(path, *args, **kwargs):
            if path == directory / "smaps_rollup":
                raise PermissionError("fixture permission denied")
            return original(path, *args, **kwargs)
        with patch.object(Path, "read_text", read):
            sample = probe.snapshot(self.proc, 10)
        self.assertIsNone(sample["processes"][0]["pss_bytes"])
        self.assertIn("permission denied", sample["errors"][0])

    def test_cpu_units_process_exit_new_and_pid_reuse(self):
        self.process(10, ticks=100)
        self.process(20, 10, ticks=500)
        first = probe.snapshot(self.proc, 10)
        self.process(10, ticks=120)
        self.process(20, 10, ticks=540)
        second = probe.snapshot(self.proc, 10)
        total = probe.aggregate(second, first["processes"], 2, 100)["total"]
        self.assertEqual(total["cpu_delta_ticks_known"], 60)
        self.assertEqual(total["cpu_percent_one_core_known"], 30)
        self.assertTrue(total["cpu_delta_complete"])
        # Reuse must not subtract old counters or count a new process's lifetime.
        self.process(10, ticks=140)
        self.process(20, 10, ticks=9000, start=200)
        third = probe.snapshot(self.proc, 10)
        total = probe.aggregate(third, second["processes"], 2, 100)["total"]
        self.assertEqual(total["cpu_delta_ticks_known"], 20)
        self.assertFalse(total["cpu_delta_complete"])
        (self.proc / "20/stat").unlink()
        self.process(10, ticks=160)
        fourth = probe.snapshot(self.proc, 10)
        total = probe.aggregate(fourth, third["processes"], 2, 100)["total"]
        self.assertEqual(total["cpu_delta_ticks_known"], 20)
        self.assertFalse(total["cpu_delta_complete"])
        self.process(30, 10, ticks=800)
        self.assertFalse(probe.aggregate(probe.snapshot(self.proc, 10), fourth["processes"], 2, 100)["total"]["cpu_delta_complete"])

    def test_root_reuse_excluded(self):
        self.process(10, start=200)
        sample = probe.snapshot(self.proc, 10, expected_start=100)
        self.assertFalse(sample["target_present"])
        self.assertIn("reused", sample["errors"][0])

    def test_regressing_cpu_counter_and_category_change_incomplete(self):
        self.process(10, ticks=100)
        self.process(20, 10, ("ai_broker.py",), ticks=100)
        first = probe.snapshot(self.proc, 10)
        self.process(10, ticks=90)
        self.process(20, 10, ("codex",), ticks=120)
        second = probe.snapshot(self.proc, 10)
        groups = probe.aggregate(second, first["processes"], 2, 100)
        self.assertEqual(groups["total"]["cpu_delta_ticks_known"], 20)
        self.assertFalse(groups["total"]["cpu_delta_complete"])
        self.assertFalse(groups["external-provider"]["cpu_delta_complete"])

    def test_missing_target_report_has_no_cpu_measurement(self):
        with patch.object(probe, "hardware", return_value={}):
            report = probe.run(999, proc=self.proc)
        self.assertEqual(len(report["samples"]), 1)
        self.assertIsNone(report["summary"]["total"]["cpu_seconds_known"])

    def test_exit_or_reuse_during_smaps_read_excluded(self):
        directory = self.process(10)
        original = Path.read_text
        def read(path, *args, **kwargs):
            text = original(path, *args, **kwargs)
            if path == directory / "smaps_rollup":
                (directory / "stat").write_text(stat(10, start=200))
            return text
        with patch.object(Path, "read_text", read):
            sample = probe.snapshot(self.proc, 10)
        self.assertEqual(sample["processes"], [])
        self.assertIn("reused", sample["errors"][0])

    def test_memory_units(self):
        self.assertEqual(probe.memory("Pss: 1024 kB\nRss: 2048 kB"),
                         {"pss_bytes": 1048576, "rss_bytes": 2097152})
        with self.assertRaises(ValueError):
            probe.memory("Pss: 1 MB")

    def test_hardware_offline(self):
        (self.proc / "cpuinfo").write_text("model name : Fixture CPU\n")
        (self.proc / "meminfo").write_text("MemTotal: 1024 kB\n")
        release = self.proc / "release"
        release.write_text('NAME="Fixture OS"')
        device = self.proc / "class/drm/card0/device"
        device.mkdir(parents=True)
        (device / "vendor").write_text("0x1234")
        (device / "device").write_text("0xabcd")
        data = probe.hardware(self.proc, self.proc, release)
        self.assertEqual(data["ram_total_bytes"], 1048576)
        self.assertEqual(data["cpu_model"], "Fixture CPU")
        self.assertEqual(data["gpu_pci_ids"][0]["device"], "0xabcd")

    def test_report_timing_peaks_and_limitations(self):
        self.process(10, ticks=100)
        def advance(_):
            self.process(10, ticks=120, pss=24)
        with patch.object(probe, "hardware", return_value={}), patch.object(probe.os, "sysconf", return_value=100), \
                patch.object(probe.time, "monotonic", side_effect=[0, 0, 2]), patch.object(probe.time, "sleep", side_effect=advance):
            report = probe.run(10, 2, 2, "static", "warm fixture", self.proc)
        self.assertEqual(report["observed_seconds"], 2)
        peaks = report["peak_observed"]["total"]
        self.assertEqual(peaks["pss_bytes"], 24 * 1024)
        self.assertEqual(report["summary"]["total"]["cpu_seconds_known"], 0.2)
        self.assertEqual(report["summary"]["total"]["average_cpu_percent_one_core_known"], 10)
        self.assertIn("not true peaks", " ".join(report["limitations"]))

    def test_cli_defaults_stdout_output_and_bounds(self):
        output = self.proc / "report.json"
        with patch.object(probe, "run", return_value={"fixture": True}) as run, contextlib.redirect_stdout(io.StringIO()) as stdout:
            probe.main(["--pid", "10", "--output", str(output)])
        self.assertEqual(run.call_args.args, (10, 60, 1, "unspecified", ""))
        self.assertEqual(json.loads(stdout.getvalue()), {"fixture": True})
        self.assertEqual(output.read_text(), stdout.getvalue())
        for options in (["--pid", "0"], ["--pid", "10", "--seconds", "nan"],
                        ["--pid", "10", "--seconds", "1801"], ["--pid", "10", "--interval", "0"],
                        ["--pid", "10", "--interval", "inf"], ["--pid", "10", "--seconds", "1", "--interval", "2"],
                        ["--pid", "10", "--seconds", "1800", "--interval", "0.1"]):
            with self.subTest(options=options), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                probe.main(options)


if __name__ == "__main__":
    unittest.main()
