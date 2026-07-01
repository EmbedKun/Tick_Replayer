Tick Replayer bitstream archive
================================

Version
-------
20260701_203500_dual_preload_gap38_mixed_timing_violation

Bitstream
---------
traffic_replay_bd_wrapper.bit

SHA256
------
9caa2ddf2dc9a0c1ad52955f4c1eb345d76974d5284cc8ccb36f4fcbd345ec72

Build root
----------
/home/user/tr_hw_20260701_203500_dual_lbus_syncreset

Build environment
-----------------
Vivado 2020.2 on the remote U200 host.

Timing
------
Bit generation completed, but this image is not timing-clean:

  WNS = -0.018 ns
  TNS = -0.228 ns
  setup failing endpoints = 21

Placed utilization
------------------
  CLB LUTs        135692 / 1182240 = 11.48%
  CLB Registers   143890 / 2364480 =  6.09%
  BRAM tiles       499.5 /    2160 = 23.13%
  URAM                 0 /     960 =  0.00%
  DSP                  3 /    6840 =  0.04%

Notes
-----
Dual-port PRELOAD experimental build with QSFP0 and QSFP1 connected by 100G
fiber.  The design includes the DDR trace reader command-head fix, deeper
payload prefetch, metadata staging in the scheduler, XPM FIFO timing cleanup,
and local reset synchronization in the AXIS-to-LBUS TX adapter.

This image is useful because it demonstrates a real CMAC loopback datapath
close to 100G for large packets and accurate mixed-packet scheduling.  It is
not a final release image because RX error counters are still nonzero in
large/mixed tests, small packets are limited by the one-packet-per-tick
scheduler, over-rate tests can leave the downstream TX path backpressured, and
post-route timing is still slightly negative.

Archived evidence
-----------------
  traffic_replay_bd_wrapper.bit
  traffic_replay_bd_wrapper.ltx
  debug_nets.ltx
  impl_runme.log
  traffic_replay_bd_wrapper_timing_summary_postroute_physopted.rpt
  traffic_replay_bd_wrapper_utilization_placed.rpt
  traffic_replay_bd_wrapper_route_status.rpt
  traffic_replay_bd_wrapper_bus_skew_postroute_physopted.rpt
  preload_gap_sweep_1518B.json
  preload_small_sweep_64B.json
  preload_mixed_120k.json
  reader_perf_sim.log
  core_perf_sim.log
  dual_core_perf_sim.log
  lbus_adapter_sim.log
