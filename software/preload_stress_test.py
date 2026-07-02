#!/usr/bin/env python3
"""Generate preload traces, replay them from DDR, and report TX robustness counters."""

from __future__ import annotations

import argparse
import csv
import os
import struct
import time
from pathlib import Path


DESC_BYTES = 64
DATA_BEAT_BYTES = 64
DEFAULT_TICK_HZ = 300_000_000

REG_CONTROL = 0x0000
REG_MODE = 0x0004
REG_STATUS = 0x0008
REG_DESC_BASE_LO = 0x0010
REG_DESC_BASE_HI = 0x0014
REG_DATA_BASE_LO = 0x0018
REG_DATA_BASE_HI = 0x001C
REG_TRACE_LO = 0x0020
REG_TRACE_HI = 0x0024
REG_PKT_LO = 0x0028
REG_PKT_HI = 0x002C
REG_START_LO = 0x0040
REG_START_HI = 0x0044
REG_RATE = 0x0048
REG_DEBUG_CTRL = 0x0054
REG_TX_PKTS_LO = 0x0060
REG_TX_PKTS_HI = 0x0064
REG_TX_BYTES_LO = 0x0068
REG_TX_BYTES_HI = 0x006C
REG_LATE_LO = 0x0070
REG_LATE_HI = 0x0074
REG_UNDERRUN_LO = 0x0078
REG_UNDERRUN_HI = 0x007C
REG_DEBUG_TICK_LO = 0x0094
REG_DEBUG_TICK_HI = 0x0098
REG_DROP_PKTS_LO = 0x00C8
REG_DROP_PKTS_HI = 0x00CC
REG_DROP_BEATS_LO = 0x00D0
REG_DROP_BEATS_HI = 0x00D4
REG_STALL_EVT_LO = 0x00D8
REG_STALL_EVT_HI = 0x00DC

TX_PORT_BASE = {0: 0x00000, 1: 0x10000}
MODE_PRELOAD = 0


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_case(value: str) -> tuple[int, int]:
    if ":" not in value:
        raise argparse.ArgumentTypeError("case must be frame_len:gap_ticks")
    frame_s, gap_s = value.split(":", 1)
    frame_len = int_auto(frame_s)
    gap_ticks = int_auto(gap_s)
    if frame_len <= 0 or frame_len > 0xFFFF:
        raise argparse.ArgumentTypeError("frame_len must be in 1..65535")
    if gap_ticks < 0:
        raise argparse.ArgumentTypeError("gap_ticks must be non-negative")
    return frame_len, gap_ticks


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--reg-base", type=int_auto)
    parser.add_argument("--desc-base", type=int_auto, default=0x0000_0000)
    parser.add_argument("--data-base", type=int_auto, default=0x1000_0000)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_preload_stress"))
    parser.add_argument("--case", action="append", type=parse_case, dest="cases", help="frame_len:gap_ticks")
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--wire-overhead-bytes", type=int_auto, default=24)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-auto-drop", action="store_true", help="clear DEBUG_CTRL[2] for strict stall observation")
    parser.add_argument("--require-no-drop", action="store_true", help="fail if drop/stall/late/underrun counters increment")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--csv", type=Path)
    return parser.parse_args()


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def make_frame(packet_index: int, frame_len: int) -> bytes:
    return bytes(((packet_index * 17 + i * 3 + (packet_index >> 4)) & 0xFF) for i in range(frame_len))


def make_trace(out_dir: Path, packet_count: int, frame_len: int, gap_ticks: int) -> tuple[Path, Path, int, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    desc_path = out_dir / "desc.bin"
    data_path = out_dir / "data.bin"
    data_words = 0

    with desc_path.open("wb") as desc_fh, data_path.open("wb") as data_fh:
        for pkt_idx in range(packet_count):
            desc = struct.pack("<QIHH", gap_ticks, data_words, frame_len, 0)
            desc_fh.write(desc)
            desc_fh.write(bytes(DESC_BYTES - len(desc)))

            frame = make_frame(pkt_idx, frame_len)
            padded_len = align_up(frame_len, DATA_BEAT_BYTES)
            data_fh.write(frame)
            data_fh.write(bytes(padded_len - frame_len))
            data_words += padded_len // DATA_BEAT_BYTES

    return desc_path, data_path, packet_count * DESC_BYTES, data_words * DATA_BEAT_BYTES


def pwrite_file(fd: int, path: Path, addr: int, chunk_bytes: int) -> None:
    offset = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(chunk_bytes)
            if not chunk:
                break
            written = 0
            while written < len(chunk):
                rc = os.pwrite(fd, chunk[written:], addr + offset + written)
                if rc <= 0:
                    raise RuntimeError("short H2C write")
                written += rc
            offset += len(chunk)


def write32(fd: int, offset: int, value: int) -> None:
    os.pwrite(fd, struct.pack("<I", value & 0xFFFF_FFFF), offset)


def read32(fd: int, offset: int) -> int:
    return struct.unpack("<I", os.pread(fd, 4, offset))[0]


def write64(fd: int, lo: int, hi: int, value: int) -> None:
    write32(fd, lo, value)
    write32(fd, hi, value >> 32)


def read64(fd: int, lo: int, hi: int) -> int:
    return read32(fd, lo) | (read32(fd, hi) << 32)


def configure_and_start(user_fd: int, base: int, args: argparse.Namespace, desc_size: int, data_size: int) -> None:
    write32(user_fd, base + REG_CONTROL, 0x2)
    time.sleep(0.001)
    write32(user_fd, base + REG_CONTROL, 0x4)
    time.sleep(0.001)
    write32(user_fd, base + REG_MODE, MODE_PRELOAD)
    write64(user_fd, base + REG_DESC_BASE_LO, base + REG_DESC_BASE_HI, args.desc_base)
    write64(user_fd, base + REG_DATA_BASE_LO, base + REG_DATA_BASE_HI, args.data_base)
    write64(user_fd, base + REG_TRACE_LO, base + REG_TRACE_HI, desc_size + data_size)
    write64(user_fd, base + REG_PKT_LO, base + REG_PKT_HI, args.packet_count)
    write64(user_fd, base + REG_START_LO, base + REG_START_HI, 0)
    write32(user_fd, base + REG_RATE, args.rate_q16_16)

    debug = read32(user_fd, base + REG_DEBUG_CTRL)
    if args.force_link_up:
        debug |= 0x1
    if args.force_tx_ready:
        debug |= 0x2
    if args.no_auto_drop:
        debug &= ~0x4
    else:
        debug |= 0x4
    write32(user_fd, base + REG_DEBUG_CTRL, debug)
    write32(user_fd, base + REG_CONTROL, 0x1)


def stop_and_clear(user_fd: int, base: int) -> None:
    write32(user_fd, base + REG_CONTROL, 0x2)
    time.sleep(0.001)
    write32(user_fd, base + REG_CONTROL, 0x4)
    time.sleep(0.001)


def wait_done(user_fd: int, base: int, packet_count: int, timeout_s: float) -> tuple[bool, float]:
    start = time.perf_counter()
    while True:
        status = read32(user_fd, base + REG_STATUS)
        tx_pkts = read64(user_fd, base + REG_TX_PKTS_LO, base + REG_TX_PKTS_HI)
        if (status & 0x2) and not (status & 0x1):
            return True, time.perf_counter() - start
        if tx_pkts >= packet_count and not (status & 0x1):
            return True, time.perf_counter() - start
        if time.perf_counter() - start > timeout_s:
            return False, time.perf_counter() - start
        time.sleep(0.005)


def run_case(args: argparse.Namespace, h2c_fd: int, user_fd: int, base: int, frame_len: int, gap_ticks: int) -> dict[str, int | float | bool]:
    case_dir = args.work_dir / f"preload_len{frame_len}_gap{gap_ticks}_pkts{args.packet_count}"
    desc_path, data_path, desc_size, data_size = make_trace(case_dir, args.packet_count, frame_len, gap_ticks)

    load_start = time.perf_counter()
    pwrite_file(h2c_fd, desc_path, args.desc_base, args.chunk_bytes)
    pwrite_file(h2c_fd, data_path, args.data_base, args.chunk_bytes)
    load_seconds = time.perf_counter() - load_start

    configure_and_start(user_fd, base, args, desc_size, data_size)
    completed, wall_seconds = wait_done(user_fd, base, args.packet_count, args.timeout)

    tx_pkts = read64(user_fd, base + REG_TX_PKTS_LO, base + REG_TX_PKTS_HI)
    tx_bytes = read64(user_fd, base + REG_TX_BYTES_LO, base + REG_TX_BYTES_HI)
    late_pkts = read64(user_fd, base + REG_LATE_LO, base + REG_LATE_HI)
    underrun_pkts = read64(user_fd, base + REG_UNDERRUN_LO, base + REG_UNDERRUN_HI)
    drop_pkts = read64(user_fd, base + REG_DROP_PKTS_LO, base + REG_DROP_PKTS_HI)
    drop_beats = read64(user_fd, base + REG_DROP_BEATS_LO, base + REG_DROP_BEATS_HI)
    stall_events = read64(user_fd, base + REG_STALL_EVT_LO, base + REG_STALL_EVT_HI)
    ticks = read64(user_fd, base + REG_DEBUG_TICK_LO, base + REG_DEBUG_TICK_HI)

    if not completed:
        stop_and_clear(user_fd, base)

    scheduled_seconds = ticks / args.tick_hz if ticks else wall_seconds
    delivered_pkts = max(0, tx_pkts - drop_pkts)
    delivered_bytes = delivered_pkts * frame_len
    delivered_l2_gbps = (delivered_bytes * 8 / scheduled_seconds / 1e9) if scheduled_seconds > 0 else 0.0
    delivered_wire_gbps = (
        delivered_pkts * (frame_len + args.wire_overhead_bytes) * 8 / scheduled_seconds / 1e9
        if scheduled_seconds > 0
        else 0.0
    )
    load_gbps = ((desc_size + data_size) * 8 / load_seconds / 1e9) if load_seconds > 0 else 0.0

    result = {
        "frame_len": frame_len,
        "gap_ticks": gap_ticks,
        "packet_count": args.packet_count,
        "completed": completed,
        "tx_packets": tx_pkts,
        "drop_packets": drop_pkts,
        "delivered_packets_est": delivered_pkts,
        "tx_bytes": tx_bytes,
        "late_packets": late_pkts,
        "underrun_packets": underrun_pkts,
        "drop_beats": drop_beats,
        "stall_events": stall_events,
        "debug_ticks": ticks,
        "scheduled_seconds": scheduled_seconds,
        "wall_seconds": wall_seconds,
        "delivered_l2_gbps": delivered_l2_gbps,
        "delivered_wire_gbps": delivered_wire_gbps,
        "load_seconds": load_seconds,
        "load_gbps": load_gbps,
    }

    print(
        f"case frame_len={frame_len} gap={gap_ticks} done={completed} "
        f"tx={tx_pkts} drop={drop_pkts} delivered_est={delivered_pkts} "
        f"late={late_pkts} underrun={underrun_pkts} stall={stall_events} "
        f"l2={delivered_l2_gbps:.3f}Gbps wire={delivered_wire_gbps:.3f}Gbps "
        f"load={load_gbps:.3f}Gbps"
    )

    if args.require_no_drop and (drop_pkts or drop_beats or stall_events or late_pkts or underrun_pkts):
        raise SystemExit(f"strict preload case failed: frame_len={frame_len} gap={gap_ticks}")
    return result


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    cases = args.cases or [(64, 3), (1518, 38), (64, 2), (1518, 0)]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    reg_base = TX_PORT_BASE[args.port] if args.reg_base is None else args.reg_base

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    results = []
    try:
        for frame_len, gap_ticks in cases:
            results.append(run_case(args, h2c_fd, user_fd, reg_base, frame_len, gap_ticks))
    except BaseException:
        stop_and_clear(user_fd, reg_base)
        raise
    finally:
        os.close(h2c_fd)
        os.close(user_fd)

    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(results[0].keys()))
            writer.writeheader()
            writer.writerows(results)
        print(f"wrote {args.csv}")


if __name__ == "__main__":
    main()
