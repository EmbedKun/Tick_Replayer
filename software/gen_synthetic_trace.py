#!/usr/bin/env python3
"""Generate a synthetic descriptor/data trace for replay stress tests."""

from __future__ import annotations

import argparse
import json
import struct
from fractions import Fraction
from pathlib import Path


DESC_BYTES = 64
DATA_BEAT_BYTES = 64
DEFAULT_TICK_HZ = 300_000_000


def int_auto(value: str) -> int:
    return int(value, 0)


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--frame-len", type=int_auto, default=64)
    parser.add_argument("--gap-ticks", type=int_auto, default=0)
    parser.add_argument("--wire-rate-gbps", type=str)
    parser.add_argument("--wire-overhead-bytes", type=int_auto, default=24)
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--seed", type=int_auto, default=0x5A)
    return parser.parse_args()


def make_frame(index: int, frame_len: int, seed: int) -> bytes:
    return bytes(((seed + index * 17 + i) & 0xFF) for i in range(frame_len))


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    if args.frame_len <= 0 or args.frame_len > 0xFFFF:
        raise SystemExit("--frame-len must be in the range 1..65535")
    if args.wire_overhead_bytes < 0:
        raise SystemExit("--wire-overhead-bytes must be non-negative")

    wire_rate_bps = None
    if args.wire_rate_gbps is not None:
        wire_rate_bps = Fraction(args.wire_rate_gbps) * 1_000_000_000
        if wire_rate_bps <= 0:
            raise SystemExit("--wire-rate-gbps must be positive")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    desc_path = args.out_dir / "desc.bin"
    data_path = args.out_dir / "data.bin"
    manifest_path = args.out_dir / "manifest.json"

    data_offset_words = 0
    total_frame_bytes = 0
    previous_target_tick = 0
    gap_min = None
    gap_max = None

    with desc_path.open("wb") as desc_fh, data_path.open("wb") as data_fh:
        for pkt_idx in range(args.packet_count):
            if wire_rate_bps is None:
                gap_ticks = args.gap_ticks
            else:
                wire_bits = (args.frame_len + args.wire_overhead_bytes) * 8
                target_numerator = pkt_idx * wire_bits * args.tick_hz * wire_rate_bps.denominator
                target_denominator = wire_rate_bps.numerator
                target_tick = (target_numerator + target_denominator // 2) // target_denominator
                gap_ticks = target_tick - previous_target_tick
                previous_target_tick = target_tick
            desc = struct.pack("<QIHH", gap_ticks, data_offset_words, args.frame_len, 0)
            desc_fh.write(desc)
            desc_fh.write(bytes(DESC_BYTES - len(desc)))

            frame = make_frame(pkt_idx, args.frame_len, args.seed)
            padded_len = align_up(args.frame_len, DATA_BEAT_BYTES)
            data_fh.write(frame)
            data_fh.write(bytes(padded_len - args.frame_len))

            data_offset_words += padded_len // DATA_BEAT_BYTES
            total_frame_bytes += args.frame_len
            gap_min = gap_ticks if gap_min is None else min(gap_min, gap_ticks)
            gap_max = gap_ticks if gap_max is None else max(gap_max, gap_ticks)

    manifest = {
        "generator": "gen_synthetic_trace.py",
        "descriptor_file": str(desc_path),
        "data_file": str(data_path),
        "descriptor_bytes": DESC_BYTES,
        "data_beat_bytes": DATA_BEAT_BYTES,
        "tick_hz": args.tick_hz,
        "packet_count": args.packet_count,
        "gap_ticks": args.gap_ticks,
        "wire_rate_gbps": args.wire_rate_gbps,
        "wire_overhead_bytes": args.wire_overhead_bytes,
        "gap_ticks_min": gap_min,
        "gap_ticks_max": gap_max,
        "timestamp_quantization": "cumulative_nearest_tick" if wire_rate_bps is not None else "fixed_gap",
        "frame_len": args.frame_len,
        "data_bytes_aligned": data_offset_words * DATA_BEAT_BYTES,
        "total_frame_bytes": total_frame_bytes,
        "max_frame_len": args.frame_len,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
