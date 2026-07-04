#!/usr/bin/env python3
"""Measure PRELOAD replay spacing at the RX CMAC side.

The FPGA RX capture core counts cycles between received packet starts in the
CMAC RX clock domain.  This script sends a uniform PRELOAD trace through the
optical loopback and compares the RX-side SOP-to-SOP gap statistics against the
requested descriptor gap converted from the TX scheduler tick clock.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import time
from pathlib import Path

import preload_stress_test as pst


RX_PORT_BASE = {0: 0x20000, 1: 0x30000}
RX_REG_CONTROL = 0x0000
RX_REG_STATUS = 0x0004
RX_REG_RING_SIZE = 0x0018
RX_REG_TRUNC_BYTES = 0x001C
RX_REG_WRITE_PTR = 0x0020
RX_REG_PKTS_LO = 0x0030
RX_REG_PKTS_HI = 0x0034
RX_REG_BYTES_LO = 0x0038
RX_REG_BYTES_HI = 0x003C
RX_REG_ERRS_LO = 0x0040
RX_REG_ERRS_HI = 0x0044
RX_REG_AXI_ERR_LO = 0x0058
RX_REG_AXI_ERR_HI = 0x005C
RX_REG_GAP_COUNT_LO = 0x0064
RX_REG_GAP_COUNT_HI = 0x0068
RX_REG_GAP_SUM_LO = 0x006C
RX_REG_GAP_SUM_HI = 0x0070
RX_REG_GAP_MIN_LO = 0x0074
RX_REG_GAP_MIN_HI = 0x0078
RX_REG_GAP_MAX_LO = 0x007C
RX_REG_GAP_MAX_HI = 0x0080
RX_REG_GAP_LAST_LO = 0x0084
RX_REG_GAP_LAST_HI = 0x0088
RX_REG_TICK_LO = 0x008C
RX_REG_TICK_HI = 0x0090


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0400_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1400_0000)
    parser.add_argument("--packet-count", type=pst.int_auto, default=1000)
    parser.add_argument("--frame-len", type=pst.int_auto, default=64)
    parser.add_argument("--gap-ticks", type=pst.int_auto, default=3000)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_rx_precision"))
    parser.add_argument("--tx-tick-hz", type=pst.int_auto, default=300_000_000)
    parser.add_argument("--rx-tick-hz", type=pst.int_auto, default=322_265_625)
    parser.add_argument("--max-error-rx-cycles", type=float, default=8.0)
    parser.add_argument("--timeout", type=float, default=30.0)
    return parser.parse_args()


def write32(fd: int, offset: int, value: int) -> None:
    os.pwrite(fd, struct.pack("<I", value & 0xFFFF_FFFF), offset)


def read32(fd: int, offset: int) -> int:
    return struct.unpack("<I", os.pread(fd, 4, offset))[0]


def read64(fd: int, lo: int, hi: int) -> int:
    # Stable enough for idle post-run reads, with hi-lo-hi avoiding rollover.
    hi0 = read32(fd, hi)
    lo0 = read32(fd, lo)
    hi1 = read32(fd, hi)
    if hi0 != hi1:
        lo0 = read32(fd, lo)
    return lo0 | (hi1 << 32)


def wait_rx_cleared(user_fd: int, base: int, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        status = read32(user_fd, base + RX_REG_STATUS)
        write_ptr = read32(user_fd, base + RX_REG_WRITE_PTR)
        rx_pkts = read64(user_fd, base + RX_REG_PKTS_LO, base + RX_REG_PKTS_HI)
        rx_bytes = read64(user_fd, base + RX_REG_BYTES_LO, base + RX_REG_BYTES_HI)
        rx_errors = read64(user_fd, base + RX_REG_ERRS_LO, base + RX_REG_ERRS_HI)
        gap_count = read64(user_fd, base + RX_REG_GAP_COUNT_LO, base + RX_REG_GAP_COUNT_HI)
        writer_state = (status >> 7) & 0x3
        busy_bits = status & 0x17
        last = (status, write_ptr, rx_pkts, rx_bytes, rx_errors, gap_count)
        if writer_state == 0 and busy_bits == 0 and write_ptr == 0 and rx_pkts == 0 and rx_bytes == 0 and rx_errors == 0 and gap_count == 0:
            return
        time.sleep(0.01)
    raise TimeoutError(f"RX clear did not settle: {last}")


def configure_rx_stats(user_fd: int, base: int) -> None:
    write32(user_fd, base + RX_REG_CONTROL, 0x0)
    write32(user_fd, base + RX_REG_CONTROL, 0x2)
    wait_rx_cleared(user_fd, base)
    write32(user_fd, base + RX_REG_RING_SIZE, 0)
    write32(user_fd, base + RX_REG_TRUNC_BYTES, 0)
    write32(user_fd, base + RX_REG_CONTROL, 0x2)
    wait_rx_cleared(user_fd, base)
    write32(user_fd, base + RX_REG_CONTROL, 0x1)


def main() -> None:
    args = parse_args()
    if args.packet_count < 2:
        raise SystemExit("--packet-count must be at least 2")

    tx_base = pst.TX_PORT_BASE[args.tx_port]
    rx_base = RX_PORT_BASE[args.rx_port]
    desc_path, data_path, desc_size, data_size = pst.make_trace(
        args.work_dir, args.packet_count, args.frame_len, args.gap_ticks
    )

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        pst.pwrite_file(h2c_fd, desc_path, args.desc_base, 4 * 1024 * 1024)
        pst.pwrite_file(h2c_fd, data_path, args.data_base, 4 * 1024 * 1024)
        configure_rx_stats(user_fd, rx_base)

        ns = argparse.Namespace(
            desc_base=args.desc_base,
            data_base=args.data_base,
            packet_count=args.packet_count,
            rate_q16_16=0x0001_0000,
            force_link_up=False,
            force_tx_ready=False,
            no_auto_drop=False,
        )
        pst.configure_and_start(user_fd, tx_base, ns, desc_size, data_size)
        completed, wall_seconds = pst.wait_done(user_fd, tx_base, args.packet_count, args.timeout)
        time.sleep(0.25)

        tx_pkts = pst.read64(user_fd, tx_base + pst.REG_TX_PKTS_LO, tx_base + pst.REG_TX_PKTS_HI)
        drop_pkts = pst.read64(user_fd, tx_base + pst.REG_DROP_PKTS_LO, tx_base + pst.REG_DROP_PKTS_HI)
        late_pkts = pst.read64(user_fd, tx_base + pst.REG_LATE_LO, tx_base + pst.REG_LATE_HI)
        underrun_pkts = pst.read64(user_fd, tx_base + pst.REG_UNDERRUN_LO, tx_base + pst.REG_UNDERRUN_HI)

        rx_pkts = read64(user_fd, rx_base + RX_REG_PKTS_LO, rx_base + RX_REG_PKTS_HI)
        rx_bytes = read64(user_fd, rx_base + RX_REG_BYTES_LO, rx_base + RX_REG_BYTES_HI)
        rx_errors = read64(user_fd, rx_base + RX_REG_ERRS_LO, rx_base + RX_REG_ERRS_HI)
        axi_errors = read64(user_fd, rx_base + RX_REG_AXI_ERR_LO, rx_base + RX_REG_AXI_ERR_HI)
        gap_count = read64(user_fd, rx_base + RX_REG_GAP_COUNT_LO, rx_base + RX_REG_GAP_COUNT_HI)
        gap_sum = read64(user_fd, rx_base + RX_REG_GAP_SUM_LO, rx_base + RX_REG_GAP_SUM_HI)
        gap_min = read64(user_fd, rx_base + RX_REG_GAP_MIN_LO, rx_base + RX_REG_GAP_MIN_HI)
        gap_max = read64(user_fd, rx_base + RX_REG_GAP_MAX_LO, rx_base + RX_REG_GAP_MAX_HI)
        gap_last = read64(user_fd, rx_base + RX_REG_GAP_LAST_LO, rx_base + RX_REG_GAP_LAST_HI)
        rx_tick = read64(user_fd, rx_base + RX_REG_TICK_LO, rx_base + RX_REG_TICK_HI)

        expected = args.gap_ticks * (args.rx_tick_hz / args.tx_tick_hz)
        avg = gap_sum / gap_count if gap_count else 0.0
        min_err = gap_min - expected
        max_err = gap_max - expected
        avg_err = avg - expected
        max_abs_error = max(abs(min_err), abs(max_err), abs(avg_err))
        cycle_ns = 1e9 / args.rx_tick_hz

        print(f"tx_port           : {args.tx_port}")
        print(f"rx_port           : {args.rx_port}")
        print(f"frame_len         : {args.frame_len}")
        print(f"gap_ticks_tx      : {args.gap_ticks}")
        print(f"tx_tick_hz        : {args.tx_tick_hz}")
        print(f"rx_tick_hz        : {args.rx_tick_hz}")
        print(f"expected_rx_gap   : {expected:.6f}")
        print(f"packet_count      : {args.packet_count}")
        print(f"completed         : {completed}")
        print(f"wall_seconds      : {wall_seconds:.6f}")
        print(f"tx_packets        : {tx_pkts}")
        print(f"drop_packets      : {drop_pkts}")
        print(f"late_packets      : {late_pkts}")
        print(f"underrun_packets  : {underrun_pkts}")
        print(f"rx_packets        : {rx_pkts}")
        print(f"rx_bytes          : {rx_bytes}")
        print(f"rx_errors         : {rx_errors}")
        print(f"axi_errors        : {axi_errors}")
        print(f"rx_gap_count      : {gap_count}")
        print(f"rx_gap_min        : {gap_min}")
        print(f"rx_gap_max        : {gap_max}")
        print(f"rx_gap_last       : {gap_last}")
        print(f"rx_gap_avg        : {avg:.6f}")
        print(f"rx_gap_min_error  : {min_err:.6f} cycles ({min_err * cycle_ns:.3f} ns)")
        print(f"rx_gap_max_error  : {max_err:.6f} cycles ({max_err * cycle_ns:.3f} ns)")
        print(f"rx_gap_avg_error  : {avg_err:.6f} cycles ({avg_err * cycle_ns:.3f} ns)")
        print(f"rx_tick           : {rx_tick}")

        if (
            not completed
            or tx_pkts != args.packet_count
            or drop_pkts != 0
            or late_pkts != 0
            or underrun_pkts != 0
            or rx_pkts < args.packet_count
            or rx_errors != 0
            or axi_errors != 0
            or gap_count != args.packet_count - 1
            or not math.isfinite(avg)
            or max_abs_error > args.max_error_rx_cycles
        ):
            raise SystemExit("FAIL: RX-side scheduling precision check failed")
        print("PASS: RX-side SOP gap statistics match requested PRELOAD spacing")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
