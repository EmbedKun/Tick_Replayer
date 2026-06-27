Traffic Replay bitstream archive
================================

Build time: 2026-06-27 18:33:47
Build root: D:\tr_build_ring_pipelined
Vivado: 2020.2
Target: Xilinx Alveo U200, xcu200-fsgd2104-2-e
ILA: disabled

Purpose
-------
Experimental high-throughput DDR ring stream build.

Important implementation changes in this version:
- DDR stream reader uses a pipelined PREP/AR/R state machine.
- Host-visible stream ring status is registered before AXI-Lite readback.
- Core mode select signals are registered to cut configuration-to-data-path fanout.
- RX capture byte accounting is pipelined by one clock.
- Vivado implementation strategy is set to Performance_ExplorePostRoutePhysOpt.
- STREAM FIFO depth is 2048 beats and DDR stream read burst length is 128 beats.

Route status
------------
All routable nets are fully routed.
Routing errors: 0.
DRC: 0 errors.

Timing status
-------------
Post-route timing does not fully meet constraints:
- WNS: -0.098 ns
- TNS: -47.187 ns
- Setup failing endpoints: 1263
- Hold failing endpoints: 0

This bitstream is suitable for hardware bring-up and performance experiments, but
it should not be treated as the final long-duration reliability image. The
remaining violations are small and mainly around hard IP / DDR / capture timing
closure. A future timing-clean release should either continue physical
optimization on the remote build host or reduce/decouple the high-speed RX
capture pressure.
