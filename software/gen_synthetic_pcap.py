#!/usr/bin/env python3
"""Generate deterministic Ethernet/IPv4/UDP classic-pcap test traffic."""

from __future__ import annotations

import argparse
import ipaddress
import random
import struct
from pathlib import Path


ETH_BYTES = 14
IPV4_BYTES = 20
UDP_BYTES = 8
MIN_ETH_FRAME_BYTES = 60
DEFAULT_TICK_HZ = 300_000_000


def int_auto(value: str) -> int:
    return int(value, 0)


def parse_mac(value: str) -> bytes:
    parts = value.split(":")
    if len(parts) != 6:
        raise argparse.ArgumentTypeError(f"invalid MAC address: {value}")
    try:
        return bytes(int(part, 16) for part in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid MAC address: {value}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True, help="output .pcap path")
    parser.add_argument("--packet-count", type=int_auto, default=100_000)
    parser.add_argument("--frame-len", type=int_auto, default=1518, help="Ethernet frame length without FCS")
    parser.add_argument("--gap-ns", type=int_auto, help="timestamp gap in nanoseconds")
    parser.add_argument("--gap-ticks", type=int_auto, help="timestamp gap in replay clock ticks")
    parser.add_argument("--tick-hz", type=int_auto, default=DEFAULT_TICK_HZ)
    parser.add_argument("--src-mac", type=parse_mac, default=parse_mac("02:00:00:00:00:01"))
    parser.add_argument("--dst-mac", type=parse_mac, default=parse_mac("02:00:00:00:00:02"))
    parser.add_argument("--src-ip", type=ipaddress.IPv4Address, default=ipaddress.IPv4Address("198.18.0.1"))
    parser.add_argument("--dst-ip", type=ipaddress.IPv4Address, default=ipaddress.IPv4Address("198.19.0.1"))
    parser.add_argument("--src-port", type=int_auto, default=12345)
    parser.add_argument("--dst-port", type=int_auto, default=443)
    parser.add_argument("--vary-flow", action="store_true", help="vary IPv4 addresses and UDP ports by packet index")
    parser.add_argument("--seed", type=int_auto, default=0x5449434B)
    return parser.parse_args()


def checksum(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    total = 0
    for idx in range(0, len(data), 2):
        total += (data[idx] << 8) | data[idx + 1]
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def payload_pattern(rng: random.Random, packet_index: int, length: int) -> bytes:
    seed = rng.randrange(0, 256)
    return bytes(((seed + packet_index * 17 + idx * 31) & 0xFF) for idx in range(length))


def make_frame(args: argparse.Namespace, rng: random.Random, packet_index: int) -> bytes:
    min_len = ETH_BYTES + IPV4_BYTES + UDP_BYTES
    if args.frame_len < MIN_ETH_FRAME_BYTES:
        raise ValueError("--frame-len must be at least 60 bytes")
    if args.frame_len > 0xFFFF:
        raise ValueError("--frame-len must fit the 16-bit replay descriptor length")
    if args.frame_len < min_len:
        raise ValueError(f"--frame-len must be at least {min_len} bytes")

    if args.vary_flow:
        src_ip = int(args.src_ip) + (packet_index & 0xFFFF)
        dst_ip = int(args.dst_ip) + ((packet_index * 3) & 0xFFFF)
        src_port = 1024 + ((args.src_port + packet_index) % (65535 - 1024))
        dst_port = 1024 + ((args.dst_port + packet_index * 7) % (65535 - 1024))
    else:
        src_ip = int(args.src_ip)
        dst_ip = int(args.dst_ip)
        src_port = args.src_port
        dst_port = args.dst_port

    udp_payload_len = args.frame_len - ETH_BYTES - IPV4_BYTES - UDP_BYTES
    udp_payload = payload_pattern(rng, packet_index, udp_payload_len)
    udp_len = UDP_BYTES + udp_payload_len
    ip_total_len = IPV4_BYTES + udp_len

    ip_header = struct.pack(
        "!BBHHHBBHII",
        0x45,
        0,
        ip_total_len,
        packet_index & 0xFFFF,
        0x4000,
        64,
        17,
        0,
        src_ip,
        dst_ip,
    )
    ip_sum = checksum(ip_header)
    ip_header = ip_header[:10] + struct.pack("!H", ip_sum) + ip_header[12:]

    udp_header = struct.pack("!HHHH", src_port, dst_port, udp_len, 0)
    pseudo = struct.pack("!IIBBH", src_ip, dst_ip, 0, 17, udp_len)
    udp_sum = checksum(pseudo + udp_header + udp_payload)
    if udp_sum == 0:
        udp_sum = 0xFFFF
    udp_header = struct.pack("!HHHH", src_port, dst_port, udp_len, udp_sum)

    ethernet = args.dst_mac + args.src_mac + struct.pack("!H", 0x0800)
    frame = ethernet + ip_header + udp_header + udp_payload
    if len(frame) < MIN_ETH_FRAME_BYTES:
        frame += bytes(MIN_ETH_FRAME_BYTES - len(frame))
    return frame


def timestamp_from_index(packet_index: int, gap_ns: int) -> tuple[int, int]:
    ts_ns = packet_index * gap_ns
    return ts_ns // 1_000_000_000, ts_ns % 1_000_000_000


def main() -> None:
    args = parse_args()
    if args.packet_count <= 0:
        raise SystemExit("--packet-count must be positive")
    if args.gap_ns is None:
        if args.gap_ticks is None:
            args.gap_ns = 0
        else:
            args.gap_ns = round(args.gap_ticks * 1_000_000_000 / args.tick_hz)
    if args.gap_ns < 0:
        raise SystemExit("--gap-ns must be non-negative")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    with args.out.open("wb") as fh:
        fh.write(struct.pack("<IHHIIII", 0xA1B23C4D, 2, 4, 0, 0, 0xFFFF, 1))
        for packet_index in range(args.packet_count):
            frame = make_frame(args, rng, packet_index)
            ts_sec, ts_nsec = timestamp_from_index(packet_index, args.gap_ns)
            fh.write(struct.pack("<IIII", ts_sec, ts_nsec, len(frame), len(frame)))
            fh.write(frame)

    total_bytes = args.packet_count * args.frame_len
    print(f"pcap              : {args.out}")
    print(f"packet_count      : {args.packet_count}")
    print(f"frame_len         : {args.frame_len}")
    print(f"gap_ns            : {args.gap_ns}")
    print(f"total_frame_bytes : {total_bytes}")


if __name__ == "__main__":
    main()
