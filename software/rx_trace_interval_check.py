#!/usr/bin/env python3
"""Compare RX-side packet intervals against a descriptor trace.

The checker loads a PRELOAD trace, sends it through the configured optical
loopback path, reads the RX capture core's SOP-to-SOP gap sample ring, and
compares the received packet intervals with the original descriptor gaps.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import struct
import time
from pathlib import Path

import preload_stress_test as pst


DESC_BYTES = 64
DATA_BEAT_BYTES = 64
RX_GAP_SAMPLE_DEPTH = 4096

RX_PORT_BASE = {0: 0x20000, 1: 0x30000}
RX_REG_CONTROL = 0x0000
RX_REG_STATUS = 0x0004
RX_REG_RING_SIZE = 0x0018
RX_REG_TRUNC_BYTES = 0x001C
RX_REG_WRITE_PTR = 0x0020
RX_REG_PKTS_LO = 0x0030
RX_REG_PKTS_HI = 0x0034
RX_REG_BYTES_LO = 0x0038
RX_REG_BYTES_HI = 0x003C
RX_REG_ERRS_LO = 0x0040
RX_REG_ERRS_HI = 0x0044
RX_REG_AXI_ERR_LO = 0x0058
RX_REG_AXI_ERR_HI = 0x005C
RX_REG_GAP_COUNT_LO = 0x0064
RX_REG_GAP_COUNT_HI = 0x0068
RX_REG_GAP_SUM_LO = 0x006C
RX_REG_GAP_SUM_HI = 0x0070
RX_REG_GAP_MIN_LO = 0x0074
RX_REG_GAP_MIN_HI = 0x0078
RX_REG_GAP_MAX_LO = 0x007C
RX_REG_GAP_MAX_HI = 0x0080
RX_REG_GAP_LAST_LO = 0x0084
RX_REG_GAP_LAST_HI = 0x0088
RX_REG_TICK_LO = 0x008C
RX_REG_TICK_HI = 0x0090
RX_REG_GAP_SAMPLE_INDEX = 0x0094
RX_REG_GAP_SAMPLE_COUNT = 0x0098
RX_REG_GAP_SAMPLE_LO = 0x009C
RX_REG_GAP_SAMPLE_HI = 0x00A0
RX_REG_GAP_SAMPLE_WRITE_INDEX = 0x00A4


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    parser.add_argument("--manifest", type=Path, help="manifest.json from pcap2trace.py or gen_synthetic_trace.py")
    parser.add_argument("--desc", type=Path, help="desc.bin path")
    parser.add_argument("--data", type=Path, help="data.bin path")
    parser.add_argument("--desc-base", type=pst.int_auto, default=0x0400_0000)
    parser.add_argument("--data-base", type=pst.int_auto, default=0x1400_0000)
    parser.add_argument("--packet-count", type=pst.int_auto, help="optional packet-count limit from the trace head")
    parser.add_argument("--tx-tick-hz", type=pst.int_auto, default=300_000_000)
    parser.add_argument("--rx-tick-hz", type=pst.int_auto, default=322_265_625)
    parser.add_argument("--rate-q16-16", type=pst.int_auto, default=0x0001_0000)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--max-samples", type=pst.int_auto, default=RX_GAP_SAMPLE_DEPTH)
    parser.add_argument("--max-error-ns", type=float, default=80.0)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--chunk-bytes", type=pst.int_auto, default=4 * 1024 * 1024)
    parser.add_argument("--csv", type=Path, help="optional per-sample CSV output")
    return parser.parse_args()


def resolve_path(path_text: str | None, manifest_path: Path | None) -> Path | None:
    if not path_text:
        return None
    path = Path(path_text)
    if path.is_file():
        return path
    if manifest_path is not None:
        candidate = manifest_path.parent / path.name
        if candidate.is_file():
            return candidate
    return path


def load_manifest(args: argparse.Namespace) -> None:
    if args.manifest is None:
        return
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    args.desc = args.desc or resolve_path(manifest.get("descriptor_file"), args.manifest)
    args.data = args.data or resolve_path(manifest.get("data_file"), args.manifest)
    if args.packet_count is None and manifest.get("packet_count") is not None:
        args.packet_count = int(manifest["packet_count"])
    if manifest.get("tick_hz") is not None:
        args.tx_tick_hz = int(manifest["tick_hz"])


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def require_file(path: Path | None, label: str) -> Path:
    if path is None:
        raise SystemExit(f"{label} is required")
    if not path.is_file():
        raise SystemExit(f"{label} not found: {path}")
    return path


def read_descriptors(desc_path: Path, packet_count: int | None) -> list[tuple[int, int, int, int]]:
    desc_bytes = desc_path.read_bytes()
    if len(desc_bytes) % DESC_BYTES != 0:
        raise SystemExit(f"descriptor file size must be a multiple of {DESC_BYTES}: {len(desc_bytes)}")
    available = len(desc_bytes) // DESC_BYTES
    count = available if packet_count is None else min(packet_count, available)
    descs = []
    for pkt_idx in range(count):
        rec = desc_bytes[pkt_idx * DESC_BYTES : pkt_idx * DESC_BYTES + 16]
        descs.append(struct.unpack("<QIHH", rec))
    return descs


def trace_data_bytes(descs: list[tuple[int, int, int, int]]) -> int:
    high = 0
    for _gap, word_off, frame_len, _flags in descs:
        high = max(high, word_off * DATA_BEAT_BYTES + align_up(frame_len, DATA_BEAT_BYTES))
    return high


def pwrite_file_limited(fd: int, path: Path, addr: int, limit: int, chunk_bytes: int) -> None:
    offset = 0
    with path.open("rb") as fh:
        while offset < limit:
            chunk = fh.read(min(chunk_bytes, limit - offset))
            if not chunk:
                raise RuntimeError(f"{path} ended before {limit} bytes")
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


def read64(fd: int, lo: int, hi: int) -> int:
    hi0 = read32(fd, hi)
    lo0 = read32(fd, lo)
    hi1 = read32(fd, hi)
    if hi0 != hi1:
        lo0 = read32(fd, lo)
    return lo0 | (hi1 << 32)


def wait_rx_cleared(user_fd: int, base: int, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        status = read32(user_fd, base + RX_REG_STATUS)
        write_ptr = read32(user_fd, base + RX_REG_WRITE_PTR)
        rx_pkts = read64(user_fd, base + RX_REG_PKTS_LO, base + RX_REG_PKTS_HI)
        rx_bytes = read64(user_fd, base + RX_REG_BYTES_LO, base + RX_REG_BYTES_HI)
        rx_errors = read64(user_fd, base + RX_REG_ERRS_LO, base + RX_REG_ERRS_HI)
        gap_count = read64(user_fd, base + RX_REG_GAP_COUNT_LO, base + RX_REG_GAP_COUNT_HI)
        sample_count = read32(user_fd, base + RX_REG_GAP_SAMPLE_COUNT)
        sample_wr = read32(user_fd, base + RX_REG_GAP_SAMPLE_WRITE_INDEX)
        writer_state = (status >> 7) & 0x3
        busy_bits = status & 0x17
        last = (status, write_ptr, rx_pkts, rx_bytes, rx_errors, gap_count, sample_count, sample_wr)
        if (
            writer_state == 0
            and busy_bits == 0
            and write_ptr == 0
            and rx_pkts == 0
            and rx_bytes == 0
            and rx_errors == 0
            and gap_count == 0
            and sample_count == 0
            and sample_wr == 0
        ):
            return
        time.sleep(0.01)
    raise TimeoutError(f"RX clear did not settle: {last}")


def configure_rx_stats(user_fd: int, base: int) -> None:
    write32(user_fd, base + RX_REG_CONTROL, 0x0)
    write32(user_fd, base + RX_REG_CONTROL, 0x2)
    wait_rx_cleared(user_fd, base)
    write32(user_fd, base + RX_REG_RING_SIZE, 0)
    write32(user_fd, base + RX_REG_TRUNC_BYTES, 0)
    write32(user_fd, base + RX_REG_CONTROL, 0x2)
    wait_rx_cleared(user_fd, base)
    write32(user_fd, base + RX_REG_CONTROL, 0x1)


def wait_rx_packets(user_fd: int, base: int, expected_packets: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rx_pkts = read64(user_fd, base + RX_REG_PKTS_LO, base + RX_REG_PKTS_HI)
        if rx_pkts >= expected_packets:
            return
        time.sleep(0.01)


def read_gap_sample(user_fd: int, base: int, index: int) -> int:
    write32(user_fd, base + RX_REG_GAP_SAMPLE_INDEX, index)
    return read64(user_fd, base + RX_REG_GAP_SAMPLE_LO, base + RX_REG_GAP_SAMPLE_HI)


def read_gap_window(user_fd: int, base: int, sample_count: int, write_index: int) -> list[int]:
    start = (write_index - sample_count) % RX_GAP_SAMPLE_DEPTH
    return [
        read_gap_sample(user_fd, base, (start + i) % RX_GAP_SAMPLE_DEPTH)
        for i in range(sample_count)
    ]


def main() -> None:
    args = parse_args()
    load_manifest(args)
    desc_path = require_file(args.desc, "--desc")
    data_path = require_file(args.data, "--data")

    descs = read_descriptors(desc_path, args.packet_count)
    if len(descs) < 2:
        raise SystemExit("at least two packets are required for interval checking")
    args.packet_count = len(descs)
    desc_size = len(descs) * DESC_BYTES
    data_size = trace_data_bytes(descs)
    if data_size > data_path.stat().st_size:
        raise SystemExit(f"data file is shorter than descriptor references: need {data_size}")

    tx_base = pst.TX_PORT_BASE[args.tx_port]
    rx_base = RX_PORT_BASE[args.rx_port]

    h2c_fd = os.open(args.h2c, os.O_WRONLY)
    user_fd = os.open(args.user, os.O_RDWR)
    try:
        pwrite_file_limited(h2c_fd, desc_path, args.desc_base, desc_size, args.chunk_bytes)
        pwrite_file_limited(h2c_fd, data_path, args.data_base, data_size, args.chunk_bytes)
        configure_rx_stats(user_fd, rx_base)

        ns = argparse.Namespace(
            desc_base=args.desc_base,
            data_base=args.data_base,
            packet_count=args.packet_count,
            rate_q16_16=args.rate_q16_16,
            force_link_up=args.force_link_up,
            force_tx_ready=args.force_tx_ready,
            no_auto_drop=False,
        )
        pst.configure_and_start(user_fd, tx_base, ns, desc_size, data_size)
        completed, wall_seconds = pst.wait_done(user_fd, tx_base, args.packet_count, args.timeout)
        wait_rx_packets(user_fd, rx_base, args.packet_count, min(2.0, args.timeout))
        time.sleep(0.2)

        tx_pkts = pst.read64(user_fd, tx_base + pst.REG_TX_PKTS_LO, tx_base + pst.REG_TX_PKTS_HI)
        drop_pkts = pst.read64(user_fd, tx_base + pst.REG_DROP_PKTS_LO, tx_base + pst.REG_DROP_PKTS_HI)
        late_pkts = pst.read64(user_fd, tx_base + pst.REG_LATE_LO, tx_base + pst.REG_LATE_HI)
        underrun_pkts = pst.read64(user_fd, tx_base + pst.REG_UNDERRUN_LO, tx_base + pst.REG_UNDERRUN_HI)

        rx_pkts = read64(user_fd, rx_base + RX_REG_PKTS_LO, rx_base + RX_REG_PKTS_HI)
        rx_bytes = read64(user_fd, rx_base + RX_REG_BYTES_LO, rx_base + RX_REG_BYTES_HI)
        rx_errors = read64(user_fd, rx_base + RX_REG_ERRS_LO, rx_base + RX_REG_ERRS_HI)
        axi_errors = read64(user_fd, rx_base + RX_REG_AXI_ERR_LO, rx_base + RX_REG_AXI_ERR_HI)
        rx_gap_count = read64(user_fd, rx_base + RX_REG_GAP_COUNT_LO, rx_base + RX_REG_GAP_COUNT_HI)
        rx_gap_sum = read64(user_fd, rx_base + RX_REG_GAP_SUM_LO, rx_base + RX_REG_GAP_SUM_HI)
        rx_gap_min = read64(user_fd, rx_base + RX_REG_GAP_MIN_LO, rx_base + RX_REG_GAP_MIN_HI)
        rx_gap_max = read64(user_fd, rx_base + RX_REG_GAP_MAX_LO, rx_base + RX_REG_GAP_MAX_HI)
        rx_gap_last = read64(user_fd, rx_base + RX_REG_GAP_LAST_LO, rx_base + RX_REG_GAP_LAST_HI)
        rx_tick = read64(user_fd, rx_base + RX_REG_TICK_LO, rx_base + RX_REG_TICK_HI)
        sample_available = read32(user_fd, rx_base + RX_REG_GAP_SAMPLE_COUNT)
        sample_wr = read32(user_fd, rx_base + RX_REG_GAP_SAMPLE_WRITE_INDEX)

        compare_count = min(
            int(sample_available),
            int(args.max_samples),
            int(rx_gap_count),
            args.packet_count - 1,
            RX_GAP_SAMPLE_DEPTH,
        )
        if compare_count <= 0:
            raise SystemExit("no RX gap samples are available; rebuild/program a bitstream with gap sample support")

        samples = read_gap_window(user_fd, rx_base, compare_count, sample_wr)
        first_desc_index = int(rx_gap_count) - compare_count + 1
        if first_desc_index < 1 or first_desc_index + compare_count > len(descs):
            raise SystemExit(
                f"cannot map RX sample window to descriptor gaps: first_desc_index={first_desc_index} "
                f"compare_count={compare_count} desc_count={len(descs)} rx_gap_count={rx_gap_count}"
            )

        rows = []
        sum_err_ns = 0.0
        max_abs_err_ns = 0.0
        min_err_ns = math.inf
        max_err_ns = -math.inf
        mismatches = 0
        for sample_idx, rx_gap_cycles in enumerate(samples):
            desc_index = first_desc_index + sample_idx
            tx_gap_ticks = descs[desc_index][0]
            expected_ns = tx_gap_ticks * 1e9 / args.tx_tick_hz
            rx_gap_ns = rx_gap_cycles * 1e9 / args.rx_tick_hz
            err_ns = rx_gap_ns - expected_ns
            abs_err_ns = abs(err_ns)
            sum_err_ns += err_ns
            max_abs_err_ns = max(max_abs_err_ns, abs_err_ns)
            min_err_ns = min(min_err_ns, err_ns)
            max_err_ns = max(max_err_ns, err_ns)
            if abs_err_ns > args.max_error_ns:
                mismatches += 1
            rows.append(
                {
                    "sample_index": sample_idx,
                    "desc_packet_index": desc_index,
                    "tx_gap_ticks": tx_gap_ticks,
                    "rx_gap_cycles": rx_gap_cycles,
                    "expected_ns": f"{expected_ns:.6f}",
                    "rx_gap_ns": f"{rx_gap_ns:.6f}",
                    "error_ns": f"{err_ns:.6f}",
                }
            )

        avg_err_ns = sum_err_ns / compare_count
        rx_gap_avg = rx_gap_sum / rx_gap_count if rx_gap_count else 0.0

        print(f"tx_port              : {args.tx_port}")
        print(f"rx_port              : {args.rx_port}")
        print(f"descriptor_file      : {desc_path}")
        print(f"data_file            : {data_path}")
        print(f"packet_count         : {args.packet_count}")
        print(f"tx_tick_hz           : {args.tx_tick_hz}")
        print(f"rx_tick_hz           : {args.rx_tick_hz}")
        print(f"completed            : {completed}")
        print(f"wall_seconds         : {wall_seconds:.6f}")
        print(f"tx_packets           : {tx_pkts}")
        print(f"drop_packets         : {drop_pkts}")
        print(f"late_packets         : {late_pkts}")
        print(f"underrun_packets     : {underrun_pkts}")
        print(f"rx_packets           : {rx_pkts}")
        print(f"rx_bytes             : {rx_bytes}")
        print(f"rx_errors            : {rx_errors}")
        print(f"axi_errors           : {axi_errors}")
        print(f"rx_gap_count         : {rx_gap_count}")
        print(f"rx_gap_min_cycles    : {rx_gap_min}")
        print(f"rx_gap_max_cycles    : {rx_gap_max}")
        print(f"rx_gap_last_cycles   : {rx_gap_last}")
        print(f"rx_gap_avg_cycles    : {rx_gap_avg:.6f}")
        print(f"rx_gap_sample_count  : {sample_available}")
        print(f"rx_gap_sample_wr     : {sample_wr}")
        print(f"compared_samples     : {compare_count}")
        print(f"first_desc_index     : {first_desc_index}")
        print(f"max_error_ns_allowed : {args.max_error_ns:.6f}")
        print(f"min_error_ns         : {min_err_ns:.6f}")
        print(f"max_error_ns         : {max_err_ns:.6f}")
        print(f"avg_error_ns         : {avg_err_ns:.6f}")
        print(f"max_abs_error_ns     : {max_abs_err_ns:.6f}")
        print(f"error_over_limit     : {mismatches}")
        print(f"rx_tick              : {rx_tick}")

        if args.csv is not None:
            args.csv.parent.mkdir(parents=True, exist_ok=True)
            with args.csv.open("w", newline="", encoding="utf-8") as fh:
                writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows)
            print(f"csv                  : {args.csv}")

        if (
            not completed
            or tx_pkts != args.packet_count
            or drop_pkts != 0
            or late_pkts != 0
            or underrun_pkts != 0
            or rx_pkts < args.packet_count
            or rx_errors != 0
            or axi_errors != 0
            or rx_gap_count < args.packet_count - 1
            or mismatches != 0
        ):
            raise SystemExit("FAIL: RX trace interval check failed")
        print("PASS: RX packet intervals match descriptor trace gaps within tolerance")
    finally:
        os.close(h2c_fd)
        os.close(user_fd)


if __name__ == "__main__":
    main()
