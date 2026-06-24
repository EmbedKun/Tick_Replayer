#!/usr/bin/env python3
"""Convert a classic pcap file into the traffic replay descriptor/data format."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


DESC_BYTES = 64
DATA_BEAT_BYTES = 64
DEFAULT_TICK_HZ = 322_265_625


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcap", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--tick-hz", type=int, default=DEFAULT_TICK_HZ)
    parser.add_argument("--min-frame", type=int, default=60)
    parser.add_argument("--keep-fcs", action="store_true")
    return parser.parse_args()


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def read_global_header(fh):
    header = fh.read(24)
    if len(header) != 24:
      raise ValueError("pcap global header is truncated")

    magic = header[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
        ns_resolution = False
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
        ns_resolution = False
    elif magic == b"\x4d\x3c\xb2\xa1":
        endian = "<"
        ns_resolution = True
    elif magic == b"\xa1\xb2\x3c\x4d":
        endian = ">"
        ns_resolution = True
    else:
        raise ValueError("only classic pcap is supported; pcapng is not supported yet")

    version_major, version_minor, _, _, snaplen, network = struct.unpack(endian + "HHIIII", header[4:])
    return endian, ns_resolution, {
        "version_major": version_major,
        "version_minor": version_minor,
        "snaplen": snaplen,
        "network": network,
    }


def timestamp_to_ns(sec: int, frac: int, ns_resolution: bool) -> int:
    if ns_resolution:
        return sec * 1_000_000_000 + frac
    return sec * 1_000_000_000 + frac * 1_000


def main() -> None:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    desc_path = args.out_dir / "desc.bin"
    data_path = args.out_dir / "data.bin"
    manifest_path = args.out_dir / "manifest.json"

    pkt_count = 0
    data_offset_words = 0
    prev_ts_ns = None
    first_ts_ns = None
    total_wire_bytes = 0
    max_frame_len = 0

    with args.pcap.open("rb") as fh, desc_path.open("wb") as desc_fh, data_path.open("wb") as data_fh:
        endian, ns_resolution, pcap_info = read_global_header(fh)
        rec_struct = struct.Struct(endian + "IIII")

        while True:
            rec_hdr = fh.read(rec_struct.size)
            if not rec_hdr:
                break
            if len(rec_hdr) != rec_struct.size:
                raise ValueError("packet record header is truncated")

            ts_sec, ts_frac, incl_len, orig_len = rec_struct.unpack(rec_hdr)
            payload = fh.read(incl_len)
            if len(payload) != incl_len:
                raise ValueError("packet payload is truncated")

            ts_ns = timestamp_to_ns(ts_sec, ts_frac, ns_resolution)
            if first_ts_ns is None:
                first_ts_ns = ts_ns
            if prev_ts_ns is None:
                gap_ns = 0
            else:
                gap_ns = max(0, ts_ns - prev_ts_ns)
            prev_ts_ns = ts_ns

            frame = payload if args.keep_fcs else payload[:orig_len]
            if len(frame) < args.min_frame:
                frame = frame + bytes(args.min_frame - len(frame))

            frame_len = len(frame)
            if frame_len > 0xffff:
                raise ValueError(f"frame too large for descriptor: {frame_len} bytes")

            gap_ticks = round(gap_ns * args.tick_hz / 1_000_000_000)
            desc = struct.pack("<QIHH", gap_ticks, data_offset_words, frame_len, 0)
            desc_fh.write(desc)
            desc_fh.write(bytes(DESC_BYTES - len(desc)))

            padded_len = align_up(frame_len, DATA_BEAT_BYTES)
            data_fh.write(frame)
            data_fh.write(bytes(padded_len - frame_len))

            data_offset_words += padded_len // DATA_BEAT_BYTES
            pkt_count += 1
            total_wire_bytes += frame_len
            max_frame_len = max(max_frame_len, frame_len)

    manifest = {
        "pcap": str(args.pcap),
        "descriptor_file": str(desc_path),
        "data_file": str(data_path),
        "descriptor_bytes": DESC_BYTES,
        "data_beat_bytes": DATA_BEAT_BYTES,
        "tick_hz": args.tick_hz,
        "packet_count": pkt_count,
        "data_bytes_aligned": data_offset_words * DATA_BEAT_BYTES,
        "total_frame_bytes": total_wire_bytes,
        "max_frame_len": max_frame_len,
        "first_timestamp_ns": first_ts_ns,
        "pcap_info": pcap_info,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
