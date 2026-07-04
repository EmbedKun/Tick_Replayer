#!/usr/bin/env python3
"""Run RX-side replay precision tests with generated PRELOAD traces.

The suite generates deterministic descriptor/data traces, replays them through
the optical loopback, and delegates per-gap checking to rx_trace_interval_check.
It is intended to cover fixed-gap, mixed-gap, small-gap, mixed-size, and longer
duration precision cases without hand-writing each trace.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import preload_stress_test as pst


SCRIPT_DIR = Path(__file__).resolve().parent


@dataclass(frozen=True)
class PrecisionCase:
    name: str
    packet_count: int
    pattern: tuple[tuple[int, int], ...]
    max_error_ns: float
    max_samples: int = 4096


DEFAULT_CASES: tuple[PrecisionCase, ...] = (
    PrecisionCase(
        name="uniform_128B_gap3000",
        packet_count=1024,
        pattern=((128, 3000),),
        max_error_ns=80.0,
    ),
    PrecisionCase(
        name="mixed_gap_128B",
        packet_count=4096,
        pattern=((128, 3000), (128, 300), (128, 1200), (128, 37), (128, 4800), (128, 96), (128, 15000), (128, 8)),
        max_error_ns=80.0,
    ),
    PrecisionCase(
        name="small_packet_small_gap",
        packet_count=4096,
        pattern=((64, 3), (64, 3), (64, 4), (64, 3), (64, 5), (64, 6), (64, 3), (64, 8)),
        max_error_ns=30.0,
    ),
    PrecisionCase(
        name="mixed_size_legal",
        packet_count=4096,
        # The descriptor gap is the interval from the previous packet to the
        # current packet.  The large gaps before 64B/256B packets cover the
        # preceding 1518B packet's serialization time.
        pattern=((64, 80), (1518, 8), (256, 80), (512, 20), (128, 25), (1518, 12)),
        max_error_ns=120.0,
    ),
    PrecisionCase(
        name="long_uniform_128B_gap3000",
        packet_count=200_000,
        pattern=((128, 3000),),
        max_error_ns=80.0,
        max_samples=4096,
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_precision_suite"))
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0400_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1400_0000)
    parser.add_argument("--desc-stride", type=pst.int_auto, default=0x0200_0000)
    parser.add_argument("--data-stride", type=pst.int_auto, default=0x1000_0000)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--chunk-bytes", type=pst.int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--case", action="append", help="run only named case; may be repeated")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--report", type=Path, help="optional markdown report path")
    return parser.parse_args()


def make_trace(out_dir: Path, packet_count: int, pattern: tuple[tuple[int, int], ...]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    desc_path = out_dir / "desc.bin"
    data_path = out_dir / "data.bin"
    data_words = 0
    total_frame_bytes = 0
    max_frame_len = 0

    with desc_path.open("wb") as desc_fh, data_path.open("wb") as data_fh:
        for pkt_idx in range(packet_count):
            frame_len, gap_ticks = pattern[pkt_idx % len(pattern)]
            desc = gap_ticks.to_bytes(8, "little")
            desc += data_words.to_bytes(4, "little")
            desc += frame_len.to_bytes(2, "little")
            desc += (0).to_bytes(2, "little")
            desc_fh.write(desc)
            desc_fh.write(bytes(pst.DESC_BYTES - len(desc)))

            frame = pst.make_frame(pkt_idx, frame_len)
            padded_len = pst.align_up(frame_len, pst.DATA_BEAT_BYTES)
            data_fh.write(frame)
            data_fh.write(bytes(padded_len - frame_len))
            data_words += padded_len // pst.DATA_BEAT_BYTES
            total_frame_bytes += frame_len
            max_frame_len = max(max_frame_len, frame_len)

    manifest = {
        "generator": "replay_precision_suite.py",
        "descriptor_file": str(desc_path),
        "data_file": str(data_path),
        "descriptor_bytes": pst.DESC_BYTES,
        "data_beat_bytes": pst.DATA_BEAT_BYTES,
        "tick_hz": pst.DEFAULT_TICK_HZ,
        "packet_count": packet_count,
        "pattern": [{"frame_len": frame_len, "gap_ticks": gap_ticks} for frame_len, gap_ticks in pattern],
        "data_bytes_aligned": data_words * pst.DATA_BEAT_BYTES,
        "total_frame_bytes": total_frame_bytes,
        "max_frame_len": max_frame_len,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def run_case(args: argparse.Namespace, case: PrecisionCase, index: int) -> tuple[bool, str]:
    case_dir = args.work_dir / case.name
    manifest = make_trace(case_dir, case.packet_count, case.pattern)
    csv_path = case_dir / "rx_gap_samples.csv"
    desc_base = args.desc_base + index * args.desc_stride
    data_base = args.data_base + index * args.data_stride

    cmd = [
        args.python,
        str(SCRIPT_DIR / "rx_trace_interval_check.py"),
        "--h2c",
        args.h2c,
        "--user",
        args.user,
        "--tx-port",
        str(args.tx_port),
        "--rx-port",
        str(args.rx_port),
        "--manifest",
        str(manifest),
        "--desc-base",
        hex(desc_base),
        "--data-base",
        hex(data_base),
        "--max-samples",
        str(case.max_samples),
        "--max-error-ns",
        str(case.max_error_ns),
        "--timeout",
        str(args.timeout),
        "--chunk-bytes",
        str(args.chunk_bytes),
        "--csv",
        str(csv_path),
    ]
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = case_dir / "run.log"
    log.write_text(proc.stdout, encoding="utf-8")
    return proc.returncode == 0, proc.stdout


def write_report(report_path: Path, results: list[tuple[PrecisionCase, bool, str]]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Replay Precision Suite",
        "",
        "The tests replay generated PRELOAD traces through the optical loopback and compare RX-side SOP-to-SOP intervals with descriptor gaps.",
        "",
        "| Case | Result | Packets | Pattern |",
        "| --- | --- | ---: | --- |",
    ]
    for case, ok, _output in results:
        pattern = ", ".join(f"{length}B/{gap}tick" for length, gap in case.pattern)
        lines.append(f"| `{case.name}` | {'PASS' if ok else 'FAIL'} | {case.packet_count} | `{pattern}` |")
    lines.append("")
    for case, _ok, output in results:
        lines.extend([f"## {case.name}", "", "```text", output.rstrip(), "```", ""])
    report_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    selected = set(args.case or [])
    cases = [case for case in DEFAULT_CASES if not selected or case.name in selected]
    unknown = selected - {case.name for case in DEFAULT_CASES}
    if unknown:
        raise SystemExit(f"unknown case(s): {', '.join(sorted(unknown))}")
    if not cases:
        raise SystemExit("no precision cases selected")

    args.work_dir.mkdir(parents=True, exist_ok=True)
    results: list[tuple[PrecisionCase, bool, str]] = []
    failed = False
    for index, case in enumerate(cases):
        print(f"=== {case.name} ===", flush=True)
        ok, output = run_case(args, case, index)
        print(output.rstrip())
        print(f"RESULT {case.name}: {'PASS' if ok else 'FAIL'}", flush=True)
        results.append((case, ok, output))
        failed = failed or not ok

    if args.report is not None:
        write_report(args.report, results)
        print(f"report: {args.report}")

    if failed:
        raise SystemExit("one or more replay precision cases failed")


if __name__ == "__main__":
    main()
