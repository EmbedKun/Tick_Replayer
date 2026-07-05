Tick Replayer bitstream archive
================================

Name
----
20260705_stream_boost_1p_timing_clean

Purpose
-------
Single-port U200 STREAM-ring boost build used for host dual-SSD + XDMA H2C
testing.  This build keeps one replay interface and one U200 DDR bank enabled
to reduce routing pressure while validating the higher-throughput STREAM path.

Main hardware changes
---------------------
* ddr_stream_reader supports multiple outstanding AXI read bursts.
* STREAM replay start is gated until the DDR prefetch FIFO has warmed.
* The build was generated with:
  TRAFFIC_REPLAY_PORT_COUNT=1
  TRAFFIC_REPLAY_DDR_BANKS=1
  TRAFFIC_REPLAY_VIVADO_JOBS=8

Timing
------
Vivado 2020.2 implementation completed through write_bitstream.
Post-route timing:
  WNS = +0.024 ns
  TNS =  0.000 ns
  WHS = +0.010 ns
  THS =  0.000 ns

Board validation summary
------------------------
Remote U200 host: 172.22.5.106
XDMA device: /dev/xdma0_*

STREAM ring, 1518B packets:
* 1,000,000 packets, gap=38 ticks, full prefill:
  tx_packets=1,000,000, late=0, underrun=0, drop=0, hw_gbps=95.874.
* 5,000,000 packets, gap=38 ticks, 12GB ring/full prefill:
  tx_packets=5,000,000, late=0, underrun=0, drop=0, hw_gbps=95.874.
* 1,000,000 packets, gap=36 ticks, full prefill:
  tx_packets=1,000,000, late=0, underrun=0, drop=0, hw_gbps=101.200.
* 5,000,000 packets, gap=38 ticks, 8GB ring/dynamic refill:
  tx_packets=5,000,000, hw_gbps=55.306, late/underrun observed because the
  current memory-mapped XDMA pwrite loader refills at about 14.6Gbps.

Host-side finding
-----------------
Dual-SSD dry-run read/reorder reached 26.828Gbps on the generated 8GB striped
dataset.  Real XDMA H2C loading reached roughly 14.6-15.6Gbps in the same test
family, so sustained 100G dynamic STREAM replay is still limited by the current
memory-mapped XDMA H2C submission path rather than the FPGA replay scheduler.

Files
-----
traffic_replay_bd_wrapper.bit
traffic_replay_bd_wrapper.ltx
hw_impl_timing_summary.rpt
timing_summary_routed.rpt
route_status.rpt

SHA256
------
traffic_replay_bd_wrapper.bit:
9a4f71b3efe83f09768160dd5a57e627da314b88c3f7a68a9dc389c972391d25
