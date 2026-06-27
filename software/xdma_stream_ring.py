#!/usr/bin/env python3
"""Continuously feed a DDR ring buffer for STREAM replay mode.

The input file must use the Tick Replayer stream-record format:

  64-byte header: gap_ticks, reserved32, frame_len, flags
  64-byte-aligned payload

The loader commits only complete packet records to FPGA DDR.  It updates the
producer pointer after each committed batch and polls the FPGA consumer pointer
before writing more data, so unread ring data is not overwritten.
"""

from __future__ import annotations

import argparse
import json
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
REG_STREAM_WR_LO = 0x00A0
REG_STREAM_WR_HI = 0x00A4
REG_STREAM_RD_LO = 0x00A8
REG_STREAM_RD_HI = 0x00AC
REG_STREAM_RING_LO = 0x00B0
REG_STREAM_RING_HI = 0x00B4
REG_STREAM_CTRL = 0x00B8
REG_STREAM_STATUS = 0x00BC
REG_STREAM_LEVEL_LO = 0x00C0
REG_STREAM_LEVEL_HI = 0x00C4

TX_PORT_BASE = {0: 0x00000, 1: 0x10000}
MODE_STREAM = 1


def int_auto(value: str) -> int:
    return int(value, 0)


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stream", type=Path, help="stream.bin path")
    parser.add_argument("--manifest", type=Path, help="stream_manifest.json from trace_to_stream.py")
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--reg-base", type=int_auto, help="override AXI-Lite replay register base")
    parser.add_argument("--ring-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--ring-size", type=int_auto, default=0x0800_0000)
    parser.add_argument("--prefill-bytes", type=int_auto, default=0)
    parser.add_argument("--guard-bytes", type=int_auto, default=1 * 1024 * 1024)
    parser.add_argument("--batch-bytes", type=int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--poll-interval", type=float, default=0.001)
    parser.add_argument("--start-time", type=int_auto, default=0)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-wait", action="store_true")
    return parser.parse_args()


def load_manifest(args: argparse.Namespace) -> int:
    if args.manifest is None:
        return 0
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if args.stream is None:
        args.stream = args.manifest.parent / Path(manifest["stream_file"]).name
    return int(manifest.get("packet_count", 0))


def require_file(path: Path | None, label: str) -> Path:
    if path is None:
        raise SystemExit(f"{label} is required")
    if not path.is_file():
        raise SystemExit(f"{label} not found: {path}")
    return path


def write32(fd: int, offset: int, value: int) -> None:
    os.pwrite(fd, struct.pack("<I", value & 0xFFFF_FFFF), offset)


def read32(fd: int, offset: int) -> int:
    return struct.unpack("<I", os.pread(fd, 4, offset))[0]


def write64(fd: int, lo: int, hi: int, value: int) -> None:
    write32(fd, lo, value)
    write32(fd, hi, value >> 32)


def read64(fd: int, lo: int, hi: int) -> int:
    return read32(fd, lo) | (read32(fd, hi) << 32)


def read_record(fh) -> bytes | None:
    header = fh.read(DATA_BEAT_BYTES)
    if not header:
        return None
    if len(header) != DATA_BEAT_BYTES:
        raise RuntimeError("short stream header")
    frame_len = struct.unpack_from("<H", header, 12)[0]
    payload_len = align_up(frame_len, DATA_BEAT_BYTES)
    payload = fh.read(payload_len)
    if len(payload) != payload_len:
        raise RuntimeError("short stream payload")
    return header + payload


def pwrite_ring(fd: int, data: bytes, ring_base: int, ring_size: int, write_count: int) -> None:
    offset = write_count % ring_size
    done = 0
    while done < len(data):
        chunk_len = min(len(data) - done, ring_size - offset)
        written = 0
        view = memoryview(data)[done:done + chunk_len]
        while written < chunk_len:
            written += os.pwrite(fd, view[written:], ring_base + offset + written)
        done += chunk_len
        offset = 0


def configure(user_fd: int, base: int, args: argparse.Namespace) -> None:
    write32(user_fd, base + REG_CONTROL, 0x4)
    write32(user_fd, base + REG_MODE, MODE_STREAM)
    write64(user_fd, base + REG_DESC_BASE_LO, base + REG_DESC_BASE_HI, args.ring_base)
    write64(user_fd, base + REG_DATA_BASE_LO, base + REG_DATA_BASE_HI, 0)
    write64(user_fd, base + REG_TRACE_LO, base + REG_TRACE_HI, 0)
    write64(user_fd, base + REG_PKT_LO, base + REG_PKT_HI, 0)
    write64(user_fd, base + REG_START_LO, base + REG_START_HI, args.start_time)
    write32(user_fd, base + REG_RATE, args.rate_q16_16)
    write64(user_fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI, 0)
    write64(user_fd, base + REG_STREAM_RING_LO, base + REG_STREAM_RING_HI, args.ring_size)
    write32(user_fd, base + REG_STREAM_CTRL, 0)

    debug = read32(user_fd, base + REG_DEBUG_CTRL)
    if args.force_link_up:
        debug |= 0x1
    if args.force_tx_ready:
        debug |= 0x2
    write32(user_fd, base + REG_DEBUG_CTRL, debug)


def start_replay(user_fd: int, base: int) -> None:
    write32(user_fd, base + REG_CONTROL, 0x1)


def wait_done(user_fd: int, base: int, timeout: float) -> tuple[bool, float]:
    t0 = time.perf_counter()
    while True:
        status = read32(user_fd, base + REG_STATUS)
        if (status & 0x2) and not (status & 0x1):
            return True, time.perf_counter() - t0
        if time.perf_counter() - t0 > timeout:
            return False, time.perf_counter() - t0
        time.sleep(0.01)


def main() -> None:
    args = parse_args()
    manifest_packets = load_manifest(args)
    stream_path = require_file(args.stream, "--stream")

    if args.ring_size <= 0 or args.ring_size % DATA_BEAT_BYTES != 0:
        raise SystemExit("--ring-size must be a positive 64-byte multiple")
    if args.guard_bytes < DATA_BEAT_BYTES:
        raise SystemExit("--guard-bytes must be at least 64")
    if args.guard_bytes >= args.ring_size:
        raise SystemExit("--guard-bytes must be smaller than --ring-size")
    if args.batch_bytes < DATA_BEAT_BYTES:
        raise SystemExit("--batch-bytes must be at least 64")

    prefill = args.prefill_bytes or min(args.ring_size // 2, 64 * 1024 * 1024)
    prefill = max(DATA_BEAT_BYTES, min(prefill, args.ring_size - args.guard_bytes))
    reg_base = TX_PORT_BASE[args.port] if args.reg_base is None else args.reg_base

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)

    started = False
    eof = False
    pending: bytes | None = None
    write_count = 0
    packet_count = 0
    max_level = 0
    min_free = args.ring_size
    load_start = time.perf_counter()

    try:
        configure(user_fd, reg_base, args)
        with stream_path.open("rb") as fh:
            while True:
                if pending is None and not eof:
                    pending = read_record(fh)
                    if pending is None:
                        eof = True
                        if manifest_packets and manifest_packets != packet_count:
                            raise RuntimeError(
                                f"manifest packet_count={manifest_packets} but parsed {packet_count}"
                            )
                        write64(user_fd, reg_base + REG_PKT_LO, reg_base + REG_PKT_HI, packet_count)
                        write32(user_fd, reg_base + REG_STREAM_CTRL, 0x1)
                        if not started:
                            start_replay(user_fd, reg_base)
                            started = True

                if pending is None:
                    break

                if len(pending) + args.guard_bytes > args.ring_size:
                    raise RuntimeError("one stream record is too large for the selected ring")

                read_count = read64(user_fd, reg_base + REG_STREAM_RD_LO, reg_base + REG_STREAM_RD_HI)
                if read_count > write_count:
                    raise RuntimeError(f"FPGA read pointer advanced past host write pointer: {read_count}>{write_count}")
                level = write_count - read_count
                free = args.ring_size - level - args.guard_bytes
                max_level = max(max_level, level)
                min_free = min(min_free, free)

                if free >= len(pending):
                    pwrite_ring(h2c_fd, pending, args.ring_base, args.ring_size, write_count)
                    write_count += len(pending)
                    packet_count += 1
                    write64(user_fd, reg_base + REG_STREAM_WR_LO, reg_base + REG_STREAM_WR_HI, write_count)
                    pending = None
                    if not started and write_count >= prefill:
                        start_replay(user_fd, reg_base)
                        started = True
                else:
                    if not started and write_count:
                        start_replay(user_fd, reg_base)
                        started = True
                    time.sleep(args.poll_interval)

        load_seconds = time.perf_counter() - load_start

        if not args.no_wait:
            completed, wall_seconds = wait_done(user_fd, reg_base, args.timeout)
        else:
            completed, wall_seconds = False, 0.0

        tx_pkts = read64(user_fd, reg_base + REG_TX_PKTS_LO, reg_base + REG_TX_PKTS_HI)
        tx_bytes = read64(user_fd, reg_base + REG_TX_BYTES_LO, reg_base + REG_TX_BYTES_HI)
        late_pkts = read64(user_fd, reg_base + REG_LATE_LO, reg_base + REG_LATE_HI)
        underrun_pkts = read64(user_fd, reg_base + REG_UNDERRUN_LO, reg_base + REG_UNDERRUN_HI)
        ticks = read64(user_fd, reg_base + REG_DEBUG_TICK_LO, reg_base + REG_DEBUG_TICK_HI)
        stream_status = read32(user_fd, reg_base + REG_STREAM_STATUS)
        stream_level = read64(user_fd, reg_base + REG_STREAM_LEVEL_LO, reg_base + REG_STREAM_LEVEL_HI)

        hw_seconds = ticks / args.tick_hz if ticks else wall_seconds
        hw_gbps = (tx_bytes * 8 / hw_seconds / 1e9) if hw_seconds > 0 else 0.0
        load_gbps = (write_count * 8 / load_seconds / 1e9) if load_seconds > 0 else 0.0

        print(f"stream_file       : {stream_path}")
        print(f"ring_base         : 0x{args.ring_base:x}")
        print(f"ring_size         : {args.ring_size}")
        print(f"committed_bytes   : {write_count}")
        print(f"committed_packets : {packet_count}")
        print(f"completed         : {completed}")
        print(f"tx_packets        : {tx_pkts}")
        print(f"tx_bytes          : {tx_bytes}")
        print(f"late_packets      : {late_pkts}")
        print(f"underrun_packets  : {underrun_pkts}")
        print(f"stream_status     : 0x{stream_status:08x}")
        print(f"final_level       : {stream_level}")
        print(f"max_ring_level    : {max_level}")
        print(f"min_ring_free     : {min_free}")
        print(f"load_gbps         : {load_gbps:.3f}")
        print(f"hw_gbps           : {hw_gbps:.3f}")
        print(f"load_seconds      : {load_seconds:.6f}")
        print(f"wall_seconds      : {wall_seconds:.6f}")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
