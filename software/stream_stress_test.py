#!/usr/bin/env python3
"""Generate STREAM ring-buffer stress datasets and run dynamic ring replay.

This script intentionally supports only the DDR ring-buffer STREAM mode.  It
creates stream-record files, invokes the ring loader, and summarizes replay and
host-to-FPGA load throughput for each generated packet size.
"""

from __future__ import annotations

import argparse
import csv
import json
import shlex
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_BEAT_BYTES = 64
DEFAULT_TICK_HZ = 300_000_000


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
    parser.add_argument("--ring-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--ring-size", type=int_auto, default=0x0800_0000)
    parser.add_argument("--prefill-bytes", type=int_auto, default=0)
    parser.add_argument("--guard-bytes", type=int_auto, default=1 * 1024 * 1024)
    parser.add_argument("--batch-bytes", type=int_auto, default=64 * 1024 * 1024)
    parser.add_argument("--read-bytes", type=int_auto, default=64 * 1024 * 1024)
    parser.add_argument("--queue-depth", type=int_auto, default=4)
    parser.add_argument("--writer-threads", type=int_auto, default=1)
    parser.add_argument("--host-cache-bytes", help="pass BYTES or auto to the C++ loader host-memory cache")
    parser.add_argument("--host-cache-fraction", type=float, default=0.85)
    parser.add_argument("--poll-interval", type=float, default=0.0002)
    parser.add_argument("--work-dir", type=Path, default=Path("/tmp/traffic_replay_stream_ring_stress"))
    parser.add_argument(
        "--lane-dir",
        type=Path,
        action="append",
        help="SSD lane directory for record-aligned striping; repeat for dual/multi SSD",
    )
    parser.add_argument("--stripe-block-bytes", type=int_auto, default=256 * 1024 * 1024)
    parser.add_argument("--frame-sizes", type=parse_frame_sizes, default=parse_frame_sizes("64,128,256,512,1024,1518"))
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--gap-ticks", type=int_auto, default=0)
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    parser.add_argument("--watermark", type=int_auto, default=4096)
    parser.add_argument("--start-time", type=int_auto, default=0)
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--feed-timeout", type=float, default=0.0)
    parser.add_argument("--csv", type=Path, help="optional CSV result path")
    parser.add_argument("--loader", choices=["auto", "cpp", "python"], default="auto")
    parser.add_argument("--cpp-loader", type=Path, default=SCRIPT_DIR / "xdma_stream_ring_fast")
    parser.add_argument("--python", default=sys.executable or "python3")
    return parser.parse_args()


def make_payload(packet_index: int, frame_len: int) -> bytes:
    return bytes(((packet_index * 13 + i) & 0xFF) for i in range(frame_len))


def make_stream(stream_path: Path, manifest_path: Path, packet_count: int, frame_len: int, gap_ticks: int) -> dict[str, int | str]:
    payload_aligned = align_up(frame_len, DATA_BEAT_BYTES)
    total_frame_bytes = packet_count * frame_len
    stream_bytes = packet_count * (DATA_BEAT_BYTES + payload_aligned)

    stream_path.parent.mkdir(parents=True, exist_ok=True)
    with stream_path.open("wb") as fh:
        for pkt_idx in range(packet_count):
            header = bytearray(DATA_BEAT_BYTES)
            header[0:8] = int(gap_ticks).to_bytes(8, "little")
            header[8:12] = (0).to_bytes(4, "little")
            header[12:14] = int(frame_len).to_bytes(2, "little")
            header[14:16] = (0).to_bytes(2, "little")
            payload = make_payload(pkt_idx, frame_len)
            fh.write(header)
            fh.write(payload)
            fh.write(bytes(payload_aligned - frame_len))

    manifest = {
        "generator": "stream_stress_test.py",
        "stream_file": str(stream_path),
        "stream_bytes": stream_bytes,
        "packet_count": packet_count,
        "gap_ticks": gap_ticks,
        "frame_len": frame_len,
        "data_beat_bytes": DATA_BEAT_BYTES,
        "total_frame_bytes": total_frame_bytes,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def shell_line(cmd: list[str]) -> str:
    return " ".join(shlex.quote(str(item)) for item in cmd)


def parse_loader_output(text: str) -> dict[str, str]:
    metrics: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if key:
            metrics[key] = value
    return metrics


def selected_loader(args: argparse.Namespace) -> str:
    if args.loader == "auto":
        return "cpp" if args.cpp_loader.exists() else "python"
    return args.loader


def build_loader_cmd(args: argparse.Namespace, manifest_path: Path, loader: str, striped: bool = False) -> list[str]:
    common = [
        "--port",
        str(args.port),
        "--stripe-manifest" if striped else "--manifest",
        str(manifest_path),
        "--h2c",
        args.h2c,
        "--user",
        args.user,
        "--ring-base",
        f"0x{args.ring_base:x}",
        "--ring-size",
        f"0x{args.ring_size:x}",
        "--prefill-bytes",
        f"0x{args.prefill_bytes:x}",
        "--guard-bytes",
        f"0x{args.guard_bytes:x}",
        "--batch-bytes",
        f"0x{args.batch_bytes:x}",
        "--watermark",
        str(args.watermark),
        "--start-time",
        str(args.start_time),
        "--rate-q16-16",
        f"0x{args.rate_q16_16:x}",
        "--tick-hz",
        str(args.tick_hz),
        "--poll-interval",
        str(args.poll_interval),
        "--timeout",
        str(args.timeout),
    ]
    if args.reg_base is not None:
        common += ["--reg-base", f"0x{args.reg_base:x}"]
    if args.feed_timeout > 0:
        common += ["--feed-timeout", str(args.feed_timeout)]
    if args.force_link_up:
        common.append("--force-link-up")
    if args.force_tx_ready:
        common.append("--force-tx-ready")

    if loader == "cpp":
        cmd = [
            str(args.cpp_loader),
            *common,
            "--read-bytes",
            f"0x{args.read_bytes:x}",
            "--queue-depth",
            str(args.queue_depth),
            "--writer-threads",
            str(args.writer_threads),
        ]
        if args.host_cache_bytes:
            cmd += ["--host-cache-bytes", args.host_cache_bytes]
            cmd += ["--host-cache-fraction", str(args.host_cache_fraction)]
        return cmd
    return [args.python, str(SCRIPT_DIR / "xdma_stream_ring.py"), *common]


def run_case(args: argparse.Namespace, frame_len: int) -> dict[str, str | int]:
    case_dir = args.work_dir / f"len{frame_len}_pkts{args.packet_count}_gap{args.gap_ticks}"
    stream_path = case_dir / "stream.bin"
    manifest_path = case_dir / "stream_manifest.json"
    manifest = make_stream(stream_path, manifest_path, args.packet_count, frame_len, args.gap_ticks)
    loader_manifest = manifest_path
    striped = False
    if args.lane_dir:
        if len(args.lane_dir) < 2:
            raise SystemExit("use at least two --lane-dir values for striped STREAM testing")
        stripe_manifest = case_dir / "stripe_manifest.json"
        lane_args = []
        for lane_dir in args.lane_dir:
            lane_args += ["--lane-dir", str(lane_dir / case_dir.name)]
        stripe_cmd = [
            args.python,
            str(SCRIPT_DIR / "stream_stripe.py"),
            "--manifest",
            str(manifest_path),
            "--out-manifest",
            str(stripe_manifest),
            "--block-bytes",
            f"0x{args.stripe_block_bytes:x}",
            "--force",
            *lane_args,
        ]
        print(f"$ {shell_line(stripe_cmd)}")
        stripe_proc = subprocess.run(stripe_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        print(stripe_proc.stdout, end="")
        if stripe_proc.returncode != 0:
            raise SystemExit(f"stream striping failed for frame_len={frame_len} with exit={stripe_proc.returncode}")
        loader_manifest = stripe_manifest
        striped = True
    loader = selected_loader(args)
    cmd = build_loader_cmd(args, loader_manifest, loader, striped)

    print(f"\ncase frame_len={frame_len} packets={args.packet_count} stream_bytes={manifest['stream_bytes']}")
    print(f"$ {shell_line(cmd)}")
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    print(proc.stdout, end="")
    if proc.returncode != 0:
        raise SystemExit(f"ring stream replay failed for frame_len={frame_len} with exit={proc.returncode}")

    metrics = parse_loader_output(proc.stdout)
    row: dict[str, str | int] = {
        "frame_len": frame_len,
        "packet_count": args.packet_count,
        "gap_ticks": args.gap_ticks,
        "stream_bytes": int(manifest["stream_bytes"]),
        "total_frame_bytes": int(manifest["total_frame_bytes"]),
        "loader": loader,
        "source_mode": metrics.get("source_mode", "striped" if striped else "stream"),
        "block_count": metrics.get("block_count", ""),
        "reader_threads": metrics.get("reader_threads", ""),
        "reader_window": metrics.get("reader_window", ""),
        "completed": metrics.get("completed", ""),
        "committed_packets": metrics.get("committed_packets", ""),
        "committed_bytes": metrics.get("committed_bytes", ""),
        "tx_packets": metrics.get("tx_packets", ""),
        "tx_bytes": metrics.get("tx_bytes", ""),
        "late_packets": metrics.get("late_packets", ""),
        "underrun_packets": metrics.get("underrun_packets", ""),
        "stream_status": metrics.get("stream_status", ""),
        "max_ring_level": metrics.get("max_ring_level", ""),
        "min_ring_free": metrics.get("min_ring_free", ""),
        "read_bytes": metrics.get("read_bytes", ""),
        "queue_depth": metrics.get("queue_depth", ""),
        "host_cache_target": metrics.get("host_cache_target", ""),
        "host_cache_window": metrics.get("host_cache_window", ""),
        "load_gbps": metrics.get("load_gbps", ""),
        "hw_gbps": metrics.get("hw_gbps", ""),
        "load_seconds": metrics.get("load_seconds", ""),
        "wall_seconds": metrics.get("wall_seconds", ""),
    }
    print(
        "summary "
        f"frame_len={row['frame_len']} completed={row['completed']} "
        f"tx_packets={row['tx_packets']} load_gbps={row['load_gbps']} hw_gbps={row['hw_gbps']}"
    )
    return row


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    if args.ring_size <= 0 or args.ring_size % DATA_BEAT_BYTES != 0:
        raise SystemExit("--ring-size must be a positive 64-byte multiple")
    if args.guard_bytes >= args.ring_size:
        raise SystemExit("--guard-bytes must be smaller than --ring-size")
    args.work_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for frame_len in args.frame_sizes:
        if frame_len <= 0 or frame_len > 0xFFFF:
            raise SystemExit(f"invalid frame size: {frame_len}")
        rows.append(run_case(args, frame_len))

    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
