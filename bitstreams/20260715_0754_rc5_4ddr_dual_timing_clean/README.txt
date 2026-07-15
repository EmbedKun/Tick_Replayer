Tick Replayer bitstream archive
================================

Version
-------
20260715_0754_rc5_4ddr_dual_timing_clean

Target
------
Board: Xilinx Alveo U200
Device: xcu200-fsgd2104-2
Build: dual-port, four DDR banks enabled
Vivado: 2020.2 on the remote Linux build host

Files
-----
traffic_replay_bd_wrapper.bit
    FPGA bitstream.

traffic_replay_bd_wrapper.ltx
    Vivado hardware debug probes.

hw_impl_timing_summary.rpt
    Routed timing report.

hw_impl_utilization.rpt
    Routed utilization report.

program.log
    Remote programming log.

Build Summary
-------------
The design was rebuilt from the RC5 timing patch RTL and programmed on the
remote U200 host.  The implementation is timing clean:

WNS = +0.006 ns
TNS = 0.000 ns
WHS = +0.006 ns
THS = 0.000 ns

Resource Summary
----------------
CLB LUTs        239471 / 1182240  20.26%
CLB Registers   308427 / 2364480  13.04%
Block RAM Tile     842 / 2160     38.98%
URAM               256 / 960      26.67%
DSPs                12 / 6840      0.18%

Validation Summary
------------------
The board validation run is documented in:

docs/evaluation_20260715_rc5_board_validation.md

Key results:

- XDMA H2C/C2H DDR readback passed on DDR0, DDR1, DDR2, and DDR3 windows.
- Single-port PRELOAD passed 1518B/gap38 at 95.873 Gbps L2.
- Single-port PRELOAD passed 64B/gap3 at 51.200 Gbps L2.
- Dual-port PRELOAD passed 1518B/gap38 at 191.746 Gbps aggregate L2.
- Dual-port PRELOAD passed 64B/gap3 at 102.399 Gbps aggregate L2.
- LOOP mode passed 100 packets x 3 loops with no late, underrun, or drop.
- STREAM single-bank correctness-safe test passed 500k x 1518B/gap800.
- TX0 to RX1 optical-loopback payload sample verification passed.
- RX-side replay precision suite passed all cases.

Known Limitation
----------------
This dual-port release assigns port 0 replay reads to DDR0 and port 1 replay
reads to DDR1.  Host XDMA can write all four DDR banks, but a port 0 STREAM
ping-pong ring spanning DDR0 and DDR1 requires a single-port or multi-DDR
port-0 build.  Attempting port 0 ping-pong in this dual-port build correctly
returns an AXI read-response error when the port 0 reader addresses DDR1.
