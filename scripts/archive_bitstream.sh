#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/archive_bitstream.sh --bitfile FILE --name NAME [options]

Options:
  --ltx FILE          matching probes file
  --build-root DIR    Vivado build root recorded in README.txt
  --notes TEXT        short verification/build note
  --out-dir DIR       archive directory, defaults to bitstreams/
EOF
}

bitfile=""
ltxfile=""
name=""
build_root=""
notes=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bitfile) bitfile="$2"; shift 2 ;;
    --ltx) ltxfile="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --build-root) build_root="$2"; shift 2 ;;
    --notes) notes="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$bitfile" || -z "$name" ]]; then
  usage
  exit 1
fi
if [[ ! -f "$bitfile" ]]; then
  echo "ERROR: bitfile not found: $bitfile" >&2
  exit 1
fi
if [[ -n "$ltxfile" && ! -f "$ltxfile" ]]; then
  echo "ERROR: ltx file not found: $ltxfile" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
if [[ -z "$out_dir" ]]; then
  out_dir="$repo_dir/bitstreams"
fi

stamp="$(date +%Y%m%d_%H%M%S)"
archive_dir="$out_dir/${stamp}_${name}"
mkdir -p "$archive_dir"

cp "$bitfile" "$archive_dir/traffic_replay_bd_wrapper.bit"
if [[ -n "$ltxfile" ]]; then
  cp "$ltxfile" "$archive_dir/traffic_replay_bd_wrapper.ltx"
fi

sha256="$(sha256sum "$archive_dir/traffic_replay_bd_wrapper.bit" | awk '{print $1}')"

cat > "$archive_dir/README.txt" <<EOF
Tick Replayer bitstream archive
================================

Version
-------
${stamp}_${name}

Bitstream
---------
traffic_replay_bd_wrapper.bit

SHA256
------
$sha256

Build root
----------
${build_root:-not recorded}

Notes
-----
${notes:-not recorded}
EOF

echo "Archived bitstream at $archive_dir"
