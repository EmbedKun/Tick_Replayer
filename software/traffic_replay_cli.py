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
REG_DEBUG_STATUS = 0x0080
REG_DEBUG_AXI = 0x0084
REG_DEBUG_AR_LO = 0x0088
REG_DEBUG_AR_HI = 0x008C
REG_DEBUG_RDATA = 0x0090
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
REG_DROP_PKTS_LO = 0x00C8
REG_DROP_PKTS_HI = 0x00CC
REG_DROP_BEATS_LO = 0x00D0
REG_DROP_BEATS_HI = 0x00D4
REG_STALL_EVT_LO = 0x00D8
REG_STALL_EVT_HI = 0x00DC

TX_PORT_BASE = {0: 0x00000, 1: 0x10000}
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
RX_REG_DEBUG = 0x0060


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
    ("DEBUG_STATUS", REG_DEBUG_STATUS),
    ("DEBUG_AXI", REG_DEBUG_AXI),
    ("DEBUG_AR_LO", REG_DEBUG_AR_LO),
    ("DEBUG_AR_HI", REG_DEBUG_AR_HI),
    ("DEBUG_RDATA", REG_DEBUG_RDATA),
    ("DEBUG_TICK_LO", REG_DEBUG_TICK_LO),
    ("DEBUG_TICK_HI", REG_DEBUG_TICK_HI),
    ("STREAM_WR_LO", REG_STREAM_WR_LO),
    ("STREAM_WR_HI", REG_STREAM_WR_HI),
    ("STREAM_RD_LO", REG_STREAM_RD_LO),
    ("STREAM_RD_HI", REG_STREAM_RD_HI),
    ("STREAM_RING_LO", REG_STREAM_RING_LO),
    ("STREAM_RING_HI", REG_STREAM_RING_HI),
    ("STREAM_CTRL", REG_STREAM_CTRL),
    ("STREAM_STATUS", REG_STREAM_STATUS),
    ("STREAM_LEVEL_LO", REG_STREAM_LEVEL_LO),
    ("STREAM_LEVEL_HI", REG_STREAM_LEVEL_HI),
    ("DROP_PKTS_LO", REG_DROP_PKTS_LO),
    ("DROP_PKTS_HI", REG_DROP_PKTS_HI),
    ("DROP_BEATS_LO", REG_DROP_BEATS_LO),
    ("DROP_BEATS_HI", REG_DROP_BEATS_HI),
    ("STALL_EVT_LO", REG_STALL_EVT_LO),
    ("STALL_EVT_HI", REG_STALL_EVT_HI),
]

RX_REG_NAMES = [
    ("CONTROL", RX_REG_CONTROL),
    ("STATUS", RX_REG_STATUS),
    ("RING_BASE_LO", RX_REG_RING_BASE_LO),
    ("RING_BASE_HI", RX_REG_RING_BASE_HI),
    ("RING_SIZE", RX_REG_RING_SIZE),
    ("TRUNC_BYTES", RX_REG_TRUNC_BYTES),
    ("WRITE_PTR", RX_REG_WRITE_PTR),
    ("RX_PKTS_LO", RX_REG_PKTS_LO),
    ("RX_PKTS_HI", RX_REG_PKTS_HI),
    ("RX_BYTES_LO", RX_REG_BYTES_LO),
    ("RX_BYTES_HI", RX_REG_BYTES_HI),
    ("RX_ERRS_LO", RX_REG_ERRS_LO),
    ("RX_ERRS_HI", RX_REG_ERRS_HI),
    ("CAP_BYTES_LO", RX_REG_CAP_BYTES_LO),
    ("CAP_BYTES_HI", RX_REG_CAP_BYTES_HI),
    ("AXI_WR_LO", RX_REG_AXI_WR_LO),
    ("AXI_WR_HI", RX_REG_AXI_WR_HI),
    ("AXI_ERR_LO", RX_REG_AXI_ERR_LO),
    ("AXI_ERR_HI", RX_REG_AXI_ERR_HI),
    ("DEBUG", RX_REG_DEBUG),
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


def print_status(fd: int, base: int) -> None:
    status = read32(fd, base + REG_STATUS)
    mode = read32(fd, base + REG_MODE) & 0x3
    debug = read32(fd, base + REG_DEBUG_CTRL)
    mode_name = {0: "preload", 1: "stream", 2: "loop"}.get(mode, f"unknown({mode})")

    print(f"mode              : {mode_name}")
    print(f"running           : {bool_word(bool(status & (1 << 0)))}")
    print(f"done              : {bool_word(bool(status & (1 << 1)))}")
    print(f"late              : {bool_word(bool(status & (1 << 2)))}")
    print(f"underrun          : {bool_word(bool(status & (1 << 3)))}")
    print(f"cmac_link_up      : {bool_word(bool(status & (1 << 4)))}")
    print(f"tx_gate_open      : {bool_word(bool(status & (1 << 5)))}")
    print(f"force_link_up     : {bool_word(bool(debug & 0x1))}")
    print(f"force_tx_ready    : {bool_word(bool(debug & 0x2))}")
    print(f"auto_tx_drop      : {bool_word(bool(debug & 0x4))}")
    print(f"fifo_level        : {read32(fd, base + REG_FIFO_LEVEL)}")
    print(f"tx_packets        : {read64(fd, base + REG_TX_PKTS_LO, base + REG_TX_PKTS_HI)}")
    print(f"tx_bytes          : {read64(fd, base + REG_TX_BYTES_LO, base + REG_TX_BYTES_HI)}")
    print(f"late_packets      : {read64(fd, base + REG_LATE_LO, base + REG_LATE_HI)}")
    print(f"underrun_packets  : {read64(fd, base + REG_UNDERRUN_LO, base + REG_UNDERRUN_HI)}")
    print(f"drop_packets      : {read64(fd, base + REG_DROP_PKTS_LO, base + REG_DROP_PKTS_HI)}")
    print(f"drop_beats        : {read64(fd, base + REG_DROP_BEATS_LO, base + REG_DROP_BEATS_HI)}")
    print(f"stall_events      : {read64(fd, base + REG_STALL_EVT_LO, base + REG_STALL_EVT_HI)}")
    print(f"debug_status      : 0x{read32(fd, base + REG_DEBUG_STATUS):08x}")
    print(f"debug_axi         : 0x{read32(fd, base + REG_DEBUG_AXI):08x}")
    print(f"debug_araddr      : 0x{read64(fd, base + REG_DEBUG_AR_LO, base + REG_DEBUG_AR_HI):016x}")
    print(f"debug_rdata_low   : 0x{read32(fd, base + REG_DEBUG_RDATA):08x}")
    print(f"debug_ticks       : {read64(fd, base + REG_DEBUG_TICK_LO, base + REG_DEBUG_TICK_HI)}")
    stream_wr = read64(fd, base + REG_STREAM_WR_LO, base + REG_STREAM_WR_HI)
    stream_rd = read64(fd, base + REG_STREAM_RD_LO, base + REG_STREAM_RD_HI)
    stream_ring = read64(fd, base + REG_STREAM_RING_LO, base + REG_STREAM_RING_HI)
    stream_level = read64(fd, base + REG_STREAM_LEVEL_LO, base + REG_STREAM_LEVEL_HI)
    stream_status = read32(fd, base + REG_STREAM_STATUS)
    print(f"stream_ring_size  : {stream_ring}")
    print(f"stream_write_ptr  : {stream_wr}")
    print(f"stream_read_ptr   : {stream_rd}")
    print(f"stream_level      : {stream_level}")
    print(f"stream_eof        : {bool_word(bool(read32(fd, base + REG_STREAM_CTRL) & 0x1))}")
    print(f"stream_wait_empty : {bool_word(bool(stream_status & (1 << 11)))}")
    print(f"stream_overrun    : {bool_word(bool(stream_status & (1 << 10)))}")
    print(f"stream_size_valid : {bool_word(bool(stream_status & (1 << 9)))}")
    print(f"stream_status     : 0x{stream_status:08x}")


def print_rx_status(fd: int, base: int) -> None:
    control = read32(fd, base + RX_REG_CONTROL)
    status = read32(fd, base + RX_REG_STATUS)
    print(f"rx_enable         : {bool_word(bool(control & 0x1))}")
    print(f"capture_enable    : {bool_word(bool(control & 0x4))}")
    print(f"link_up           : {bool_word(bool(status & (1 << 5)))}")
    print(f"fifo_ready        : {bool_word(bool(status & (1 << 3)))}")
    print(f"fifo_valid        : {bool_word(bool(status & (1 << 4)))}")
    print(f"overflow_seen     : {bool_word(bool(status & (1 << 6)))}")
    print(f"writer_state      : {(status >> 7) & 0x3}")
    print(f"ring_base         : 0x{read64(fd, base + RX_REG_RING_BASE_LO, base + RX_REG_RING_BASE_HI):016x}")
    print(f"ring_size         : {read32(fd, base + RX_REG_RING_SIZE)}")
    print(f"truncate_bytes    : {read32(fd, base + RX_REG_TRUNC_BYTES)}")
    print(f"write_ptr         : {read32(fd, base + RX_REG_WRITE_PTR)}")
    print(f"rx_packets        : {read64(fd, base + RX_REG_PKTS_LO, base + RX_REG_PKTS_HI)}")
    print(f"rx_bytes          : {read64(fd, base + RX_REG_BYTES_LO, base + RX_REG_BYTES_HI)}")
    print(f"rx_errors         : {read64(fd, base + RX_REG_ERRS_LO, base + RX_REG_ERRS_HI)}")
    print(f"captured_bytes    : {read64(fd, base + RX_REG_CAP_BYTES_LO, base + RX_REG_CAP_BYTES_HI)}")
    print(f"axi_writes        : {read64(fd, base + RX_REG_AXI_WR_LO, base + RX_REG_AXI_WR_HI)}")
    print(f"axi_errors        : {read64(fd, base + RX_REG_AXI_ERR_LO, base + RX_REG_AXI_ERR_HI)}")
    print(f"debug             : 0x{read32(fd, base + RX_REG_DEBUG):08x}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0, help="TX/RX logical port")
    parser.add_argument("--base", type=int_auto, help="override AXI-Lite base address")

    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("regs")
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("clear")
    sub.add_parser("pause")
    sub.add_parser("resume")
    sub.add_parser("rx-status")
    sub.add_parser("rx-regs")
    sub.add_parser("rx-clear")
    sub.add_parser("rx-enable")
    sub.add_parser("rx-disable")

    rx_capture = sub.add_parser("rx-capture")
    rx_capture.add_argument("state", choices=["on", "off"])

    rx_config = sub.add_parser("rx-config")
    rx_config.add_argument("--ring-base", type=int_auto)
    rx_config.add_argument("--ring-size", type=int_auto)
    rx_config.add_argument("--truncate-bytes", type=int_auto)

    debug = sub.add_parser("debug-force-link")
    debug.add_argument("state", choices=["on", "off"])

    debug_tx = sub.add_parser("debug-tx-ready")
    debug_tx.add_argument("state", choices=["on", "off"])

    auto_drop = sub.add_parser("auto-drop")
    auto_drop.add_argument("state", choices=["on", "off"])

    read_reg = sub.add_parser("read-reg")
    read_reg.add_argument("offset", type=int_auto)

    write_reg = sub.add_parser("write-reg")
    write_reg.add_argument("offset", type=int_auto)
    write_reg.add_argument("value", type=int_auto)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    tx_base = TX_PORT_BASE[args.port] if args.base is None else args.base
    rx_base = RX_PORT_BASE[args.port] if args.base is None else args.base
    fd = os.open(args.user, os.O_RDWR)
    try:
      if args.cmd == "status":
          print_status(fd, tx_base)
      elif args.cmd == "regs":
          for name, offset in REG_NAMES:
              addr = tx_base + offset
              print(f"0x{addr:05x} {name:<14} 0x{read32(fd, addr):08x}")
      elif args.cmd == "start":
          write32(fd, tx_base + REG_CONTROL, 0x1)
      elif args.cmd == "stop":
          write32(fd, tx_base + REG_CONTROL, 0x2)
      elif args.cmd == "clear":
          write32(fd, tx_base + REG_CONTROL, 0x4)
      elif args.cmd == "pause":
          write32(fd, tx_base + REG_CONTROL, 0x8)
      elif args.cmd == "resume":
          write32(fd, tx_base + REG_CONTROL, 0x0)
      elif args.cmd == "debug-force-link":
          value = read32(fd, tx_base + REG_DEBUG_CTRL)
          value = (value | 0x1) if args.state == "on" else (value & ~0x1)
          write32(fd, tx_base + REG_DEBUG_CTRL, value)
      elif args.cmd == "debug-tx-ready":
          value = read32(fd, tx_base + REG_DEBUG_CTRL)
          value = (value | 0x2) if args.state == "on" else (value & ~0x2)
          write32(fd, tx_base + REG_DEBUG_CTRL, value)
      elif args.cmd == "auto-drop":
          value = read32(fd, tx_base + REG_DEBUG_CTRL)
          value = (value | 0x4) if args.state == "on" else (value & ~0x4)
          write32(fd, tx_base + REG_DEBUG_CTRL, value)
      elif args.cmd == "rx-status":
          print_rx_status(fd, rx_base)
      elif args.cmd == "rx-regs":
          for name, offset in RX_REG_NAMES:
              addr = rx_base + offset
              print(f"0x{addr:05x} {name:<14} 0x{read32(fd, addr):08x}")
      elif args.cmd == "rx-clear":
          value = read32(fd, rx_base + RX_REG_CONTROL)
          write32(fd, rx_base + RX_REG_CONTROL, value | 0x2)
      elif args.cmd == "rx-enable":
          value = read32(fd, rx_base + RX_REG_CONTROL)
          write32(fd, rx_base + RX_REG_CONTROL, value | 0x1)
      elif args.cmd == "rx-disable":
          value = read32(fd, rx_base + RX_REG_CONTROL)
          write32(fd, rx_base + RX_REG_CONTROL, value & ~0x1)
      elif args.cmd == "rx-capture":
          value = read32(fd, rx_base + RX_REG_CONTROL)
          value = (value | 0x4) if args.state == "on" else (value & ~0x4)
          write32(fd, rx_base + RX_REG_CONTROL, value)
      elif args.cmd == "rx-config":
          if args.ring_base is not None:
              write32(fd, rx_base + RX_REG_RING_BASE_LO, args.ring_base)
              write32(fd, rx_base + RX_REG_RING_BASE_HI, args.ring_base >> 32)
          if args.ring_size is not None:
              write32(fd, rx_base + RX_REG_RING_SIZE, args.ring_size)
          if args.truncate_bytes is not None:
              write32(fd, rx_base + RX_REG_TRUNC_BYTES, args.truncate_bytes)
      elif args.cmd == "read-reg":
          value = read32(fd, tx_base + args.offset)
          print(f"0x{tx_base + args.offset:05x}: 0x{value:08x}")
      elif args.cmd == "write-reg":
          write32(fd, tx_base + args.offset, args.value)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
