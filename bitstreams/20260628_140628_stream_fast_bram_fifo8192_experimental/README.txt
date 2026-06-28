Tick Replayer bitstream archive
================================

Version
-------
20260628_140628_stream_fast_bram_fifo8192_experimental

Purpose
-------
Experimental STREAM-mode performance build.

Main changes included in this bitstream:
- STREAM prefetch FIFO depth increased to 8192 beats per replay port.
- Large AXI-Stream FIFO implementation changed from register/LUTRAM storage to Xilinx XPM block-RAM FIFO.
- DDR stream reader configured for 128-beat AXI read bursts in the replay core source.
- Built without debug ILA.

Build
-----
Remote host: 172.22.5.106
Vivado: 2020.2
Build root:
  /home/user/tr_build_stream_fast_bram_fifo8192_20260628_120119
Build log:
  build.log

Bitstream
---------
traffic_replay_bd_wrapper.bit
traffic_replay_bd_wrapper.ltx

Timing
------
Implementation completed and bitstream generation succeeded.

Final timing summary:
- WNS: -0.247 ns
- TNS: -51.325 ns
- WHS: 0.000 ns
- THS: 0.000 ns

This is not a timing-clean release.  It is kept as an experimental hardware
checkpoint for STREAM-mode functional and throughput testing.

Post-programming checks
----------------------
The bitstream was programmed on the remote U200 board through hw_server.
After programming, the XDMA driver was reloaded from:
  /home/user/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko

Basic checks performed:
- XDMA H2C/C2H DDR readback: PASS.
- STREAM ring smoke, 1000 packets, 1518-byte frames, gap=30000 ticks:
  PASS, tx_packets=1000, late=0, underrun=0.
- Synthetic PCAP -> trace -> stream -> STREAM ring replay:
  PASS, tx_packets=10000, underrun=0.
- QSFP0 TX to QSFP1 RX low-rate loopback:
  RX observed 2000 packets.

Measured behavior
-----------------
STREAM ring dynamic mode, 100000 packets, 1518-byte frames:
- gap=720 ticks: 5.060 Gbps, late=0, underrun=0.
- gap=600 ticks: 6.072 Gbps, late=0, underrun=0.
- gap=480 ticks: 7.590 Gbps, late=0, underrun=0.
- gap=360 ticks: 10.120 Gbps target, late and underrun observed.

Finite STREAM buffer mode, 100000 packets, 1518-byte frames:
- gap=0 ticks: about 96.98 Gbps TX byte rate, but late/underrun counters assert
  because this is a maximum-throughput stress case rather than a precision
  timestamp replay case.

Interpretation
--------------
The C++ host loader and BRAM FIFO hardware improve the STREAM path, but the
current dynamic ring implementation is still limited by memory-mapped XDMA
pwrite into FPGA DDR and by the single-reader DDR stream path.  Sustained
100Gbps dynamic replay requires a future AXI4-Stream H2C/QDMA-style ingestion
path and more aggressive FPGA-side prefetch/outstanding-read architecture.
