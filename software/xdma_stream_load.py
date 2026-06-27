#!/usr/bin/env python3
"""Load a DDR-backed stream buffer and start STREAM replay mode."""

from __future__ import annotations

import argparse
import json
import os
import struct
from pathlib import Path


REG_CONTROL = 0x0000
REG_MODE = 0x0004
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
REG_STREAM_WR_LO = 0x00A0
REG_STREAM_WR_HI = 0x00A4
REG_STREAM_RING_LO = 0x00B0
REG_STREAM_RING_HI = 0x00B4
REG_STREAM_CTRL = 0x00B8

TX_PORT_BASE = {0: 0x00000, 1: 0x10000}
MODE_STREAM = 1
DATA_BEAT_BYTES = 64


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stream", type=Path, help="stream.bin path")
    parser.add_argument("--manifest", type=Path, help="stream_manifest.json from trace_to_stream.py")
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--reg-base", type=int_auto, help="override AXI-Lite replay register base")
    parser.add_argument("--stream-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--start-time", type=int_auto, default=0)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--clear-force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--clear-force-tx-ready", action="store_true")
    parser.add_argument("--no-start", action="store_true")
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    return parser.parse_args()


def load_manifest(args: argparse.Namespace) -> tuple[int | None, int | None]:
    if args.manifest is None:
        return None, None
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    base = args.manifest.parent
    if args.stream is None:
        args.stream = base / Path(manifest["stream_file"]).name
    return int(manifest.get("packet_count", 0)), int(manifest.get("total_frame_bytes", 0))


def require_file(path: Path | None, label: str) -> Path:
    if path is None:
        raise SystemExit(f"{label} is required")
    if not path.is_file():
        raise SystemExit(f"{label} not found: {path}")
    return path


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


def write64(fd: int, offset_lo: int, offset_hi: int, value: int) -> None:
    write32(fd, offset_lo, value)
    write32(fd, offset_hi, value >> 32)


def main() -> None:
    args = parse_args()
    reg_base = TX_PORT_BASE[args.port] if args.reg_base is None else args.reg_base
    manifest_pkt_count, _ = load_manifest(args)
    stream_path = require_file(args.stream, "--stream")
    stream_size = stream_path.stat().st_size
    if stream_size == 0:
        raise SystemExit("stream file is empty")
    if stream_size % DATA_BEAT_BYTES != 0:
        raise SystemExit(f"stream file size must be 64-byte aligned: {stream_size}")
    pkt_count = manifest_pkt_count if manifest_pkt_count is not None else 0

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    try:
        print(f"DMA stream {stream_path} -> {args.h2c}@0x{args.stream_base:x} ({stream_size} bytes)")
        pwrite_all(h2c_fd, stream_path, args.stream_base, args.chunk_bytes)
    finally:
        os.close(h2c_fd)

    user_fd = os.open(args.user, os.O_RDWR)
    try:
        write32(user_fd, reg_base + REG_CONTROL, 0x4)
        write32(user_fd, reg_base + REG_MODE, MODE_STREAM)
        write64(user_fd, reg_base + REG_DESC_BASE_LO, reg_base + REG_DESC_BASE_HI, args.stream_base)
        write64(user_fd, reg_base + REG_DATA_BASE_LO, reg_base + REG_DATA_BASE_HI, 0)
        write64(user_fd, reg_base + REG_TRACE_LO, reg_base + REG_TRACE_HI, stream_size)
        write64(user_fd, reg_base + REG_PKT_LO, reg_base + REG_PKT_HI, pkt_count)
        write64(user_fd, reg_base + REG_START_LO, reg_base + REG_START_HI, args.start_time)
        write32(user_fd, reg_base + REG_RATE, args.rate_q16_16)
        write64(user_fd, reg_base + REG_STREAM_WR_LO, reg_base + REG_STREAM_WR_HI, 0)
        write64(user_fd, reg_base + REG_STREAM_RING_LO, reg_base + REG_STREAM_RING_HI, 0)
        write32(user_fd, reg_base + REG_STREAM_CTRL, 0)
        if args.force_link_up or args.clear_force_link_up or args.force_tx_ready or args.clear_force_tx_ready:
            debug = read32(user_fd, reg_base + REG_DEBUG_CTRL)
            if args.force_link_up:
                debug |= 0x1
            if args.clear_force_link_up:
                debug &= ~0x1
            if args.force_tx_ready:
                debug |= 0x2
            if args.clear_force_tx_ready:
                debug &= ~0x2
            write32(user_fd, reg_base + REG_DEBUG_CTRL, debug)
        if not args.no_start:
            write32(user_fd, reg_base + REG_CONTROL, 0x1)
    finally:
        os.close(user_fd)

    action = "configured" if args.no_start else "started"
    print(f"{action}: port={args.port} mode=stream packets={pkt_count} stream_base=0x{args.stream_base:x} stream_bytes={stream_size}")


if __name__ == "__main__":
    main()
