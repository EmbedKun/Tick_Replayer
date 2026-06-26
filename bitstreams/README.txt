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
    bitgen completed successfully with routed timing met.  This is the current
    hardware-tested STREAM mode image.
