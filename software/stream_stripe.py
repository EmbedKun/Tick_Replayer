#!/usr/bin/env python3
"""Stripe a STREAM record file into record-aligned blocks across SSD lanes."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


DATA_BEAT_BYTES = 64
DEFAULT_BLOCK_BYTES = 256 * 1024 * 1024


def int_auto(value: str) -> int:
    return int(value, 0)


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="stream_manifest.json from trace_to_stream.py")
    parser.add_argument("--stream", type=Path, help="stream.bin path; overrides manifest stream_file")
    parser.add_argument(
        "--lane-dir",
        type=Path,
        action="append",
        required=True,
        help="output directory on one SSD lane; repeat for dual/multi SSD striping",
    )
    parser.add_argument("--block-bytes", type=int_auto, default=DEFAULT_BLOCK_BYTES)
    parser.add_argument("--out-manifest", type=Path, required=True)
    parser.add_argument("--block-list", type=Path, help="TSV block list path; defaults next to out-manifest")
    parser.add_argument("--force", action="store_true", help="overwrite existing block files")
    return parser.parse_args()


def load_stream_path(args: argparse.Namespace) -> tuple[Path, dict]:
    manifest: dict = {}
    if args.manifest is not None:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if args.stream is not None:
        stream = args.stream
    else:
        stream_file = manifest.get("stream_file")
        if not stream_file:
            raise SystemExit("--stream is required when manifest has no stream_file")
        stream = args.manifest.parent / Path(stream_file).name
    if not stream.is_file():
        raise SystemExit(f"stream file not found: {stream}")
    return stream, manifest


def read_exact(fh, size: int, label: str) -> bytes:
    data = fh.read(size)
    if len(data) != size:
        raise SystemExit(f"short {label}: need {size} bytes, got {len(data)}")
    return data


def block_path_for(lane_dirs: list[Path], block_id: int) -> Path:
    lane = block_id % len(lane_dirs)
    return lane_dirs[lane] / f"block_{block_id:08d}.bin"


def open_block(lane_dirs: list[Path], block_id: int, force: bool):
    path = block_path_for(lane_dirs, block_id)
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing block file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    return path, path.open("wb")


def main() -> None:
    args = parse_args()
    if len(args.lane_dir) < 2:
        raise SystemExit("use at least two --lane-dir values for SSD striping")
    if args.block_bytes < DATA_BEAT_BYTES:
        raise SystemExit("--block-bytes must be at least 64")
    if args.block_bytes % DATA_BEAT_BYTES != 0:
        raise SystemExit("--block-bytes must be a 64-byte multiple")

    stream_path, source_manifest = load_stream_path(args)
    lane_dirs = [path.resolve() for path in args.lane_dir]
    for path in lane_dirs:
        path.mkdir(parents=True, exist_ok=True)

    out_manifest = args.out_manifest.resolve()
    out_manifest.parent.mkdir(parents=True, exist_ok=True)
    block_list = (args.block_list or (out_manifest.parent / "blocks.tsv")).resolve()
    block_list.parent.mkdir(parents=True, exist_ok=True)

    blocks = []
    packet_count = 0
    stream_bytes = 0
    total_frame_bytes = 0
    block_id = 0
    first_packet = 0
    block_packets = 0
    block_bytes = 0
    block_path, block_fh = open_block(lane_dirs, block_id, args.force)

    with stream_path.open("rb") as src:
        while True:
            header = src.read(DATA_BEAT_BYTES)
            if not header:
                break
            if len(header) != DATA_BEAT_BYTES:
                raise SystemExit("stream file ends with a partial 64-byte header")

            _, _, frame_len, _ = struct.unpack("<QIHH", header[:16])
            payload_len = align_up(frame_len, DATA_BEAT_BYTES)
            payload = read_exact(src, payload_len, "payload")
            record_len = DATA_BEAT_BYTES + payload_len

            if block_packets != 0 and block_bytes + record_len > args.block_bytes:
                block_fh.close()
                blocks.append(
                    {
                        "block_id": block_id,
                        "lane": block_id % len(lane_dirs),
                        "path": str(block_path),
                        "bytes": block_bytes,
                        "packets": block_packets,
                        "first_packet": first_packet,
                    }
                )
                block_id += 1
                first_packet = packet_count
                block_packets = 0
                block_bytes = 0
                block_path, block_fh = open_block(lane_dirs, block_id, args.force)

            block_fh.write(header)
            block_fh.write(payload)
            block_packets += 1
            block_bytes += record_len
            packet_count += 1
            stream_bytes += record_len
            total_frame_bytes += frame_len

    block_fh.close()
    if block_packets != 0:
        blocks.append(
            {
                "block_id": block_id,
                "lane": block_id % len(lane_dirs),
                "path": str(block_path),
                "bytes": block_bytes,
                "packets": block_packets,
                "first_packet": first_packet,
            }
        )
    else:
        block_path.unlink(missing_ok=True)

    if packet_count == 0:
        raise SystemExit("stream file has no packet records")

    with block_list.open("w", encoding="utf-8", newline="") as fh:
        fh.write("block_id\tlane\tpath\tbytes\tpackets\tfirst_packet\n")
        for block in blocks:
            fh.write(
                f"{block['block_id']}\t{block['lane']}\t{block['path']}\t"
                f"{block['bytes']}\t{block['packets']}\t{block['first_packet']}\n"
            )

    manifest = {
        "generator": "stream_stripe.py",
        "source_manifest": str(args.manifest) if args.manifest else None,
        "source_stream_file": str(stream_path),
        "data_beat_bytes": DATA_BEAT_BYTES,
        "block_bytes_target": args.block_bytes,
        "block_list_file": str(block_list),
        "lane_count": len(lane_dirs),
        "lanes": [{"lane": idx, "dir": str(path)} for idx, path in enumerate(lane_dirs)],
        "block_count": len(blocks),
        "packet_count": packet_count,
        "stream_bytes": stream_bytes,
        "total_frame_bytes": total_frame_bytes,
        "input": source_manifest,
    }
    out_manifest.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
