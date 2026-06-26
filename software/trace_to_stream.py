#!/usr/bin/env python3
"""Convert descriptor/data trace files into a DDR-backed stream buffer."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


DESC_BYTES = 64
DATA_BEAT_BYTES = 64


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="manifest.json from pcap2trace.py or gen_synthetic_trace.py")
    parser.add_argument("--desc", type=Path, help="desc.bin path")
    parser.add_argument("--data", type=Path, help="data.bin path")
    parser.add_argument("--out", type=Path, required=True, help="output stream.bin path")
    parser.add_argument("--out-manifest", type=Path, help="output stream manifest JSON path")
    return parser.parse_args()


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def load_manifest(args: argparse.Namespace) -> dict:
    if args.manifest is None:
        return {}
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    base = args.manifest.parent
    if args.desc is None:
        args.desc = base / Path(manifest["descriptor_file"]).name
    if args.data is None:
        args.data = base / Path(manifest["data_file"]).name
    return manifest


def require_file(path: Path | None, label: str) -> Path:
    if path is None:
        raise SystemExit(f"{label} is required")
    if not path.is_file():
        raise SystemExit(f"{label} not found: {path}")
    return path


def main() -> None:
    args = parse_args()
    manifest_in = load_manifest(args)
    desc_path = require_file(args.desc, "--desc")
    data_path = require_file(args.data, "--data")

    desc_bytes = desc_path.read_bytes()
    data_bytes = data_path.read_bytes()
    if len(desc_bytes) % DESC_BYTES != 0:
        raise SystemExit(f"descriptor file size must be a multiple of {DESC_BYTES}: {len(desc_bytes)}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    packet_count = len(desc_bytes) // DESC_BYTES
    total_frame_bytes = 0
    stream_bytes = 0

    with args.out.open("wb") as out_fh:
        for pkt_idx in range(packet_count):
            desc = desc_bytes[pkt_idx * DESC_BYTES:(pkt_idx + 1) * DESC_BYTES]
            gap_ticks, data_word_offset, frame_len, flags = struct.unpack("<QIHH", desc[:16])
            payload_offset = data_word_offset * DATA_BEAT_BYTES
            payload_len_aligned = align_up(frame_len, DATA_BEAT_BYTES)
            payload = data_bytes[payload_offset:payload_offset + payload_len_aligned]
            if len(payload) != payload_len_aligned:
                raise SystemExit(
                    f"payload for packet {pkt_idx} is truncated: "
                    f"need {payload_len_aligned} bytes at offset {payload_offset}, got {len(payload)}"
                )

            header = bytearray(DESC_BYTES)
            struct.pack_into("<QIHH", header, 0, gap_ticks, 0, frame_len, flags)
            out_fh.write(header)
            out_fh.write(payload)

            stream_bytes += DESC_BYTES + payload_len_aligned
            total_frame_bytes += frame_len

    out_manifest = {
        "generator": "trace_to_stream.py",
        "source_manifest": str(args.manifest) if args.manifest else None,
        "source_descriptor_file": str(desc_path),
        "source_data_file": str(data_path),
        "stream_file": str(args.out),
        "stream_bytes": stream_bytes,
        "packet_count": packet_count,
        "total_frame_bytes": total_frame_bytes,
        "data_beat_bytes": DATA_BEAT_BYTES,
        "input": manifest_in,
    }
    manifest_path = args.out_manifest or (args.out.parent / "stream_manifest.json")
    manifest_path.write_text(json.dumps(out_manifest, indent=2), encoding="utf-8")
    print(json.dumps(out_manifest, indent=2))


if __name__ == "__main__":
    main()
