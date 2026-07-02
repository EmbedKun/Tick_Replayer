#!/usr/bin/env python3
"""Generate stream-mode stress datasets, load them through XDMA, and report throughput."""

from __future__ import annotations

import argparse
import csv
import os
import struct
import time
from pathlib import Path


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
REG_WATERMARK = 0x004C
REG_DEBUG_CTRL = 0x0054
REG_STREAM_WR_LO = 0x00A0
REG_STREAM_WR_HI = 0x00A4
REG_STREAM_RING_LO = 0x00B0
REG_STREAM_RING_HI = 0x00B4
REG_STREAM_CTRL = 0x00B8
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
MODE_STREAM = 1


def int_auto(value: str) -> int:
    return int(value, 0)


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def parse_frame_sizes(value: str) -> list[int]:
    sizes = [int_auto(item.strip()) for item in value.split(",") if item.strip()]
    if not sizes:
        raise argparse.ArgumentTypeError("at least one frame size is required")
    return sizes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--reg-base", type=int_auto, help="override AXI-Lite replay register base")
    parser.add_argument("--stream-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_stream_stress"))
    parser.add_argument("--frame-sizes", type=parse_frame_sizes, default=parse_frame_sizes("64,128,256,512,1024,1518"))
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--gap-ticks", type=int_auto, default=0)
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--watermark", type=int_auto, default=4096)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-auto-drop", action="store_true", help="clear DEBUG_CTRL[2] for strict no-drop tests")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--csv", type=Path, help="optional CSV result path")
    return parser.parse_args()


def make_payload(packet_index: int, frame_len: int) -> bytes:
    return bytes(((packet_index * 13 + i) & 0xFF) for i in range(frame_len))


def make_stream(path: Path, packet_count: int, frame_len: int, gap_ticks: int) -> tuple[int, int]:
    payload_aligned = align_up(frame_len, DATA_BEAT_BYTES)
    total_frame_bytes = packet_count * frame_len
    stream_bytes = packet_count * (DATA_BEAT_BYTES + payload_aligned)

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fh:
        for pkt_idx in range(packet_count):
            header = bytearray(DATA_BEAT_BYTES)
            struct.pack_into("<QIHH", header, 0, gap_ticks, 0, frame_len, 0)
            payload = make_payload(pkt_idx, frame_len)
            fh.write(header)
            fh.write(payload)
            fh.write(bytes(payload_aligned - frame_len))
    return stream_bytes, total_frame_bytes


def pwrite_all(fd: int, path: Path, addr: int, chunk_bytes: int) -> None:
    offset = 0
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(chunk_bytes)
            if not chunk:
                break
            written = 0
            while written < len(chunk):
                written += os.pwrite(fd, chunk[written:], addr + offset + written)
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


def configure_and_start(fd: int, base: int, args: argparse.Namespace, stream_bytes: int, packet_count: int) -> None:
    write32(fd, base + REG_CONTROL, 0x2)
    time.sleep(0.001)
    write32(fd, base + REG_CONTROL, 0x4)
    time.sleep(0.001)
    write32(fd, base + REG_MODE, MODE_STREAM)
    write64(fd, base + REG_DESC_BASE_LO, base + REG_DESC_BASE_HI, args.stream_base)
    write64(fd, base + REG_DATA_BASE_LO, base + REG_DATA_BASE_HI, 0)
    write64(fd, base + REG_TRACE_LO, base + REG_TRACE_HI, stream_bytes)
    write64(fd, base + REG_PKT_LO, base + REG_PKT_HI, packet_count)
    write64(fd, base + REG_START_LO, base + REG_START_HI, 0)
    write32(fd, base + REG_RATE, args.rate_q16_16)
    write32(fd, base + REG_WATERMARK, args.watermark)
    write64(fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI, 0)
    write64(fd, base + REG_STREAM_RING_LO, base + REG_STREAM_RING_HI, 0)
    write32(fd, base + REG_STREAM_CTRL, 0)

    debug = read32(fd, base + REG_DEBUG_CTRL)
    if args.force_link_up:
        debug |= 0x1
    if args.force_tx_ready:
        debug |= 0x2
    if args.no_auto_drop:
        debug &= ~0x4
    else:
        debug |= 0x4
    write32(fd, base + REG_DEBUG_CTRL, debug)
    write32(fd, base + REG_CONTROL, 0x1)


def stop_and_clear(fd: int, base: int) -> None:
    write32(fd, base + REG_CONTROL, 0x2)
    time.sleep(0.001)
    write32(fd, base + REG_CONTROL, 0x4)
    time.sleep(0.001)


def wait_done(fd: int, base: int, timeout_s: float) -> tuple[bool, float]:
    start = time.perf_counter()
    while True:
        status = read32(fd, base + REG_STATUS)
        running = bool(status & 0x1)
        done = bool(status & 0x2)
        if done and not running:
            return True, time.perf_counter() - start
        if time.perf_counter() - start > timeout_s:
            return False, time.perf_counter() - start
        time.sleep(0.005)


def run_case(args: argparse.Namespace, h2c_fd: int, user_fd: int, base: int, frame_len: int) -> dict[str, int | float | bool]:
    stream_path = args.work_dir / f"stream_len{frame_len}_pkts{args.packet_count}.bin"
    stream_bytes, total_frame_bytes = make_stream(stream_path, args.packet_count, frame_len, args.gap_ticks)

    print(f"\ncase frame_len={frame_len} packets={args.packet_count} stream_bytes={stream_bytes}")
    load_start = time.perf_counter()
    pwrite_all(h2c_fd, stream_path, args.stream_base, args.chunk_bytes)
    load_seconds = time.perf_counter() - load_start

    configure_and_start(user_fd, base, args, stream_bytes, args.packet_count)
    completed, wall_seconds = wait_done(user_fd, base, args.timeout)

    tx_pkts = read64(user_fd, base + REG_TX_PKTS_LO, base + REG_TX_PKTS_HI)
    tx_bytes = read64(user_fd, base + REG_TX_BYTES_LO, base + REG_TX_BYTES_HI)
    late_pkts = read64(user_fd, base + REG_LATE_LO, base + REG_LATE_HI)
    underrun_pkts = read64(user_fd, base + REG_UNDERRUN_LO, base + REG_UNDERRUN_HI)
    drop_pkts = read64(user_fd, base + REG_DROP_PKTS_LO, base + REG_DROP_PKTS_HI)
    drop_beats = read64(user_fd, base + REG_DROP_BEATS_LO, base + REG_DROP_BEATS_HI)
    stall_events = read64(user_fd, base + REG_STALL_EVT_LO, base + REG_STALL_EVT_HI)
    ticks = read64(user_fd, base + REG_DEBUG_TICK_LO, base + REG_DEBUG_TICK_HI)

    hw_seconds = ticks / args.tick_hz if ticks else wall_seconds
    hw_gbps = (tx_bytes * 8 / hw_seconds / 1e9) if hw_seconds > 0 else 0.0
    load_gbps = (stream_bytes * 8 / load_seconds / 1e9) if load_seconds > 0 else 0.0

    result = {
        "frame_len": frame_len,
        "packet_count": args.packet_count,
        "stream_bytes": stream_bytes,
        "total_frame_bytes": total_frame_bytes,
        "completed": completed,
        "tx_packets": tx_pkts,
        "tx_bytes": tx_bytes,
        "late_packets": late_pkts,
        "underrun_packets": underrun_pkts,
        "drop_packets": drop_pkts,
        "drop_beats": drop_beats,
        "stall_events": stall_events,
        "debug_ticks": ticks,
        "hw_seconds": hw_seconds,
        "hw_gbps": hw_gbps,
        "load_seconds": load_seconds,
        "load_gbps": load_gbps,
        "wall_seconds": wall_seconds,
    }
    print(
        "result "
        f"done={completed} tx_pkts={tx_pkts} tx_bytes={tx_bytes} "
        f"hw_gbps={hw_gbps:.3f} load_gbps={load_gbps:.3f} "
        f"late={late_pkts} underrun={underrun_pkts} "
        f"drop_pkts={drop_pkts} stall_events={stall_events}"
    )
    if not completed:
        stop_and_clear(user_fd, base)
    return result


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    args.work_dir.mkdir(parents=True, exist_ok=True)
    reg_base = TX_PORT_BASE[args.port] if args.reg_base is None else args.reg_base

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    results = []
    try:
        for frame_len in args.frame_sizes:
            if frame_len <= 0 or frame_len > 0xFFFF:
                raise SystemExit(f"invalid frame size: {frame_len}")
            results.append(run_case(args, h2c_fd, user_fd, reg_base, frame_len))
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
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
