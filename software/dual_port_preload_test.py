#!/usr/bin/env python3
"""Run a simultaneous two-port PRELOAD replay test.

The script loads two generated traces into DDR first, configures both replay
ports without starting them, and then arms both ports back-to-back.  Use
different DDR bank base addresses on four-bank builds to measure whether the
shared single-bank path has been removed as the bottleneck.
"""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path
from types import SimpleNamespace

import preload_stress_test as ps


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_dual_preload"))
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--frame-len", type=int_auto, default=1518)
    parser.add_argument("--gap-ticks", type=int_auto, default=38)
    parser.add_argument("--port0-desc-base", type=int_auto, default=0x0000_0000)
    parser.add_argument("--port0-data-base", type=int_auto, default=0x1000_0000)
    parser.add_argument("--port1-desc-base", type=int_auto, default=0x4_0000_0000)
    parser.add_argument("--port1-data-base", type=int_auto, default=0x4_1000_0000)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--no-auto-drop", action="store_true")
    parser.add_argument("--require-no-drop", action="store_true")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--chunk-bytes", type=int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--tick-hz", type=int_auto, default=ps.DEFAULT_TICK_HZ)
    parser.add_argument("--wire-overhead-bytes", type=int_auto, default=24)
    return parser.parse_args()


def make_port_args(args: argparse.Namespace, port: int, desc_base: int, data_base: int) -> SimpleNamespace:
    return SimpleNamespace(
        port=port,
        desc_base=desc_base,
        data_base=data_base,
        packet_count=args.packet_count,
        force_link_up=args.force_link_up,
        force_tx_ready=args.force_tx_ready,
        no_auto_drop=args.no_auto_drop,
        rate_q16_16=0x0001_0000,
    )


def configure_no_start(user_fd: int, base: int, port_args: SimpleNamespace, desc_size: int, data_size: int) -> None:
    ps.write32(user_fd, base + ps.REG_CONTROL, 0x2)
    time.sleep(0.001)
    ps.write32(user_fd, base + ps.REG_CONTROL, 0x4)
    time.sleep(0.001)
    ps.write32(user_fd, base + ps.REG_MODE, ps.MODE_PRELOAD)
    ps.write64(user_fd, base + ps.REG_DESC_BASE_LO, base + ps.REG_DESC_BASE_HI, port_args.desc_base)
    ps.write64(user_fd, base + ps.REG_DATA_BASE_LO, base + ps.REG_DATA_BASE_HI, port_args.data_base)
    ps.write64(user_fd, base + ps.REG_TRACE_LO, base + ps.REG_TRACE_HI, desc_size + data_size)
    ps.write64(user_fd, base + ps.REG_PKT_LO, base + ps.REG_PKT_HI, port_args.packet_count)
    ps.write64(user_fd, base + ps.REG_START_LO, base + ps.REG_START_HI, 0)
    ps.write32(user_fd, base + ps.REG_RATE, port_args.rate_q16_16)

    debug = ps.read32(user_fd, base + ps.REG_DEBUG_CTRL)
    if port_args.force_link_up:
        debug |= 0x1
    if port_args.force_tx_ready:
        debug |= 0x2
    if port_args.no_auto_drop:
        debug &= ~0x4
    else:
        debug |= 0x4
    ps.write32(user_fd, base + ps.REG_DEBUG_CTRL, debug)


def read_stats(user_fd: int, base: int, args: argparse.Namespace) -> dict[str, int | float | bool]:
    tx_pkts = ps.read64(user_fd, base + ps.REG_TX_PKTS_LO, base + ps.REG_TX_PKTS_HI)
    tx_bytes = ps.read64(user_fd, base + ps.REG_TX_BYTES_LO, base + ps.REG_TX_BYTES_HI)
    late_pkts = ps.read64(user_fd, base + ps.REG_LATE_LO, base + ps.REG_LATE_HI)
    underrun_pkts = ps.read64(user_fd, base + ps.REG_UNDERRUN_LO, base + ps.REG_UNDERRUN_HI)
    drop_pkts = ps.read64(user_fd, base + ps.REG_DROP_PKTS_LO, base + ps.REG_DROP_PKTS_HI)
    drop_beats = ps.read64(user_fd, base + ps.REG_DROP_BEATS_LO, base + ps.REG_DROP_BEATS_HI)
    stall_events = ps.read64(user_fd, base + ps.REG_STALL_EVT_LO, base + ps.REG_STALL_EVT_HI)
    ticks = ps.read64(user_fd, base + ps.REG_DEBUG_TICK_LO, base + ps.REG_DEBUG_TICK_HI)
    scheduled_seconds = ticks / args.tick_hz if ticks else 0.0
    delivered_pkts = max(0, tx_pkts - drop_pkts)
    l2_gbps = delivered_pkts * args.frame_len * 8 / scheduled_seconds / 1e9 if scheduled_seconds > 0 else 0.0
    wire_gbps = (
        delivered_pkts * (args.frame_len + args.wire_overhead_bytes) * 8 / scheduled_seconds / 1e9
        if scheduled_seconds > 0
        else 0.0
    )
    return {
        "tx_packets": tx_pkts,
        "tx_bytes": tx_bytes,
        "late_packets": late_pkts,
        "underrun_packets": underrun_pkts,
        "drop_packets": drop_pkts,
        "drop_beats": drop_beats,
        "stall_events": stall_events,
        "debug_ticks": ticks,
        "scheduled_seconds": scheduled_seconds,
        "delivered_l2_gbps": l2_gbps,
        "delivered_wire_gbps": wire_gbps,
    }


def print_stats(label: str, stats: dict[str, int | float | bool]) -> None:
    print(
        f"{label}: tx={stats['tx_packets']} drop={stats['drop_packets']} "
        f"late={stats['late_packets']} underrun={stats['underrun_packets']} "
        f"stall={stats['stall_events']} "
        f"l2={stats['delivered_l2_gbps']:.3f}Gbps "
        f"wire={stats['delivered_wire_gbps']:.3f}Gbps"
    )


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    if args.frame_len <= 0 or args.frame_len > 0xFFFF:
        raise SystemExit("--frame-len must be in 1..65535")

    args.work_dir.mkdir(parents=True, exist_ok=True)
    port_cfg = [
        make_port_args(args, 0, args.port0_desc_base, args.port0_data_base),
        make_port_args(args, 1, args.port1_desc_base, args.port1_data_base),
    ]
    bases = [ps.TX_PORT_BASE[0], ps.TX_PORT_BASE[1]]

    traces = []
    for cfg in port_cfg:
        trace_dir = args.work_dir / f"port{cfg.port}_len{args.frame_len}_gap{args.gap_ticks}_pkts{args.packet_count}"
        traces.append(ps.make_trace(trace_dir, args.packet_count, args.frame_len, args.gap_ticks))

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        for cfg, trace in zip(port_cfg, traces):
            desc_path, data_path, desc_size, data_size = trace
            t0 = time.perf_counter()
            ps.pwrite_file(h2c_fd, desc_path, cfg.desc_base, args.chunk_bytes)
            ps.pwrite_file(h2c_fd, data_path, cfg.data_base, args.chunk_bytes)
            load_s = time.perf_counter() - t0
            load_gbps = (desc_size + data_size) * 8 / load_s / 1e9 if load_s > 0 else 0.0
            print(
                f"loaded port{cfg.port}: desc_base=0x{cfg.desc_base:x} "
                f"data_base=0x{cfg.data_base:x} bytes={desc_size + data_size} "
                f"load={load_gbps:.3f}Gbps"
            )

        for base, cfg, trace in zip(bases, port_cfg, traces):
            _, _, desc_size, data_size = trace
            configure_no_start(user_fd, base, cfg, desc_size, data_size)

        start = time.perf_counter()
        ps.write32(user_fd, bases[0] + ps.REG_CONTROL, 0x1)
        ps.write32(user_fd, bases[1] + ps.REG_CONTROL, 0x1)

        completed = [False, False]
        while True:
            now = time.perf_counter()
            for idx, base in enumerate(bases):
                status = ps.read32(user_fd, base + ps.REG_STATUS)
                tx_pkts = ps.read64(user_fd, base + ps.REG_TX_PKTS_LO, base + ps.REG_TX_PKTS_HI)
                completed[idx] = bool((status & 0x2) and not (status & 0x1)) or tx_pkts >= args.packet_count
            if all(completed):
                break
            if now - start > args.timeout:
                for base in bases:
                    ps.stop_and_clear(user_fd, base)
                raise SystemExit("dual-port preload timed out")
            time.sleep(0.005)

        stats0 = read_stats(user_fd, bases[0], args)
        stats1 = read_stats(user_fd, bases[1], args)
        print_stats("port0", stats0)
        print_stats("port1", stats1)
        aggregate_wire = float(stats0["delivered_wire_gbps"]) + float(stats1["delivered_wire_gbps"])
        aggregate_l2 = float(stats0["delivered_l2_gbps"]) + float(stats1["delivered_l2_gbps"])
        print(f"aggregate: l2={aggregate_l2:.3f}Gbps wire={aggregate_wire:.3f}Gbps")

        if args.require_no_drop:
            bad0 = any(int(stats0[k]) != 0 for k in ["drop_packets", "drop_beats", "late_packets", "underrun_packets", "stall_events"])
            bad1 = any(int(stats1[k]) != 0 for k in ["drop_packets", "drop_beats", "late_packets", "underrun_packets", "stall_events"])
            if bad0 or bad1:
                raise SystemExit("strict dual-port preload failed")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
