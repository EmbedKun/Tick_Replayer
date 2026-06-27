#!/usr/bin/env python3
"""Check XDMA H2C/C2H access to FPGA DDR with deterministic patterns."""

from __future__ import annotations

import argparse
import os
import time


DEFAULT_CASES = [
    (0x0000_0000, 4 * 1024),
    (0x0010_0000, 64 * 1024),
    (0x1000_0000, 1024 * 1024),
]


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_case(value: str) -> tuple[int, int]:
    if ":" not in value:
        raise argparse.ArgumentTypeError("case must be addr:size")
    addr_s, size_s = value.split(":", 1)
    return int_auto(addr_s), int_auto(size_s)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--c2h", default="/dev/xdma0_c2h_0")
    parser.add_argument(
        "--case",
        action="append",
        type=parse_case,
        dest="cases",
        help="DDR test range as addr:size; may be repeated",
    )
    parser.add_argument("--repeat", type=int_auto, default=1)
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    return parser.parse_args()


def make_pattern(addr: int, size: int, repeat_index: int) -> bytes:
    return bytes(((addr >> 6) + repeat_index * 29 + i * 17 + (i >> 8)) & 0xFF for i in range(size))


def pwrite_all(fd: int, data: bytes, addr: int) -> None:
    offset = 0
    while offset < len(data):
        written = os.pwrite(fd, data[offset:], addr + offset)
        if written <= 0:
            raise RuntimeError("short H2C write")
        offset += written


def pread_all(fd: int, size: int, addr: int) -> bytes:
    out = bytearray()
    while len(out) < size:
        chunk = os.pread(fd, size - len(out), addr + len(out))
        if not chunk:
            raise RuntimeError("short C2H read")
        out.extend(chunk)
    return bytes(out)


def first_mismatch(expected: bytes, actual: bytes) -> tuple[int, int, int] | None:
    for index, (exp, got) in enumerate(zip(expected, actual)):
        if exp != got:
            return index, exp, got
    if len(expected) != len(actual):
        return min(len(expected), len(actual)), -1, -1
    return None


def main() -> None:
    args = parse_args()
    cases = args.cases or DEFAULT_CASES
    if args.repeat <= 0:
        raise SystemExit("--repeat must be positive")

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    c2h_fd = os.open(args.c2h, os.O_RDONLY)
    total_bytes = 0
    start = time.perf_counter()
    try:
        for repeat_index in range(args.repeat):
            for addr, size in cases:
                pattern = make_pattern(addr, size, repeat_index)
                t0 = time.perf_counter()
                pwrite_all(h2c_fd, pattern, addr)
                write_s = time.perf_counter() - t0

                t1 = time.perf_counter()
                readback = pread_all(c2h_fd, size, addr)
                read_s = time.perf_counter() - t1

                mismatch = first_mismatch(pattern, readback)
                if mismatch is not None:
                    offset, expected, got = mismatch
                    raise SystemExit(
                        f"FAIL addr=0x{addr:x} size={size} repeat={repeat_index}: "
                        f"offset=0x{offset:x} expected=0x{expected:02x} got=0x{got:02x}"
                    )

                total_bytes += size
                write_gbps = size * 8 / write_s / 1e9 if write_s > 0 else 0.0
                read_gbps = size * 8 / read_s / 1e9 if read_s > 0 else 0.0
                print(
                    f"PASS addr=0x{addr:08x} size={size} repeat={repeat_index} "
                    f"h2c={write_gbps:.3f}Gbps c2h={read_gbps:.3f}Gbps"
                )
    finally:
        os.close(h2c_fd)
        os.close(c2h_fd)

    elapsed = time.perf_counter() - start
    aggregate_gbps = total_bytes * 16 / elapsed / 1e9 if elapsed > 0 else 0.0
    print(f"SUMMARY cases={len(cases)} repeat={args.repeat} checked_bytes={total_bytes} aggregate_rw={aggregate_gbps:.3f}Gbps")


if __name__ == "__main__":
    main()
