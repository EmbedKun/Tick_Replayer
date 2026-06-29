#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run_vivado.sh ACTION [BITFILE]

Actions:
  sim             run RTL simulation
  synth           run syntax/synthesis check
  hwbd            create the Vivado hardware project
  hwbit           create the hardware project and build a bitstream
  hwbit_existing  build a bitstream from an existing hardware project
  rerun_impl      rerun implementation from completed synthesis
  program         program the remote FPGA target; BITFILE is required

Environment:
  XILINX_VIVADO                  Vivado installation root, for example /tools/Xilinx/Vivado/2020.2
  VIVADO_BIN                     Optional Vivado executable override
  TRAFFIC_REPLAY_HW_BUILD_ROOT   Optional build root, defaults to <repo>/build
  TRAFFIC_REPLAY_PORT_COUNT      Optional hardware port count: 1 or 2, defaults to 2
  TRAFFIC_REPLAY_VIVADO_JOBS     Optional Vivado run job count
  TRAFFIC_REPLAY_IMPL_STRATEGY   Optional implementation strategy
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

action="$1"
shift || true

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

if [[ -z "${TRAFFIC_REPLAY_HW_BUILD_ROOT:-}" ]]; then
  export TRAFFIC_REPLAY_HW_BUILD_ROOT="$repo_dir/build"
fi

vivado_bin="${VIVADO_BIN:-}"
if [[ -z "$vivado_bin" && -n "${XILINX_VIVADO:-}" && -x "$XILINX_VIVADO/bin/vivado" ]]; then
  vivado_bin="$XILINX_VIVADO/bin/vivado"
fi
if [[ -z "$vivado_bin" ]]; then
  vivado_bin="vivado"
fi
if ! command -v "$vivado_bin" >/dev/null 2>&1; then
  echo "ERROR: Vivado executable not found." >&2
  echo "Source settings64.sh or set XILINX_VIVADO/VIVADO_BIN first." >&2
  exit 1
fi

mkdir -p "$TRAFFIC_REPLAY_HW_BUILD_ROOT"

case "$action" in
  sim)
    "$vivado_bin" -mode batch -source "$script_dir/run_sim.tcl"
    ;;
  synth)
    "$vivado_bin" -mode batch -source "$script_dir/synth_check.tcl"
    ;;
  hwbd)
    "$vivado_bin" -mode batch -source "$script_dir/create_hw_project.tcl"
    ;;
  hwbit)
    "$vivado_bin" -mode batch -source "$script_dir/build_hw_bitstream.tcl"
    ;;
  hwbit_existing)
    "$vivado_bin" -mode batch -source "$script_dir/build_existing_hw_bitstream.tcl"
    ;;
  rerun_impl)
    "$vivado_bin" -mode batch -source "$script_dir/rerun_hw_impl.tcl"
    ;;
  program)
    if [[ $# -ne 1 ]]; then
      echo "ERROR: program requires BITFILE." >&2
      usage
      exit 1
    fi
    "$vivado_bin" -mode batch -source "$script_dir/program_remote.tcl" -tclargs "$1"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "ERROR: unknown action: $action" >&2
    usage
    exit 1
    ;;
esac
