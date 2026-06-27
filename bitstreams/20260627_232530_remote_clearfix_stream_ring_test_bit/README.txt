Traffic Replay FPGA Bitstream Archive
=====================================

Version name:
  20260627_232530_remote_clearfix_stream_ring_test_bit

Purpose:
  Remote Vivado 2020.2 build for the stream/ring replay version with the
  start/clear replay-running fix. This is the first bitstream generated after
  making clear_pulse reset replay_running and after adding stream loader
  timeout/cleanup robustness in the host tools.

Build host:
  user@172.22.5.106

Build root:
  /home/user/tr_build_remote_clearfix

Remote source snapshot:
  /home/user/traffic_replay_remote_src

Vivado command:
  TRAFFIC_REPLAY_HW_BUILD_ROOT=/home/user/tr_build_remote_clearfix
  TRAFFIC_REPLAY_ENABLE_ILA=0
  TRAFFIC_REPLAY_VIVADO_JOBS=1
  TRAFFIC_REPLAY_IMPL_STRATEGY=Performance_ExplorePostRoutePhysOpt
  vivado -mode batch -source scripts/build_hw_bitstream.tcl

Generated files:
  traffic_replay_bd_wrapper.bit
  traffic_replay_bd_wrapper.ltx
  debug_nets.ltx

SHA256:
  bit: ef91e5a35bb081f0a738ac48a99874dd838b98e3f10ad6c74ec4f8931611aa93
  ltx: 9a2dabfebb84bd0ce9816ce4108ae21e7f8bc7ad8b335c713fab85a0b0a98de8

Implementation result:
  Synthesis: complete
  Implementation: write_bitstream Complete
  Bitgen: completed successfully
  DRC before bitgen: 0 Errors, 1 Warning, 22 Advisories
  Route status: 277340 routable nets, 277340 fully routed, 0 routing errors

Timing:
  Final report: hw_impl_timing_summary.rpt
  WNS = -0.229 ns
  TNS = -552.917 ns
  WHS = 0.001 ns
  THS = 0.000 ns
  Status: Timing constraints are not met.

Notes:
  This bitstream is usable for hardware functional testing and throughput
  characterization, but it is not a fully timing-closed release. Timing
  violations are mainly in the high-speed replay/DDR/XDMA/CMAC region and
  should be optimized before treating this as a production image.

Important source changes included:
  - trace_replay_core.sv: clear_pulse now clears replay_running.
  - ddr_stream_reader.sv: stream-ring burst setup is pipelined before AXI AR.
  - rx_capture_bd_core.sv: RX byte/stat clear paths were registered.
  - build_hw_bitstream.tcl: implementation strategy defaults to
    Performance_ExplorePostRoutePhysOpt and supports an environment override.

Archived reports:
  build.log
  impl_runme.log
  hw_impl_timing_summary.rpt
  hw_impl_utilization.rpt
  hw_synth_timing_summary.rpt
  traffic_replay_bd_wrapper_route_status.rpt
  traffic_replay_bd_wrapper_drc_routed.rpt
  traffic_replay_bd_wrapper_methodology_drc_routed.rpt
  traffic_replay_bd_wrapper_timing_summary_postroute_physopted.rpt
  traffic_replay_bd_wrapper_bus_skew_postroute_physopted.rpt

Hardware validation:
  Test date:
    2026-06-27 / 2026-06-28 CST

  Target:
    Remote U200 host 172.22.5.106, QSFP0 and QSFP1 connected by 100G fiber.

  Report archive:
    reports/20260628_remote_validation_stream_ring/

  Programming and PCIe:
    JTAG programming passed.
    PCIe rescan passed.
    Device enumerated as 10ee:903f.
    XDMA driver loaded and created /dev/xdma0_h2c_0, /dev/xdma0_c2h_0,
    /dev/xdma0_user, and /dev/xdma0_xvc.

  Basic correctness:
    XDMA H2C/C2H DDR readback passed across 0x00000000, 0x00100000, and
    0x10000000 test regions.
    Smoke profile passed.
    Stress profile passed.
    Low-rate TX0 -> RX1 optical loopback passed with 1000/1000 packets.

  Finite STREAM throughput, zero-gap synthetic TX0, 100000 packets:
    64B   : 38.388 Gbps, complete
    128B  : 61.409 Gbps, complete
    256B  : 77.289 Gbps, complete
    512B  : 88.371 Gbps, complete
    1024B : 94.190 Gbps, complete
    1518B : 95.518 Gbps, complete

  DDR ring STREAM:
    200000 packets, 1518B, gap_ticks=15000:
      complete, TX packets matched, late=0, underrun=0, replay=0.243 Gbps.

    50000-packet gap sweep, 1518B:
      gap_ticks=8000 was the fastest no-underrun point measured in this run
      at about 0.455 Gbps. gap_ticks=6000 and 4000 completed but reported
      late and underrun events.

  Robustness finding:
    A 500000-packet finite STREAM long sweep exposed a recovery issue. 64B,
    128B, and 256B completed; 512B timed out after 481174 packets; subsequent
    1024B and 1518B cases transmitted 0 packets. Normal stop/clear did not
    restore TX, while reprogramming the same bitstream and rescanning PCIe did.
    This indicates that clear should be strengthened into a full per-port
    replay-path soft reset before this image is treated as production-ready.
