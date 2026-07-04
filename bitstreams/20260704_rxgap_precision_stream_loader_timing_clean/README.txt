Tick_Replayer bitstream archive
================================

Archive name:
  20260704_rxgap_precision_stream_loader_timing_clean

Remote build directory:
  /home/user/tr_build_rxgap_precision_20260704

Remote source snapshot:
  /home/user/traffic_replay_rxgap_20260704_src

Bitstream:
  traffic_replay_bd_wrapper.bit

SHA256:
  fdb6b704908dbdb715d5e45aa40a1a10ad72a148509b32ad61566954e0441703

LTX files:
  traffic_replay_bd_wrapper.ltx
  debug_nets.ltx

Timing:
  WNS = +0.024 ns
  TNS = 0.000 ns
  WHS = +0.001 ns
  THS = 0.000 ns
  All user specified timing constraints are met.

Resource summary:
  CLB LUTs       135886 / 1182240  = 11.49%
  CLB Registers  139967 / 2364480  = 5.92%
  BRAM Tiles        531.5 / 2160   = 24.61%
  URAM                 0 / 960     = 0.00%
  DSP                  3 / 6840    = 0.04%

Main changes represented by this archive:
  - RX-side SOP-to-SOP gap statistics for preload scheduling precision tests.
  - traffic_replay_cli.py can print RX gap statistics.
  - preload_rx_precision_check.py verifies TX0->RX1 loopback spacing from the RX side.
  - Host-side stream loader was optimized after this bitstream without changing hardware:
    fixed-record fast path.  More aggressive DMA buffer and parallel-pwrite
    experiments were rejected because correctness is more important than a
    small load-throughput gain.

Validation summary:
  - Vivado simulation passed for replay reader, core performance, dual-core performance,
    stream ring reader, and RX capture clear/gap statistics.
  - Full implementation is timing-clean at 300 MHz.
  - Board programmed through remote Vivado hardware server.
  - XDMA H2C/C2H DDR readback passed at several addresses.
  - RX-side preload gap precision passed:
    gap=3000 ticks: average error about -0.002 ns, min/max within about +/-9 ns.
    gap=300 ticks: average error about -0.002 ns, min/max within about +/-14 ns.
  - Raw XDMA H2C host-memory benchmark reached 83.675 Gbps with 2 threads over 8 GiB.
  - Final correctness-safe stream loader reached 12.956 Gbps in finite-buffer
    no-wait loading of a 1.6GB stream.

Known limitations:
  - Current hardware uses one DDR4/MIG bank, not the full 64 GB across four DDR banks.
  - Dynamic stream ring replay is loader-limited and does not reach 100 Gbps.
  - RX precision statistics are aggregate gap stats, not a full per-packet timestamp ring.
