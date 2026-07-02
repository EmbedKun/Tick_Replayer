#!/usr/bin/env python3
"""Verify TX -> optical loopback -> RX sample-ring payload bytes."""

from __future__ import annotations

import argparse
import os
import struct
import time
from pathlib import Path

import preload_mixed_test as pmt
import preload_stress_test as pst


RX_PORT_BASE = {0: 0x20000, 1: 0x30000}
RX_REG_CONTROL = 0x0000
RX_REG_STATUS = 0x0004
RX_REG_RING_BASE_LO = 0x0010
RX_REG_RING_BASE_HI = 0x0014
RX_REG_RING_SIZE = 0x0018
RX_REG_TRUNC_BYTES = 0x001C
RX_REG_WRITE_PTR = 0x0020
RX_REG_PKTS_LO = 0x0030
RX_REG_PKTS_HI = 0x0034
RX_REG_BYTES_LO = 0x0038
RX_REG_BYTES_HI = 0x003C
RX_REG_ERRS_LO = 0x0040
RX_REG_ERRS_HI = 0x0044
RX_REG_CAP_BYTES_LO = 0x0048
RX_REG_CAP_BYTES_HI = 0x004C
RX_REG_AXI_WR_LO = 0x0050
RX_REG_AXI_WR_HI = 0x0054
RX_REG_AXI_ERR_LO = 0x0058
RX_REG_AXI_ERR_HI = 0x005C


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--c2h", default="/dev/xdma0_c2h_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0400_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1400_0000)
    parser.add_argument("--rx-ring-base", type=pst.int_auto, default=0x3200_0000)
    parser.add_argument("--rx-ring-size", type=pst.int_auto, default=0x0010_0000)
    parser.add_argument("--truncate-bytes", type=pst.int_auto, default=64)
    parser.add_argument("--packet-count", type=pst.int_auto, default=64)
    parser.add_argument("--frame-len", type=pst.int_auto, default=128)
    parser.add_argument("--gap-ticks", type=pst.int_auto, default=2000)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_loopback_verify"))
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--timeout", type=float, default=30.0)
    return parser.parse_args()


def write32(fd: int, offset: int, value: int) -> None:
    os.pwrite(fd, struct.pack("<I", value & 0xFFFF_FFFF), offset)


def read32(fd: int, offset: int) -> int:
    return struct.unpack("<I", os.pread(fd, 4, offset))[0]


def write64(fd: int, lo: int, hi: int, value: int) -> None:
    write32(fd, lo, value)
    write32(fd, hi, value >> 32)


def read64(fd: int, lo: int, hi: int) -> int:
    return read32(fd, lo) | (read32(fd, hi) << 32)


def pread_all(fd: int, size: int, addr: int) -> bytes:
    out = bytearray()
    while len(out) < size:
        chunk = os.pread(fd, size - len(out), addr + len(out))
        if not chunk:
            raise RuntimeError("short C2H read")
        out.extend(chunk)
    return bytes(out)


def configure_rx(user_fd: int, base: int, ring_base: int, ring_size: int, truncate_bytes: int) -> None:
    write32(user_fd, base + RX_REG_CONTROL, 0x0)
    time.sleep(0.001)
    write64(user_fd, base + RX_REG_RING_BASE_LO, base + RX_REG_RING_BASE_HI, ring_base)
    write32(user_fd, base + RX_REG_RING_SIZE, ring_size)
    write32(user_fd, base + RX_REG_TRUNC_BYTES, truncate_bytes)
    write32(user_fd, base + RX_REG_CONTROL, 0x2)
    time.sleep(0.001)
    write32(user_fd, base + RX_REG_CONTROL, 0x5)


def main() -> None:
    args = parse_args()
    if args.truncate_bytes > 64:
        raise SystemExit("this checker currently compares the first 64 bytes per packet")

    pattern = [(args.frame_len, args.gap_ticks)]
    desc_path, data_path, desc_size, data_size, _payload_bytes, _expected_ticks = pmt.make_mixed_trace(
        args.work_dir, args.packet_count, pattern
    )
    tx_base = pst.TX_PORT_BASE[args.tx_port]
    rx_base = RX_PORT_BASE[args.rx_port]

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    c2h_fd = os.open(args.c2h, os.O_RDONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        pst.pwrite_file(h2c_fd, desc_path, args.desc_base, 4 * 1024 * 1024)
        pst.pwrite_file(h2c_fd, data_path, args.data_base, 4 * 1024 * 1024)
        configure_rx(user_fd, rx_base, args.rx_ring_base, args.rx_ring_size, args.truncate_bytes)

        ns = argparse.Namespace(
            desc_base=args.desc_base,
            data_base=args.data_base,
            packet_count=args.packet_count,
            rate_q16_16=0x0001_0000,
            force_link_up=args.force_link_up,
            force_tx_ready=args.force_tx_ready,
            no_auto_drop=False,
        )
        pst.configure_and_start(user_fd, tx_base, ns, desc_size, data_size)
        completed, wall_seconds = pst.wait_done(user_fd, tx_base, args.packet_count, args.timeout)
        time.sleep(0.5)

        tx_pkts = pst.read64(user_fd, tx_base + pst.REG_TX_PKTS_LO, tx_base + pst.REG_TX_PKTS_HI)
        drop_pkts = pst.read64(user_fd, tx_base + pst.REG_DROP_PKTS_LO, tx_base + pst.REG_DROP_PKTS_HI)
        late_pkts = pst.read64(user_fd, tx_base + pst.REG_LATE_LO, tx_base + pst.REG_LATE_HI)
        stall_events = pst.read64(user_fd, tx_base + pst.REG_STALL_EVT_LO, tx_base + pst.REG_STALL_EVT_HI)
        rx_pkts = read64(user_fd, rx_base + RX_REG_PKTS_LO, rx_base + RX_REG_PKTS_HI)
        rx_bytes = read64(user_fd, rx_base + RX_REG_BYTES_LO, rx_base + RX_REG_BYTES_HI)
        rx_errors = read64(user_fd, rx_base + RX_REG_ERRS_LO, rx_base + RX_REG_ERRS_HI)
        cap_bytes = read64(user_fd, rx_base + RX_REG_CAP_BYTES_LO, rx_base + RX_REG_CAP_BYTES_HI)
        axi_writes = read64(user_fd, rx_base + RX_REG_AXI_WR_LO, rx_base + RX_REG_AXI_WR_HI)
        axi_errors = read64(user_fd, rx_base + RX_REG_AXI_ERR_LO, rx_base + RX_REG_AXI_ERR_HI)
        write_ptr = read32(user_fd, rx_base + RX_REG_WRITE_PTR)
        status = read32(user_fd, rx_base + RX_REG_STATUS)

        sample_bytes = args.packet_count * 64
        captured = pread_all(c2h_fd, sample_bytes, args.rx_ring_base)
        mismatches = []
        for pkt_idx in range(args.packet_count):
            expected = pst.make_frame(pkt_idx, args.frame_len)[:64]
            actual = captured[pkt_idx * 64 : (pkt_idx + 1) * 64]
            if actual != expected:
                for byte_idx, (exp, got) in enumerate(zip(expected, actual)):
                    if exp != got:
                        mismatches.append((pkt_idx, byte_idx, exp, got))
                        break
                if len(mismatches) >= 8:
                    break

        print(f"tx_port           : {args.tx_port}")
        print(f"rx_port           : {args.rx_port}")
        print(f"frame_len         : {args.frame_len}")
        print(f"gap_ticks         : {args.gap_ticks}")
        print(f"packet_count      : {args.packet_count}")
        print(f"completed         : {completed}")
        print(f"wall_seconds      : {wall_seconds:.6f}")
        print(f"tx_packets        : {tx_pkts}")
        print(f"drop_packets      : {drop_pkts}")
        print(f"late_packets      : {late_pkts}")
        print(f"stall_events      : {stall_events}")
        print(f"rx_packets        : {rx_pkts}")
        print(f"rx_bytes          : {rx_bytes}")
        print(f"rx_errors         : {rx_errors}")
        print(f"captured_bytes    : {cap_bytes}")
        print(f"axi_writes        : {axi_writes}")
        print(f"axi_errors        : {axi_errors}")
        print(f"write_ptr         : {write_ptr}")
        print(f"rx_status         : 0x{status:08x}")
        print(f"checked_samples   : {args.packet_count}")
        print(f"sample_mismatches : {len(mismatches)}")
        for pkt_idx, byte_idx, exp, got in mismatches:
            print(f"mismatch pkt={pkt_idx} byte={byte_idx} expected=0x{exp:02x} got=0x{got:02x}")

        if (
            not completed
            or tx_pkts != args.packet_count
            or drop_pkts != 0
            or late_pkts != 0
            or stall_events != 0
            or rx_pkts < args.packet_count
            or rx_errors != 0
            or axi_errors != 0
            or mismatches
        ):
            raise SystemExit("FAIL: loopback RX verification failed")
        print("PASS: TX/RX loopback sample payloads match")
    finally:
        os.close(h2c_fd)
        os.close(c2h_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
