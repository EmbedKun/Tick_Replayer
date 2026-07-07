#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export TRAFFIC_REPLAY_PORT_COUNT="${TRAFFIC_REPLAY_PORT_COUNT:-2}"
export TRAFFIC_REPLAY_DDR_BANKS="${TRAFFIC_REPLAY_DDR_BANKS:-4}"
export TRAFFIC_REPLAY_PORT0_MULTI_DDR="${TRAFFIC_REPLAY_PORT0_MULTI_DDR:-0}"
export TRAFFIC_REPLAY_HW_BUILD_ROOT="${TRAFFIC_REPLAY_HW_BUILD_ROOT:-$repo_dir/build_hw_4ddr_dual}"

vivado -mode batch -source "$repo_dir/scripts/build_hw_bitstream.tcl"
