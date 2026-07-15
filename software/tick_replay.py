#!/usr/bin/env python3
"""Unified Linux command line for Tick Replayer."""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from pathlib import Path


VERSION = "0.9.0-rc1"
TOOL_DIR = Path(__file__).resolve().parent
DRY_RUN = False


def int_auto(value: str) -> int:
    return int(value, 0)


def tool(name: str) -> Path:
    path = TOOL_DIR / name
    if not path.exists() and not DRY_RUN:
        raise FileNotFoundError(f"required Tick Replayer tool is missing: {path}")
    return path


def run(command: list[str]) -> None:
    print("$ " + " ".join(shlex.quote(item) for item in command), flush=True)
    if not DRY_RUN:
        subprocess.run(command, check=True)


def python_tool(name: str, *args: str) -> list[str]:
    return [sys.executable, str(tool(name)), *args]


def port_bases(port: int) -> tuple[int, int, int]:
    if port == 0:
        return 0x0000_0000, 0x0010_0000_00, 0x0020_0000_00
    return 0x0400_0000_00, 0x0410_0000_00, 0x0420_0000_00


def add_device_args(parser: argparse.ArgumentParser, *, stream: bool = False) -> None:
    parser.add_argument("--user", default="/dev/xdma0_user")
    parser.add_argument("--h2c", default="auto" if stream else "/dev/xdma0_h2c_0")


def add_port_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tick-replay",
        description="Prepare, load, replay, observe, and validate PCAP traffic on Tick Replayer.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the complete command chain without accessing FPGA devices",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare", help="convert a classic PCAP into FPGA trace files")
    prepare.add_argument("pcap", type=Path)
    prepare.add_argument("--out-dir", type=Path, required=True)
    prepare.add_argument("--tick-hz", type=int_auto, default=300_000_000)
    prepare.add_argument("--min-frame", type=int_auto, default=60)
    prepare.add_argument("--keep-fcs", action="store_true")

    load = sub.add_parser("load", help="load and optionally start PRELOAD or LOOP replay")
    load.add_argument("--manifest", type=Path, required=True)
    load.add_argument("--mode", choices=["preload", "loop"], default="preload")
    add_port_arg(load)
    add_device_args(load)
    load.add_argument("--desc-base", type=int_auto)
    load.add_argument("--data-base", type=int_auto)
    load.add_argument("--loop-count", type=int_auto, default=0)
    load.add_argument("--loop-gap", type=int_auto, default=0)
    load.add_argument("--start-time", type=int_auto, default=0)
    load.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    load.add_argument("--arm-only", action="store_true", help="load/configure without issuing START")
    load.add_argument("--force-link-up", action="store_true")
    load.add_argument("--force-tx-ready", action="store_true")
    load.add_argument("--strict", action="store_true", help="disable automatic drop on prolonged TX stalls")

    stream = sub.add_parser("stream", help="run the high-performance STREAM ring backend")
    source = stream.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path)
    source.add_argument("--stripe-manifest", type=Path)
    add_port_arg(stream)
    add_device_args(stream, stream=True)
    stream.add_argument("--ring-base", type=int_auto)
    stream.add_argument("--ring-size", type=int_auto, default=0x4000_0000)
    stream.add_argument("--pingpong", action="store_true")
    stream.add_argument("--pingpong-bank1-base", type=int_auto, default=0x0400_0000_00)
    stream.add_argument("--prefill-bytes", type=int_auto, default=0x0400_0000)
    stream.add_argument("--guard-bytes", type=int_auto, default=0x0010_0000)
    stream.add_argument("--batch-bytes", type=int_auto, default=0x0400_0000)
    stream.add_argument("--read-bytes", type=int_auto, default=0x0400_0000)
    stream.add_argument("--queue-depth", type=int_auto, default=128)
    stream.add_argument("--writer-threads", type=int_auto, default=4)
    stream.add_argument("--reader-threads", type=int_auto, default=16)
    stream.add_argument("--reader-window-blocks", type=int_auto, default=128)
    stream.add_argument("--host-cache-bytes")
    stream.add_argument("--host-cache-fraction", type=float, default=0.85)
    stream.add_argument("--watermark", type=int_auto, default=4096)
    stream_start = stream.add_mutually_exclusive_group()
    stream_start.add_argument("--start-time", type=int_auto, default=0)
    stream_start.add_argument("--start-delay-ms", type=float, default=0.0)
    stream.add_argument("--tick-hz", type=int_auto, default=300_000_000)
    stream.add_argument("--rate-q16-16", type=int_auto, default=0x0001_0000)
    stream.add_argument("--sync-enable", action="store_true")
    stream.add_argument("--egress-schedule", action="store_true")
    stream.add_argument("--timeout", type=float, default=120.0)
    stream.add_argument("--feed-timeout", type=float, default=120.0)
    stream.add_argument("--buffered-read", action="store_true")
    stream.add_argument("--force-link-up", action="store_true")
    stream.add_argument("--force-tx-ready", action="store_true")
    stream.add_argument("--no-wait", action="store_true")

    status = sub.add_parser("status", help="show TX and RX status")
    status.add_argument("--port", choices=["0", "1", "all"], default="all")
    status.add_argument("--user", default="/dev/xdma0_user")

    for name in ("start", "stop", "clear", "pause", "resume"):
        control = sub.add_parser(name, help=f"{name} one replay port")
        add_port_arg(control)
        control.add_argument("--user", default="/dev/xdma0_user")

    sync = sub.add_parser("sync-start", help="arm multiple ports for one absolute FPGA tick")
    sync.add_argument("--ports", default="0,1")
    sync.add_argument("--delay-ms", type=float, default=100.0)
    sync.add_argument("--tick-hz", type=int_auto, default=300_000_000)
    sync.add_argument("--egress-schedule", action="store_true")
    sync.add_argument("--user", default="/dev/xdma0_user")

    rx = sub.add_parser("rx", help="RX measurement and sample controls")
    add_port_arg(rx)
    rx.add_argument("--user", default="/dev/xdma0_user")
    rx_sub = rx.add_subparsers(dest="rx_command", required=True)
    rx_sub.add_parser("status")
    rx_sub.add_parser("clear")
    rx_sub.add_parser("enable")
    rx_sub.add_parser("disable")
    events = rx_sub.add_parser("events")
    events.add_argument("--limit", type=int_auto, default=64)
    histogram = rx_sub.add_parser("histogram")
    histogram.add_argument("index", nargs="?", type=int_auto)

    verify = sub.add_parser("verify", help="run hardware correctness checks")
    verify_sub = verify.add_subparsers(dest="verify_command", required=True)
    ddr = verify_sub.add_parser("ddr", help="H2C/C2H DDR readback")
    ddr.add_argument("--case", action="append")
    ddr.add_argument("--repeat", type=int_auto, default=1)
    ddr.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    ddr.add_argument("--c2h", default="/dev/xdma0_c2h_0")
    loopback = verify_sub.add_parser("loopback", help="TX-to-RX optical payload verification")
    loopback.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    loopback.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    loopback.add_argument("--packet-count", type=int_auto, default=4096)
    loopback.add_argument("--frame-len", type=int_auto, default=128)
    loopback.add_argument("--gap-ticks", type=int_auto, default=2000)
    precision = verify_sub.add_parser("precision", help="RX-side replay precision suite")
    precision.add_argument("--tx-port", type=int, choices=[0, 1], default=0)
    precision.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    precision.add_argument("--work-dir", type=Path, default=Path("/tmp/tick_replay_precision"))
    precision.add_argument("--report", type=Path, default=Path("/tmp/tick_replay_precision/report.md"))

    validate = sub.add_parser("validate", help="run an archived hardware validation profile")
    validate.add_argument("--profile", choices=["smoke", "stress", "long"], default="smoke")
    validate.add_argument("--work-dir", type=Path, default=Path("/var/tmp/tick-replayer-validation"))
    add_port_arg(validate)
    validate.add_argument("--h2c", default="/dev/xdma0_h2c_0")
    validate.add_argument("--c2h", default="/dev/xdma0_c2h_0")
    validate.add_argument("--user", default="/dev/xdma0_user")
    validate.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    validate.add_argument("--ring-loader", choices=["cpp", "python"], default="cpp")
    validate.add_argument("--skip-ddr", action="store_true")
    validate.add_argument("--skip-preload", action="store_true")
    validate.add_argument("--skip-ring", action="store_true")
    validate.add_argument("--skip-rx", action="store_true")
    validate.add_argument("--force-link-up", action="store_true")
    validate.add_argument("--force-tx-ready", action="store_true")

    benchmark = sub.add_parser("benchmark", help="run Host/FPGA throughput benchmarks")
    benchmark_sub = benchmark.add_subparsers(dest="benchmark_command", required=True)
    h2c = benchmark_sub.add_parser("h2c")
    h2c.add_argument("--h2c", default="auto")
    h2c.add_argument("--addr", type=int_auto, default=0x8000_0000)
    h2c.add_argument("--bytes", type=int_auto, default=0x4000_0000)
    h2c.add_argument("--chunk-bytes", type=int_auto, default=0x0400_0000)
    h2c.add_argument("--threads", type=int_auto, default=4)
    h2c.add_argument("--passes", type=int_auto, default=1)

    return parser


def dispatch(args: argparse.Namespace) -> None:
    if args.command == "prepare":
        command = python_tool(
            "pcap2trace.py",
            str(args.pcap),
            "--out-dir",
            str(args.out_dir),
            "--tick-hz",
            str(args.tick_hz),
            "--min-frame",
            str(args.min_frame),
        )
        if args.keep_fcs:
            command.append("--keep-fcs")
        run(command)
        return

    if args.command == "load":
        default_desc, default_data, _ = port_bases(args.port)
        command = python_tool(
            "xdma_load_trace.py",
            "--manifest",
            str(args.manifest),
            "--port",
            str(args.port),
            "--h2c",
            args.h2c,
            "--user",
            args.user,
            "--desc-base",
            hex(default_desc if args.desc_base is None else args.desc_base),
            "--data-base",
            hex(default_data if args.data_base is None else args.data_base),
            "--mode",
            args.mode,
            "--loop-count",
            str(args.loop_count),
            "--loop-gap",
            str(args.loop_gap),
            "--start-time",
            str(args.start_time),
            "--rate-q16-16",
            hex(args.rate_q16_16),
        )
        if args.arm_only:
            command.append("--no-start")
        if args.force_link_up:
            command.append("--force-link-up")
        if args.force_tx_ready:
            command.append("--force-tx-ready")
        command.append("--no-auto-drop" if args.strict else "--auto-drop")
        run(command)
        return

    if args.command == "stream":
        _, _, default_ring = port_bases(args.port)
        command = [
            str(tool("xdma_stream_ring_fast")),
            "--manifest" if args.manifest else "--stripe-manifest",
            str(args.manifest or args.stripe_manifest),
            "--port",
            str(args.port),
            "--h2c",
            args.h2c,
            "--user",
            args.user,
            "--ring-base",
            hex(default_ring if args.ring_base is None else args.ring_base),
            "--ring-size",
            hex(args.ring_size),
            "--prefill-bytes",
            hex(args.prefill_bytes),
            "--guard-bytes",
            hex(args.guard_bytes),
            "--batch-bytes",
            hex(args.batch_bytes),
            "--read-bytes",
            hex(args.read_bytes),
            "--queue-depth",
            str(args.queue_depth),
            "--writer-threads",
            str(args.writer_threads),
            "--reader-threads",
            str(args.reader_threads),
            "--reader-window-blocks",
            str(args.reader_window_blocks),
            "--watermark",
            str(args.watermark),
            "--start-time",
            str(args.start_time),
            "--tick-hz",
            str(args.tick_hz),
            "--rate-q16-16",
            hex(args.rate_q16_16),
            "--timeout",
            str(args.timeout),
            "--feed-timeout",
            str(args.feed_timeout),
        ]
        if args.pingpong:
            command += ["--pingpong", "--pingpong-bank1-base", hex(args.pingpong_bank1_base)]
        if args.start_delay_ms:
            start_index = command.index("--start-time")
            del command[start_index : start_index + 2]
            command += ["--start-delay-ms", str(args.start_delay_ms)]
        if args.sync_enable:
            command.append("--sync-enable")
        if args.egress_schedule:
            command.append("--egress-schedule")
        if args.host_cache_bytes:
            command += [
                "--host-cache-bytes",
                args.host_cache_bytes,
                "--host-cache-fraction",
                str(args.host_cache_fraction),
            ]
        if args.buffered_read:
            command.append("--buffered-read")
        if args.force_link_up:
            command.append("--force-link-up")
        if args.force_tx_ready:
            command.append("--force-tx-ready")
        if args.no_wait:
            command.append("--no-wait")
        run(command)
        return

    if args.command == "status":
        ports = (0, 1) if args.port == "all" else (int(args.port),)
        for port in ports:
            print(f"\n[port {port} TX]")
            run(python_tool("traffic_replay_cli.py", "--user", args.user, "--port", str(port), "status"))
            print(f"\n[port {port} RX]")
            run(python_tool("traffic_replay_cli.py", "--user", args.user, "--port", str(port), "rx-status"))
        return

    if args.command in {"start", "stop", "clear", "pause", "resume"}:
        run(python_tool("traffic_replay_cli.py", "--user", args.user, "--port", str(args.port), args.command))
        return

    if args.command == "sync-start":
        ports = [int(port.strip(), 0) for port in args.ports.split(",")]
        if args.egress_schedule:
            for port in ports:
                run(
                    python_tool(
                        "traffic_replay_cli.py",
                        "--user",
                        args.user,
                        "--port",
                        str(port),
                        "egress-schedule",
                        "on",
                    )
                )
        run(
            python_tool(
                "traffic_replay_cli.py",
                "--user",
                args.user,
                "sync-start",
                "--ports",
                args.ports,
                "--delay-ms",
                str(args.delay_ms),
                "--tick-hz",
                str(args.tick_hz),
            )
        )
        return

    if args.command == "rx":
        rx_map = {"status": "rx-status", "clear": "rx-clear", "enable": "rx-enable", "disable": "rx-disable"}
        command = rx_map.get(args.rx_command, args.rx_command)
        cli_args = ["--user", args.user, "--port", str(args.port)]
        if command == "events":
            cli_args += ["rx-events", "--limit", str(args.limit)]
        elif command == "histogram":
            cli_args.append("rx-histogram")
            if args.index is not None:
                cli_args.append(str(args.index))
        else:
            cli_args.append(command)
        run(python_tool("traffic_replay_cli.py", *cli_args))
        return

    if args.command == "verify":
        if args.verify_command == "ddr":
            cases = args.case or [
                "0x0000000000:0x100000",
                "0x03fff00000:0x100000",
                "0x0400000000:0x100000",
                "0x07fff00000:0x100000",
                "0x0800000000:0x100000",
                "0x0bfff00000:0x100000",
                "0x0c00000000:0x100000",
                "0x0ffff00000:0x100000",
            ]
            command = python_tool(
                "ddr_readback_check.py",
                "--h2c",
                args.h2c,
                "--c2h",
                args.c2h,
                "--repeat",
                str(args.repeat),
            )
            for case in cases:
                command += ["--case", case]
            run(command)
        elif args.verify_command == "loopback":
            tx_desc, tx_data, _ = port_bases(args.tx_port)
            rx_ring = 0x0C10_0000_00 if args.rx_port == 1 else 0x0810_0000_00
            run(
                python_tool(
                    "loopback_rx_verify.py",
                    "--tx-port",
                    str(args.tx_port),
                    "--rx-port",
                    str(args.rx_port),
                    "--desc-base",
                    hex(tx_desc),
                    "--data-base",
                    hex(tx_data),
                    "--rx-ring-base",
                    hex(rx_ring),
                    "--rx-ring-size",
                    "0x01000000",
                    "--truncate-bytes",
                    str(args.frame_len),
                    "--packet-count",
                    str(args.packet_count),
                    "--frame-len",
                    str(args.frame_len),
                    "--gap-ticks",
                    str(args.gap_ticks),
                )
            )
        else:
            tx_desc, tx_data, _ = port_bases(args.tx_port)
            run(
                python_tool(
                    "replay_precision_suite.py",
                    "--tx-port",
                    str(args.tx_port),
                    "--rx-port",
                    str(args.rx_port),
                    "--work-dir",
                    str(args.work_dir),
                    "--desc-base",
                    hex(tx_desc),
                    "--data-base",
                    hex(tx_data),
                    "--timeout",
                    "180",
                    "--report",
                    str(args.report),
                )
            )
        return

    if args.command == "validate":
        command = python_tool(
            "hw_validation_suite.py",
            "--profile",
            args.profile,
            "--work-dir",
            str(args.work_dir),
            "--port",
            str(args.port),
            "--h2c",
            args.h2c,
            "--c2h",
            args.c2h,
            "--user",
            args.user,
            "--rx-port",
            str(args.rx_port),
            "--ring-loader",
            args.ring_loader,
        )
        for option in ("skip_ddr", "skip_preload", "skip_ring", "skip_rx"):
            if getattr(args, option):
                command.append("--" + option.replace("_", "-"))
        if args.force_link_up:
            command.append("--force-link-up")
        if args.force_tx_ready:
            command.append("--force-tx-ready")
        run(command)
        return

    if args.command == "benchmark" and args.benchmark_command == "h2c":
        run(
            [
                str(tool("xdma_h2c_bench")),
                "--h2c",
                args.h2c,
                "--addr",
                hex(args.addr),
                "--bytes",
                hex(args.bytes),
                "--chunk-bytes",
                hex(args.chunk_bytes),
                "--threads",
                str(args.threads),
                "--passes",
                str(args.passes),
            ]
        )
        return

    raise RuntimeError(f"unhandled command: {args.command}")


def main() -> None:
    global DRY_RUN
    parser = build_parser()
    try:
        args = parser.parse_args()
        DRY_RUN = args.dry_run
        dispatch(args)
    except (OSError, subprocess.CalledProcessError, ValueError, RuntimeError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")


if __name__ == "__main__":
    main()
