from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


SOFTWARE_DIR = Path(__file__).resolve().parents[1]
CLI = SOFTWARE_DIR / "tick_replay.py"


class TickReplayCliTests(unittest.TestCase):
    def dry_run(self, *args: str) -> str:
        result = subprocess.run(
            [sys.executable, str(CLI), "--dry-run", *args],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertNotIn("ERROR:", result.stderr)
        return result.stdout

    def test_prepare_and_preload_commands(self) -> None:
        prepare = self.dry_run("prepare", "input.pcap", "--out-dir", "trace")
        self.assertIn("pcap2trace.py", prepare)
        self.assertIn("--tick-hz 300000000", prepare)

        preload = self.dry_run(
            "load",
            "--manifest",
            "trace/manifest.json",
            "--port",
            "1",
            "--mode",
            "loop",
            "--arm-only",
        )
        self.assertIn("xdma_load_trace.py", preload)
        self.assertIn("--desc-base 0x400000000", preload)
        self.assertIn("--data-base 0x410000000", preload)
        self.assertIn("--mode loop", preload)
        self.assertIn("--no-start", preload)

    def test_stream_command_uses_multichannel_auto_backend(self) -> None:
        output = self.dry_run(
            "stream",
            "--stripe-manifest",
            "stripe/manifest.json",
            "--port",
            "0",
            "--pingpong",
            "--egress-schedule",
            "--start-delay-ms",
            "25",
        )
        self.assertIn("xdma_stream_ring_fast", output)
        self.assertIn("--h2c auto", output)
        self.assertIn("--ring-base 0x20000000", output)
        self.assertIn("--writer-threads 4", output)
        self.assertIn("--reader-threads 16", output)
        self.assertIn("--pingpong-bank1-base 0x400000000", output)
        self.assertIn("--start-delay-ms 25.0", output)
        self.assertIn("--egress-schedule", output)

    def test_control_measurement_and_validation_commands(self) -> None:
        sync = self.dry_run("sync-start", "--ports", "0,1", "--egress-schedule")
        self.assertEqual(sync.count("egress-schedule on"), 2)
        self.assertIn("sync-start --ports 0,1", sync)

        events = self.dry_run("rx", "--port", "1", "events", "--limit", "1024")
        self.assertIn("--port 1 rx-events --limit 1024", events)

        ddr = self.dry_run("verify", "ddr", "--repeat", "2")
        self.assertEqual(ddr.count("--case"), 8)
        self.assertIn("--case 0x03fff00000:0x100000", ddr)
        self.assertIn("--case 0x0ffff00000:0x100000", ddr)
        self.assertIn("--repeat 2", ddr)

        benchmark = self.dry_run("benchmark", "h2c", "--threads", "4")
        self.assertIn("xdma_h2c_bench", benchmark)
        self.assertIn("--h2c auto", benchmark)
        self.assertIn("--threads 4", benchmark)

        validate = self.dry_run(
            "validate",
            "--profile",
            "stress",
            "--port",
            "1",
            "--rx-port",
            "0",
            "--skip-ring",
        )
        self.assertIn("hw_validation_suite.py", validate)
        self.assertIn("--profile stress", validate)
        self.assertIn("--port 1 --h2c /dev/xdma0_h2c_0", validate)
        self.assertIn("--c2h /dev/xdma0_c2h_0 --user /dev/xdma0_user --rx-port 0", validate)
        self.assertIn("--skip-ring", validate)


if __name__ == "__main__":
    unittest.main()
