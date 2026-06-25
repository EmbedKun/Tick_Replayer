#!/usr/bin/env python3
"""Small control CLI for the FPGA traffic replay AXI-Lite register block."""

from __future__ import annotations

import argparse
import os
import struct


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
REG_LOOP_LO = 0x0030
REG_LOOP_HI = 0x0034
REG_LOOP_GAP_LO = 0x0038
REG_LOOP_GAP_HI = 0x003C
REG_START_LO = 0x0040
REG_START_HI = 0x0044
REG_RATE = 0x0048
REG_WATERMARK = 0x004C
REG_FIFO_LEVEL = 0x0050
REG_DEBUG_CTRL = 0x0054
REG_TX_PKTS_LO = 0x0060
REG_TX_PKTS_HI = 0x0064
REG_TX_BYTES_LO = 0x0068
REG_TX_BYTES_HI = 0x006C
REG_LATE_LO = 0x0070
REG_LATE_HI = 0x0074
REG_UNDERRUN_LO = 0x0078
REG_UNDERRUN_HI = 0x007C


REG_NAMES = [
    ("CONTROL", REG_CONTROL),
    ("MODE", REG_MODE),
    ("STATUS", REG_STATUS),
    ("DESC_BASE_LO", REG_DESC_BASE_LO),
    ("DESC_BASE_HI", REG_DESC_BASE_HI),
    ("DATA_BASE_LO", REG_DATA_BASE_LO),
    ("DATA_BASE_HI", REG_DATA_BASE_HI),
    ("TRACE_LO", REG_TRACE_LO),
    ("TRACE_HI", REG_TRACE_HI),
    ("PKT_LO", REG_PKT_LO),
    ("PKT_HI", REG_PKT_HI),
    ("LOOP_LO", REG_LOOP_LO),
    ("LOOP_HI", REG_LOOP_HI),
    ("LOOP_GAP_LO", REG_LOOP_GAP_LO),
    ("LOOP_GAP_HI", REG_LOOP_GAP_HI),
    ("START_LO", REG_START_LO),
    ("START_HI", REG_START_HI),
    ("RATE", REG_RATE),
    ("WATERMARK", REG_WATERMARK),
    ("FIFO_LEVEL", REG_FIFO_LEVEL),
    ("DEBUG_CTRL", REG_DEBUG_CTRL),
    ("TX_PKTS_LO", REG_TX_PKTS_LO),
    ("TX_PKTS_HI", REG_TX_PKTS_HI),
    ("TX_BYTES_LO", REG_TX_BYTES_LO),
    ("TX_BYTES_HI", REG_TX_BYTES_HI),
    ("LATE_LO", REG_LATE_LO),
    ("LATE_HI", REG_LATE_HI),
    ("UNDERRUN_LO", REG_UNDERRUN_LO),
    ("UNDERRUN_HI", REG_UNDERRUN_HI),
]


def int_auto(value: str) -> int:
    return int(value, 0)


def read32(fd: int, offset: int) -> int:
    return struct.unpack("<I", os.pread(fd, 4, offset))[0]


def write32(fd: int, offset: int, value: int) -> None:
    os.pwrite(fd, struct.pack("<I", value & 0xFFFF_FFFF), offset)


def read64(fd: int, lo: int, hi: int) -> int:
    return read32(fd, lo) | (read32(fd, hi) << 32)


def bool_word(value: bool) -> str:
    return "yes" if value else "no"


def print_status(fd: int) -> None:
    status = read32(fd, REG_STATUS)
    mode = read32(fd, REG_MODE) & 0x3
    debug = read32(fd, REG_DEBUG_CTRL)
    mode_name = {0: "preload", 1: "stream", 2: "loop"}.get(mode, f"unknown({mode})")

    print(f"mode              : {mode_name}")
    print(f"running           : {bool_word(bool(status & (1 << 0)))}")
    print(f"done              : {bool_word(bool(status & (1 << 1)))}")
    print(f"late              : {bool_word(bool(status & (1 << 2)))}")
    print(f"underrun          : {bool_word(bool(status & (1 << 3)))}")
    print(f"cmac_link_up      : {bool_word(bool(status & (1 << 4)))}")
    print(f"tx_gate_open      : {bool_word(bool(status & (1 << 5)))}")
    print(f"force_link_up     : {bool_word(bool(debug & 0x1))}")
    print(f"fifo_level        : {read32(fd, REG_FIFO_LEVEL)}")
    print(f"tx_packets        : {read64(fd, REG_TX_PKTS_LO, REG_TX_PKTS_HI)}")
    print(f"tx_bytes          : {read64(fd, REG_TX_BYTES_LO, REG_TX_BYTES_HI)}")
    print(f"late_packets      : {read64(fd, REG_LATE_LO, REG_LATE_HI)}")
    print(f"underrun_packets  : {read64(fd, REG_UNDERRUN_LO, REG_UNDERRUN_HI)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="/dev/xdma0_user")

    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("regs")
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("clear")
    sub.add_parser("pause")
    sub.add_parser("resume")

    debug = sub.add_parser("debug-force-link")
    debug.add_argument("state", choices=["on", "off"])

    read_reg = sub.add_parser("read-reg")
    read_reg.add_argument("offset", type=int_auto)

    write_reg = sub.add_parser("write-reg")
    write_reg.add_argument("offset", type=int_auto)
    write_reg.add_argument("value", type=int_auto)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    fd = os.open(args.user, os.O_RDWR)
    try:
      if args.cmd == "status":
          print_status(fd)
      elif args.cmd == "regs":
          for name, offset in REG_NAMES:
              print(f"0x{offset:04x} {name:<14} 0x{read32(fd, offset):08x}")
      elif args.cmd == "start":
          write32(fd, REG_CONTROL, 0x1)
      elif args.cmd == "stop":
          write32(fd, REG_CONTROL, 0x2)
      elif args.cmd == "clear":
          write32(fd, REG_CONTROL, 0x4)
      elif args.cmd == "pause":
          write32(fd, REG_CONTROL, 0x8)
      elif args.cmd == "resume":
          write32(fd, REG_CONTROL, 0x0)
      elif args.cmd == "debug-force-link":
          write32(fd, REG_DEBUG_CTRL, 1 if args.state == "on" else 0)
      elif args.cmd == "read-reg":
          value = read32(fd, args.offset)
          print(f"0x{args.offset:04x}: 0x{value:08x}")
      elif args.cmd == "write-reg":
          write32(fd, args.offset, args.value)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
