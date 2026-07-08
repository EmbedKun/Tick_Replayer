Tick Replayer bitstream archive
================================

Version
-------
20260708_040647_4ddr_dual_prefetch_timing_clean

Target
------
Xilinx Alveo U200, dual QSFP/CMAC build, four DDR4 banks enabled.

Build configuration
-------------------
- TRAFFIC_REPLAY_PORT_COUNT=2
- TRAFFIC_REPLAY_DDR_BANKS=4
- TRAFFIC_REPLAY_PORT0_MULTI_DDR=0
- Implementation strategy: Performance_ExplorePostRoutePhysOpt
- Vivado: 2020.2 on the remote Linux build host

Address map intent
------------------
- DDR bank 0: port 0 replay descriptors and payload
- DDR bank 1: port 1 replay descriptors and payload
- DDR bank 2: port 0 RX sample/capture region
- DDR bank 3: port 1 RX sample/capture region

Main hardware changes
---------------------
- Enabled the default four-DDR-bank hardware build.
- Added AXI register slices in front of DDR banks 1/2/3 to balance bank-local timing.
- Increased replay reader prefetch depth and outstanding DDR read capacity.
- Added registered payload and metadata stages in the DDR trace reader.
- Increased AXI-Stream FIFO read-side output buffering for timing and throughput.

Post-route timing
-----------------
- WNS: +0.010 ns
- TNS: 0.000 ns
- WHS: +0.006 ns
- THS: 0.000 ns
- All user specified timing constraints are met.
- Route status: 537900/537900 routable nets fully routed, 0 routing errors.
- Bus skew constraints: MET.

Placed utilization
------------------
- CLB LUTs: 243083 / 1182240, 20.56%
- CLB registers: 283137 / 2364480, 11.97%
- Block RAM tiles: 732 / 2160, 33.89%
- URAM: 0 / 960, 0.00%
- DSPs: 12 / 6840, 0.18%

Warnings
--------
- Vivado reports an evaluation license critical warning for licensed Xilinx IP.
- DRC advisories are Xilinx IP BRAM WRITE_FIRST collision advisories.
- No route errors and no timing violations were reported.

Bitstream
---------
traffic_replay_bd_wrapper.bit

Bitstream SHA256
----------------
1621b5656ce4aaa5ff3ec2da5b9654f69b32673b17ec49a8b733444b3ce9a3c6

LTX SHA256
----------
fdb462c913475fc3ea07a028e375a52fd07b7fd673b7f91a94c8df992a918697

Remote build root
-----------------
/home/user/tr_4ddr_timingfix_runs/bd_4ddr_dual_20260708_001610

Included reports
----------------
- traffic_replay_bd_wrapper_timing_summary_routed.rpt
- traffic_replay_bd_wrapper_timing_summary_postroute_physopted.rpt
- traffic_replay_bd_wrapper_utilization_placed.rpt
- traffic_replay_bd_wrapper_route_status.rpt
- traffic_replay_bd_wrapper_bus_skew_routed.rpt
- traffic_replay_bd_wrapper_drc_routed.rpt
- traffic_replay_bd_wrapper_methodology_drc_routed.rpt
- vivado_create.log
- vivado_synth.log
- vivado_impl.log
- runme.log
