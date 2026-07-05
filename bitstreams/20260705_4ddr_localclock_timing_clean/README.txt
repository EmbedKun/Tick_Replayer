Tick Replayer bitstream archive: 20260705_4ddr_localclock_timing_clean

Target
------
- Board: Xilinx Alveo U200
- Ports: dual 100G CMAC, QSFP0 and QSFP1
- DDR: all four U200 DDR4 banks enabled
- PCIe: XDMA Gen3 x16, memory-mapped H2C/C2H plus user BAR

Build
-----
- Source tree on the validation host: /home/user/tr_build_4ddr_localclock_src
- Build root on the validation host: /home/user/tr_build_4ddr_localclock_impl_addrinc
- Vivado: 2020.2
- Build options:
  - TRAFFIC_REPLAY_PORT_COUNT=2
  - TRAFFIC_REPLAY_DDR_BANKS=4
  - TRAFFIC_REPLAY_VIVADO_JOBS=8
  - TRAFFIC_REPLAY_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt

Architecture Notes
------------------
- Host XDMA can address four 16GiB DDR windows:
  - ddr4_0: 0x0000000000 .. 0x03ffffffff
  - ddr4_1: 0x0400000000 .. 0x07ffffffff
  - ddr4_2: 0x0800000000 .. 0x0bffffffff
  - ddr4_3: 0x0c00000000 .. 0x0fffffffff
- Port 0 TX reads from ddr4_0.
- Port 1 TX reads from ddr4_1.
- RX capture 0 writes samples to ddr4_2.
- RX capture 1 writes samples to ddr4_3.
- The four-bank build uses bank-local SmartConnect and bank-local DDR UI clock
  domains instead of a single large all-to-all DDR crossbar.
- The stream ring reader address path was changed from a wide base+offset
  combinational addition to an incrementing AXI address counter to close timing.

Timing
------
- Post-route physopt timing report: timing_summary_postroute_physopted.rpt
- WNS: +0.002 ns
- TNS: 0.000 ns
- WHS: +0.005 ns
- THS: 0.000 ns
- Vivado report: All user specified timing constraints are met.

Resource Snapshot
-----------------
- Block RAM Tile: 609 / 2160, 28.19%
- URAM: 0 / 960, 0.00%
- DSP: 12 / 6840, 0.18%

Board Validation Summary
------------------------
- PCIe endpoint enumerated as 10ee:903f, XDMA driver bound.
- After JTAG reprogramming, a PCIe remove/rescan was required before BAR reads
  and XDMA transfers returned valid data.
- H2C/C2H readback passed on all four low-address bank windows.
- H2C/C2H readback passed at the high end of all four 16GiB DDR windows.
- Single-port PRELOAD:
  - 64B gap=3: 70.399Gbps wire, no drop/late/underrun/stall.
  - 1518B gap=38: 97.389Gbps wire, no drop/late/underrun/stall.
- Dual-port PRELOAD:
  - 1518B gap=38 on both ports: 194.778Gbps aggregate wire, no drop/late/underrun/stall.
  - 64B gap=3 on both ports: 140.798Gbps aggregate wire, no drop/late/underrun/stall.
- STREAM ring:
  - 1518B gap=300 with C++ loader and writer_threads=2 passed at 12.144Gbps scheduled replay.
  - Higher requested STREAM rates exposed the current host/XDMA loader bottleneck and produced late/underrun events.
- RX loopback:
  - Low-rate TX/RX payload sample checks passed in both directions.
  - High-rate RX sample capture can overflow because the current sample writer is intentionally lightweight.
- RX SOP-to-SOP precision suite passed fixed-gap, mixed-gap, small-gap, mixed-size, and long-trace cases.

Files
-----
- traffic_replay_bd_wrapper.bit: bitstream
- traffic_replay_bd_wrapper.ltx: debug probes
- timing_summary_postroute_physopted.rpt: final timing report
- utilization_placed.rpt: resource report
- drc_routed.rpt: routed DRC report
