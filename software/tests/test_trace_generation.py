from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOFTWARE_DIR = Path(__file__).resolve().parents[1]


def read_gaps(desc_path: Path) -> list[int]:
    raw = desc_path.read_bytes()
    if len(raw) % 64:
        raise AssertionError("descriptor file is not 64-byte aligned")
    return [struct.unpack_from("<Q", raw, offset)[0] for offset in range(0, len(raw), 64)]


class TraceGenerationTests(unittest.TestCase):
    def test_synthetic_100g_64b_uses_fractional_tick_cadence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "trace"
            subprocess.run(
                [
                    sys.executable,
                    str(SOFTWARE_DIR / "gen_synthetic_trace.py"),
                    "--out-dir",
                    str(out_dir),
                    "--packet-count",
                    "10000",
                    "--frame-len",
                    "64",
                    "--wire-rate-gbps",
                    "100",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            gaps = read_gaps(out_dir / "desc.bin")
            self.assertEqual(gaps[0], 0)
            self.assertEqual(set(gaps[1:]), {2, 3})
            expected_last = round((len(gaps) - 1) * 88 * 8 * 300_000_000 / 100_000_000_000)
            self.assertEqual(sum(gaps), expected_last)

            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["timestamp_quantization"], "cumulative_nearest_tick")
            self.assertEqual(manifest["gap_ticks_min"], 0)
            self.assertEqual(manifest["gap_ticks_max"], 3)

    def test_pcap_absolute_quantization_does_not_accumulate_rounding_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            pcap_path = tmp_path / "fractional.pcap"
            out_dir = tmp_path / "trace"
            packet_count = 2000

            with pcap_path.open("wb") as fh:
                fh.write(b"\x4d\x3c\xb2\xa1")
                fh.write(struct.pack("<HHIIII", 2, 4, 0, 0, 65535, 1))
                for index in range(packet_count):
                    timestamp_ns = round(index * 6.72)
                    frame = bytes([index & 0xFF]) * 64
                    fh.write(struct.pack("<IIII", 0, timestamp_ns, len(frame), len(frame)))
                    fh.write(frame)

            subprocess.run(
                [
                    sys.executable,
                    str(SOFTWARE_DIR / "pcap2trace.py"),
                    str(pcap_path),
                    "--out-dir",
                    str(out_dir),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            gaps = read_gaps(out_dir / "desc.bin")
            expected_last_ns = round((packet_count - 1) * 6.72)
            expected_last_tick = round(expected_last_ns * 300_000_000 / 1_000_000_000)
            self.assertEqual(sum(gaps), expected_last_tick)
            self.assertLessEqual(abs(sum(gaps) / 300_000_000 * 1e9 - expected_last_ns), 1.667)


if __name__ == "__main__":
    unittest.main()
