#!/usr/bin/env python3
"""Check PRELOAD scheduler tick accounting against descriptor gap_ticks."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import preload_mixed_test as pmt
import preload_stress_test as pst


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0000_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1000_0000)
    parser.add_argument("--packet-count", type=pst.int_auto, default=50_000)
    parser.add_argument("--pattern", type=pmt.parse_pattern, default=pmt.parse_pattern("64:3,1518:38"))
    parser.add_argument("--work-dir", default="/tmp/traffic_replay_preload_precision")
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-auto-drop", action="store_true")
    parser.add_argument("--rate-q16-16", type=pst.int_auto, default=0x0001_0000)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--max-abs-tick-error", type=pst.int_auto, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    reg_base = pst.TX_PORT_BASE[args.port]
    desc_path, data_path, desc_size, data_size, _payload_bytes, expected_ticks = pmt.make_mixed_trace(
        Path(args.work_dir), args.packet_count, args.pattern
    )

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        pst.pwrite_file(h2c_fd, desc_path, args.desc_base, 4 * 1024 * 1024)
        pst.pwrite_file(h2c_fd, data_path, args.data_base, 4 * 1024 * 1024)
        pst.configure_and_start(user_fd, reg_base, args, desc_size, data_size)
        completed, wall_seconds = pst.wait_done(user_fd, reg_base, args.packet_count, args.timeout)

        tx_pkts = pst.read64(user_fd, reg_base + pst.REG_TX_PKTS_LO, reg_base + pst.REG_TX_PKTS_HI)
        late_pkts = pst.read64(user_fd, reg_base + pst.REG_LATE_LO, reg_base + pst.REG_LATE_HI)
        underrun_pkts = pst.read64(user_fd, reg_base + pst.REG_UNDERRUN_LO, reg_base + pst.REG_UNDERRUN_HI)
        drop_pkts = pst.read64(user_fd, reg_base + pst.REG_DROP_PKTS_LO, reg_base + pst.REG_DROP_PKTS_HI)
        stall_events = pst.read64(user_fd, reg_base + pst.REG_STALL_EVT_LO, reg_base + pst.REG_STALL_EVT_HI)
        debug_ticks = pst.read64(user_fd, reg_base + pst.REG_DEBUG_TICK_LO, reg_base + pst.REG_DEBUG_TICK_HI)
        tick_error = int(debug_ticks) - int(expected_ticks)

        print(f"port              : {args.port}")
        print(f"pattern           : {','.join(f'{length}:{gap}' for length, gap in args.pattern)}")
        print(f"packet_count      : {args.packet_count}")
        print(f"completed         : {completed}")
        print(f"tx_packets        : {tx_pkts}")
        print(f"late_packets      : {late_pkts}")
        print(f"underrun_packets  : {underrun_pkts}")
        print(f"drop_packets      : {drop_pkts}")
        print(f"stall_events      : {stall_events}")
        print(f"expected_ticks    : {expected_ticks}")
        print(f"debug_ticks       : {debug_ticks}")
        print(f"tick_error        : {tick_error}")
        print(f"wall_seconds      : {wall_seconds:.6f}")

        if (
            not completed
            or tx_pkts != args.packet_count
            or late_pkts != 0
            or underrun_pkts != 0
            or drop_pkts != 0
            or stall_events != 0
            or abs(tick_error) > args.max_abs_tick_error
        ):
            raise SystemExit("FAIL: scheduler precision check failed")
        print("PASS: scheduler debug_ticks matches descriptor gap_ticks budget")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
