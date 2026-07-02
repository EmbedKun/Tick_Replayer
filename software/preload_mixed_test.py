#!/usr/bin/env python3
"""Replay an alternating PRELOAD pattern and report mixed-packet throughput."""

from __future__ import annotations

import argparse
import csv
import os
import struct
import time
from pathlib import Path

import preload_stress_test as pst


def parse_pattern(value: str) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        out.append(pst.parse_case(item))
    if not out:
        raise argparse.ArgumentTypeError("pattern must contain at least one frame_len:gap_ticks item")
    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0000_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1000_0000)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_preload_mixed"))
    parser.add_argument("--packet-count", type=pst.int_auto, default=100_000)
    parser.add_argument("--pattern", type=parse_pattern, default=parse_pattern("64:3,1518:38"))
    parser.add_argument("--tick-hz", type=pst.int_auto, default=pst.DEFAULT_TICK_HZ)
    parser.add_argument("--wire-overhead-bytes", type=pst.int_auto, default=24)
    parser.add_argument("--rate-q16-16", type=pst.int_auto, default=0x0001_0000)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-auto-drop", action="store_true")
    parser.add_argument("--require-no-drop", action="store_true")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--chunk-bytes", type=pst.int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--csv", type=Path)
    return parser.parse_args()


def make_mixed_trace(out_dir: Path, packet_count: int, pattern: list[tuple[int, int]]) -> tuple[Path, Path, int, int, int, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    desc_path = out_dir / "desc.bin"
    data_path = out_dir / "data.bin"
    data_words = 0
    payload_bytes = 0
    expected_ticks = 0

    with desc_path.open("wb") as desc_fh, data_path.open("wb") as data_fh:
        for pkt_idx in range(packet_count):
            frame_len, gap_ticks = pattern[pkt_idx % len(pattern)]
            desc = struct.pack("<QIHH", gap_ticks, data_words, frame_len, 0)
            desc_fh.write(desc)
            desc_fh.write(bytes(pst.DESC_BYTES - len(desc)))

            frame = pst.make_frame(pkt_idx, frame_len)
            padded_len = pst.align_up(frame_len, pst.DATA_BEAT_BYTES)
            data_fh.write(frame)
            data_fh.write(bytes(padded_len - frame_len))
            data_words += padded_len // pst.DATA_BEAT_BYTES
            payload_bytes += frame_len
            expected_ticks += gap_ticks

    return desc_path, data_path, packet_count * pst.DESC_BYTES, data_words * pst.DATA_BEAT_BYTES, payload_bytes, expected_ticks


def main() -> None:
    args = parse_args()
    reg_base = pst.TX_PORT_BASE[args.port]
    desc_path, data_path, desc_size, data_size, payload_bytes, expected_ticks = make_mixed_trace(
        args.work_dir, args.packet_count, args.pattern
    )

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        load_start = time.perf_counter()
        pst.pwrite_file(h2c_fd, desc_path, args.desc_base, args.chunk_bytes)
        pst.pwrite_file(h2c_fd, data_path, args.data_base, args.chunk_bytes)
        load_seconds = time.perf_counter() - load_start

        pst.configure_and_start(user_fd, reg_base, args, desc_size, data_size)
        completed, wall_seconds = pst.wait_done(user_fd, reg_base, args.packet_count, args.timeout)

        tx_pkts = pst.read64(user_fd, reg_base + pst.REG_TX_PKTS_LO, reg_base + pst.REG_TX_PKTS_HI)
        tx_bytes = pst.read64(user_fd, reg_base + pst.REG_TX_BYTES_LO, reg_base + pst.REG_TX_BYTES_HI)
        late_pkts = pst.read64(user_fd, reg_base + pst.REG_LATE_LO, reg_base + pst.REG_LATE_HI)
        underrun_pkts = pst.read64(user_fd, reg_base + pst.REG_UNDERRUN_LO, reg_base + pst.REG_UNDERRUN_HI)
        drop_pkts = pst.read64(user_fd, reg_base + pst.REG_DROP_PKTS_LO, reg_base + pst.REG_DROP_PKTS_HI)
        drop_beats = pst.read64(user_fd, reg_base + pst.REG_DROP_BEATS_LO, reg_base + pst.REG_DROP_BEATS_HI)
        stall_events = pst.read64(user_fd, reg_base + pst.REG_STALL_EVT_LO, reg_base + pst.REG_STALL_EVT_HI)
        debug_ticks = pst.read64(user_fd, reg_base + pst.REG_DEBUG_TICK_LO, reg_base + pst.REG_DEBUG_TICK_HI)

        if not completed:
            pst.stop_and_clear(user_fd, reg_base)

        scheduled_seconds = debug_ticks / args.tick_hz if debug_ticks else wall_seconds
        delivered_pkts = max(0, tx_pkts - drop_pkts)
        delivered_ratio = delivered_pkts / tx_pkts if tx_pkts else 0.0
        delivered_payload = int(payload_bytes * delivered_ratio)
        l2_gbps = delivered_payload * 8 / scheduled_seconds / 1e9 if scheduled_seconds > 0 else 0.0
        wire_payload = 0
        for pkt_idx in range(args.packet_count):
            frame_len, _ = args.pattern[pkt_idx % len(args.pattern)]
            wire_payload += frame_len + args.wire_overhead_bytes
        wire_gbps = int(wire_payload * delivered_ratio) * 8 / scheduled_seconds / 1e9 if scheduled_seconds > 0 else 0.0
        load_gbps = (desc_size + data_size) * 8 / load_seconds / 1e9 if load_seconds > 0 else 0.0
        tick_error = int(debug_ticks) - int(expected_ticks)

        result = {
            "port": args.port,
            "packet_count": args.packet_count,
            "pattern": ",".join(f"{length}:{gap}" for length, gap in args.pattern),
            "completed": completed,
            "tx_packets": tx_pkts,
            "tx_bytes": tx_bytes,
            "drop_packets": drop_pkts,
            "late_packets": late_pkts,
            "underrun_packets": underrun_pkts,
            "drop_beats": drop_beats,
            "stall_events": stall_events,
            "expected_ticks": expected_ticks,
            "debug_ticks": debug_ticks,
            "tick_error": tick_error,
            "scheduled_seconds": scheduled_seconds,
            "wall_seconds": wall_seconds,
            "delivered_l2_gbps": l2_gbps,
            "delivered_wire_gbps": wire_gbps,
            "load_seconds": load_seconds,
            "load_gbps": load_gbps,
        }

        print(
            "mixed "
            f"port={args.port} pattern={result['pattern']} packets={args.packet_count} "
            f"done={completed} tx={tx_pkts} drop={drop_pkts} late={late_pkts} "
            f"underrun={underrun_pkts} stall={stall_events} "
            f"ticks={debug_ticks} expected_ticks={expected_ticks} tick_error={tick_error} "
            f"l2={l2_gbps:.3f}Gbps wire={wire_gbps:.3f}Gbps load={load_gbps:.3f}Gbps"
        )

        if args.csv:
            args.csv.parent.mkdir(parents=True, exist_ok=True)
            with args.csv.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=list(result.keys()))
                writer.writeheader()
                writer.writerow(result)
            print(f"wrote {args.csv}")

        if args.require_no_drop and (
            not completed or drop_pkts != 0 or late_pkts != 0 or underrun_pkts != 0 or stall_events != 0
        ):
            raise SystemExit("strict mixed preload case failed")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
