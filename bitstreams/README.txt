Traffic Replay Bitstream Archive
================================

Important generated bitstreams are stored under this directory.  Each archived
version should live in its own timestamped subdirectory and include a matching
TXT note file with the source commit, SHA256 hash, build path, and verification
status.

Recommended command from PowerShell:

  powershell -ExecutionPolicy Bypass -File scripts\archive_bitstream.ps1 `
    -Bitfile D:\tr_build_dual\vivado_hw\traffic_replay_hw.runs\impl_1\traffic_replay_bd_wrapper.bit `
    -Name dual_qsfp_loop_verified `
    -BuildRoot D:\tr_build_dual `
    -Notes "H2C/C2H DDR readback passed; TX0->RX1 and TX1->RX0 loopback passed."

Archived versions currently kept in this repository:

  20260626_194501_pre_stream_dual_qsfp_loop_verified
    Dual-QSFP preload/loop bring-up image with optical loop verification.

  20260626_212201_stream_ddr_buffer_dual_qsfp_impl
    First DDR-backed STREAM mode implementation image.

  20260627_014343_stream_prefetch_lutram_fifo_dual_qsfp_impl
    Restored LUTRAM stream-prefetch FIFO image.  Vivado implementation and
    bitgen completed successfully with routed timing met.  This is a
    hardware-tested STREAM mode image.

  20260701_203500_dual_preload_gap38_mixed_timing_violation
    Dual-port PRELOAD experimental image.  Bitgen completed, but timing is
    slightly negative (WNS=-0.018 ns).  QSFP0->QSFP1 loopback reached
    97.386Gbps wire-estimated throughput for 1518B packets at gap=38 and
    96.158Gbps for a mixed-size trace with only +11 tick schedule error.
    RX error counters and over-rate recovery still need RTL cleanup.
