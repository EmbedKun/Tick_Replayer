#!/usr/bin/env python3
"""Load a generated replay trace into DDR through Xilinx XDMA char devices."""

from __future__ import annotations

import argparse
import json
import os
import struct
from pathlib import Path


DESC_BYTES = 64

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
REG_LOOP_LO = 0x0030
REG_LOOP_HI = 0x0034
REG_LOOP_GAP_LO = 0x0038
REG_LOOP_GAP_HI = 0x003C
REG_START_LO = 0x0040
REG_START_HI = 0x0044
REG_RATE = 0x0048
REG_DEBUG_CTRL = 0x0054

MODE_PRELOAD = 0
MODE_STREAM = 1
MODE_LOOP = 2


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="manifest.json from pcap2trace.py")
    parser.add_argument("--desc", type=Path, help="desc.bin path")
    parser.add_argument("--data", type=Path, help="data.bin path")
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--desc-base", type=int_auto, default=0x0000_0000)
    parser.add_argument("--data-base", type=int_auto, default=0x1000_0000)
    parser.add_argument("--mode", choices=["preload", "loop"], default="preload")
    parser.add_argument("--loop-count", type=int_auto, default=0)
    parser.add_argument("--loop-gap", type=int_auto, default=0)
    parser.add_argument("--start-time", type=int_auto, default=0)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--force-link-up", action="store_true", help="set DEBUG_CTRL[0] before start for no-fiber ILA bring-up")
    parser.add_argument("--clear-force-link-up", action="store_true", help="clear DEBUG_CTRL[0] before start")
    parser.add_argument("--no-start", action="store_true")
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    return parser.parse_args()


def load_manifest(args: argparse.Namespace) -> None:
    if args.manifest is None:
        return
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    base = args.manifest.parent
    if args.desc is None:
        args.desc = base / Path(manifest["descriptor_file"]).name
    if args.data is None:
        args.data = base / Path(manifest["data_file"]).name


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


def write64(fd: int, offset_lo: int, offset_hi: int, value: int) -> None:
    write32(fd, offset_lo, value)
    write32(fd, offset_hi, value >> 32)


def main() -> None:
    args = parse_args()
    load_manifest(args)
    desc_path = require_file(args.desc, "--desc")
    data_path = require_file(args.data, "--data")

    desc_size = desc_path.stat().st_size
    data_size = data_path.stat().st_size
    if desc_size % DESC_BYTES != 0:
        raise SystemExit(f"descriptor file size must be a multiple of {DESC_BYTES}: {desc_size}")
    pkt_count = desc_size // DESC_BYTES

    mode_value = MODE_PRELOAD if args.mode == "preload" else MODE_LOOP

    with os.fdopen(os.open(args.h2c, os.O_WRONLY), "wb", closefd=True) as h2c_fh:
        h2c_fd = h2c_fh.fileno()
        print(f"DMA desc {desc_path} -> {args.h2c}@0x{args.desc_base:x} ({desc_size} bytes)")
        pwrite_all(h2c_fd, desc_path, args.desc_base, args.chunk_bytes)
        print(f"DMA data {data_path} -> {args.h2c}@0x{args.data_base:x} ({data_size} bytes)")
        pwrite_all(h2c_fd, data_path, args.data_base, args.chunk_bytes)

    user_fd = os.open(args.user, os.O_RDWR)
    try:
        write32(user_fd, REG_CONTROL, 0x4)
        write32(user_fd, REG_MODE, mode_value)
        write64(user_fd, REG_DESC_BASE_LO, REG_DESC_BASE_HI, args.desc_base)
        write64(user_fd, REG_DATA_BASE_LO, REG_DATA_BASE_HI, args.data_base)
        write64(user_fd, REG_TRACE_LO, REG_TRACE_HI, desc_size + data_size)
        write64(user_fd, REG_PKT_LO, REG_PKT_HI, pkt_count)
        write64(user_fd, REG_LOOP_LO, REG_LOOP_HI, args.loop_count)
        write64(user_fd, REG_LOOP_GAP_LO, REG_LOOP_GAP_HI, args.loop_gap)
        write64(user_fd, REG_START_LO, REG_START_HI, args.start_time)
        write32(user_fd, REG_RATE, args.rate_q16_16)
        if args.force_link_up or args.clear_force_link_up:
            write32(user_fd, REG_DEBUG_CTRL, 1 if args.force_link_up else 0)
        if not args.no_start:
            write32(user_fd, REG_CONTROL, 0x1)
    finally:
        os.close(user_fd)

    action = "configured" if args.no_start else "started"
    print(f"{action}: mode={args.mode} packets={pkt_count} desc_base=0x{args.desc_base:x} data_base=0x{args.data_base:x}")


if __name__ == "__main__":
    main()
