#!/usr/bin/env python3
"""Run a repeatable hardware validation suite for Tick Replayer.

The suite is intended to run on the host that owns the XDMA devices.  Run it
with sudo so it can access /dev/xdma0_*.
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent


PROFILES = {
    "smoke": {
        "ddr_repeat": 1,
        "pcap_packets": 4096,
        "finite_packets": 2000,
        "ring_packets": 20000,
        "ring_gap_ticks": 480,
        "ring_size": 0x0080_0000,
        "prefill": 0x0040_0000,
        "rx_packets": 2000,
        "timeout": 30,
    },
    "stress": {
        "ddr_repeat": 3,
        "pcap_packets": 100000,
        "finite_packets": 100000,
        "ring_packets": 200000,
        "ring_gap_ticks": 240,
        "ring_size": 0x0200_0000,
        "prefill": 0x0100_0000,
        "rx_packets": 50000,
        "timeout": 120,
    },
    "long": {
        "ddr_repeat": 10,
        "pcap_packets": 500000,
        "finite_packets": 500000,
        "ring_packets": 1000000,
        "ring_gap_ticks": 240,
        "ring_size": 0x0400_0000,
        "prefill": 0x0200_0000,
        "rx_packets": 200000,
        "timeout": 600,
    },
}


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="smoke")
    parser.add_argument("--work-dir", type=Path, default=Path("/home/user/traffic_replay_validation"))
    parser.add_argument("--python", default=sys.executable or "python3")
    parser.add_argument("--port", type=int, choices=[0, 1], default=0)
    parser.add_argument("--rx-port", type=int, choices=[0, 1], default=1)
    parser.add_argument("--stream-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--ring-base", type=int_auto, default=0x2000_0000)
    parser.add_argument("--rx-ring-base", type=int_auto, default=0x3000_0000)
    parser.add_argument("--rx-ring-size", type=int_auto, default=0x0100_0000)
    parser.add_argument("--watermark", type=int_auto, default=4096)
    parser.add_argument("--ring-loader", choices=["cpp", "python"], default="cpp")
    parser.add_argument("--skip-ddr", action="store_true")
    parser.add_argument("--skip-finite", action="store_true")
    parser.add_argument("--skip-ring", action="store_true")
    parser.add_argument("--skip-rx", action="store_true")
    parser.add_argument("--force-link-up", action="store_true")
    parser.add_argument("--force-tx-ready", action="store_true")
    return parser.parse_args()


def shell_line(cmd: list[str]) -> str:
    return " ".join(shlex.quote(str(item)) for item in cmd)


def run_step(name: str, cmd: list[str], log_path: Path) -> subprocess.CompletedProcess[str]:
    banner = f"\n===== {name} =====\n$ {shell_line(cmd)}\n"
    print(banner, end="", flush=True)
    with log_path.open("a", encoding="utf-8") as log:
        log.write(banner)
        log.flush()
        start = time.perf_counter()
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        elapsed = time.perf_counter() - start
        log.write(proc.stdout)
        log.write(f"\n[exit={proc.returncode} elapsed={elapsed:.3f}s]\n")
    print(proc.stdout, end="")
    print(f"[exit={proc.returncode} elapsed={elapsed:.3f}s]")
    if proc.returncode != 0:
        raise SystemExit(f"step failed: {name}")
    return proc


def script(name: str) -> str:
    return str(SCRIPT_DIR / name)


def maybe_force_args(args: argparse.Namespace) -> list[str]:
    force = []
    if args.force_link_up:
        force.append("--force-link-up")
    if args.force_tx_ready:
        force.append("--force-tx-ready")
    return force


def main() -> None:
    args = parse_args()
    cfg = PROFILES[args.profile]
    run_dir = args.work_dir / f"{time.strftime('%Y%m%d_%H%M%S')}_{args.profile}"
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "validation.log"
    csv_path = run_dir / "finite_stream_sweep.csv"

    print(f"validation_dir    : {run_dir}")
    print(f"profile           : {args.profile}")

    cli = [args.python, script("traffic_replay_cli.py")]
    run_step("tx status before", cli + ["--port", str(args.port), "status"], log_path)
    run_step("rx status before", cli + ["--port", str(args.rx_port), "rx-status"], log_path)

    if not args.skip_ddr:
        run_step(
            "xdma h2c/c2h ddr readback",
            [
                args.python,
                script("ddr_readback_check.py"),
                "--repeat",
                str(cfg["ddr_repeat"]),
                "--case",
                "0x00000000:0x1000",
                "--case",
                "0x00100000:0x10000",
                "--case",
                "0x10000000:0x100000",
            ],
            log_path,
        )

    pcap_dir = run_dir / "pcap_1518"
    pcap_path = pcap_dir / "udp_1518.pcap"
    trace_dir = pcap_dir / "trace"
    stream_path = pcap_dir / "stream.bin"
    run_step(
        "generate synthetic pcap",
        [
            args.python,
            script("gen_synthetic_pcap.py"),
            "--out",
            str(pcap_path),
            "--packet-count",
            str(cfg["pcap_packets"]),
            "--frame-len",
            "1518",
            "--gap-ticks",
            str(cfg["ring_gap_ticks"]),
            "--vary-flow",
        ],
        log_path,
    )
    run_step(
        "pcap to descriptor/data trace",
        [args.python, script("pcap2trace.py"), str(pcap_path), "--out-dir", str(trace_dir)],
        log_path,
    )
    run_step(
        "descriptor/data trace to stream records",
        [
            args.python,
            script("trace_to_stream.py"),
            "--manifest",
            str(trace_dir / "manifest.json"),
            "--out",
            str(stream_path),
        ],
        log_path,
    )

    if not args.skip_finite:
        run_step(
            "finite stream throughput sweep",
            [
                args.python,
                script("stream_stress_test.py"),
                "--port",
                str(args.port),
                "--frame-sizes",
                "64,128,256,512,1024,1518",
                "--packet-count",
                str(cfg["finite_packets"]),
                "--gap-ticks",
                "0",
                "--stream-base",
                f"0x{args.stream_base:x}",
                "--work-dir",
                str(run_dir / "finite_stream"),
                "--csv",
                str(csv_path),
                "--timeout",
                str(cfg["timeout"]),
                "--watermark",
                str(args.watermark),
            ]
            + maybe_force_args(args),
            log_path,
        )

    if not args.skip_ring:
        ring_trace_dir = run_dir / "ring_trace_1518"
        run_step(
            "generate oversized ring-stream trace",
            [
                args.python,
                script("gen_synthetic_trace.py"),
                "--out-dir",
                str(ring_trace_dir),
                "--packet-count",
                str(cfg["ring_packets"]),
                "--frame-len",
                "1518",
                "--gap-ticks",
                str(cfg["ring_gap_ticks"]),
            ],
            log_path,
        )
        run_step(
            "ring trace to stream records",
            [
                args.python,
                script("trace_to_stream.py"),
                "--manifest",
                str(ring_trace_dir / "manifest.json"),
                "--out",
                str(ring_trace_dir / "stream.bin"),
            ],
            log_path,
        )
        if args.ring_loader == "cpp":
            fast_loader = SCRIPT_DIR / "xdma_stream_ring_fast"
            batch_bytes = min(int(cfg["prefill"]), 32 * 1024 * 1024)
            run_step(
                "dynamic ddr ring stream replay cpp",
                [
                    str(fast_loader),
                    "--port",
                    str(args.port),
                    "--manifest",
                    str(ring_trace_dir / "stream_manifest.json"),
                    "--ring-base",
                    f"0x{args.ring_base:x}",
                    "--ring-size",
                    f"0x{cfg['ring_size']:x}",
                    "--prefill-bytes",
                    f"0x{cfg['prefill']:x}",
                    "--batch-bytes",
                    f"0x{batch_bytes:x}",
                    "--read-bytes",
                    f"0x{batch_bytes:x}",
                    "--queue-depth",
                    "4",
                    "--watermark",
                    str(args.watermark),
                    "--timeout",
                    str(cfg["timeout"]),
                    "--feed-timeout",
                    str(cfg["timeout"]),
                ]
                + maybe_force_args(args),
                log_path,
            )
        else:
            run_step(
                "dynamic ddr ring stream replay python",
                [
                    args.python,
                    script("xdma_stream_ring.py"),
                    "--port",
                    str(args.port),
                    "--manifest",
                    str(ring_trace_dir / "stream_manifest.json"),
                    "--ring-base",
                    f"0x{args.ring_base:x}",
                    "--ring-size",
                    f"0x{cfg['ring_size']:x}",
                    "--prefill-bytes",
                    f"0x{cfg['prefill']:x}",
                    "--watermark",
                    str(args.watermark),
                    "--timeout",
                    str(cfg["timeout"]),
                ]
                + maybe_force_args(args),
                log_path,
            )

    if not args.skip_rx:
        run_step("rx disable", cli + ["--port", str(args.rx_port), "rx-disable"], log_path)
        run_step(
            "rx configure capture ring",
            cli
            + [
                "--port",
                str(args.rx_port),
                "rx-config",
                "--ring-base",
                f"0x{args.rx_ring_base:x}",
                "--ring-size",
                f"0x{args.rx_ring_size:x}",
                "--truncate-bytes",
                "128",
            ],
            log_path,
        )
        run_step("rx clear", cli + ["--port", str(args.rx_port), "rx-clear"], log_path)
        run_step("rx enable", cli + ["--port", str(args.rx_port), "rx-enable"], log_path)
        run_step("rx capture on", cli + ["--port", str(args.rx_port), "rx-capture", "on"], log_path)
        run_step(
            "tx to opposite qsfp for rx loopback",
            [
                args.python,
                script("stream_stress_test.py"),
                "--port",
                str(args.port),
                "--frame-sizes",
                "512",
                "--packet-count",
                str(cfg["rx_packets"]),
                "--gap-ticks",
                "0",
                "--stream-base",
                f"0x{args.stream_base:x}",
                "--work-dir",
                str(run_dir / "rx_loopback_tx"),
                "--timeout",
                str(cfg["timeout"]),
                "--watermark",
                str(args.watermark),
            ]
            + maybe_force_args(args),
            log_path,
        )
        run_step("rx status after loopback", cli + ["--port", str(args.rx_port), "rx-status"], log_path)

    run_step("tx status after", cli + ["--port", str(args.port), "status"], log_path)
    print(f"\nvalidation log    : {log_path}")
    print(f"finite csv        : {csv_path}")


if __name__ == "__main__":
    main()
